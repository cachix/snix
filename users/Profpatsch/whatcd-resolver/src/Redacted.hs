{-# LANGUAGE QuasiQuotes #-}

module Redacted where

import AppT
import Arg
import Bencode
import Builder
import Comparison
import Conduit (ConduitT)
import Conduit qualified as Cond
import Control.Monad.Logger.CallStack
import Control.Monad.Reader
import Control.Monad.Trans.Resource (resourceForkWith)
import Data.Aeson qualified as Json
import Data.Aeson.BetterErrors qualified as Json
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.BEncode (BEncode)
import Data.Conduit ((.|))
import Data.Error.Tree
import Data.List qualified as List
import Data.List.NonEmpty qualified as NonEmpty
import Data.Maybe (catMaybes)
import Data.Text.IO qualified as Text.IO
import Data.Time (NominalDiffTime, UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Database.PostgreSQL.Simple (Binary (Binary), Only (..))
import Database.PostgreSQL.Simple.Types (PGArray (PGArray))
import FieldParser (FieldParser)
import FieldParser qualified as Field
import Http qualified
import Json qualified
import Label
import MyLabel
import MyPrelude
import Network.HTTP.Types
import Network.Wai.Parse qualified as Wai
import OpenTelemetry.Context.ThreadLocal qualified as Otel
import OpenTelemetry.Trace qualified as Otel hiding (getTracer, inSpan, inSpan')
import Optional
import Parse (Parse, mapLookup, mapLookupMay, runParse)
import Parse qualified
import Postgres.Decoder qualified as Dec
import Postgres.MonadPostgres
import Pretty
import RevList (RevList)
import RevList qualified
import UnliftIO (MonadUnliftIO, askRunInIO, async, newQSem, withQSem)
import UnliftIO.Async (Async)
import UnliftIO.Async qualified as Async
import UnliftIO.Concurrent (threadDelay)
import Prelude hiding (length, span)

class MonadRedacted m where
  getRedactedApiKey :: m ByteString

instance (MonadIO m) => MonadRedacted (AppT m) where
  getRedactedApiKey = AppT (asks (.redactedApiKey))

redactedSearch ::
  ( MonadThrow m,
    MonadOtel m,
    MonadRedacted m,
    HasField "actionArgs" extraArguments [(ByteString, ByteString)],
    HasField "page" dat (Maybe Natural)
  ) =>
  extraArguments ->
  dat ->
  Json.Parse ErrorTree a ->
  m a
redactedSearch extraArguments dat parser =
  inSpan' "Redacted API Search" $ \span ->
    redactedPagedRequest
      span
      ( t3
          #action
          "browse"
          #actionArgs
          extraArguments.actionArgs
          #page
          dat.page
      )
      parser

redactedGetArtist ::
  ( MonadOtel m,
    MonadThrow m,
    MonadRedacted m,
    HasField "artistId" r Int,
    HasField "page" r (Maybe Natural)
  ) =>
  r ->
  Json.Parse ErrorTree a ->
  m a
redactedGetArtist dat parser =
  inSpan' "Redacted Get Artist" $ \span -> do
    redactedPagedRequest
      span
      ( t3
          #action
          "artist"
          #actionArgs
          [("id", buildBytes intDecimalB dat.artistId)]
          #page
          (dat.page)
      )
      parser

redactedPagedRequest ::
  ( MonadThrow m,
    MonadOtel m,
    MonadRedacted m,
    HasField "action" dat ByteString,
    HasField "actionArgs" dat [(ByteString, ByteString)],
    HasField "page" dat (Maybe Natural)
  ) =>
  Otel.Span ->
  dat ->
  Json.Parse ErrorTree a ->
  m a
redactedPagedRequest span dat parser =
  redactedApiRequestJson
    span
    ( t2
        #action
        dat.action
        #actionArgs
        ( (dat.actionArgs <&> second Just)
            <> ( dat.page
                   & ifExists
                     (\page -> ("page", Just $ buildBytes naturalDecimalB page))
               )
        )
    )
    parser

redactedGetTorrentFile ::
  ( MonadLogger m,
    MonadThrow m,
    HasField "torrentId" dat Int,
    HasField "useFreeleechTokens" dat Bool,
    MonadOtel m,
    MonadRedacted m
  ) =>
  dat ->
  m ByteString
redactedGetTorrentFile dat = inSpan' "Redacted Get Torrent File" $ \span -> do
  let actionArgs =
        [ ("id", Just (buildBytes intDecimalB dat.torrentId))
        ]
          -- try using tokens as long as we have them (TODO: what if there’s no tokens left?
          -- ANSWER: it breaks:
          -- responseBody = "{\"status\":\"failure\",\"error\":\"You do not have any freeleech tokens left. Please use the regular DL link.\"}",
          <> (if dat.useFreeleechTokens then [("usetoken", Just "1")] else [])
  let reqDat =
        ( T2
            (label @"action" "download")
            ( label @"actionArgs" $ actionArgs
            )
        )
  addAttribute span "redacted.request" (toOtelJsonAttr reqDat)
  req <- mkRedactedApiRequest reqDat

  httpTorrent span req

mkRedactedTorrentLink :: Arg "torrentGroupId" Int -> Text
mkRedactedTorrentLink torrentId = [fmt|https://redacted.sh/torrents.php?id={torrentId.unArg}|]

exampleSearch :: (MonadThrow m, MonadLogger m, MonadPostgres m, MonadOtel m, MonadRedacted m) => Transaction m ()
exampleSearch = do
  _x1 <-
    redactedSearchAndInsert
      [ ("searchstr", "cherish"),
        ("artistname", "kirinji"),
        -- ("year", "1982"),
        -- ("format", "MP3"),
        -- ("releasetype", "album"),
        ("order_by", "year")
      ]
  _x3 <-
    redactedSearchAndInsert
      [ ("searchstr", "mouss et hakim"),
        ("artistname", "mouss et hakim"),
        -- ("year", "1982"),
        -- ("format", "MP3"),
        -- ("releasetype", "album"),
        ("order_by", "year")
      ]
  _x2 <-
    redactedSearchAndInsert
      [ ("searchstr", "thriller"),
        ("artistname", "michael jackson"),
        -- ("year", "1982"),
        -- ("format", "MP3"),
        -- ("releasetype", "album"),
        ("order_by", "year")
      ]
  pure ()

redactedRefreshArtist ::
  ( MonadLogger m,
    MonadPostgres m,
    MonadThrow m,
    MonadOtel m,
    MonadRedacted m,
    HasField "artistId" dat Int
  ) =>
  dat ->
  Transaction m (Label "newTorrents" [Label "torrentId" Int])
redactedRefreshArtist dat = do
  redactedPagedSearchAndInsert
    ( Json.key "torrentgroup" $
        parseTourGroups
          ( t2
              #torrentFieldName
              "torrent"
              #torrentIdName
              "id"
          )
    )
    ( \page ->
        redactedGetArtist
          ( T2
              (getLabel @"artistId" dat)
              page
          )
    )

-- | Do the search, return a transaction that inserts all results from all pages of the search.
redactedSearchAndInsert ::
  (MonadLogger m, MonadPostgres m, MonadThrow m, MonadOtel m, MonadRedacted m) =>
  [(ByteString, ByteString)] ->
  Transaction m (Label "newTorrents" [Label "torrentId" Int])
redactedSearchAndInsert extraArguments =
  redactedPagedSearchAndInsert
    (Json.key "results" $ parseTourGroups (T2 (label @"torrentFieldName" "torrents") (label @"torrentIdName" "torrentId")))
    ( redactedSearch
        (label @"actionArgs" extraArguments)
    )

-- | Parse the standard Redacted reply object, @{ status: "success", response: ... }@ or throw an error.
--
-- The response might contain a `pages` field, if not we’ll return 1.
parseRedactedReplyStatus ::
  (Monad m) =>
  Json.ParseT ErrorTree m b ->
  Json.ParseT ErrorTree m (T2 "pages" Natural "response" b)
parseRedactedReplyStatus inner = do
  status <- Json.key "status" Json.asText
  when (status /= "success") $ do
    Json.throwCustomError ([fmt|Status was not "success", but {status}|] :: ErrorTree)
  Json.key "response" $ do
    pages <-
      Json.keyMay
        "pages"
        ( Field.toJsonParser
            ( Field.mapError singleError $
                Field.jsonNumber >>> Field.boundedScientificIntegral @Int "not an Integer" >>> Field.integralToNatural
            )
        )
        -- in case the field is missing, let’s assume there is only one page
        <&> fromMaybe 1
    res <- inner
    pure $
      T2
        (label @"pages" pages)
        (label @"response" res)

type TourGroups =
  ( Label
      "tourGroups"
      [ T2
          "tourGroup"
          TourGroup
          "torrents"
          [T2 "torrentId" Int "fullJsonResult" Json.Value]
      ]
  )

data TourGroup = TourGroup
  { groupId :: Int,
    groupName :: Text,
    fullJsonResult :: Json.Value,
    -- | Needed for sm0rt request recursion
    groupArtists :: [Label "artistId" Int]
  }

parseTourGroups ::
  ( Monad m,
    HasField "torrentFieldName" opts Text,
    HasField "torrentIdName" opts Text
  ) =>
  opts ->
  Json.ParseT err m TourGroups
parseTourGroups opts =
  do
    label @"tourGroups"
    <$> ( catMaybes
            <$> ( Json.eachInArray $ do
                    Json.keyMay opts.torrentFieldName (pure ()) >>= \case
                      -- not a torrent group, maybe some files or something (e.g. guitar tabs see Dream Theater Systematic Chaos)
                      Nothing -> pure Nothing
                      Just () -> do
                        groupId <- Json.key "groupId" (Json.asIntegral @_ @Int)
                        groupName <- Json.key "groupName" Json.asText
                        groupArtists <-
                          Json.keyMayMempty "artists" $
                            Json.eachInArray $
                              lbl #artistId <$> Json.key "id" (Json.asIntegral @_ @Int)
                        fullJsonResult <-
                          Json.asObject
                            -- remove torrents cause they are inserted separately below
                            <&> KeyMap.filterWithKey (\k _ -> k /= (opts.torrentFieldName & Key.fromText))
                            <&> Json.Object
                        let tourGroup = TourGroup {..}
                        torrents <- Json.keyLabel @"torrents" opts.torrentFieldName $
                          Json.eachInArray $ do
                            torrentId <- Json.keyLabel @"torrentId" opts.torrentIdName (Json.asIntegral @_ @Int)
                            fullJsonResultT <-
                              label @"fullJsonResult"
                                <$> ( Json.asObject
                                        <&> KeyMap.mapKeyVal
                                          ( \k ->
                                              if
                                                -- some torrent objects use “snatched” instead of “snatches”
                                                | k == "snatched" -> "snatches"
                                                -- normalize the torrent id field
                                                | k == (opts.torrentIdName & Key.fromText) -> "torrentId"
                                                | otherwise -> k
                                          )
                                          id
                                        <&> Json.Object
                                    )
                            pure $ T2 torrentId fullJsonResultT
                        pure $ Just (T2 (label @"tourGroup" tourGroup) torrents)
                )
        )

testChunkBetween :: IO [NonEmpty Integer]
testChunkBetween = do
  Cond.runConduit $
    ( do
        Cond.yield [0]
        Cond.yield [1, 2]
        Cond.yield [3, 4]
        Cond.yield []
        Cond.yield [5, 6]
        Cond.yield [7]
    )
      .| filterEmpty
      .| chunkBetween (t2 #low 2 #high 4)
      .| Cond.sinkList

filterEmpty :: (Monad m) => ConduitT [a] (NonEmpty a) m ()
filterEmpty = Cond.awaitForever yieldIfNonEmpty

-- | Chunk the given stream of lists into chunks that are between @low@ and @high@ (both incl).
-- The last chunk might be shorter than low.
chunkBetween ::
  ( HasField "low" p Natural,
    HasField "high" p Natural,
    Monad m
  ) =>
  p ->
  ConduitT (NonEmpty a) (NonEmpty a) m ()
chunkBetween opts = do
  go mempty
  where
    low = min opts.low opts.high
    high = max opts.low opts.high
    high' = assertField (boundedNatural @Int) high
    l = lengthNatural
    go !acc = do
      if l acc >= low
        then do
          let (c, rest) = List.splitAt high' acc
          yieldIfNonEmpty c
          go rest
        else do
          xs <- Cond.await
          case xs of
            Nothing -> yieldIfNonEmpty acc
            Just xs' -> go (acc <> NonEmpty.toList xs')

yieldIfNonEmpty :: (Monad m) => [a] -> ConduitT i (NonEmpty a) m ()
yieldIfNonEmpty = \case
  IsNonEmpty xs -> Cond.yield xs
  IsEmpty -> pure ()

redactedPagedSearchAndInsert ::
  forall m.
  ( MonadLogger m,
    MonadPostgres m,
    MonadOtel m
  ) =>
  Json.Parse ErrorTree TourGroups ->
  -- | A redacted request that returns a paged result
  ( forall a.
    Label "page" (Maybe Natural) ->
    Json.Parse ErrorTree a ->
    m a
  ) ->
  Transaction m (Label "newTorrents" [Label "torrentId" Int])
redactedPagedSearchAndInsert innerParser pagedRequest = do
  -- The first search returns the amount of pages, so we use that to query all results piece by piece.
  firstPage <- go Nothing
  let remainingPages = firstPage.pages - 1
  logInfo [fmt|Got the first page, found {remainingPages} more pages|]
  let otherPagesNum = [(2 :: Natural) .. remainingPages]

  Cond.runConduit @(Transaction m) $
    ( do
        Cond.yield (singleton firstPage)
        case otherPagesNum of
          IsNonEmpty o -> runConcurrentlyBunched' (lbl #batchSize 5) (go . Just <$> o)
          IsEmpty -> pure ()
    )
      .| chunkBetween (t2 #low 5 #high 10)
      .| Cond.mapMC
        ( \block ->
            block
              & concatMap (.response.tourGroups)
              & \case
                IsNonEmpty tgs -> do
                  tgs & insertTourGroupsAndTorrents
                  pure $ tgs & concatMap (\tg -> tg.torrents <&> getLabel @"torrentId")
                IsEmpty -> pure []
        )
      .| Cond.concatC
      .| Cond.sinkList
        <&> label @"newTorrents"
  where
    go mpage =
      lift @Transaction $
        pagedRequest
          (label @"page" mpage)
          ( parseRedactedReplyStatus $ innerParser
          )
    insertTourGroupsAndTorrents ::
      NonEmpty
        ( T2
            "tourGroup"
            TourGroup
            "torrents"
            [T2 "torrentId" Int "fullJsonResult" Json.Value]
        ) ->
      Transaction m ()
    insertTourGroupsAndTorrents dat = inSpan' "Insert Tour Groups & Torrents" $ \span -> do
      addAttribute span "tour_group.length" (dat & lengthNatural, naturalDecimalT)
      let tourGroups = dat <&> (.tourGroup)
      let torrents = dat <&> (.torrents)
      insertTourGroups tourGroups
        >>= ( \res ->
                insertTorrents $
                  zipT2 $
                    T2
                      (label @"torrentGroupIdPg" $ res <&> (.tourGroupIdPg))
                      (label @"torrents" (torrents & toList))
            )
    insertTourGroups ::
      NonEmpty TourGroup ->
      Transaction m [Label "tourGroupIdPg" Int]
    insertTourGroups dats = do
      let groupNames =
            dats <&> \dat -> [fmt|{dat.groupId}: {dat.groupName}|]
      logInfo [fmt|Inserting tour groups for {showPretty groupNames}|]
      _ <-
        execute
          [fmt|
                  DELETE FROM redacted.torrent_groups
                  WHERE group_id = ANY (?::integer[])
              |]
          (Only $ (dats <&> (.groupId) & toList & PGArray :: PGArray Int))
      executeManyReturningWith
        [fmt|
              INSERT INTO redacted.torrent_groups (
                group_id, group_name, full_json_result
              ) VALUES
              ( ?, ? , ? )
              ON CONFLICT (group_id) DO UPDATE SET
                group_id = excluded.group_id,
                group_name = excluded.group_name,
                full_json_result = excluded.full_json_result
              RETURNING (id)
            |]
        ( dats
            -- make sure we don’t have the same conflict target twice
            & NonEmpty.nubBy (\a b -> a.groupId == b.groupId)
            <&> ( \dat ->
                    ( dat.groupId,
                      dat.groupName,
                      dat.fullJsonResult
                    )
                )
        )
        (label @"tourGroupIdPg" <$> Dec.fromField @Int)

    insertTorrents ::
      [ T2
          "torrentGroupIdPg"
          Int
          "torrents"
          [T2 "torrentId" Int "fullJsonResult" Json.Value]
      ] ->
      Transaction m ()
    insertTorrents dats = do
      _ <-
        execute
          [sql|
            DELETE FROM redacted.torrents_json
            WHERE torrent_id = ANY (?::integer[])
          |]
          ( Only $
              PGArray
                [ torrent.torrentId
                  | dat <- dats,
                    torrent <- dat.torrents
                ]
          )

      execute
        [sql|
          INSERT INTO redacted.torrents_json
            ( torrent_group
            , torrent_id
            , full_json_result)
          SELECT *
          FROM UNNEST(
              ?::integer[]
            , ?::integer[]
            , ?::jsonb[]
          ) AS inputs(
              torrent_group
            , torrent_id
            , full_json_result)
          |]
        ( [ T3
              (getLabel @"torrentGroupIdPg" dat)
              (getLabel @"torrentId" group)
              (getLabel @"fullJsonResult" group)
            | dat <- dats,
              group <- dat.torrents
          ]
            & List.nubBy (\a b -> a.torrentId == b.torrentId)
            & unzip3PGArray
              @"torrentGroupIdPg"
              @Int
              @"torrentId"
              @Int
              @"fullJsonResult"
              @Json.Value
        )
      pure ()

-- | Traverse over the given function in parallel, but only allow a certain amount of concurrent requests.
-- Will start new threads as soon as a resource becomes available, but always return results in input ordering.
runConcurrentlyBunched' ::
  forall m opts a.
  ( MonadUnliftIO m,
    HasField "batchSize" opts Natural
  ) =>
  opts ->
  -- | list of actions to run
  NonEmpty (m a) ->
  ConduitT () (NonEmpty a) m ()
runConcurrentlyBunched' opts acts = do
  let batchSize = assertField (boundedNatural @Int) opts.batchSize
  runInIO <- lift askRunInIO
  -- NB: make sure none of the asyncs escape from here
  Cond.transPipe (Cond.runResourceT @m) $ do
    -- This use of resourceForkWith looks a little off, but it’s the only way to return an `Async a`, I hope it brackets correctly lol
    ctx <- Otel.getContext
    let spawn :: m a -> Cond.ResourceT m (Async a)
        spawn f = resourceForkWith (\io -> async (io >> Otel.attachContext ctx >> runInIO f)) (pure ())
    qsem <- newQSem batchSize

    -- spawn all asyncs here, but limit how many get run consecutively by threading through a semaphore
    spawned <- for acts $ \act ->
      lift $ spawn $ withQSem qsem $ act

    Cond.yieldMany (spawned & NonEmpty.toList)
      .| awaitAllReadyAsyncs

-- | Consume as many asyncs as are ready and return their results.
--
-- Make sure they are already running (if you use 'Cond.yieldM' they are only started when awaited by the conduit).
--
-- If any async throws an exception, the exception will be thrown in the conduit.
-- Already running asyncs will not be cancelled. (TODO: can we somehow make that a thing?)
awaitAllReadyAsyncs :: forall m a. (MonadIO m) => ConduitT (Async a) (NonEmpty a) m ()
awaitAllReadyAsyncs = go
  where
    -- wait for the next async and then consume as many as are already done
    go :: ConduitT (Async a) (NonEmpty a) m ()
    go = do
      Cond.await >>= \case
        Nothing -> pure ()
        Just nextAsync -> do
          res <- Async.wait nextAsync
          -- consume as many asyncs as are already done
          goAllReady (RevList.singleton res)

    goAllReady :: RevList a -> ConduitT (Async a) (NonEmpty a) m ()
    goAllReady !acc = do
      next <- Cond.await
      case next of
        Nothing -> yieldIfNonEmptyRev acc
        Just a -> do
          thereAlready <- Async.poll a
          case thereAlready of
            Nothing -> do
              -- consumed everything that was available, yield and wait for the next block
              yieldIfNonEmptyRev acc
              Cond.leftover a
              go
            Just _ -> do
              -- will not block
              res <- Async.wait a
              goAllReady (acc <> RevList.singleton res)

    yieldIfNonEmptyRev :: RevList a -> ConduitT (Async a) (NonEmpty a) m ()
    yieldIfNonEmptyRev r = do
      case r & RevList.revListToList of
        IsNonEmpty e -> Cond.yield e
        IsEmpty -> pure ()

testAwaitAllReadyAsyncs :: IO [[Char]]
testAwaitAllReadyAsyncs =
  Cond.runConduit $
    ( do
        running <-
          lift $
            sequence
              [ async (print "foo" >> pure 'a'),
                async (pure 'b'),
                async (threadDelay 5000 >> pure 'c'),
                async (print "bar" >> pure '5'),
                async (threadDelay 1_000_000 >> print "lol" >> pure 'd'),
                async (error "no"),
                async (print "baz" >> pure 'f')
              ]
        Cond.yieldMany running
    )
      .| awaitAllReadyAsyncs
      .| Cond.mapC toList
      .| Cond.sinkList

-- | Run the field parser and throw an uncatchable assertion error if it fails.
assertField :: (HasCallStack) => FieldParser from to -> from -> to
assertField parser from = Field.runFieldParser parser from & unwrapError

boundedNatural :: forall i. (Integral i, Bounded i) => FieldParser Natural i
boundedNatural = lmap naturalToInteger (Field.bounded @i "boundedNatural")

redactedGetTorrentFileAndInsert ::
  ( HasField "torrentId" r Int,
    HasField "useFreeleechTokens" r Bool,
    MonadPostgres m,
    MonadThrow m,
    MonadLogger m,
    MonadOtel m,
    MonadRedacted m
  ) =>
  r ->
  Transaction m (Label "torrentFile" ByteString)
redactedGetTorrentFileAndInsert dat = inSpan' "Redacted Get Torrent File and Insert" $ \span -> do
  bytes <- lift $ redactedGetTorrentFile dat
  execute
    [sql|
    UPDATE redacted.torrents_json
    SET torrent_file = ?::bytea
    WHERE torrent_id = ?::integer
  |]
    ( (Binary bytes :: Binary ByteString),
      dat.torrentId
    )
    >>= assertOneUpdated span "redactedGetTorrentFileAndInsert"
    >>= \() -> pure (label @"torrentFile" bytes)

getTorrentFileById ::
  ( MonadPostgres m,
    HasField "torrentId" r Int,
    MonadThrow m
  ) =>
  r ->
  Transaction m (Maybe (Label "torrentFile" ByteString))
getTorrentFileById dat = do
  queryWith
    [sql|
    SELECT torrent_file
    FROM redacted.torrents
    WHERE torrent_id = ?::integer
  |]
    (Only $ (dat.torrentId :: Int))
    (fmap @Maybe (label @"torrentFile") <$> Dec.byteaMay)
    >>= ensureSingleRow

updateTransmissionTorrentHashById ::
  ( MonadPostgres m,
    HasField "torrentId" r Int,
    HasField "torrentHash" r Text
  ) =>
  r ->
  Transaction m (Label "numberOfRowsAffected" Natural)
updateTransmissionTorrentHashById dat = do
  execute
    [sql|
    UPDATE redacted.torrents_json
    SET transmission_torrent_hash = ?::text
    WHERE torrent_id = ?::integer
    |]
    ( dat.torrentHash :: Text,
      dat.torrentId :: Int
    )

assertOneUpdated ::
  (HasField "numberOfRowsAffected" r Natural, MonadThrow m, MonadIO m) =>
  Otel.Span ->
  Text ->
  r ->
  m ()
assertOneUpdated span name x = case x.numberOfRowsAffected of
  1 -> pure ()
  n -> appThrow span ([fmt|{name :: Text}: Expected to update exactly one row, but updated {n :: Natural} row(s)|])

data TorrentData transmissionInfo = TorrentData
  { groupId :: Int,
    torrentId :: Int,
    releaseType :: ReleaseType,
    seedingWeight :: Int,
    artists :: [T2 "artistId" Int "artistName" Text],
    torrentGroupJson :: TorrentGroupJson,
    torrentStatus :: TorrentStatus transmissionInfo,
    torrentFormat :: Text
  }

-- | https://redacted.sh/wiki.php?action=article&id=455#_1804298149
data ReleaseType = ReleaseType {intKey :: Int, stringKey :: Text}
  deriving stock (Eq, Show)

releaseTypeFromTextOrIntKey :: Text -> ReleaseType
releaseTypeFromTextOrIntKey t =
  allReleaseTypesSorted
    & List.find
      ( \rt -> do
          rt.stringKey == t || buildText intDecimalT rt.intKey == t
      )
    & fromMaybe (ReleaseType {intKey = (-1), stringKey = t})

releaseTypeComparison :: Comparison ReleaseType
releaseTypeComparison = listIndexComparison allReleaseTypesSorted

allReleaseTypesSorted :: [ReleaseType]
allReleaseTypesSorted =
  [ releaseTypeAlbum,
    releaseTypeLiveAlbum,
    releaseTypeAnthology,
    releaseTypeSoundtrack,
    releaseTypeEP,
    releaseTypeCompilation,
    releaseTypeSingle,
    releaseTypeRemix,
    releaseTypeBootleg,
    releaseTypeInterview,
    releaseTypeMixtape,
    releaseTypeDemo,
    releaseTypeConcertRecording,
    releaseTypeDJMix,
    releaseTypeUnknown,
    releaseTypeProducedBy,
    releaseTypeComposition,
    releaseTypeRemixedBy,
    releaseTypeGuestAppearance
  ]

releaseTypeAlbum, releaseTypeSoundtrack, releaseTypeEP, releaseTypeAnthology, releaseTypeCompilation, releaseTypeSingle, releaseTypeLiveAlbum, releaseTypeRemix, releaseTypeBootleg, releaseTypeInterview, releaseTypeMixtape, releaseTypeDemo, releaseTypeConcertRecording, releaseTypeDJMix, releaseTypeUnknown, releaseTypeProducedBy, releaseTypeComposition, releaseTypeRemixedBy, releaseTypeGuestAppearance :: ReleaseType
releaseTypeAlbum = ReleaseType 1 "Album"
releaseTypeSoundtrack = ReleaseType 3 "Soundtrack"
releaseTypeEP = ReleaseType 5 "EP"
releaseTypeAnthology = ReleaseType 6 "Anthology"
releaseTypeCompilation = ReleaseType 7 "Compilation"
releaseTypeSingle = ReleaseType 9 "Single"
releaseTypeLiveAlbum = ReleaseType 11 "Live album"
releaseTypeRemix = ReleaseType 13 "Remix"
releaseTypeBootleg = ReleaseType 14 "Bootleg"
releaseTypeInterview = ReleaseType 15 "Interview"
releaseTypeMixtape = ReleaseType 16 "Mixtape"
releaseTypeDemo = ReleaseType 17 "Demo"
releaseTypeConcertRecording = ReleaseType 18 "Concert Recording"
releaseTypeDJMix = ReleaseType 19 "DJ Mix"
releaseTypeUnknown = ReleaseType 21 "Unknown"
releaseTypeProducedBy = ReleaseType 1021 "Produced By"
releaseTypeComposition = ReleaseType 1022 "Composition"
releaseTypeRemixedBy = ReleaseType 1023 "Remixed By"
releaseTypeGuestAppearance = ReleaseType 1024 "Guest Appearance"

data TorrentGroupJson = TorrentGroupJson
  { groupName :: Text,
    groupYear :: Natural
  }

data TorrentStatus transmissionInfo
  = NoTorrentFileYet
  | NotInTransmissionYet
  | InTransmission (T2 "torrentHash" Text "transmissionInfo" transmissionInfo)

getTorrentById :: (MonadPostgres m, HasField "torrentId" r Int, MonadThrow m) => r -> Transaction m Json.Value
getTorrentById dat = do
  queryWith
    [sql|
    SELECT full_json_result FROM redacted.torrents
    WHERE torrent_id = ?::integer
  |]
    (getLabel @"torrentId" dat)
    (Dec.json Json.asValue)
    >>= ensureSingleRow

data GetBestTorrentsFilter = GetBestTorrentsFilter
  { onlyArtist :: Maybe (Label "artistRedactedId" Int),
    onlyTheseTorrents :: Maybe ([Label "torrentId" Int]),
    disallowedReleaseTypes :: [ReleaseType],
    limitResults :: Maybe Natural,
    ordering :: BestTorrentsOrdering,
    onlyFavourites :: Bool
  }

data BestTorrentsOrdering = BySeedingWeight | ByLastReleases

-- | Find the best torrent for each torrent group (based on the seeding_weight)
getBestTorrents ::
  (MonadPostgres m) =>
  GetBestTorrentsFilter ->
  Transaction m [TorrentData ()]
getBestTorrents opts = do
  queryWith
    ( [sql|
      WITH
      artist_has_been_snatched AS (
        SELECT DISTINCT artist_id
        FROM (
          SELECT
            UNNEST(artist_ids) as artist_id,
            t.torrent_file IS NOT NULL as has_torrent_file
          FROM redacted.torrents t) as _
        WHERE has_torrent_file
      ),
      filtered_torrents AS (
        SELECT DISTINCT ON (torrent_group)
          id
        FROM
          redacted.torrents
        JOIN LATERAL
          -- filter everything that’s not a favourite if requested
          (SELECT (
            artist_ids && ARRAY(SELECT artist_id FROM redacted.artist_favourites)
            OR artist_ids && ARRAY(SELECT artist_id FROM artist_has_been_snatched)
          ) as is_favourite) as _
          ON (NOT ?::bool OR is_favourite)
        WHERE
          -- filter by artist id
          (?::bool OR (?::int = any (artist_ids)))
          -- filter by torrent ids
          AND
          (?::bool OR torrent_id = ANY (?::int[]))
        ORDER BY
          torrent_group,
          -- prefer torrents which we already downloaded
          torrent_file,
          seeding_weight DESC
      ),
      prepare1 AS (
        SELECT
          tg.group_id,
          t.torrent_id,
          t.seeding_weight,
          tg.full_json_result->>'releaseType' AS release_type,
          -- TODO: different endpoints handle this differently (e.g. action=search and action=artist), we should unify this while parsing
          COALESCE(
            t.full_json_result->'artists',
            tg.full_json_result->'artists',
            '[]'::jsonb
          ) as artists,
          t.artist_ids || tg.artist_ids as artist_ids,
          tg.full_json_result->>'groupName' AS group_name,
          tg.full_json_result->>'groupYear' AS group_year,
          t.torrent_file IS NOT NULL AS has_torrent_file,
          t.transmission_torrent_hash,
          t.full_json_result->>'encoding' AS torrent_format
        FROM filtered_torrents f
        JOIN redacted.torrents t ON t.id = f.id
        JOIN redacted.torrent_groups tg ON tg.id = t.torrent_group
        WHERE
          tg.full_json_result->>'releaseType' <> ALL (?::text[])
      )
      SELECT
        group_id,
        torrent_id,
        seeding_weight,
        release_type,
        artists,
        group_name,
        group_year,
        has_torrent_file,
        transmission_torrent_hash,
        torrent_format
      FROM prepare1
    |]
        <> case opts.ordering of
          BySeedingWeight -> [fmt|ORDER BY seeding_weight DESC|] <> "\n"
          ByLastReleases -> [fmt|ORDER BY group_id DESC|] <> "\n"
        <> [sql|
      LIMIT ?::int
    |]
    )
    ( do
        let (onlyArtistB, onlyArtistId) = case opts.onlyArtist of
              Nothing -> (True, 0)
              Just a -> (False, a.artistRedactedId)
        let (onlyTheseTorrentsB, onlyTheseTorrents) = case opts.onlyTheseTorrents of
              Nothing -> (True, PGArray [])
              Just a -> (False, a <&> (.torrentId) & PGArray)
        ( opts.onlyFavourites :: Bool,
          onlyArtistB :: Bool,
          onlyArtistId :: Int,
          onlyTheseTorrentsB :: Bool,
          onlyTheseTorrents,
          (opts.disallowedReleaseTypes & concatMap (\rt -> [rt.stringKey, rt.intKey & buildText intDecimalT]) & PGArray :: PGArray Text),
          opts.limitResults <&> naturalToInteger :: Maybe Integer
          )
    )
    ( do
        groupId <- Dec.fromField @Int
        torrentId <- Dec.fromField @Int
        seedingWeight <- Dec.fromField @Int
        releaseType <- releaseTypeFromTextOrIntKey <$> Dec.text
        artists <- Dec.json $
          Json.eachInArray $ do
            id_ <- Json.keyLabel @"artistId" "id" (Json.asIntegral @_ @Int)
            name <- Json.keyLabel @"artistName" "name" Json.asText
            pure $ T2 id_ name
        torrentGroupJson <- do
          groupName <- Dec.text
          groupYear <- Dec.textParse Field.decimalNatural
          pure $ TorrentGroupJson {..}
        hasTorrentFile <- Dec.fromField @Bool
        transmissionTorrentHash <- Dec.fromField @(Maybe Text)
        torrentFormat <- Dec.text
        pure $
          TorrentData
            { torrentStatus =
                if
                  | not hasTorrentFile -> NoTorrentFileYet
                  | Nothing <- transmissionTorrentHash -> NotInTransmissionYet
                  | Just hash <- transmissionTorrentHash ->
                      InTransmission $
                        T2 (label @"torrentHash" hash) (label @"transmissionInfo" ()),
              torrentFormat = case torrentFormat of
                "Lossless" -> "flac"
                "V0 (VBR)" -> "V0"
                "V2 (VBR)" -> "V2"
                "320" -> "320"
                "256" -> "256"
                o -> o,
              ..
            }
    )

getArtistNameById :: (MonadPostgres m, HasField "artistId" r Int) => r -> Transaction m (Maybe Text)
getArtistNameById dat = do
  queryFirstRowWithMaybe
    [sql|
        SELECT artist_name FROM redacted.artist_names
        WHERE artist_id = ?::int
        LIMIT 1
  |]
    (getLabel @"artistId" dat)
    (Dec.fromField @Text)

-- | Do a request to the redacted API. If you know what that is, you know how to find the API docs.
mkRedactedApiRequest ::
  ( MonadThrow m,
    HasField "action" p ByteString,
    HasField "actionArgs" p [(ByteString, Maybe ByteString)],
    MonadRedacted m
  ) =>
  p ->
  m Http.Request
mkRedactedApiRequest dat = do
  authKey <- getRedactedApiKey
  pure $
    [fmt|https://redacted.sh/ajax.php|]
      & Http.setRequestMethod "GET"
      & Http.setQueryString (("action", Just dat.action) : dat.actionArgs)
      & Http.setRequestHeader "Authorization" [authKey]

httpTorrent ::
  ( MonadIO m,
    MonadThrow m
  ) =>
  Otel.Span ->
  Http.Request ->
  m ByteString
httpTorrent span req =
  Http.httpBS req
    >>= assertM
      span
      ( \resp -> do
          let statusCode = resp & Http.getResponseStatus & (.statusCode)
              contentType =
                resp
                  & Http.getResponseHeaders
                  & List.lookup "content-type"
                  <&> Wai.parseContentType
                  <&> (\(ct, _mimeAttributes) -> ct)
          if
            | statusCode == 200,
              Just "application/x-bittorrent" <- contentType ->
                Right $ (resp & Http.getResponseBody)
            | statusCode == 200,
              Just otherType <- contentType ->
                Left [fmt|Redacted returned a non-torrent body, with content-type "{otherType}"|]
            | statusCode == 200,
              Nothing <- contentType ->
                Left [fmt|Redacted returned a body with unspecified content type|]
            | code <- statusCode -> Left $ AppExceptionPretty [[fmt|Redacted returned an non-200 error code, code {code}|], pretty resp]
      )

redactedApiRequestJson ::
  ( MonadThrow m,
    HasField "action" p ByteString,
    HasField "actionArgs" p [(ByteString, Maybe ByteString)],
    MonadOtel m,
    MonadRedacted m
  ) =>
  Otel.Span ->
  p ->
  Json.Parse ErrorTree a ->
  m a
redactedApiRequestJson span dat parser = do
  addAttribute span "redacted.request" (toOtelJsonAttr (T2 (getLabel @"action" dat) (getLabel @"actionArgs" dat)))
  mkRedactedApiRequest dat
    >>= Http.httpJson defaults parser

test :: (MonadThrow m, MonadRedacted m, MonadOtel m) => m ()
test =
  inSpan' "test" $ \span -> do
    redactedApiRequestJson
      span
      (T2 (label @"action" "artist") (label @"actionArgs" [("id", Just "2785")]))
      (Json.asValue)
      <&> Pretty.showPrettyJsonColored
      >>= liftIO . putStderrLn

readTorrentFile :: (MonadIO m, MonadPostgres m) => m ()
readTorrentFile = runTransaction $ do
  torrentBytes <-
    queryWith
      [sql|
    SELECT torrent_file from redacted.torrents where torrent_file is not null limit 10 |]
      ()
      Dec.bytea
  liftIO $ for_ torrentBytes $ \b -> case testBencode b of
    Left e -> do
      Text.IO.putStrLn $ prettyErrorTree e
    Right a -> printPretty a
  liftIO $ print $ lengthNatural torrentBytes

testBencode :: ByteString -> (Either ErrorTree TorrentFile)
testBencode bs = Parse.runParse "cannot parse bencode" (parseBencode >>> bencodeTorrentParser) bs

-- | A torrent file
--
-- from wikipedia:
--
-- * announce—the URL of the high tracker
-- * info—this maps to a dictionary whose keys are very dependent on whether one or more files are being shared:
--   - files—a list of dictionaries each corresponding to a file (only when multiple files are being shared). Each dictionary has the following keys:
--     * length—size of the file in bytes.
--     * path—a list of strings corresponding to subdirectory names, the last of which is the actual file name
--   - length—size of the file in bytes (only when one file is being shared though)
--   - name—suggested filename where the file is to be saved (if one file)/suggested directory name where the files are to be saved (if multiple files)
--   - piece length—number of bytes per piece. This is commonly 28 KiB = 256 KiB = 262,144 B.
--   - pieces—a hash list, i.e., a concatenation of each piece's SHA-1 hash. As SHA-1 returns a 160-bit hash, pieces will be a string whose length is a multiple of 20 bytes. If the torrent contains multiple files, the pieces are formed by concatenating the files in the order they appear in the files dictionary (i.e., all pieces in the torrent are the full piece length except for the last piece, which may be shorter).
data TorrentFile = TorrentFile
  { announce :: Text,
    comment :: Maybe Text,
    createdBy :: Maybe Text,
    creationDate :: Maybe UTCTime,
    encoding :: Maybe Text,
    info :: Info
  }
  deriving stock (Eq, Show)

data Info = Info
  { name :: Text,
    files :: [File],
    pieceLength :: Natural,
    pieces :: ByteString,
    private :: Maybe Bool,
    source :: Maybe Text
  }
  deriving stock (Eq, Show)

data File = File
  { length_ :: Natural,
    path :: [Text]
  }
  deriving stock (Eq, Show)

bencodeTorrentParser :: Parse BEncode TorrentFile
bencodeTorrentParser =
  bencodeDict >>> do
    announce <- mapLookup "announce" bencodeTextLenient
    comment <- mapLookupMay "comment" bencodeTextLenient
    createdBy <- mapLookupMay "created by" bencodeTextLenient
    creationDate <- mapLookupMay "creation date" (bencodeInteger <&> posixSecondsToUTCTime . fromInteger @NominalDiffTime)
    encoding <- mapLookupMay "encoding" bencodeTextLenient
    info <-
      mapLookup "info" $
        bencodeDict >>> do
          name <- mapLookup "name" bencodeTextLenient
          files <-
            mapLookup "files" $
              bencodeList
                >>> ( Parse.multiple $
                        bencodeDict >>> do
                          length_ <- mapLookup "length" bencodeNatural
                          path <- mapLookup "path" $ bencodeList >>> Parse.multiple bencodeTextLenient
                          pure $ File {..}
                    )
          pieceLength <- mapLookup "piece length" bencodeNatural
          pieces <- mapLookup "pieces" bencodeBytes
          private <-
            mapLookupMay "private" bencodeInteger
              <&> fmap
                ( \case
                    0 -> False
                    _ -> True
                )
          source <- mapLookupMay "source" bencodeTextLenient
          pure Info {..}
    pure TorrentFile {..}
