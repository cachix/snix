{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE QuasiQuotes #-}

module HtmxExperiment where

import Control.Category qualified as Cat
import Control.Exception qualified as Exc
import Control.Monad.Logger
import Control.Selective (Selective (select))
import Control.Selective qualified as Selective
import Data.ByteString qualified as Bytes
import Data.DList (DList)
import Data.Functor.Compose
import Data.List qualified as List
import Data.Maybe (maybeToList)
import Data.Maybe qualified as Maybe
import Data.Monoid qualified as Monoid
import Data.Text qualified as Text
import FieldParser hiding (nonEmpty)
import IHP.HSX.QQ (hsx)
import Label
import Multipart2 (FormValidation (FormValidation), FormValidationResult, MultipartParseT, failFormValidation)
import Multipart2 qualified as Multipart
import Network.HTTP.Types qualified as Http
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp qualified as Warp
import PossehlAnalyticsPrelude
import ServerErrors (ServerError (..), throwUserErrorTree)
import Text.Blaze.Html5 (Html, docTypeHtml)
import Text.Blaze.Renderer.Utf8 (renderMarkup)
import UnliftIO (MonadUnliftIO (withRunInIO))
import Prelude hiding (compare)

-- data Routes
--   = Root
--   | Register
--   | RegisterSubmit

-- data Router url = Router
--   { parse :: Routes.URLParser url,
--     print :: url -> [Text]
--   }

-- routerPathInfo :: Routes.PathInfo a => Router a
-- routerPathInfo =
--   Router
--     { parse = Routes.fromPathSegments,
--       print = Routes.toPathSegments
--     }

-- subroute :: Text -> Router subUrl -> Router subUrl
-- subroute path inner =
--   Router
--     { parse = Routes.segment path *> inner.parse,
--       print = \url -> path : inner.print url
--     }

-- routerLeaf :: a -> Router a
-- routerLeaf a =
--   Router
--     { parse = pure a,
--       print = \_ -> []
--     }

-- routerToSite ::
--   ((url -> [(Text, Maybe Text)] -> Text) -> url -> a) ->
--   Router url ->
--   Routes.Site url a
-- routerToSite handler router =
--   Routes.Site
--     { handleSite = handler,
--       formatPathSegments = (\x -> (x, [])) . router.print,
--       parsePathSegments = Routes.parseSegments router.parse
--     }

-- handlers queryParams = \case
--   Root -> "root"
--   Register -> "register"
--   RegisterSubmit -> "registersubmit"

newtype Router handler from to = Router {unRouter :: from -> [Text] -> (Maybe handler, to)}
  deriving
    (Functor, Applicative)
    via ( Compose
            ((->) from)
            ( Compose
                ((->) [Text])
                ((,) (Monoid.First handler))
            )
        )

data Routes r handler = Routes
  { users :: r (Label "register" handler)
  }

data Endpoint handler subroutes = Endpoint
  { root :: handler,
    subroutes :: subroutes
  }
  deriving stock (Show, Eq)

data Handler = Handler {url :: Text}

-- myRoute :: Router () from (Endpoint (Routes (Endpoint ()) Handler) b)
-- myRoute =
--   root $ do
--     users <- fixed "users" () $ fixedFinal @"register" ()
--     pure $ Routes {..}

-- -- | the root and its children
-- root :: routes from a -> routes from (Endpoint a b)
-- root = todo

-- | A fixed sub-route with children
fixed :: Text -> handler -> Router handler from a -> Router handler from (Endpoint handler a)
fixed route handler inner = Router $ \from -> \case
  [final]
    | route == final ->
        ( Just handler,
          Endpoint
            { root = handler,
              subroutes = (inner.unRouter from []) & snd
            }
        )
  (this : more)
    | route == this ->
        ( (inner.unRouter from more) & fst,
          Endpoint
            { root = handler,
              subroutes = (inner.unRouter from more) & snd
            }
        )
  _ -> (Nothing, Endpoint {root = handler, subroutes = (inner.unRouter from []) & snd})

-- integer ::
--   forall routeName routes from a.
--   Router (T2 routeName Integer "more" from) a ->
--   Router from (Endpoint () a)
-- integer inner = Router $ \case
--   (path, []) ->
--     runFieldParser Field.signedDecimal path
--   (path, more) ->
--     inner.unRouter more (runFieldParser Field.signedDecimal path)

-- -- | A leaf route
-- fixedFinal :: forall route handler from. (KnownSymbol route) => handler -> Router handler from (Label route Handler)
-- fixedFinal handler = do
--   let route = symbolText @route
--   Rounter $ \from -> \case
--     [final] | route == final -> (Just handler, label @route (Handler from))
--     _ -> (Nothing, label @route handler)

main :: IO ()
main = runStderrLoggingT @IO $ do
  withRunInIO @(LoggingT IO) $ \runInIO -> do
    Warp.run 8080 $ \req respond -> catchServerError respond $ do
      let respondOk res = Wai.responseLBS Http.ok200 [] (renderMarkup res)
      let htmlRoot inner =
            docTypeHtml
              [hsx|
            <head>
              <script src="https://unpkg.com/htmx.org@1.9.2" integrity="sha384-L6OqL9pRWyyFU3+/bjdSri+iIphTN/bvYyM37tICVyOJkWZLpP2vGn6VUEXgzg6h" crossorigin="anonymous"></script>
            </head>
            <body>
              {inner}
            </body>
        |]
      res <-
        case req & Wai.pathInfo of
          [] ->
            pure $
              respondOk $
                htmlRoot
                  [hsx|
                      <div id="register_buttons">
                        <button hx-get="/register" hx-target="body" hx-push-url="/register">Register an account</button>
                        <button hx-get="/login" hx-target="body">Login</button>
                      </div>
              |]
          ["register"] ->
            pure $ respondOk $ fullEndpoint req $ \case
              FullPage -> htmlRoot $ registerForm mempty
              Snippet -> registerForm mempty
          ["register", "submit"] -> do
            FormValidation body <-
              req
                & parsePostBody
                  registerFormValidate
                & runInIO
            case body of
              -- if the parse succeeds, ignore any of the data
              (_, Just a) -> pure $ respondOk $ htmlRoot [hsx|{a}|]
              (errs, Nothing) -> pure $ respondOk $ htmlRoot $ registerForm errs
          other ->
            pure $ respondOk [hsx|no route here at {other}|]
      respond $ res
  where
    catchServerError respond io =
      Exc.catch io (\(ex :: ServerError) -> respond $ Wai.responseLBS ex.status [] ex.errBody)

parsePostBody ::
  (MonadIO m, MonadThrow m, MonadLogger m) =>
  MultipartParseT m b ->
  Wai.Request ->
  m b
parsePostBody parser req =
  Multipart.parseMultipartOrThrow throwUserErrorTree parser req

-- migrate :: IO (Label "numberOfRowsAffected" Natural)
-- migrate =
--   Init.runAppTest $ do
--     runTransaction $
--       execute
--         [sql|
--         CREATE TABLE IF NOT EXISTS experiments.users (
--           id SERIAL PRIMARY KEY,
--           email TEXT NOT NULL,
--           registration_pending_token TEXT NULL
--         )
--         |]
--         ()

data HsxRequest
  = Snippet
  | FullPage

fullEndpoint :: Wai.Request -> (HsxRequest -> t) -> t
fullEndpoint req act = do
  let isHxRequest = req & Wai.requestHeaders & List.find (\h -> (h & fst) == "HX-Request") & Maybe.isJust
  if isHxRequest
    then act Snippet
    else act FullPage

data FormField = FormField
  { label_ :: Html,
    required :: Bool,
    id_ :: Text,
    name :: ByteString,
    type_ :: Text,
    placeholder :: Maybe Text
  }

inputHtml ::
  FormField ->
  DList FormValidationResult ->
  Html
inputHtml (FormField {..}) validationResults = do
  let validation =
        validationResults
          & toList
          & mapMaybe
            ( \v ->
                if v.formFieldName == name
                  then
                    Just
                      ( T2
                          (label @"errors" (maybeToList v.hasError))
                          (label @"originalValue" (Monoid.First (Just v.originalValue)))
                      )
                  else Nothing
            )
          & mconcat
  let isFirstError =
        validationResults
          & List.find (\res -> Maybe.isJust res.hasError && res.formFieldName == name)
          & Maybe.isJust
  [hsx|
      <label for={id_}>{label_}
        <input
          autofocus={isFirstError}
          onfocus="this.select()"
          required={required}
          id={id_}
          name={name}
          type={type_}
          placeholder={placeholder}
          value={validation.originalValue.getFirst}
        />
        <p id="{id_}.validation">{validation.errors & nonEmpty <&> toList <&> map prettyError <&> Text.intercalate "; "}</p>
      </label>
  |]

registerForm :: DList FormValidationResult -> Html
registerForm validationErrors =
  let fields =
        mconcat
          [ inputHtml $
              FormField
                { label_ = "Your Email:",
                  required = True,
                  id_ = "register_email",
                  name = "email",
                  type_ = "email",
                  placeholder = Just "your@email.com"
                },
            inputHtml $
              FormField
                { label_ = "New password:",
                  required = True,
                  id_ = "register_password",
                  name = "password",
                  type_ = "password",
                  placeholder = Just "hunter2"
                },
            inputHtml $
              FormField
                { label_ = "Repeated password:",
                  required = True,
                  id_ = "register_password_repeated",
                  name = "password_repeated",
                  type_ = "password",
                  placeholder = Just "hunter2"
                }
          ]
   in [hsx|
  <form hx-post="/register/submit">
    <fieldset>
      <legend>Register user</legend>
      {fields validationErrors}
      <button id="register_submit_button" name="register">
        Register
      </button>
    </fieldset>
  </form>
  |]

registerFormValidate ::
  (Applicative m) =>
  MultipartParseT
    m
    (FormValidation (T2 "email" ByteString "password" ByteString))
registerFormValidate = do
  let emailFP = FieldParser $ \b ->
        if
          | Bytes.elem (charToWordUnsafe '@') b -> Right b
          | otherwise -> Left [fmt|This is not an email address: "{b & bytesToTextUtf8Unsafe}"|]

  getCompose @(MultipartParseT _) @FormValidation $ do
    email <- Compose $ Multipart.fieldLabel' @"email" "email" emailFP
    password <-
      aEqB
        "password_repeated"
        "The two password fields must be the same"
        (Compose $ Multipart.field' "password" Cat.id)
        (\field -> Compose $ Multipart.field' field Cat.id)
    pure $ T2 email (label @"password" password)
  where
    aEqB field validateErr fCompare fValidate =
      Selective.fromMaybeS
        -- TODO: this check only reached if the field itself is valid. Could we combine those errors?
        (Compose $ pure $ failFormValidation (T2 (label @"formFieldName" field) (label @"originalValue" "")) validateErr)
        $ do
          compare <- fCompare
          validate <- fValidate field
          pure $ if compare == validate then Just validate else Nothing

-- | A lifted version of 'Data.Maybe.fromMaybe'.
fromMaybeS :: (Selective f) => f a -> f (Maybe a) -> f a
fromMaybeS ifNothing fma =
  select
    ( fma <&> \case
        Nothing -> Left ()
        Just a -> Right a
    )
    ( do
        a <- ifNothing
        pure (\() -> a)
    )
