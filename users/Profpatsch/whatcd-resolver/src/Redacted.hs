{-# LANGUAGE QuasiQuotes #-}

module Redacted where

import AppT
import Arg
import Comparison
import Control.Monad.Logger.CallStack
import Control.Monad.Reader
import Data.Aeson qualified as Json
import Data.Aeson.BetterErrors qualified as Json
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Error.Tree
import Data.List qualified as List
import Database.PostgreSQL.Simple (Binary (Binary), Only (..))
import Database.PostgreSQL.Simple.Types (PGArray (PGArray))
import FieldParser qualified as Field
import Http qualified
import Json qualified
import Label
import MyPrelude
import Network.HTTP.Types
import Network.Wai.Parse qualified as Wai
import OpenTelemetry.Trace qualified as Otel hiding (getTracer, inSpan, inSpan')
import Optional
import Postgres.Decoder qualified as Dec
import Postgres.MonadPostgres
import Pretty
import Prelude hiding (span)

class MonadRedacted m where
  getRedactedApiKey :: m ByteString

instance (MonadIO m) => MonadRedacted (AppT m) where
  getRedactedApiKey = AppT (asks (.redactedApiKey))

redactedSearch ::
  (MonadThrow m, MonadOtel m, MonadRedacted m) =>
  [(ByteString, ByteString)] ->
  Json.Parse ErrorTree a ->
  m a
redactedSearch advanced parser =
  inSpan' "Redacted API Search" $ \span ->
    redactedApiRequestJson
      span
      ( T2
          (label @"action" "browse")
          (label @"actionArgs" ((advanced <&> second Just)))
      )
      parser

redactedGetTorrentFile ::
  ( MonadLogger m,
    MonadThrow m,
    HasField "torrentId" dat Int,
    MonadOtel m,
    MonadRedacted m
  ) =>
  dat ->
  m ByteString
redactedGetTorrentFile dat = inSpan' "Redacted Get Torrent File" $ \span -> do
  req <-
    mkRedactedApiRequest
      ( T2
          (label @"action" "download")
          ( label @"actionArgs"
              [ ("id", Just (dat.torrentId & showToText @Int & textToBytesUtf8))
              -- try using tokens as long as we have them (TODO: what if there’s no tokens left?
              -- ANSWER: it breaks:
              -- responseBody = "{\"status\":\"failure\",\"error\":\"You do not have any freeleech tokens left. Please use the regular DL link.\"}",
              -- ("usetoken", Just "1")
              ]
          )
      )
  httpTorrent span req

mkRedactedTorrentLink :: Arg "torrentGroupId" Int -> Text
mkRedactedTorrentLink torrentId = [fmt|https://redacted.sh/torrents.php?id={torrentId.unArg}|]

exampleSearch :: (MonadThrow m, MonadLogger m, MonadPostgres m, MonadOtel m, MonadRedacted m) => m (Transaction m ())
exampleSearch = do
  t1 <-
    redactedSearchAndInsert
      [ ("searchstr", "cherish"),
        ("artistname", "kirinji"),
        -- ("year", "1982"),
        -- ("format", "MP3"),
        -- ("releasetype", "album"),
        ("order_by", "year")
      ]
  t3 <-
    redactedSearchAndInsert
      [ ("searchstr", "mouss et hakim"),
        ("artistname", "mouss et hakim"),
        -- ("year", "1982"),
        -- ("format", "MP3"),
        -- ("releasetype", "album"),
        ("order_by", "year")
      ]
  t2 <-
    redactedSearchAndInsert
      [ ("searchstr", "thriller"),
        ("artistname", "michael jackson"),
        -- ("year", "1982"),
        -- ("format", "MP3"),
        -- ("releasetype", "album"),
        ("order_by", "year")
      ]
  pure (t1 >> t2 >> t3)

-- | Do the search, return a transaction that inserts all results from all pages of the search.
redactedSearchAndInsert ::
  forall m.
  ( MonadLogger m,
    MonadPostgres m,
    MonadThrow m,
    MonadOtel m,
    MonadRedacted m
  ) =>
  [(ByteString, ByteString)] ->
  m (Transaction m ())
redactedSearchAndInsert extraArguments = do
  logInfo [fmt|Doing redacted search with arguments: {showPretty extraArguments}|]
  -- The first search returns the amount of pages, so we use that to query all results piece by piece.
  firstPage <- go Nothing
  let remainingPages = firstPage.pages - 1
  logInfo [fmt|Got the first page, found {remainingPages} more pages|]
  let otherPagesNum = [(2 :: Natural) .. remainingPages]
  otherPages <- traverse go (Just <$> otherPagesNum)
  pure $
    (firstPage : otherPages)
      & concatMap (.tourGroups)
      & \case
        IsNonEmpty tgs -> tgs & insertTourGroupsAndTorrents
        IsEmpty -> pure ()
  where
    go mpage =
      redactedSearch
        ( extraArguments
            -- pass the page (for every search but the first one)
            <> (mpage & ifExists (\page -> ("page", (page :: Natural) & showToText & textToBytesUtf8)))
        )
        ( do
            status <- Json.key "status" Json.asText
            when (status /= "success") $ do
              Json.throwCustomError [fmt|Status was not "success", but {status}|]
            Json.key "response" $ do
              pages <-
                Json.keyMay "pages" (Field.toJsonParser (Field.mapError singleError $ Field.jsonNumber >>> Field.boundedScientificIntegral @Int "not an Integer" >>> Field.integralToNatural))
                  -- in case the field is missing, let’s assume there is only one page
                  <&> fromMaybe 1
              Json.key "results" $ do
                tourGroups <-
                  label @"tourGroups"
                    <$> ( Json.eachInArray $ do
                            groupId <- Json.keyLabel @"groupId" "groupId" (Json.asIntegral @_ @Int)
                            groupName <- Json.keyLabel @"groupName" "groupName" Json.asText
                            fullJsonResult <-
                              label @"fullJsonResult"
                                <$> ( Json.asObject
                                        -- remove torrents cause they are inserted separately below
                                        <&> KeyMap.filterWithKey (\k _ -> k /= "torrents")
                                        <&> Json.Object
                                    )
                            let tourGroup = T3 groupId groupName fullJsonResult
                            torrents <- Json.keyLabel @"torrents" "torrents" $
                              Json.eachInArray $ do
                                torrentId <- Json.keyLabel @"torrentId" "torrentId" (Json.asIntegral @_ @Int)
                                fullJsonResultT <- label @"fullJsonResult" <$> Json.asValue
                                pure $ T2 torrentId fullJsonResultT
                            pure (T2 (label @"tourGroup" tourGroup) torrents)
                        )
                pure
                  ( T2
                      (label @"pages" pages)
                      tourGroups
                  )
        )
    insertTourGroupsAndTorrents ::
      NonEmpty
        ( T2
            "tourGroup"
            (T3 "groupId" Int "groupName" Text "fullJsonResult" Json.Value)
            "torrents"
            [T2 "torrentId" Int "fullJsonResult" Json.Value]
        ) ->
      Transaction m ()
    insertTourGroupsAndTorrents dat = do
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
      NonEmpty
        ( T3
            "groupId"
            Int
            "groupName"
            Text
            "fullJsonResult"
            Json.Value
        ) ->
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
        ( dats <&> \dat ->
            ( dat.groupId,
              dat.groupName,
              dat.fullJsonResult
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
            & unzip3PGArray
              @"torrentGroupIdPg"
              @Int
              @"torrentId"
              @Int
              @"fullJsonResult"
              @Json.Value
        )
      pure ()

redactedGetTorrentFileAndInsert ::
  ( HasField "torrentId" r Int,
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
newtype ReleaseType = ReleaseType {unReleaseType :: Text}
  deriving stock (Eq, Show)

releaseTypeComparison :: Comparison ReleaseType
releaseTypeComparison = listIndexComparison [releaseTypeAlbum, releaseTypeSoundtrack, releaseTypeEP, releaseTypeAnthology, releaseTypeCompilation, releaseTypeSingle, releaseTypeLiveAlbum, releaseTypeRemix, releaseTypeBootleg, releaseTypeInterview, releaseTypeMixtape, releaseTypeDemo, releaseTypeConcertRecording, releaseTypeDJMix, releaseTypeUnknown, releaseTypeProducedBy, releaseTypeComposition, releaseTypeRemixedBy, releaseTypeGuestAppearance]

releaseTypeAlbum, releaseTypeSoundtrack, releaseTypeEP, releaseTypeAnthology, releaseTypeCompilation, releaseTypeSingle, releaseTypeLiveAlbum, releaseTypeRemix, releaseTypeBootleg, releaseTypeInterview, releaseTypeMixtape, releaseTypeDemo, releaseTypeConcertRecording, releaseTypeDJMix, releaseTypeUnknown, releaseTypeProducedBy, releaseTypeComposition, releaseTypeRemixedBy, releaseTypeGuestAppearance :: ReleaseType
releaseTypeAlbum = ReleaseType "Album"
releaseTypeSoundtrack = ReleaseType "Soundtrack"
releaseTypeEP = ReleaseType "EP"
releaseTypeAnthology = ReleaseType "Anthology"
releaseTypeCompilation = ReleaseType "Compilation"
releaseTypeSingle = ReleaseType "Single"
releaseTypeLiveAlbum = ReleaseType "Live album"
releaseTypeRemix = ReleaseType "Remix"
releaseTypeBootleg = ReleaseType "Bootleg"
releaseTypeInterview = ReleaseType "Interview"
releaseTypeMixtape = ReleaseType "Mixtape"
releaseTypeDemo = ReleaseType "Demo"
releaseTypeConcertRecording = ReleaseType "Concert Recording"
releaseTypeDJMix = ReleaseType "DJ Mix"
releaseTypeUnknown = ReleaseType "Unknown"
releaseTypeProducedBy = ReleaseType "Produced By"
releaseTypeComposition = ReleaseType "Composition"
releaseTypeRemixedBy = ReleaseType "Remixed By"
releaseTypeGuestAppearance = ReleaseType "Guest Appearance"

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
  { onlyDownloaded :: Bool,
    onlyArtist :: Maybe (Label "artistRedactedId" Natural)
  }

-- | Find the best torrent for each torrent group (based on the seeding_weight)
getBestTorrents ::
  (MonadPostgres m) =>
  GetBestTorrentsFilter ->
  Transaction m [TorrentData ()]
getBestTorrents opts = do
  queryWith
    [sql|
      WITH filtered_torrents AS (
        SELECT DISTINCT ON (torrent_group)
          id
        FROM
          redacted.torrents
        WHERE
          -- onlyDownloaded
          ((NOT ?::bool) OR torrent_file IS NOT NULL)
          -- filter by artist id
          AND
          (?::bool OR (to_jsonb(?::int) <@ (jsonb_path_query_array(full_json_result, '$.artists[*].id'))))
        ORDER BY
          torrent_group,
          -- prefer torrents which we already downloaded
          torrent_file,
          seeding_weight DESC
      )
      SELECT
        tg.group_id,
        t.torrent_id,
        t.seeding_weight,
        tg.full_json_result->>'releaseType' AS release_type,
        t.full_json_result->'artists' AS artists,
        tg.full_json_result->>'groupName' AS group_name,
        tg.full_json_result->>'groupYear' AS group_year,
        t.torrent_file IS NOT NULL AS has_torrent_file,
        t.transmission_torrent_hash,
        t.full_json_result->>'encoding' AS torrent_format
      FROM filtered_torrents f
      JOIN redacted.torrents t ON t.id = f.id
      JOIN redacted.torrent_groups tg ON tg.id = t.torrent_group
      ORDER BY seeding_weight DESC
    |]
    ( do
        let (onlyArtistB, onlyArtistId) = case opts.onlyArtist of
              Nothing -> (True, 0)
              Just a -> (False, a.artistRedactedId)
        ( opts.onlyDownloaded :: Bool,
          onlyArtistB :: Bool,
          onlyArtistId & fromIntegral @Natural @Int
          )
    )
    ( do
        groupId <- Dec.fromField @Int
        torrentId <- Dec.fromField @Int
        seedingWeight <- Dec.fromField @Int
        releaseType <- ReleaseType <$> Dec.text
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
