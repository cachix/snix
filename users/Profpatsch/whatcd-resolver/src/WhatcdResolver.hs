{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE QuasiQuotes #-}

module WhatcdResolver where

import AppT
import Arg
import Builder
import Comparison
import Conduit (ConduitT)
import Conduit qualified
import Control.Category qualified as Cat
import Control.Monad.Logger.CallStack
import Control.Monad.Reader
import Data.Aeson qualified as Json
import Data.Aeson.BetterErrors qualified as Json
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.CaseInsensitive (CI)
import Data.Conduit ((.|))
import Data.Error.Tree
import Data.HashMap.Strict qualified as HashMap
import Data.List qualified as List
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Pool qualified as Pool
import Data.Text qualified as Text
import Database.PostgreSQL.Simple qualified as Postgres
import Database.PostgreSQL.Simple.Types (Only (..), PGArray (PGArray))
import Database.Postgres.Temp qualified as TmpPg
import FieldParser (FieldParser)
import FieldParser qualified as Field
import GHC.Records (HasField (..))
import Html qualified
import Http
import IHP.HSX.QQ (hsx)
import IHP.HSX.ToHtml (ToHtml)
import Json qualified
import Json.Enc (Enc)
import Json.Enc qualified as Enc
import JsonLd
import Label
import Multipart2 (MultipartParseT)
import Multipart2 qualified as Multipart
import MyLabel
import MyPrelude
import Network.HTTP.Client.Conduit qualified as Http
import Network.HTTP.Simple qualified as Http
import Network.HTTP.Types
import Network.HTTP.Types qualified as Http
import Network.Wai (ResponseReceived)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Parse (parseContentType)
import OpenTelemetry.Attributes qualified as Otel
import OpenTelemetry.Trace qualified as Otel hiding (getTracer, inSpan, inSpan')
import OpenTelemetry.Trace.Monad qualified as Otel
import Parse (Parse, showContext)
import Parse qualified
import Postgres.Decoder qualified as Dec
import Postgres.MonadPostgres
import Pretty
import Redacted
import RunCommand (runCommandExpect0)
import System.Directory qualified as Dir
import System.Directory qualified as Xdg
import System.Environment qualified as Env
import System.FilePath ((</>))
import Text.Blaze.Html (Html)
import Text.Blaze.Html.Renderer.Utf8 qualified as Html
import Text.Blaze.Html5 qualified as Html
import Tool (readTool, readTools)
import Transmission
import UnliftIO hiding (Handler)
import UnliftIO.Async qualified as Async
import UnliftIO.Concurrent (threadDelay)
import Prelude hiding (span)

main :: IO ()
main =
  runAppWith
    ( do
        -- todo: trace that to the init functions as well
        Otel.inSpan "whatcd-resolver main function" Otel.defaultSpanArguments $ do
          _ <- runTransaction migrate
          htmlUi
    )
    <&> first showToError
    >>= expectIOError "could not start whatcd-resolver"

htmlUi :: AppT IO ()
htmlUi = do
  uniqueRunId <-
    runTransaction $
      querySingleRowWith
        [sql|
            SELECT gen_random_uuid()::text
        |]
        ()
        (Dec.fromField @Text)

  ourHtmlIntegrities <- prefetchHtmlIntegrities

  (counterHtmlM, counterHandler, _counterAsync) <- testCounter (label @"endpoint" "counter")

  withRunInIO $ \runInIO -> Warp.run 9093 $ \req respondOrig -> do
    let catchAppException act =
          try act >>= \case
            Right a -> pure a
            Left (AppExceptionTree err) -> do
              runInIO (logError (prettyErrorTree err))
              respondOrig (Wai.responseLBS Http.status500 [] "")
            Left (AppExceptionPretty err) -> do
              runInIO (logError (err & Pretty.prettyErrsNoColor & stringToText))
              respondOrig (Wai.responseLBS Http.status500 [] "")
            Left (AppExceptionEnc err) -> do
              runInIO (logError (Enc.encToTextPrettyColored err))
              respondOrig (Wai.responseLBS Http.status500 [] "")

    catchAppException $ do
      let torrentIdMp span =
            parseMultipartOrThrow
              span
              req
              ( do
                  label @"torrentId" <$> Multipart.field "torrent-id" ((Field.utf8 >>> Field.signedDecimal >>> Field.bounded @Int "int"))
              )

      let parseQueryArgsNewSpan spanName parser =
            Parse.runParse "Unable to find the right request query arguments" (lmap Wai.queryString parser) req
              & assertMNewSpan spanName (first AppExceptionTree)

      let handlers :: Handlers (AppT IO)
          handlers =
            Map.fromList $
              ourHtmlIntegrities.handlers
                <> [ ( "",
                       HtmlStream (pure ()) $ \_dat span ->
                         ( pure $ htmlPageChrome ourHtmlIntegrities "whatcd-resolver",
                           do
                             counterHtml <- counterHtmlM
                             mainHtml counterHtml uniqueRunId span
                         )
                     ),
                     ( "redacted-search",
                       HtmlStream (label @"searchstr" <$> singleQueryArgument "searchstr" Cat.id) $
                         \dat _span ->
                           ( pure $ htmlPageChrome ourHtmlIntegrities [fmt|whatcd-resolver – Search – {dat.queryArgs.searchstr & bytesToTextUtf8Lenient}|],
                             do
                               runTransaction $ do
                                 res <- redactedSearchAndInsert [("searchstr", dat.queryArgs.searchstr)]
                                 (table, settings) <-
                                   concurrentlyTraced
                                     ( do
                                         d <-
                                           getBestTorrentsData
                                             bestTorrentsDataDefault
                                             ( Just
                                                 ( E21
                                                     (label @"onlyTheseTorrents" res.newTorrents)
                                                 ) ::
                                                 Maybe
                                                   ( E2
                                                       "onlyTheseTorrents"
                                                       [Label "torrentId" Int]
                                                       "artistRedactedId"
                                                       Int
                                                   )
                                             )
                                         pure $ mkBestTorrentsTableByReleaseType d
                                     )
                                     (getSettings)
                                 pure $
                                   mainHtml'
                                     ( MainHtml
                                         { returnUrl = dat.returnUrl,
                                           counterHtml = "",
                                           mainContent =
                                             [hsx|<h1>Search results for <pre>{dat.queryArgs.searchstr}</pre></h1>{table}|],
                                           uniqueRunId,
                                           searchFieldContent = dat.queryArgs.searchstr & bytesToTextUtf8Lenient,
                                           settings
                                         }
                                     )
                           )
                     ),
                     ( "snips/redacted/torrentDataJson",
                       Html $ \span -> do
                         dat <- torrentIdMp span
                         Html.mkVal <$> (runTransaction $ getTorrentById dat)
                     ),
                     ( "snips/redacted/getTorrentFile",
                       HtmlOrReferer $ \span -> do
                         dat <- torrentIdMp span
                         runTransaction $ do
                           settings <- getSettings
                           inserted <- redactedGetTorrentFileAndInsert (T2 dat (getLabel @"useFreeleechTokens" settings))
                           running <-
                             lift @Transaction $
                               doTransmissionRequest' (transmissionRequestAddTorrent inserted)
                           updateTransmissionTorrentHashById
                             ( T2
                                 (getLabel @"torrentHash" running)
                                 (getLabel @"torrentId" dat)
                             )
                           pure $
                             everySecond
                               "snips/transmission/getTorrentState"
                               (Enc.object [("torrent-hash", Enc.text running.torrentHash)])
                               "Starting"
                     ),
                     -- TODO: this is bad duplication??
                     ( "snips/redacted/startTorrentFile",
                       Html $ \span -> do
                         dat <- torrentIdMp span
                         runTransaction $ do
                           file <-
                             getTorrentFileById dat
                               <&> annotate [fmt|No torrent file for torrentId "{dat.torrentId}"|]
                               >>= orAppThrow span

                           running <-
                             lift @Transaction $
                               doTransmissionRequest' (transmissionRequestAddTorrent file)
                           updateTransmissionTorrentHashById
                             ( T2
                                 (getLabel @"torrentHash" running)
                                 (getLabel @"torrentId" dat)
                             )
                           pure $
                             everySecond
                               "snips/transmission/getTorrentState"
                               (Enc.object [("torrent-hash", Enc.text running.torrentHash)])
                               "Starting"
                     ),
                     ( "snips/transmission/getTorrentState",
                       Html $ \span -> do
                         dat <- parseMultipartOrThrow span req $ label @"torrentHash" <$> Multipart.field "torrent-hash" Field.utf8
                         status <-
                           doTransmissionRequest'
                             ( transmissionRequestListOnlyTorrents
                                 ( T2
                                     (label @"ids" [label @"torrentHash" dat.torrentHash])
                                     (label @"fields" ["hashString"])
                                 )
                                 (Json.keyLabel @"torrentHash" "hashString" Json.asText)
                             )
                             <&> List.find (\torrent -> torrent.torrentHash == dat.torrentHash)

                         pure $
                           case status of
                             Nothing -> [hsx|ERROR unknown|]
                             Just _torrent -> [hsx|Running|]
                     ),
                     ( "snips/jsonld/render",
                       do
                         HtmlWithQueryArgs
                           ( label @"target"
                               <$> ( (singleQueryArgument "target" Field.utf8 >>> textToURI)
                                       & Parse.andParse uriToHttpClientRequest
                                   )
                           )
                           ( \dat _span -> do
                               jsonld <- httpGetJsonLd (dat.queryArgs.target)
                               pure $ renderJsonld jsonld
                           )
                     ),
                     ("counter", counterHandler),
                     ( "settings",
                       PostAndRedirect
                         ( do
                             settings <- runTransaction getSettings
                             pure $ do
                               returnTo <- Multipart.fieldLabel @"returnTo" "returnTo" Field.utf8
                               parsed <- label @"settings" <$> settingsMultipartParser settings
                               pure $ T2 returnTo parsed
                         )
                         $ \_span (s :: T2 "returnTo" Text "settings" Settings) -> do
                           let Settings {useFreeleechTokens} = s.settings
                           runTransaction $ do
                             _ <-
                               writeSettings
                                 [ T2
                                     (label @"key" "useFreeleechTokens")
                                     (label @"val" $ Json.Bool useFreeleechTokens)
                                 ]
                             pure $ label @"redirectTo" (s.returnTo & textToBytesUtf8)
                     ),
                     ( "artist",
                       do
                         HtmlStream
                           ( label @"artistRedactedId"
                               <$> ( singleQueryArgument
                                       "redacted_id"
                                       ( Field.utf8
                                           >>> (Field.decimalNatural <&> toInteger)
                                           >>> (Field.bounded @Int "Int")
                                       )
                                   )
                           )
                           $ \dat _span ->
                             ( do
                                 runTransaction $ do
                                   (artistName, _) <-
                                     concurrentlyTraced
                                       ( inSpan' "finding artist name" $ \span -> do
                                           addAttribute span "artist-redacted-id" (dat.queryArgs.artistRedactedId, intDecimalT)
                                           mArtistName <- getArtistNameById (lbl #artistId dat.queryArgs.artistRedactedId)
                                           let pageTitle = case mArtistName of
                                                 Nothing -> "whatcd-resolver"
                                                 Just a -> [fmt|{a} - Artist Page - whatcd-resolver|]
                                           pure $ htmlPageChrome ourHtmlIntegrities pageTitle
                                       )
                                       ( do
                                           execute [sql|INSERT INTO redacted.artist_favourites (artist_id) VALUES (?) ON CONFLICT DO NOTHING|] (Only (dat.queryArgs.artistRedactedId :: Int))
                                       )
                                   pure artistName,
                               do
                                 artistPage (T2 dat.queryArgs (label @"uniqueRunId" uniqueRunId))
                             )
                     ),
                     ( "artist/refresh",
                       HtmlOrRedirect $
                         \span -> do
                           dat <-
                             parseMultipartOrThrow
                               span
                               req
                               ( label @"artistId"
                                   <$> Multipart.field
                                     "artist-id"
                                     ( Field.utf8
                                         >>> (Field.decimalNatural <&> toInteger)
                                         >>> (Field.bounded @Int "Int")
                                     )
                               )
                           runTransaction $ redactedRefreshArtist dat
                           pure $ E22 (label @"redirectTo" $ textToBytesUtf8 $ mkArtistLink dat)
                     ),
                     ( "autorefresh",
                       Plain $ do
                         qry <-
                           parseQueryArgsNewSpan
                             "Autorefresh Query Parse"
                             ( label @"hasItBeenRestarted"
                                 <$> singleQueryArgument "hasItBeenRestarted" Field.utf8
                             )
                         pure $
                           Wai.responseLBS
                             Http.ok200
                             ( [("Content-Type", "text/html")]
                                 <> if uniqueRunId /= qry.hasItBeenRestarted
                                   then -- cause the client side to refresh
                                     [("HX-Refresh", "true")]
                                   else []
                             )
                             ""
                     )
                   ]
      runInIO $
        runHandlers
          ( Html $ \span -> do
              counterHtml <- counterHtmlM
              mainHtml counterHtml uniqueRunId span
          )
          handlers
          req
          respondOrig
  where
    everySecond :: Text -> Enc -> Html -> Html
    everySecond call extraData innerHtml = [hsx|<div hx-trigger="every 1s" hx-swap="outerHTML" hx-post={call} hx-vals={Enc.encToBytesUtf8 extraData}>{innerHtml}</div>|]

    mainHtml :: Html -> Text -> Otel.Span -> AppT IO Html
    mainHtml counterHtml uniqueRunId _span = runTransaction $ do
      -- jsonld <-
      --   httpGetJsonLd
      --     ( URI.parseURI "https://musicbrainz.org/work/92000fd4-d304-406d-aeb4-6bdbeed318ec" & annotate "not an URI" & unwrapError,
      --       "https://musicbrainz.org/work/92000fd4-d304-406d-aeb4-6bdbeed318ec"
      --     )
      --     <&> renderJsonld
      (bestTorrentsTable, settings) <-
        concurrentlyTraced
          ( do
              d <-
                getBestTorrentsData
                  ( BestTorrentsData
                      { limitResults = Just 100,
                        ordering = ByLastReleases,
                        onlyFavourites = True,
                        disallowedReleaseTypes =
                          [ releaseTypeBootleg,
                            releaseTypeGuestAppearance,
                            releaseTypeRemix
                          ],
                        ..
                      }
                  )
                  Nothing
              pure $ case d & nonEmpty of
                Nothing -> [hsx|<h1>Latest Releases</h1><p>No torrents found</p>|]
                Just d' -> mkBestTorrentsTableSection (lbl #sectionName "Last Releases") d'
          )
          (getSettings)
      -- transmissionTorrentsTable <- lift @Transaction getTransmissionTorrentsTable
      pure $
        mainHtml'
          ( MainHtml
              { returnUrl = "/",
                counterHtml,
                mainContent = bestTorrentsTable,
                uniqueRunId,
                settings,
                searchFieldContent = ""
              }
          )

data MainHtml = MainHtml
  { returnUrl :: ByteString,
    counterHtml :: Html,
    mainContent :: Html,
    searchFieldContent :: Text,
    uniqueRunId :: Text,
    settings :: Settings
  }

mainHtml' :: MainHtml -> Html
mainHtml' dat = do
  [hsx|
            {dat.counterHtml}
            {settingButtons dat}

            <form action="redacted-search">
              <label for="redacted-search-input">Redacted Search</label>
              <input
                id="redacted-search-input"
                type="text"
                name="searchstr"
                value={dat.searchFieldContent} />
              <button type="submit" hx-disabled-elt="this">Search</button>
              <div class="htmx-indicator">Search running!</div>
            </form>
            <div>
              {dat.mainContent}
            </div>
            <!-- refresh the page if the uniqueRunId is different -->
            <!-- <input
                hidden
                type="text"
                id="autorefresh"
                name="hasItBeenRestarted"
                value={dat.uniqueRunId}
                hx-get="/autorefresh"
                hx-trigger="every 5s"
                hx-swap="none"
            /> -->
            |]

parseMultipartOrThrow :: (MonadLogger m, MonadIO m, MonadThrow m) => Otel.Span -> Wai.Request -> Multipart.MultipartParseT m a -> m a
parseMultipartOrThrow span req parser =
  Multipart.parseMultipartOrThrow
    (appThrow span . AppExceptionTree)
    parser
    req

-- | Reload the current page (via the Referer header) if the browser has Javascript disabled (and thus htmx does not work). This should make post requests work out of the box.
htmxOrReferer :: Wai.Request -> Wai.Response -> Wai.Response
htmxOrReferer req resp = do
  let fnd h = req & Wai.requestHeaders & List.find (\(hdr, _) -> hdr == h)
  let referer = fnd "Referer"
  if
    | Just _ <- fnd "Hx-Request" -> resp
    | Nothing <- referer -> resp
    | Just (_, rfr) <- referer -> do
        Wai.responseLBS seeOther303 [("Location", rfr)] ""

-- | Redirect to the given page, if the browser has Javascript enabled use HTMX client side redirect, otherwise use a normal HTTP redirect.
redirectOrFallback :: ByteString -> (Status -> (CI ByteString, ByteString) -> Wai.Response) -> Wai.Request -> Wai.Response
redirectOrFallback target responseFn req = do
  let fnd h = req & Wai.requestHeaders & List.find (\(hdr, _) -> hdr == h)
  case fnd "Hx-Request" of
    Just _ -> responseFn Http.ok200 ("Hx-Redirect", target)
    Nothing -> responseFn Http.seeOther303 ("Location", target)

htmlPageChrome :: OurHtmlIntegrities m -> Text -> HtmlHead
htmlPageChrome integrities title =
  HtmlHead
    { title,
      headContent =
        [hsx|
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <!--
          prevent favicon request, based on answers in
          https://stackoverflow.com/questions/1321878/how-to-prevent-favicon-ico-requests
          TODO: create favicon
        -->
        <link rel="icon" href="data:,">
        {integrities.html}
        <style>
          dl {
            margin: 1em;
            padding: 0.5em 1em;
            border: thin solid;
          }
        </style>
    |]
    }

data OurHtmlIntegrities m = OurHtmlIntegrities
  { html :: Html,
    handlers :: [(Text, HandlerResponse m)]
  }

prefetchHtmlIntegrities :: (MonadOtel m, MonadThrow m) => m (OurHtmlIntegrities m)
prefetchHtmlIntegrities = do
  let resources =
        [ HtmlIntegrity
            { integrityName = "Bootstrap CSS",
              integrityUrl = "https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css",
              integrityHash = "sha384-9ndCyUaIbzAi2FUVXJi0CjmCapSmO7SnpJef0486qhLnuZ2cdeRhO02iuK6FUUVM",
              localPath = "resources/bootstrap.min.css",
              provideSourceMap = True,
              isTag = E21 (label @"link" ())
            },
          HtmlIntegrity
            { integrityName = "Bootstrap JS",
              integrityUrl = "https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js",
              integrityHash = "sha384-geWF76RCwLtnZ8qwWowPQNguL3RmwHVBC9FhGdlKrxdiJJigb/j/68SIy3Te4Bkz",
              localPath = "resources/bootstrap.bundle.min.js",
              provideSourceMap = True,
              isTag = E22 (label @"script" ())
            },
          HtmlIntegrity
            { integrityName = "htmx",
              integrityUrl = "https://unpkg.com/htmx.org@1.9.2",
              integrityHash = "sha384-L6OqL9pRWyyFU3+/bjdSri+iIphTN/bvYyM37tICVyOJkWZLpP2vGn6VUEXgzg6h",
              localPath = "resources/htmx.js",
              provideSourceMap = False,
              isTag = E22 (label @"script" ())
            }
        ]
  resources
    & mapConcurrentlyTraced
      ( \r ->
          prefetchResourceIntegrity r <&> \(html, handler) ->
            ( html,
              [(r.localPath, handler (Arg @"giveSourceMap" False))]
                -- a little hacky, we provide an extra handler if there is a source map
                <> ifTrue
                  (r.provideSourceMap)
                  [(r.localPath <> ".map", handler (Arg @"giveSourceMap" True))]
            )
      )
    <&> fold
    <&> \(html, handlers) -> OurHtmlIntegrities {..}

artistPage ::
  ( HasField "artistRedactedId" dat Int,
    HasField "uniqueRunId" dat Text,
    MonadPostgres m,
    MonadOtel m,
    MonadLogger m,
    MonadThrow m,
    MonadTransmission m
  ) =>
  dat ->
  m Html
artistPage dat = runTransaction $ do
  (fresh, settings) <-
    concurrentlyTraced
      ( getBestTorrentsData
          bestTorrentsDataDefault
          (Just $ E22 (getLabel @"artistRedactedId" dat))
      )
      (getSettings)
  let torrents = mkBestTorrentsTableByReleaseType fresh

  let returnUrl =
        textToBytesUtf8 $
          mkArtistLink (label @"artistId" (dat.artistRedactedId))

  let mainContent =
        [hsx|
        <div id="artist-torrents">
          {torrents}
        </div>

        <form method="post" action="artist/refresh" hx-post="artist/refresh">
          <input
            hidden
            type="text"
            name="artist-id"
            value={dat.artistRedactedId & buildText intDecimalT}
            />
          <button type="submit" hx-disabled-elt="this">Refresh Artist Page</button>
          <div class="htmx-indicator">Refreshing!</div>
        </form>
      |]
  pure $
    mainHtml'
      ( MainHtml
          { -- pageTitle,
            returnUrl,
            counterHtml = "",
            mainContent,
            uniqueRunId = dat.uniqueRunId,
            searchFieldContent = "",
            settings
          }
      )

type Handlers m = Map Text (HandlerResponse m)

data QueryArgsDat a = QueryArgsDat
  { queryArgs :: a,
    returnUrl :: ByteString
  }

data HtmlHead = HtmlHead
  { title :: Text,
    headContent :: Html
  }

data HandlerResponse m where
  -- | render html
  Html :: (Otel.Span -> m Html) -> HandlerResponse m
  -- | either render html or redirect to another page
  HtmlOrRedirect :: (Otel.Span -> m (E2 "respond" Html "redirectTo" ByteString)) -> HandlerResponse m
  -- | render html after parsing some query arguments
  HtmlWithQueryArgs :: Parse Query a -> (QueryArgsDat a -> Otel.Span -> m Html) -> HandlerResponse m
  -- | render html or reload the page via the Referer header if no htmx
  HtmlOrReferer :: (Otel.Span -> m Html) -> HandlerResponse m
  -- | render html and stream the head before even doing any work in the handler
  HtmlStream :: Parse Query a -> (QueryArgsDat a -> Otel.Span -> (m HtmlHead, m Html)) -> HandlerResponse m
  -- | parse the request as POST submission, then redirect to the given endpoint
  PostAndRedirect ::
    m (MultipartParseT m dat) ->
    (Otel.Span -> dat -> m (Label "redirectTo" ByteString)) ->
    HandlerResponse m
  -- | render a plain wai response
  Plain :: m Wai.Response -> HandlerResponse m

runHandlers ::
  forall m.
  (MonadOtel m, MonadLogger m, MonadThrow m) =>
  (HandlerResponse m) ->
  (Map Text (HandlerResponse m)) ->
  Wai.Request ->
  (Wai.Response -> IO ResponseReceived) ->
  m ResponseReceived
runHandlers defaultHandler handlers req respond = withRunInIO $ \runInIO -> do
  let path = req & Wai.pathInfo & Text.intercalate "/"
  let inRouteSpan =
        Otel.inSpan'
          [fmt|Route /{path}|]
          ( Otel.defaultSpanArguments
              { Otel.attributes =
                  HashMap.fromList
                    [ ("_.server.path", Otel.toAttribute @Text path),
                      ("_.server.query_args", Otel.toAttribute @Text (req.rawQueryString & bytesToTextUtf8Lenient))
                    ]
              }
          )
  let html' resp act =
        inRouteSpan
          ( \span -> do
              res <- act span <&> (\h -> label @"html" h)
              addEventSimple span "Got Html result, rendering…"
              liftIO $ respond (resp res)
          )
  let htmlResp res = Wai.responseLBS Http.ok200 ([("Content-Type", "text/html")]) . Html.renderHtml $ res.html
  let html = html' htmlResp
  let htmlOrReferer = html' $ \res -> htmxOrReferer req (htmlResp res)
  let htmlOrRedirect :: (Otel.Span -> m (E2 "respond" Html "redirectTo" ByteString)) -> m ResponseReceived
      htmlOrRedirect = html' $ \res -> case res.html of
        E21 h -> htmlResp (label @"html" h.respond)
        E22 r ->
          redirectOrFallback
            r.redirectTo
            (\status header -> Wai.responseLBS status [header] "")
            req
  let postAndRedirect ::
        MultipartParseT m dat ->
        (Otel.Span -> dat -> m (Label "redirectTo" ByteString)) ->
        m ResponseReceived
      postAndRedirect parser act = inRouteSpan $ \span -> do
        if (req & Wai.requestMethod) == "POST"
          then do
            dat <- parseMultipartOrThrow span req parser
            res <- act span dat
            liftIO $ respond (Wai.responseLBS Http.seeOther303 [("Location", res.redirectTo)] "")
          else do
            liftIO $ respond (Wai.responseLBS Http.methodNotAllowed405 [] "")
  let htmlWithQueryArgs' parser =
        case req & Parse.runParse "Unable to find the right request query arguments" (lmap Wai.queryString parser) of
          Right queryArgs -> Right $ QueryArgsDat {queryArgs, returnUrl = (req & Wai.rawPathInfo) <> (req & Wai.rawQueryString)}
          Left err ->
            Left
              ( \span -> do
                  recordException
                    span
                    ( T2
                        (label @"type_" "Query Parse Exception")
                        (label @"message" (prettyErrorTree err))
                    )

                  pure
                    [hsx|
                              <h1>Error:</h1>
                              <pre>{err & prettyErrorTree}</pre>
                            |]
              )
  let htmlWithQueryArgs parser act = case htmlWithQueryArgs' parser of
        Right dat -> html (act dat)
        Left act' -> html act'

  let htmlStream :: Parse Query a -> (QueryArgsDat a -> Otel.Span -> (m HtmlHead, m Html)) -> m ResponseReceived
      htmlStream parser act = inRouteSpan $ \span -> do
        case htmlWithQueryArgs' parser of
          Left act' -> html act'
          Right dat -> do
            let (mkHead, mkBody) = act dat span
            -- start the body work (heh) immediately, but stream the head first
            withAsyncTraced mkBody $ \bodyAsync -> do
              withRunInIO $ \runInIO' -> respond $ Wai.responseStream Http.ok200 [("Content-Type", "text/html")] $ \send flush -> do
                runInIO' $ inSpan "sending <head>" $ do
                  htmlHead <- mkHead
                  liftIO $ do
                    send "<!DOCTYPE html>\n"
                    send "<html>\n"
                    send $
                      Html.renderHtmlBuilder $
                        [hsx|
                            <head>
                              <title>{htmlHead.title}</title>
                              {htmlHead.headContent}
                            </head>
                        |]
                    flush
                htmlBody <- liftIO $ wait bodyAsync
                send "<body>\n"
                send $ Html.renderHtmlBuilder htmlBody
                send "</body>\n"
                send "</html>\n"
                flush

  let handler =
        handlers
          & Map.lookup path
          & fromMaybe defaultHandler
          & \case
            Html act -> html act
            HtmlOrRedirect act -> htmlOrRedirect act
            HtmlWithQueryArgs parser act -> htmlWithQueryArgs parser act
            HtmlOrReferer act -> htmlOrReferer act
            HtmlStream parser act -> htmlStream parser act
            PostAndRedirect mParser act -> mParser >>= \parser -> postAndRedirect parser act
            Plain act -> liftIO $ runInIO act >>= respond
  runInIO handler

singleQueryArgument :: Text -> FieldParser ByteString to -> Parse Http.Query to
singleQueryArgument field inner =
  Parse.mkParsePushContext
    field
    ( \(ctx, qry) -> case qry
        & mapMaybe
          ( \(k, v) ->
              if k == (field & textToBytesUtf8)
                then Just v
                else Nothing
          ) of
        [] -> Left [fmt|No such query argument "{field}", at {ctx & Parse.showContext}|]
        [Nothing] -> Left [fmt|Expected one query argument with a value, but "{field}" was a query flag|]
        [Just one] -> Right one
        more -> Left [fmt|More than one value for query argument "{field}": {show more}, at {ctx & Parse.showContext}|]
    )
    >>> Parse.fieldParser inner

singleQueryArgumentMay :: Text -> FieldParser ByteString to -> Parse Http.Query (Maybe to)
singleQueryArgumentMay field inner =
  Parse.mkParsePushContext
    field
    ( \(ctx, qry) -> case qry
        & mapMaybe
          ( \(k, v) ->
              if k == (field & textToBytesUtf8)
                then Just v
                else Nothing
          ) of
        [] -> Right Nothing
        [Nothing] -> Left [fmt|Expected one query argument with a value, but "{field}" was a query flag|]
        [Just one] -> Right (Just one)
        more -> Left [fmt|More than one value for query argument "{field}": {show more}, at {ctx & Parse.showContext}|]
    )
    >>> Parse.maybe (Parse.fieldParser inner)

data ArtistFilter = ArtistFilter
  { onlyArtist :: Maybe (Label "artistId" Text)
  }

doIfJust :: (Applicative f) => (a -> f ()) -> Maybe a -> f ()
doIfJust = traverse_

data BestTorrentsData = BestTorrentsData
  { limitResults :: Maybe Natural,
    ordering :: BestTorrentsOrdering,
    disallowedReleaseTypes :: [ReleaseType],
    onlyFavourites :: Bool
  }

bestTorrentsDataDefault :: BestTorrentsData
bestTorrentsDataDefault =
  BestTorrentsData
    { limitResults = Nothing,
      ordering = BySeedingWeight,
      disallowedReleaseTypes = [],
      onlyFavourites = False
    }

getBestTorrentsData ::
  ( MonadTransmission m,
    MonadThrow m,
    MonadLogger m,
    MonadPostgres m,
    MonadOtel m
  ) =>
  BestTorrentsData ->
  Maybe (E2 "onlyTheseTorrents" [Label "torrentId" Int] "artistRedactedId" Int) ->
  Transaction m [TorrentData (Label "percentDone" Percentage)]
getBestTorrentsData opts filters = inSpan' "get torrents table data" $ \span -> do
  let onlyArtist = label @"artistRedactedId" <$> (filters >>= getE22 @"artistRedactedId")
  onlyArtist & doIfJust (\a -> addAttribute span "artist-filter.redacted-id" (a.artistRedactedId, intDecimalT))
  let onlyTheseTorrents = filters >>= getE21 @"onlyTheseTorrents"
  onlyTheseTorrents & doIfJust (\a -> addAttribute span "torrent-filter.ids" (a <&> (getLabel @"torrentId") & showToText & Otel.toAttribute))
  let limitResults = getField @"limitResults" opts

  let ordering = opts.ordering
  let disallowedReleaseTypes = opts.disallowedReleaseTypes
  let onlyFavourites = opts.onlyFavourites
  let getBest = getBestTorrents GetBestTorrentsFilter {..}

  bestStale :: [TorrentData ()] <- getBest
  (statusInfo, transmissionStatus) <-
    getAndUpdateTransmissionTorrentsStatus
      ( bestStale
          & mapMaybe
            ( \td -> case td.torrentStatus of
                InTransmission h -> Just (getLabel @"torrentHash" h, td)
                _ -> Nothing
            )
          & Map.fromList
      )
  bestBest <-
    -- Instead of serving a stale table when a torrent gets deleted, fetch
    -- the whole view again. This is a little wasteful, but torrents
    -- shouldn’t get deleted very often, so it’s fine.
    -- Re-evaluate invariant if this happens too often.
    if statusInfo.knownTorrentsStale
      then inSpan' "Fetch torrents table data again" $
        \span' -> do
          addEventSimple span' "The transmission torrent list was out of date, refetching torrent list."
          getBest
      else pure bestStale
  pure $
    bestBest
      -- filter out some kinds we don’t really care about
      & filter
        ( \td ->
            td.releaseType
              `List.notElem` [ releaseTypeCompilation,
                               releaseTypeDJMix,
                               releaseTypeMixtape,
                               releaseTypeRemix
                             ]
        )
      --  we have to update the status of every torrent that’s not in tranmission anymore
      -- TODO I feel like it’s easier (& more correct?) to just do the database request again …
      <&> ( \td -> case td.torrentStatus of
              InTransmission info ->
                case transmissionStatus & Map.lookup (getLabel @"torrentHash" info) of
                  -- TODO this is also pretty dumb, cause it assumes that we have the torrent file if it was in transmission before,
                  -- which is an internal factum that is established in getBestTorrents (and might change later)
                  Nothing -> td {torrentStatus = NotInTransmissionYet}
                  Just transmissionInfo -> td {torrentStatus = InTransmission (T2 (getLabel @"torrentHash" info) (label @"transmissionInfo" transmissionInfo))}
              NotInTransmissionYet -> td {torrentStatus = NotInTransmissionYet}
              NoTorrentFileYet -> td {torrentStatus = NoTorrentFileYet}
          )

mkBestTorrentsTableByReleaseType ::
  [TorrentData (Label "percentDone" Percentage)] ->
  Html
mkBestTorrentsTableByReleaseType fresh =
  fresh
    & toList
    & groupAllWithComparison ((.releaseType) >$< releaseTypeComparison)
    & foldMap
      ( \ts -> do
          let releaseType = ts & NonEmpty.head & (.releaseType.stringKey)
          mkBestTorrentsTableSection (lbl #sectionName [fmt|{releaseType}s|]) ts
      )

mkBestTorrentsTableSection ::
  (HasField "sectionName" opts Text) =>
  opts ->
  NonEmpty (TorrentData (Label "percentDone" Percentage)) ->
  Html
mkBestTorrentsTableSection opts torrents = do
  let localTorrent b = case b.torrentStatus of
        NoTorrentFileYet ->
          [hsx|
        <form method="post">
          <input type="hidden" name="torrent-id" value={b.torrentId & show} />
          <button
            formaction="snips/redacted/getTorrentFile"
            hx-post="snips/redacted/getTorrentFile"
            hx-swap="outerHTML"
            hx-vals={Enc.encToBytesUtf8 $ Enc.object [("torrent-id", Enc.int b.torrentId)]}>Upload Torrent</button>
        </form>
        |]
        InTransmission info -> [hsx|{info.transmissionInfo.percentDone.unPercentage}% done|]
        NotInTransmissionYet -> [hsx|<button hx-post="snips/redacted/startTorrentFile" hx-swap="outerHTML" hx-vals={Enc.encToBytesUtf8 $ Enc.object [("torrent-id", Enc.int b.torrentId)]}>Start Torrent</button>|]
  let bestRows :: NonEmpty (TorrentData (Label "percentDone" Percentage)) -> Html
      bestRows rowData =
        rowData
          & foldMap
            ( \b -> do
                let torrentPosition :: Text = [fmt|torrent-{b.torrentId}|]
                let artists =
                      b.artists
                        <&> ( \a ->
                                T2
                                  (label @"url" $ mkArtistLink a)
                                  (label @"content" $ Html.toHtml @Text a.artistName)
                            )
                        & mkLinkList
                let releaseTypeTooltip rt = [fmt|{rt.stringKey} (Release type ID: {rt.intKey})|] :: Text
                [hsx|
                  <tr id={torrentPosition}>
                  <td>{localTorrent b}</td>
                  <td>{Html.toHtml @Int b.groupId}</td>
                  <td>
                    {artists}
                  </td>
                  <td>
                    <a href={mkRedactedTorrentLink (Arg b.groupId)} target="_blank">
                      {Html.toHtml @Text b.torrentGroupJson.groupName}
                    </a>
                  </td>
                  <td title={releaseTypeTooltip b.releaseType}>{Html.toHtml @Text b.releaseType.stringKey}</td>
                  <td>{Html.toHtml @Natural b.torrentGroupJson.groupYear}</td>
                  <td>{Html.toHtml @Int b.seedingWeight}</td>
                  <td>{Html.toHtml @Text b.torrentFormat}</td>
                  <td><details hx-trigger="toggle once" hx-post="snips/redacted/torrentDataJson" hx-vals={Enc.encToBytesUtf8 $ Enc.object [("torrent-id", Enc.int b.torrentId)]}></details></td>
                  </tr>
                |]
            )

  [hsx|
        <h2>{opts.sectionName}</h2>
        <table class="table">
          <thead>
            <tr>
              <th>Local</th>
              <th>Group ID</th>
              <th>Artist</th>
              <th>Name</th>
              <th>Type</th>
              <th>Year</th>
              <th>Weight</th>
              <th>Format</th>
              <th>Torrent</th>
            </tr>
          </thead>
          <tbody>
            {bestRows torrents}
          </tbody>
        </table>
      |]

mkLinkList :: [T2 "url" Text "content" Html] -> Html
mkLinkList xs =
  xs
    <&> ( \x -> do
            [hsx|<a href={x.url}>{x.content}</a>|]
        )
    & List.intersperse ", "
    & mconcat

mkArtistLink :: (HasField "artistId" r Int) => r -> Text
mkArtistLink a = [fmt|/artist?redacted_id={a.artistId}|]

getTransmissionTorrentsTable ::
  (MonadTransmission m, MonadThrow m, MonadLogger m, MonadOtel m) => m Html
getTransmissionTorrentsTable = do
  let fields =
        [ "hashString",
          "name",
          "percentDone",
          "percentComplete",
          "downloadDir",
          "files"
        ]
  doTransmissionRequest'
    ( transmissionRequestListAllTorrents fields $ do
        Json.asObject <&> KeyMap.toMapText
    )
    <&> \resp ->
      Html.toTable
        ( resp
            & List.sortOn (\m -> m & Map.lookup "percentDone" & fromMaybe (Json.Number 0))
            <&> Map.toList
            -- TODO
            & List.take 100
        )

unzip3PGArray :: [(a1, a2, a3)] -> (PGArray a1, PGArray a2, PGArray a3)
unzip3PGArray xs = xs & unzip3 & \(a, b, c) -> (PGArray a, PGArray b, PGArray c)

assertOneUpdated ::
  (HasField "numberOfRowsAffected" r Natural, MonadThrow m, MonadIO m) =>
  Otel.Span ->
  Text ->
  r ->
  m ()
assertOneUpdated span name x = case x.numberOfRowsAffected of
  1 -> pure ()
  n -> appThrow span ([fmt|{name :: Text}: Expected to update exactly one row, but updated {n :: Natural} row(s)|])

migrate ::
  ( MonadPostgres m,
    MonadOtel m
  ) =>
  Transaction m (Label "numberOfRowsAffected" Natural)
migrate = inSpan "Database Migration" $ do
  execute
    [sql|
    CREATE SCHEMA IF NOT EXISTS redacted;

    CREATE TABLE IF NOT EXISTS redacted.settings (
      id SERIAL PRIMARY KEY,
      key TEXT NOT NULL UNIQUE,
      value JSONB
    );

    CREATE TABLE IF NOT EXISTS redacted.torrent_groups (
      id SERIAL PRIMARY KEY,
      group_id INTEGER,
      group_name TEXT,
      full_json_result JSONB,
      UNIQUE(group_id)
    );

    CREATE TABLE IF NOT EXISTS redacted.torrents_json (
      id SERIAL PRIMARY KEY,
      torrent_id INTEGER,
      torrent_group SERIAL NOT NULL REFERENCES redacted.torrent_groups(id) ON DELETE CASCADE,
      full_json_result JSONB,
      UNIQUE(torrent_id)
    );

    CREATE INDEX IF NOT EXISTS redacted_torrents_json_torrent_group_fk ON redacted.torrents_json (torrent_group);


    ALTER TABLE redacted.torrents_json
    ADD COLUMN IF NOT EXISTS torrent_file bytea NULL;
    ALTER TABLE redacted.torrents_json
    ADD COLUMN IF NOT EXISTS transmission_torrent_hash text NULL;

    -- the seeding weight is used to find the best torrent in a group.
    CREATE OR REPLACE FUNCTION calc_seeding_weight(full_json_result jsonb) RETURNS int AS $$
    BEGIN
      RETURN
        -- three times seeders plus one times snatches
        (3 * (full_json_result->'seeders')::integer
        + (full_json_result->'snatches')::integer
        )
        -- prefer remasters by multiplying them with 3
        * (CASE
            WHEN full_json_result->>'remasterTitle' ILIKE '%remaster%'
            THEN 3
            ELSE 1
          END)
        -- slightly push mp3 V0, to make sure it’s preferred over 320 CBR
        * (CASE
            WHEN full_json_result->>'encoding' ILIKE '%v0%'
            THEN 2
            ELSE 1
          END)
        -- remove 24bit torrents from the result (wayyy too big)
        * (CASE
            WHEN full_json_result->>'encoding' ILIKE '%24bit%'
            THEN 0
            ELSE 1
          END)
        -- discount FLACS, so we only use them when there’s no mp3 alternative (to save space)
        / (CASE
            WHEN full_json_result->>'encoding' ILIKE '%lossless%'
            THEN 5
            ELSE 1
          END)
        ;
    END;
    $$ LANGUAGE plpgsql IMMUTABLE;

    ALTER TABLE redacted.torrents_json
    ADD COLUMN IF NOT EXISTS seeding_weight int NOT NULL GENERATED ALWAYS AS (calc_seeding_weight(full_json_result)) STORED;

    CREATE OR REPLACE FUNCTION artist_record_to_id(artists jsonb) RETURNS int[]
    as $$
      SELECT array_agg(x::int) from jsonb_path_query(artists, '$[*].id') j(x);
    $$ LANGUAGE sql IMMUTABLE;

    ALTER TABLE redacted.torrents_json
    ADD COLUMN IF NOT EXISTS artist_ids int[] NOT NULL GENERATED ALWAYS AS (COALESCE(artist_record_to_id(full_json_result->'artists'), ARRAY[]::int[])) STORED;
    ALTER TABLE redacted.torrent_groups
    ADD COLUMN IF NOT EXISTS artist_ids int[] NOT NULL GENERATED ALWAYS AS (COALESCE(artist_record_to_id(full_json_result->'artists'), ARRAY[]::int[])) STORED;

    CREATE INDEX IF NOT EXISTS torrents_json_artist_ids ON redacted.torrents_json USING GIN (artist_ids);
    CREATE INDEX IF NOT EXISTS torrent_groups_artist_ids ON redacted.torrent_groups USING GIN (artist_ids);

    -- inflect out values of the full json
    CREATE OR REPLACE VIEW redacted.torrents AS
    SELECT
      t.id,
      t.torrent_id,
      t.torrent_group,
      -- the seeding weight is used to find the best torrent in a group.
      t.seeding_weight,
      t.full_json_result,
      t.torrent_file,
      t.transmission_torrent_hash,
      t.artist_ids
    FROM redacted.torrents_json t;

    CREATE INDEX IF NOT EXISTS torrents_json_seeding ON redacted.torrents_json(((full_json_result->'seeding')::integer));
    CREATE INDEX IF NOT EXISTS torrents_json_snatches ON redacted.torrents_json(((full_json_result->'snatches')::integer));

    CREATE TABLE IF NOT EXISTS redacted.artist_favourites (
      id SERIAL PRIMARY KEY,
      artist_id INTEGER NOT NULL,
      UNIQUE(artist_id)
    );

    -- for easier query lookup, a mapping from artist ids to names
    CREATE OR REPLACE VIEW redacted.artist_names AS
    SELECT
      t.artist_id, x.name as artist_name
    FROM
      (SELECT unnest(artist_ids) as artist_id, * FROM redacted.torrents t) as t
      join LATERAL
      jsonb_to_recordset(full_json_result->'artists') as x(id int, name text)
      ON x.id = t.artist_id
      WHERE x.id = t.artist_id
    UNION ALL
    SELECT
      t.artist_id, x.name as artist_name
    FROM
      (SELECT unnest(artist_ids) as artist_id, * FROM redacted.torrent_groups t) as t
      join LATERAL
      jsonb_to_recordset(full_json_result->'artists') as x(id int, name text)
      ON x.id = t.artist_id
      WHERE x.id = t.artist_id;

  |]
    ()

runAppWith :: AppT IO a -> IO (Either TmpPg.StartError a)
runAppWith appT = withTracer $ \tracer -> withDb $ \db -> do
  tool <- readTools (label @"toolsEnvVar" "WHATCD_RESOLVER_TOOLS") (readTool "pg_format")
  prettyPrintDatabaseQueries <-
    Env.lookupEnv "WHATCD_RESOLVER_PRETTY_PRINT_DATABASE_QUERIES" >>= \case
      Nothing -> pure DontPrettyPrintDatabaseQueries
      Just _ -> do
        pgFormat <- initPgFormatPool (label @"pgFormat" tool)
        pure $ PrettyPrintDatabaseQueries pgFormat
  let pgConfig =
        T2
          (label @"logDatabaseQueries" LogDatabaseQueries)
          (label @"prettyPrintDatabaseQueries" prettyPrintDatabaseQueries)
  pgConnPool <-
    Pool.newPool $
      Pool.defaultPoolConfig
        {- resource init action -} (Postgres.connectPostgreSQL (db & TmpPg.toConnectionString))
        {- resource destruction -} Postgres.close
        {- unusedResourceOpenTime -} 10
        {- max resources across all stripes -} 20
  transmissionSessionId <- newIORef Nothing
  redactedApiKey <-
    Env.lookupEnv "WHATCD_RESOLVER_REDACTED_API_KEY" >>= \case
      Just k -> pure (k & stringToBytesUtf8)
      Nothing -> runStderrLoggingT $ do
        logInfo "WHATCD_RESOLVER_REDACTED_API_KEY was not set, trying pass"
        runCommandExpect0 "pass" ["internet/redacted/api-keys/whatcd-resolver"]
  let newAppT = do
        logInfo [fmt|Running with config: {showPretty pgConfig}|]
        logInfo [fmt|Connected to database at {db & TmpPg.toDataDirectory} on socket {db & TmpPg.toConnectionString}|]
        appT
  runReaderT newAppT.unAppT Context {..}
    `catch` ( \case
                AppExceptionPretty p -> throwM $ EscapedException (p & Pretty.prettyErrs)
                AppExceptionTree t -> throwM $ EscapedException (t & prettyErrorTree & textToString)
                AppExceptionEnc e -> throwM $ EscapedException (e & Enc.encToTextPrettyColored & textToString)
            )

-- | Just a silly wrapper so that correctly format any 'AppException' that would escape the runAppWith scope.
newtype EscapedException = EscapedException String
  deriving anyclass (Exception)

instance Show EscapedException where
  show (EscapedException s) = s

withTracer :: (Otel.Tracer -> IO c) -> IO c
withTracer f = do
  setDefaultEnv "OTEL_SERVICE_NAME" "whatcd-resolver"
  bracket
    -- Install the SDK, pulling configuration from the environment
    ( do
        (processors, opts) <- Otel.getTracerProviderInitializationOptions
        tp <-
          Otel.createTracerProvider
            processors
            -- workaround the attribute length bug https://github.com/iand675/hs-opentelemetry/issues/113
            ( opts
                { Otel.tracerProviderOptionsAttributeLimits =
                    opts.tracerProviderOptionsAttributeLimits
                      { Otel.attributeCountLimit = Just 65_000
                      }
                }
            )
        Otel.setGlobalTracerProvider tp
        pure tp
    )
    -- Ensure that any spans that haven't been exported yet are flushed
    Otel.shutdownTracerProvider
    -- Get a tracer so you can create spans
    (\tracerProvider -> f $ Otel.makeTracer tracerProvider "whatcd-resolver" Otel.tracerOptions)

setDefaultEnv :: String -> String -> IO ()
setDefaultEnv envName defaultValue = do
  Env.lookupEnv envName >>= \case
    Just _env -> pure ()
    Nothing -> Env.setEnv envName defaultValue

withDb :: (TmpPg.DB -> IO a) -> IO (Either TmpPg.StartError a)
withDb act = do
  dataDir <- Xdg.getXdgDirectory Xdg.XdgData "whatcd-resolver"
  let databaseDir = dataDir </> "database"
  let socketDir = dataDir </> "database-socket"
  Dir.createDirectoryIfMissing True socketDir
  initDbConfig <-
    Dir.doesDirectoryExist databaseDir >>= \case
      True -> pure TmpPg.Zlich
      False -> do
        putStderrLn [fmt|Database does not exist yet, creating in "{databaseDir}"|]
        Dir.createDirectoryIfMissing True databaseDir
        pure TmpPg.DontCare
  let cfg =
        mempty
          { TmpPg.dataDirectory = TmpPg.Permanent (databaseDir),
            TmpPg.socketDirectory = TmpPg.Permanent socketDir,
            TmpPg.port = pure $ Just 5431,
            TmpPg.initDbConfig
          }
  TmpPg.withConfig cfg $ \db -> do
    -- print [fmt|data dir: {db & TmpPg.toDataDirectory}|]
    -- print [fmt|conn string: {db & TmpPg.toConnectionString}|]
    act db

data Settings = Settings
  { useFreeleechTokens :: Bool
  }
  deriving stock (Generic)

settingFreeleechToken :: Bool -> Settings
settingFreeleechToken b = Settings {useFreeleechTokens = b}

instance Semigroup Settings where
  a <> b = Settings {useFreeleechTokens = a.useFreeleechTokens || b.useFreeleechTokens}

instance Monoid Settings where
  mempty = Settings {useFreeleechTokens = False}

submitSettingForm :: (HasField "returnUrl" r ByteString, ToHtml a) => r -> a -> Html
submitSettingForm opts inputs =
  [hsx|
  <form
    method="post"
    action="/settings"
  >
    <input type="hidden" name="returnTo" value={opts.returnUrl} />
    {inputs}
  </form>
  |]

settingButtons :: (HasField "returnUrl" opts ByteString, HasField "settings" opts Settings) => opts -> Html
settingButtons opts =
  if opts.settings.useFreeleechTokens
    then
      submitSettingForm
        opts
        [hsx|<p>Using freeleech tokens! <input type="submit" name="useFreeleechTokensOFF" value="Turn off" /></p>|]
    else
      submitSettingForm
        opts
        [hsx|<p>Not using freeleech tokens <input type="submit" name="useFreeleechTokensON" value="Turn on" /></p>|]

settingsMultipartParser :: (Applicative m) => Settings -> MultipartParseT m Settings
settingsMultipartParser old = do
  useFreeleechTokens <- do
    on <-
      Multipart.fieldMay
        "useFreeleechTokensON"
        (cconst $ True)
    off <-
      Multipart.fieldMay
        "useFreeleechTokensOFF"
        (cconst $ False)
    pure $ (on <|> off) & fromMaybe old.useFreeleechTokens
  pure $ Settings {..}

getSettings :: (MonadPostgres m, MonadOtel m) => Transaction m Settings
getSettings = inSpan' "Get Settings" $ \span -> do
  res <-
    foldRowsWithMonoid
      [sql|
    SELECT key, value
    FROM redacted.settings
  |]
      ()
      ( do
          key <- Dec.text
          Dec.jsonMay
            ( case key of
                "useFreeleechTokens" -> settingFreeleechToken <$> Json.asBool
                _ -> pure mempty
            )
            <&> fromMaybe mempty
      )
  lift $ addAttribute span "settings" (toOtelAttrGenericStruct res)
  pure res

writeSettings ::
  (MonadPostgres m, MonadOtel m) =>
  [T2 "key" Text "val" Json.Value] ->
  Transaction m (Label "numberOfRowsAffected" Natural)
writeSettings settings = inSpan' "Write Settings" $ \span -> do
  addAttribute
    span
    "settings"
    ( toOtelJsonAttr $
        Enc.list
          (\s -> Enc.tuple2 Enc.text Enc.value (s.key, s.val))
          settings
    )
  execute
    [sql|
    INSERT INTO redacted.settings (key, value)
    SELECT * FROM UNNEST(?::text[], ?::jsonb[])
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
  |]
    (settings & unzipPGArray @"key" @Text @"val" @Json.Value)

-- | Given a conduit that produces Html,
-- return a htmx html snippet which will regularly poll for new results in the conduit,
-- and a handler endpoint that returns the newest output when it happens.
conduitToHtmx ::
  (HasField "endpoint" opts Text, MonadUnliftIO m) =>
  opts ->
  -- | initial inner html
  Html ->
  ConduitT () Html m () ->
  m (m Html, HandlerResponse m, Async.Async ())
conduitToHtmx opts init' conduit = do
  let htmlPolling inner =
        [hsx|
     <div hx-get={opts.endpoint} hx-trigger="every 1s" hx-swap="outerHTML">
        {inner :: Html}
     </div>
    |]
  currentHtml <- newIORef $! htmlPolling init'
  collectorHandle <- Async.async $ do
    liftIO $ putStderrLn "spawned async collector"
    lastVal <-
      conduit
        .| Conduit.mapMC
          ( \html -> do
              atomicWriteIORef currentHtml $! (htmlPolling html)
              pure html
          )
        .| Conduit.lastDefC init'
          & Conduit.runConduit
    -- when the original conduit finishes, we stop polling for updates.
    atomicWriteIORef currentHtml $! [hsx|<div>{lastVal}</div>|]

  let handler = Html $ \_span -> do
        -- TODO: can we use Etags here and return 304 instead?
        readIORef currentHtml

  pure (readIORef currentHtml, handler, collectorHandle)

testCounter ::
  (HasField "endpoint" opts Text, MonadUnliftIO m) =>
  opts ->
  m (m Html, HandlerResponse m, Async ())
testCounter opts = conduitToHtmx opts [hsx|<p>0</p>|] counterConduit

counterConduit :: (MonadIO m) => ConduitT i Html m ()
counterConduit =
  Conduit.yieldMany [0 .. 100]
    .| Conduit.awaitForever
      ( \(i :: Int) -> do
          threadDelay 300_000
          Conduit.yield [hsx|<p>{i}</p>|]
      )

data HtmlIntegrity = HtmlIntegrity
  { -- | The name of the resource, for debugging purposes
    integrityName :: Text,
    -- | The URL of the resource content
    integrityUrl :: Text,
    -- | The integrity hash of the resource
    integrityHash :: Text,
    -- | The local url path to fetch the cached resource from the frontend
    localPath :: Text,
    -- | Whether there is a resource map at the URL + `.map`
    provideSourceMap :: Bool,
    -- | is @<link>@ or @<script>@ tag?
    isTag :: E2 "link" () "script" ()
  }

-- | Fetch a resource, calculate its integrity hash, and return a html @<link>@ snippet and a handler to return the resource.
prefetchResourceIntegrity :: forall m. (MonadOtel m, MonadThrow m) => HtmlIntegrity -> m (Html, (Arg "giveSourceMap" Bool) -> HandlerResponse m)
prefetchResourceIntegrity dat = inSpan' [fmt|prefetching resource {dat.integrityName}|] $ \span -> do
  let x =
        dat.integrityUrl
          & Parse.runParse "Failed to parse URI" (textToURI >>> uriToHttpClientRequest)
          & unwrapErrorTree

  resp <- Http.httpBS x
  let !statusCode = resp & Http.responseStatus & (.statusCode)
  let !mContentType =
        resp
          & Http.responseHeaders
          & List.lookup "content-type"
          <&> parseContentType
          <&> (\(!ct, _mimeAttributes) -> ct)

  let !bodyStrict = resp & Http.responseBody
  let !bodyLength = bodyStrict & ByteString.length
  if
    | statusCode == 200 -> do
        let tagMatch prx1 val1 prx2 val2 =
              dat.isTag
                & caseE2
                  ( t2
                      prx1
                      (\() -> val1)
                      prx2
                      (\() -> val2)
                  )
        mSourceMap <-
          if
            | dat.provideSourceMap -> do
                inSpan' [fmt|Get Source Map for {dat.integrityName}|] $ \span' -> do
                  let sourceMapUrl = dat.integrityUrl <> ".map"
                  let x' =
                        sourceMapUrl
                          & Parse.runParse "Failed to parse URI" (textToURI >>> uriToHttpClientRequest)
                          & unwrapErrorTree
                  resp' <- Http.httpBS x'
                  let !statusCode' = resp' & Http.responseStatus & (.statusCode)
                  if
                    | statusCode' == 200 -> do
                        pure $ Just <$> resp' & Http.responseBody
                    -- if it does not exist, let’s 404 as well
                    | statusCode' == 404 -> do
                        pure Nothing
                    | otherwise -> do
                        appThrow span' $ AppExceptionPretty [[fmt|Failed to fetch source map, got status code {statusCode'}|]]
            | otherwise -> pure Nothing
        pure
          ( tagMatch
              #link
              [hsx|<link rel="stylesheet" href={dat.localPath} integrity={dat.integrityHash} crossorigin="anonymous">|]
              #script
              [hsx|<script src={dat.localPath} integrity={dat.integrityHash} crossorigin="anonymous"></script>|],
            \(Arg giveSourceMap) -> Plain $ do
              if
                | giveSourceMap,
                  Just sourceMap <- mSourceMap -> do
                    pure $
                      Wai.responseLBS
                        Http.ok200
                        [ ( "Content-Type",
                            "application/json"
                          ),
                          ("Content-Length", buildBytes intDecimalB (ByteString.length sourceMap))
                        ]
                        (toLazyBytes sourceMap)
                | giveSourceMap -> do
                    pure $ Wai.responseLBS Http.notFound404 [] ""
                | otherwise -> do
                    pure $
                      Wai.responseLBS
                        Http.ok200
                        [ ( "Content-Type",
                            mContentType
                              & fromMaybe
                                ( tagMatch
                                    #script
                                    "text/javascript; charset=UTF-8"
                                    #link
                                    "text/css; charset=UTF-8"
                                )
                          ),
                          ("Content-Length", buildBytes intDecimalB bodyLength)
                        ]
                        (toLazyBytes $ bodyStrict)
          )
    | code <- statusCode -> appThrow span $ AppExceptionPretty [[fmt|Server returned an non-200 error code, code {code}:|], pretty resp]
