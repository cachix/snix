{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module AppT where

import Builder
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
import GHC.Generics qualified as G
import GHC.Records (getField)
import GHC.Stack qualified
import GHC.TypeLits
import Json.Enc
import Json.Enc qualified as Enc
import Label
import MyPrelude
import OpenTelemetry.Context.ThreadLocal qualified as Otel
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
  | AppExceptionEnc Enc
  deriving anyclass (Exception)

instance IsString AppException where
  fromString s = AppExceptionTree (fromString s)

instance Show AppException where
  showsPrec _ (AppExceptionTree t) = ("AppException: " ++) . ((textToString $ prettyErrorTree t) ++)
  showsPrec _ (AppExceptionPretty t) = ("AppException: " ++) . ((Pretty.prettyErrsNoColor t) ++)
  showsPrec _ (AppExceptionEnc e) = ((textToString $ Enc.encToTextPretty e) ++)

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

instance Otel.ToAttribute (a, TextBuilder a) where
  toAttribute (a, b) = buildText b a & Otel.toAttribute

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
        AppExceptionEnc e -> Enc.encToTextPretty e
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
        AppExceptionEnc e -> Enc.encToTextPretty e
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

-- * Async wrappers with Otel tracing

withAsyncTraced :: (MonadUnliftIO m) => m a -> (Async a -> m b) -> m b
withAsyncTraced act f = do
  ctx <- Otel.getContext
  withAsync
    ( do
        _old <- Otel.attachContext ctx
        act
    )
    f

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

mapConcurrentlyTraced :: (MonadUnliftIO m, Traversable t) => (a -> m b) -> t a -> m (t b)
mapConcurrentlyTraced f t = do
  ctx <- Otel.getContext
  mapConcurrently
    ( \a -> do
        _old <- Otel.attachContext ctx
        f a
    )
    t

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

-- | Best effort to convert a value to a JSON string that can be put in an Otel attribute.
toOtelJsonAttr :: (ToOtelJsonAttr a) => a -> Otel.Attribute
toOtelJsonAttr = toOtelJsonAttrImpl >>> Enc.encToTextPretty >>> Otel.toAttribute

-- | Best effort to convert a value to a JSON string that can be put in an Otel attribute.
class ToOtelJsonAttr a where
  toOtelJsonAttrImpl :: a -> Enc

instance ToOtelJsonAttr Enc where
  toOtelJsonAttrImpl = id

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

-- | Pretty-print the given value to a string
toOtelAttrGenericStruct :: (Generic a, GenericStructSimple (G.Rep a)) => a -> Otel.Attribute
toOtelAttrGenericStruct a = toOtelJsonAttr @Enc $ encodeSimpleValue $ G.from a

class GenericStruct f where
  encodeStructAsObject :: f a -> [(Text, Enc)]

-- :*: (product)
-- Object fields (get field name and put into a list of key-value pair)
instance
  (KnownSymbol l, ToOtelJsonAttr val) =>
  GenericStruct (G.M1 G.S (G.MetaSel (Just l) u s f) (G.K1 i val))
  where
  encodeStructAsObject (G.M1 (G.K1 x)) = [(symbolText @l, toOtelJsonAttrImpl x)]

-- Concatenate two fields in a struct
instance (GenericStruct f, GenericStruct g) => GenericStruct (f G.:*: g) where
  encodeStructAsObject (f G.:*: g) = encodeStructAsObject f <> encodeStructAsObject g

class GenericStructSimple f where
  encodeSimpleValue :: f a -> Enc

instance
  (ToOtelJsonAttr val, KnownSymbol l) =>
  GenericStructSimple (G.M1 G.S (G.MetaSel (Just l) u s f) (G.K1 i val))
  where
  encodeSimpleValue (G.M1 x) = Enc.object $ [(symbolText @l, encodeSimpleValue x)]

-- pass through other M1
instance (GenericStructSimple f) => GenericStructSimple (G.M1 G.D u f) where
  encodeSimpleValue (G.M1 x) = encodeSimpleValue x

-- pass through other M1
instance (GenericStructSimple f) => GenericStructSimple (G.M1 G.C u f) where
  encodeSimpleValue (G.M1 x) = encodeSimpleValue x

-- | Encode a generic representation as an object with :*:
instance (GenericStruct f, GenericStruct g) => GenericStructSimple (f G.:*: g) where
  encodeSimpleValue (a G.:*: b) = Enc.object $ encodeStructAsObject a <> encodeStructAsObject b

-- Void
instance GenericStructSimple G.V1 where
  encodeSimpleValue x = case x of {}

-- Empty type is the empty object
instance GenericStructSimple G.U1 where
  encodeSimpleValue _ = emptyObject

-- K1
instance (ToOtelJsonAttr val) => GenericStructSimple (G.K1 i val) where
  encodeSimpleValue (G.K1 x) = toOtelJsonAttrImpl x
