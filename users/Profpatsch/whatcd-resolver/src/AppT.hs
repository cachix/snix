{-# LANGUAGE DeriveAnyClass #-}

module AppT where

import Control.Monad.Logger qualified as Logger
import Control.Monad.Logger.CallStack
import Control.Monad.Reader
import Data.Error.Tree
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HashMap
import Data.Pool (Pool)
import Data.String (IsString (fromString))
import Data.Text qualified as Text
import Database.PostgreSQL.Simple qualified as Postgres
import FieldParser (FieldParser)
import FieldParser qualified as Field
import GHC.Records (getField)
import GHC.Stack qualified
import GHC.TypeLits
import Json.Enc
import Json.Enc qualified as Enc
import Label
import MyPrelude
import OpenTelemetry.Trace qualified as Otel hiding (getTracer, inSpan, inSpan')
import OpenTelemetry.Trace.Core qualified as Otel hiding (inSpan, inSpan')
import OpenTelemetry.Trace.Monad qualified as Otel
import Postgres.MonadPostgres
import Pretty qualified
import System.IO qualified as IO
import UnliftIO
import Prelude hiding (span)

data Context = Context
  { pgConfig ::
      T2
        "logDatabaseQueries"
        DebugLogDatabaseQueries
        "prettyPrintDatabaseQueries"
        PrettyPrintDatabaseQueries,
    pgConnPool :: (Pool Postgres.Connection),
    tracer :: Otel.Tracer,
    transmissionSessionId :: IORef (Maybe ByteString),
    redactedApiKey :: ByteString
  }

newtype AppT m a = AppT {unAppT :: ReaderT Context m a}
  deriving newtype (Functor, Applicative, Monad, MonadIO, MonadUnliftIO, MonadThrow)

data AppException
  = AppExceptionTree ErrorTree
  | AppExceptionPretty [Pretty.Err]
  deriving anyclass (Exception)

instance IsString AppException where
  fromString s = AppExceptionTree (fromString s)

instance Show AppException where
  showsPrec _ (AppExceptionTree t) = ("AppException: " ++) . ((textToString $ prettyErrorTree t) ++)
  showsPrec _ (AppExceptionPretty t) = ("AppException: " ++) . ((Pretty.prettyErrsNoColor t) ++)

instance (MonadIO m) => MonadLogger (AppT m) where
  monadLoggerLog loc src lvl msg = liftIO $ Logger.defaultOutput IO.stderr loc src lvl (Logger.toLogStr msg)

instance (Monad m) => Otel.MonadTracer (AppT m) where
  getTracer = AppT $ asks (.tracer)

class (MonadUnliftIO m, Otel.MonadTracer m) => MonadOtel m

instance (MonadUnliftIO m) => MonadOtel (AppT m)

instance (MonadOtel m) => MonadOtel (Transaction m)

inSpan :: (MonadOtel m) => Text -> m a -> m a
inSpan name = Otel.inSpan name Otel.defaultSpanArguments

inSpan' :: (MonadOtel m) => Text -> (Otel.Span -> m a) -> m a
inSpan' name = Otel.inSpan' name Otel.defaultSpanArguments

-- | Add the attribute to the span, prefixing it with the `_` namespace (to easier distinguish our application’s tags from standard tags)
addAttribute :: (MonadIO m, Otel.ToAttribute a) => Otel.Span -> Text -> a -> m ()
addAttribute span key a = Otel.addAttribute span ("_." <> key) a

-- | Add the attributes to the span, prefixing each key with the `_` namespace (to easier distinguish our application’s tags from standard tags)
addAttributes :: (MonadIO m) => Otel.Span -> HashMap Text Otel.Attribute -> m ()
addAttributes span attrs = Otel.addAttributes span $ attrs & HashMap.mapKeys ("_." <>)

addEventSimple :: (MonadIO m) => Otel.Span -> Text -> m ()
addEventSimple span name =
  Otel.addEvent
    span
    Otel.NewEvent
      { Otel.newEventName = name,
        Otel.newEventTimestamp = Nothing,
        Otel.newEventAttributes = mempty
      }

-- | Create an otel attribute from a json encoder
jsonAttribute :: Enc -> Otel.Attribute
jsonAttribute e = e & Enc.encToTextPretty & Otel.toAttribute

parseOrThrow :: (MonadThrow m, MonadIO m) => Otel.Span -> FieldParser from to -> from -> m to
parseOrThrow span fp f =
  f & Field.runFieldParser fp & \case
    Left err -> appThrow span (AppExceptionTree $ singleError err)
    Right a -> pure a

orThrowAppErrorNewSpan :: (MonadThrow m, MonadOtel m) => Text -> Either AppException a -> m a
orThrowAppErrorNewSpan msg = \case
  Left err -> appThrowNewSpan msg err
  Right a -> pure a

appThrowNewSpan :: (MonadThrow m, MonadOtel m) => Text -> AppException -> m a
appThrowNewSpan spanName exc = inSpan' spanName $ \span -> do
  let msg = case exc of
        AppExceptionTree e -> prettyErrorTree e
        AppExceptionPretty p -> Pretty.prettyErrsNoColor p & stringToText
  recordException
    span
    ( T2
        (label @"type_" "AppException")
        (label @"message" msg)
    )
  throwM $ exc

appThrow :: (MonadThrow m, MonadIO m) => Otel.Span -> AppException -> m a
appThrow span exc = do
  let msg = case exc of
        AppExceptionTree e -> prettyErrorTree e
        AppExceptionPretty p -> Pretty.prettyErrsNoColor p & stringToText
  recordException
    span
    ( T2
        (label @"type_" "AppException")
        (label @"message" msg)
    )
  throwM $ exc

orAppThrow :: (MonadThrow m, MonadIO m) => Otel.Span -> Either AppException a -> m a
orAppThrow span = \case
  Left err -> appThrow span err
  Right a -> pure a

-- | If action returns a Left, throw an AppException
assertM :: (MonadThrow f, MonadIO f) => Otel.Span -> (t -> Either AppException a) -> t -> f a
assertM span f v = case f v of
  Right a -> pure a
  Left err -> appThrow span err

assertMNewSpan :: (MonadThrow f, MonadOtel f) => Text -> (t -> Either AppException a) -> t -> f a
assertMNewSpan spanName f v = case f v of
  Right a -> pure a
  Left err -> appThrowNewSpan spanName err

-- | A specialized variant of @addEvent@ that records attributes conforming to
-- the OpenTelemetry specification's
-- <https://github.com/open-telemetry/opentelemetry-specification/blob/49c2f56f3c0468ceb2b69518bcadadd96e0a5a8b/specification/trace/semantic_conventions/exceptions.md semantic conventions>
--
-- @since 0.0.1.0
recordException ::
  ( MonadIO m,
    HasField "message" r Text,
    HasField "type_" r Text
  ) =>
  Otel.Span ->
  r ->
  m ()
recordException span dat = liftIO $ do
  callStack <- GHC.Stack.whoCreated dat.message
  newEventTimestamp <- Just <$> Otel.getTimestamp
  Otel.addEvent span $
    Otel.NewEvent
      { newEventName = "exception",
        newEventAttributes =
          HashMap.fromList
            [ ("exception.type", Otel.toAttribute @Text dat.type_),
              ("exception.message", Otel.toAttribute @Text dat.message),
              ("exception.stacktrace", Otel.toAttribute @Text $ Text.unlines $ Prelude.map stringToText callStack)
            ],
        ..
      }

-- * Postgres

instance (MonadThrow m, MonadUnliftIO m) => MonadPostgres (AppT m) where
  execute = executeImpl dbConfig
  executeMany = executeManyImpl dbConfig
  executeManyReturningWith = executeManyReturningWithImpl dbConfig
  queryWith = queryWithImpl dbConfig
  queryWith_ = queryWithImpl_ (dbConfig <&> snd)

  foldRowsWithAcc = foldRowsWithAccImpl dbConfig
  runTransaction = runPGTransaction

dbConfig :: (Monad m) => AppT m (DebugLogDatabaseQueries, PrettyPrintDatabaseQueries)
dbConfig =
  AppT $
    asks
      ( \c ->
          ( c.pgConfig.logDatabaseQueries,
            c.pgConfig.prettyPrintDatabaseQueries
          )
      )

runPGTransaction :: (MonadUnliftIO m) => Transaction (AppT m) a -> AppT m a
runPGTransaction (Transaction transaction) = do
  pool <- AppT ask <&> (.pgConnPool)
  withRunInIO $ \unliftIO ->
    withPGTransaction pool $ \conn -> do
      unliftIO $ runReaderT transaction conn

toOtelJsonAttr :: (ToOtelJsonAttr a) => a -> Otel.Attribute
toOtelJsonAttr = toOtelJsonAttrImpl >>> Enc.encToTextPretty >>> Otel.toAttribute

-- | Best effort to convert a value to a JSON string that can be put in an Otel attribute.
class ToOtelJsonAttr a where
  toOtelJsonAttrImpl :: a -> Enc

-- | Bytes are leniently converted to Text, because they are often used as UTF-8 encoded strings.
instance ToOtelJsonAttr ByteString where
  toOtelJsonAttrImpl = Enc.text . bytesToTextUtf8Lenient

instance ToOtelJsonAttr Text where
  toOtelJsonAttrImpl = Enc.text

instance ToOtelJsonAttr Int where
  toOtelJsonAttrImpl = Enc.int

instance ToOtelJsonAttr Natural where
  toOtelJsonAttrImpl = Enc.natural

instance ToOtelJsonAttr Bool where
  toOtelJsonAttrImpl = Enc.bool

instance (ToOtelJsonAttr a) => ToOtelJsonAttr (Maybe a) where
  toOtelJsonAttrImpl = \case
    Nothing -> Enc.null
    Just a -> toOtelJsonAttrImpl a

instance (ToOtelJsonAttr a) => ToOtelJsonAttr [a] where
  toOtelJsonAttrImpl = Enc.list toOtelJsonAttrImpl

instance (ToOtelJsonAttr t1, ToOtelJsonAttr t2, KnownSymbol l1, KnownSymbol l2) => ToOtelJsonAttr (T2 l1 t1 l2 t2) where
  toOtelJsonAttrImpl (T2 a b) =
    Enc.object
      [ (symbolText @l1, a & getField @l1 & toOtelJsonAttrImpl),
        (symbolText @l2, b & getField @l2 & toOtelJsonAttrImpl)
      ]

instance (ToOtelJsonAttr t1, ToOtelJsonAttr t2, ToOtelJsonAttr t3, KnownSymbol l1, KnownSymbol l2, KnownSymbol l3) => ToOtelJsonAttr (T3 l1 t1 l2 t2 l3 t3) where
  toOtelJsonAttrImpl (T3 a b c) =
    Enc.object
      [ (symbolText @l1, a & getField @l1 & toOtelJsonAttrImpl),
        (symbolText @l2, b & getField @l2 & toOtelJsonAttrImpl),
        (symbolText @l3, c & getField @l3 & toOtelJsonAttrImpl)
      ]

instance (ToOtelJsonAttr t1, ToOtelJsonAttr t2) => ToOtelJsonAttr (t1, t2) where
  toOtelJsonAttrImpl t = Enc.tuple2 toOtelJsonAttrImpl toOtelJsonAttrImpl t

instance (ToOtelJsonAttr t1, ToOtelJsonAttr t2, ToOtelJsonAttr t3) => ToOtelJsonAttr (t1, t2, t3) where
  toOtelJsonAttrImpl t = Enc.tuple3 toOtelJsonAttrImpl toOtelJsonAttrImpl toOtelJsonAttrImpl t
