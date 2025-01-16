{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE QuasiQuotes #-}

module WhatcdResolver where

import AppT
import Arg
import Builder
import Comparison
import Control.Category qualified as Cat
import Control.Monad.Catch.Pure (runCatch)
import Control.Monad.Logger.CallStack
import Control.Monad.Reader
import Data.Aeson qualified as Json
import Data.Aeson.BetterErrors qualified as Json
import Data.Aeson.KeyMap qualified as KeyMap
import Data.CaseInsensitive (CI)
import Data.Error.Tree
import Data.HashMap.Strict qualified as HashMap
import Data.List qualified as List
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Pool qualified as Pool
import Data.Text qualified as Text
import Database.PostgreSQL.Simple qualified as Postgres
import Database.PostgreSQL.Simple.Types (PGArray (PGArray))
import Database.Postgres.Temp qualified as TmpPg
import FieldParser (FieldParser, FieldParser' (..))
import FieldParser qualified as Field
import Html qualified
import IHP.HSX.QQ (hsx)
import IHP.HSX.ToHtml (ToHtml)
import Json qualified
import Json.Enc (Enc)
import Json.Enc qualified as Enc
import JsonLd
import Label
import Multipart2 (MultipartParseT)
import Multipart2 qualified as Multipart
import MyPrelude
import Network.HTTP.Client.Conduit qualified as Http
import Network.HTTP.Simple qualified as Http
import Network.HTTP.Types
import Network.HTTP.Types qualified as Http
import Network.URI (URI)
import Network.URI qualified
import Network.Wai (ResponseReceived)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp qualified as Warp
import OpenTelemetry.Attributes qualified as Otel
import OpenTelemetry.Context.ThreadLocal qualified as Otel
import OpenTelemetry.Trace qualified as Otel hiding (getTracer, inSpan, inSpan')
import OpenTelemetry.Trace.Monad qualified as Otel
import Parse (Parse)
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
            Map.fromList
              [ ("", Html (mainHtml uniqueRunId)),
                ( "snips/redacted/search",
                  Html $
                    \span -> do
                      dat <-
                        parseMultipartOrThrow
                          span
                          req
                          ( do
                              label @"searchstr" <$> Multipart.field "redacted-search" Cat.id
                          )
                      t <- redactedSearchAndInsert [("searchstr", dat.searchstr)]
                      runTransaction $ do
                        res <- t
                        table <-
                          getBestTorrentsTable
                            (label @"groupByReleaseType" True)
                            ( Just (E21 (label @"onlyTheseTorrents" res.newTorrents)) ::
                                ( Maybe
                                    ( E2
                                        "onlyTheseTorrents"
                                        [Label "torrentId" Int]
                                        "artistRedactedId"
                                        Natural
                                    )
                                )
                            )
                        pure
                          [hsx|
                          <h1>Search results for <pre>{dat.searchstr}</pre></h1>
                          {table}
                        |]
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
                      ( \qry _span -> do
                          jsonld <- httpGetJsonLd (qry.target)
                          pure $ renderJsonld jsonld
                      )
                ),
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
                    HtmlWithQueryArgs
                      ( label @"artistRedactedId"
                          <$> (singleQueryArgument "redacted_id" (Field.utf8 >>> Field.decimalNatural))
                      )
                      $ \qry _span -> do
                        artistPage qry
                ),
                ( "artist/refresh",
                  HtmlOrRedirect $
                    \span -> do
                      dat <-
                        parseMultipartOrThrow
                          span
                          req
                          (label @"artistId" <$> Multipart.field "artist-id" Field.utf8)
                      t <- redactedRefreshArtist dat
                      runTransaction $ do
                        t
                      pure $ E22 (label @"redirectTo" [fmt|/artist?redacted_id={dat.artistId}|])
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
          (Html $ mainHtml uniqueRunId)
          handlers
          req
          respondOrig
  where
    everySecond :: Text -> Enc -> Html -> Html
    everySecond call extraData innerHtml = [hsx|<div hx-trigger="every 1s" hx-swap="outerHTML" hx-post={call} hx-vals={Enc.encToBytesUtf8 extraData}>{innerHtml}</div>|]

    mainHtml :: Text -> Otel.Span -> AppT IO Html
    mainHtml uniqueRunId _span = runTransaction $ do
      -- jsonld <-
      --   httpGetJsonLd
      --     ( URI.parseURI "https://musicbrainz.org/work/92000fd4-d304-406d-aeb4-6bdbeed318ec" & annotate "not an URI" & unwrapError,
      --       "https://musicbrainz.org/work/92000fd4-d304-406d-aeb4-6bdbeed318ec"
      --     )
      --     <&> renderJsonld
      (bestTorrentsTable, settings) <-
        concurrentlyTraced
          (getBestTorrentsTable (label @"groupByReleaseType" False) Nothing)
          (getSettings)
      -- transmissionTorrentsTable <- lift @Transaction getTransmissionTorrentsTable
      let returnUrl = (label @"returnUrl" "/")
      pure $
        htmlPageChrome
          "whatcd-resolver"
          [hsx|
            {settingButtons returnUrl settings}
            <form
              hx-post="/snips/redacted/search"
              hx-target="#redacted-search-results">
              <label for="redacted-search">Redacted Search</label>
              <input
                id="redacted-search"
                type="text"
                name="redacted-search" />
              <button type="submit" hx-disabled-elt="this">Search</button>
              <div class="htmx-indicator">Search running!</div>
            </form>
            <div id="redacted-search-results">
              {bestTorrentsTable}
            </div>
            <!-- refresh the page if the uniqueRunId is different -->
            <input
                hidden
                type="text"
                id="autorefresh"
                name="hasItBeenRestarted"
                value={uniqueRunId}
                hx-get="/autorefresh"
                hx-trigger="every 5s"
                hx-swap="none"
            />
        |]

-- | Run two actions concurrently, and add them to the current Otel trace
concurrentlyTraced :: (MonadUnliftIO m) => m a -> m b -> m (a, b)
concurrentlyTraced act1 act2 = do
  ctx <- Otel.getContext
  concurrently
    ( do
        _old <- Otel.attachContext ctx
        act1
    )
    ( do
        _old <- Otel.attachContext ctx
        act2
    )

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

htmlPageChrome :: (ToHtml a) => Text -> a -> Html
htmlPageChrome title body =
  Html.docTypeHtml $
    [hsx|
      <head>
        <!-- TODO: set nice page title for each page -->
        <title>{title}</title>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <!--
          prevent favicon request, based on answers in
          https://stackoverflow.com/questions/1321878/how-to-prevent-favicon-ico-requests
          TODO: create favicon
        -->
        <link rel="icon" href="data:,">
        <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet" integrity="sha384-9ndCyUaIbzAi2FUVXJi0CjmCapSmO7SnpJef0486qhLnuZ2cdeRhO02iuK6FUUVM" crossorigin="anonymous">
        <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js" integrity="sha384-geWF76RCwLtnZ8qwWowPQNguL3RmwHVBC9FhGdlKrxdiJJigb/j/68SIy3Te4Bkz" crossorigin="anonymous"></script>
        <script src="https://unpkg.com/htmx.org@1.9.2" integrity="sha384-L6OqL9pRWyyFU3+/bjdSri+iIphTN/bvYyM37tICVyOJkWZLpP2vGn6VUEXgzg6h" crossorigin="anonymous"></script>
        <style>
          dl {
            margin: 1em;
            padding: 0.5em 1em;
            border: thin solid;
          }
        </style>
      </head>
      <body>
        {body}
      </body>
    |]

artistPage ::
  ( HasField "artistRedactedId" dat Natural,
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
          (Just $ E22 (getLabel @"artistRedactedId" dat))
      )
      (getSettings)
  let artistName = fresh & findMaybe (\t -> t.artists & findMaybe (\a -> if a.artistId == (dat.artistRedactedId & fromIntegral @Natural @Int) then Just a.artistName else Nothing))
  let torrents = mkBestTorrentsTable (label @"groupByReleaseType" True) fresh

  let returnUrl =
        label @"returnUrl" $
          mkArtistLink (label @"artistId" (dat.artistRedactedId & fromIntegral @Natural @Int))
  pure $
    htmlPageChrome
      ( case artistName of
          Nothing -> "whatcd-resolver"
          Just a -> [fmt|{a} - Artist Page - whatcd-resolver|]
      )
      [hsx|
        {settingButtons returnUrl settings}
        <p>Artist ID: {dat.artistRedactedId}</p>

        <div id="artist-torrents">
          {torrents}
        </div>

        <form method="post" action="artist/refresh" hx-post="artist/refresh">
          <input
            hidden
            type="text"
            name="artist-id"
            value={dat.artistRedactedId & buildText naturalDecimalT}
            />
          <button type="submit" hx-disabled-elt="this">Refresh Artist Page</button>
          <div class="htmx-indicator">Refreshing!</div>
        </form>
      |]

type Handlers m = Map Text (HandlerResponse m)

data HandlerResponse m where
  -- | render html
  Html :: (Otel.Span -> m Html) -> HandlerResponse m
  -- | either render html or redirect to another page
  HtmlOrRedirect :: (Otel.Span -> m (E2 "respond" Html "redirectTo" ByteString)) -> HandlerResponse m
  -- | render html after parsing some query arguments
  HtmlWithQueryArgs :: Parse Query a -> (a -> Otel.Span -> m Html) -> HandlerResponse m
  -- | render html or reload the page via the Referer header if no htmx
  HtmlOrReferer :: (Otel.Span -> m Html) -> HandlerResponse m
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
  let htmlWithQueryArgs parser act =
        case req & Parse.runParse "Unable to find the right request query arguments" (lmap Wai.queryString parser) of
          Right a -> html (act a)
          Left err ->
            html
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

  let handler =
        handlers
          & Map.lookup path
          & fromMaybe defaultHandler
          & \case
            Html act -> html act
            HtmlOrRedirect act -> htmlOrRedirect act
            HtmlWithQueryArgs parser act -> htmlWithQueryArgs parser act
            HtmlOrReferer act -> htmlOrReferer act
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

-- | Make sure we can parse the given Text into an URI.
textToURI :: Parse Text URI
textToURI =
  Parse.fieldParser
    ( FieldParser $ \text ->
        text
          & textToString
          & Network.URI.parseURI
          & annotate [fmt|Cannot parse this as a URL: "{text}"|]
    )

-- | Make sure we can parse the given URI into a Request.
--
-- This tries to work around the horrible, horrible interface in Http.Client.
uriToHttpClientRequest :: Parse URI Http.Request
uriToHttpClientRequest =
  Parse.mkParseNoContext
    ( \url ->
        (url & Http.requestFromURI)
          & runCatch
          & first (checkException @Http.HttpException)
          & \case
            Left (Right (Http.InvalidUrlException urlText reason)) ->
              Left [fmt|Unable to set the url "{urlText}" as request URL, reason: {reason}|]
            Left (Right exc@(Http.HttpExceptionRequest _ _)) ->
              Left [fmt|Weird! Should not get a HttpExceptionRequest when parsing an URL (bad library design), was {exc & displayException}|]
            Left (Left someExc) ->
              Left [fmt|Weird! Should not get anyhting but a HttpException when parsing an URL (bad library design), was {someExc & displayException}|]
            Right req -> pure req
    )

checkException :: (Exception b) => SomeException -> Either SomeException b
checkException some = case fromException some of
  Nothing -> Left some
  Just e -> Right e

data ArtistFilter = ArtistFilter
  { onlyArtist :: Maybe (Label "artistId" Text)
  }

getBestTorrentsTable ::
  ( MonadTransmission m,
    MonadThrow m,
    MonadLogger m,
    MonadPostgres m,
    MonadOtel m,
    HasField "groupByReleaseType" opts Bool
  ) =>
  opts ->
  Maybe (E2 "onlyTheseTorrents" [Label "torrentId" Int] "artistRedactedId" Natural) ->
  Transaction m Html
getBestTorrentsTable opts dat = do
  fresh <- getBestTorrentsData dat
  pure $ mkBestTorrentsTable opts fresh

doIfJust :: (Applicative f) => (a -> f ()) -> Maybe a -> f ()
doIfJust = traverse_

getBestTorrentsData ::
  ( MonadTransmission m,
    MonadThrow m,
    MonadLogger m,
    MonadPostgres m,
    MonadOtel m
  ) =>
  Maybe (E2 "onlyTheseTorrents" [Label "torrentId" Int] "artistRedactedId" Natural) ->
  Transaction m [TorrentData (Label "percentDone" Percentage)]
getBestTorrentsData filters = inSpan' "get torrents table data" $ \span -> do
  let onlyArtist = label @"artistRedactedId" <$> (filters >>= getE22 @"artistRedactedId")
  onlyArtist & doIfJust (\a -> addAttribute span "artist-filter.redacted-id" (a.artistRedactedId, naturalDecimalT))
  let onlyTheseTorrents = filters >>= getE21 @"onlyTheseTorrents"
  onlyTheseTorrents & doIfJust (\a -> addAttribute span "torrent-filter.ids" (a <&> (getLabel @"torrentId") & showToText & Otel.toAttribute))

  let getBest = getBestTorrents GetBestTorrentsFilter {onlyDownloaded = False, ..}
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

mkBestTorrentsTable ::
  (HasField "groupByReleaseType" opts Bool) =>
  opts ->
  [TorrentData (Label "percentDone" Percentage)] ->
  Html
mkBestTorrentsTable opts fresh = do
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
  let bestRows rowData =
        rowData
          & foldMap
            ( \b -> do
                let artists =
                      b.artists
                        <&> ( \a ->
                                T2
                                  (label @"url" $ mkArtistLink a)
                                  (label @"content" $ Html.toHtml @Text a.artistName)
                            )
                        & mkLinkList

                [hsx|
                  <tr>
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
                  <td>{Html.toHtml @Text b.releaseType.unReleaseType}</td>
                  <td>{Html.toHtml @Natural b.torrentGroupJson.groupYear}</td>
                  <td>{Html.toHtml @Int b.seedingWeight}</td>
                  <td>{Html.toHtml @Text b.torrentFormat}</td>
                  <td><details hx-trigger="toggle once" hx-post="snips/redacted/torrentDataJson" hx-vals={Enc.encToBytesUtf8 $ Enc.object [("torrent-id", Enc.int b.torrentId)]}></details></td>
                  </tr>
                |]
            )
  let section rows = do
        let releaseType = rows & NonEmpty.head & (.releaseType.unReleaseType)
        [hsx|
        <h2>{releaseType}s</h2>
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
            {bestRows rows}
          </tbody>
        </table>
      |]

  case fresh & nonEmpty of
    Nothing -> [hsx|No torrents found|]
    Just fresh' -> do
      ( if opts.groupByReleaseType
          then
            fresh'
              & toList
              & groupAllWithComparison ((.releaseType) >$< releaseTypeComparison)
          else [fresh']
        )
        & foldMap section

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
      t.transmission_torrent_hash
    FROM redacted.torrents_json t;


    CREATE INDEX IF NOT EXISTS torrents_json_seeding ON redacted.torrents_json(((full_json_result->'seeding')::integer));
    CREATE INDEX IF NOT EXISTS torrents_json_snatches ON redacted.torrents_json(((full_json_result->'snatches')::integer));
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

submitSettingForm :: (HasField "returnUrl" r Text, ToHtml a) => r -> a -> Html
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

settingButtons :: (HasField "returnUrl" opts Text) => opts -> Settings -> Html
settingButtons opts s =
  if s.useFreeleechTokens
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
