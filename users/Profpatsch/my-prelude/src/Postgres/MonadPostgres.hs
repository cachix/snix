{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE QuasiQuotes #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Postgres.MonadPostgres where

import Arg
import AtLeast (AtLeast)
import Control.Exception
  ( Exception (displayException),
    Handler (Handler),
    catches,
    try,
  )
import Control.Foldl qualified as Fold
import Control.Monad.Logger.CallStack (MonadLogger, logDebug, logWarn)
import Control.Monad.Reader (MonadReader (ask), ReaderT (..))
import Control.Monad.Trans.Resource
import Data.Aeson (FromJSON)
import Data.ByteString qualified as ByteString
import Data.Error.Tree
import Data.HashMap.Strict qualified as HashMap
import Data.Int (Int64)
import Data.Kind (Type)
import Data.List qualified as List
import Data.Pool (Pool)
import Data.Pool qualified as Pool
import Data.Text qualified as Text
import Data.Typeable (Typeable)
import Database.PostgreSQL.Simple (Connection, FormatError, FromRow, Query, QueryError, ResultError, SqlError, ToRow)
import Database.PostgreSQL.Simple qualified as PG
import Database.PostgreSQL.Simple qualified as Postgres
import Database.PostgreSQL.Simple.FromRow qualified as PG
import Database.PostgreSQL.Simple.ToField (ToField)
import Database.PostgreSQL.Simple.ToRow (ToRow (toRow))
import Database.PostgreSQL.Simple.Types (PGArray (PGArray), Query (..))
import GHC.IO.Handle (Handle)
import GHC.Records (getField)
import Label
import Language.Haskell.TH.Quote (QuasiQuoter)
import OpenTelemetry.Trace.Core (NewEvent (newEventName))
import OpenTelemetry.Trace.Core qualified as Otel hiding (inSpan, inSpan')
import OpenTelemetry.Trace.Monad qualified as Otel
import PossehlAnalyticsPrelude
import Postgres.Decoder
import Postgres.Decoder qualified as Dec
import Pretty (showPretty)
import PyF qualified
import Seconds
import System.Exit (ExitCode (..))
import Tool
import UnliftIO (MonadUnliftIO (withRunInIO), bracket, hClose, mask_)
import UnliftIO.Concurrent (forkIO)
import UnliftIO.Process (ProcessHandle)
import UnliftIO.Process qualified as Process
import UnliftIO.Resource qualified as Resource
import Prelude hiding (init, span)

-- | Postgres queries/commands that can be executed within a running transaction.
--
-- These are implemented with the @postgresql-simple@ primitives of the same name
-- and will behave the same unless othewise documented.
class (Monad m) => MonadPostgres (m :: Type -> Type) where
  -- | Execute an INSERT, UPDATE, or other SQL query that is not expected to return results.

  -- Returns the number of rows affected.
  execute ::
    (ToRow params, Typeable params) =>
    Query ->
    params ->
    Transaction m (Label "numberOfRowsAffected" Natural)

  -- | Execute a multi-row INSERT, UPDATE, or other SQL query that is not expected to return results.
  --
  -- Returns the number of rows affected. If the list of parameters is empty,
  -- this function will simply return 0 without issuing the query to the backend.
  -- If this is not desired, consider using the 'PG.Values' constructor instead.
  executeMany ::
    (ToRow params, Typeable params) =>
    Query ->
    NonEmpty params ->
    Transaction m (Label "numberOfRowsAffected" Natural)

  -- | Execute INSERT ... RETURNING, UPDATE ... RETURNING,
  -- or other SQL query that accepts multi-row input and is expected to return results.
  -- Note that it is possible to write query conn "INSERT ... RETURNING ..." ...
  -- in cases where you are only inserting a single row,
  -- and do not need functionality analogous to 'executeMany'.
  --
  -- If the list of parameters is empty, this function will simply return [] without issuing the query to the backend. If this is not desired, consider using the 'PG.Values' constructor instead.
  executeManyReturningWith :: (ToRow q) => Query -> NonEmpty q -> Decoder r -> Transaction m [r]

  -- | Run a query, passing parameters and result row parser.
  queryWith ::
    (PG.ToRow params, Typeable params, Typeable r) =>
    PG.Query ->
    params ->
    Decoder r ->
    Transaction m [r]

  -- | Run a query without any parameters and result row parser.
  queryWith_ ::
    (Typeable r) =>
    PG.Query ->
    Decoder r ->
    Transaction m [r]

  -- | Run a query, passing parameters, and fold over the resulting rows.
  --
  -- This doesn’t have to realize the full list of results in memory,
  -- rather results are streamed incrementally from the database.
  --
  -- When dealing with small results, it may be simpler (and perhaps faster) to use query instead.
  --
  -- This fold is _not_ strict. The stream consumer is responsible
  -- for forcing the evaluation of its result to avoid space leaks.
  --
  -- If you can, prefer aggregating in the database itself.
  foldRowsWithAcc ::
    (ToRow params, Typeable row, Typeable params) =>
    Query ->
    params ->
    Decoder row ->
    a ->
    (a -> row -> Transaction m a) ->
    Transaction m a

  -- | Run a given transaction in a transaction block, rolling back the transaction
  -- if any exception (postgres or Haskell Exception) is thrown during execution.
  --
  -- Re-throws the exception.
  --
  -- Don’t do any long-running things on the Haskell side during a transaction,
  -- because it will block a database connection and potentially also lock
  -- database tables from being written or read by other clients.
  --
  -- Nonetheless, try to push transactions as far out to the handlers as possible,
  -- don’t do something like @runTransaction $ query …@, because it will lead people
  -- to accidentally start nested transactions (the inner transaction is run on a new connections,
  -- thus can’t see any changes done by the outer transaction).
  -- Only handlers should run transactions.
  runTransaction :: Transaction m a -> m a

-- | Quasi-Quoter for multi-line SQL literals. Trims leading whitespace up to the least-indented line.
sql :: QuasiQuoter
sql = PyF.fmtTrim

-- | Run a query, passing parameters. Prefer 'queryWith' if possible.
query ::
  forall m params r.
  (PG.ToRow params, PG.FromRow r, Typeable params, Typeable r, MonadPostgres m) =>
  PG.Query ->
  params ->
  Transaction m [r]
query qry params = queryWith qry params (Decoder PG.fromRow)

-- | Run a query without any parameters. Prefer 'queryWith' if possible.
--
-- TODO: I think(?) this can always be replaced by passing @()@ to 'query', remove?
query_ ::
  forall m r.
  (Typeable r, PG.FromRow r, MonadPostgres m) =>
  PG.Query ->
  Transaction m [r]
query_ qry = queryWith_ qry (Decoder PG.fromRow)

-- TODO: implement via fold, so that the result doesn’t have to be realized in memory
querySingleRow ::
  ( MonadPostgres m,
    ToRow qParams,
    Typeable qParams,
    FromRow a,
    Typeable a,
    MonadThrow m
  ) =>
  Query ->
  qParams ->
  Transaction m a
querySingleRow qry params = do
  query qry params >>= ensureSingleRow

-- TODO: implement via fold, so that the result doesn’t have to be realized in memory
querySingleRowWith ::
  ( MonadPostgres m,
    ToRow qParams,
    Typeable qParams,
    Typeable a,
    MonadThrow m
  ) =>
  Query ->
  qParams ->
  Decoder a ->
  Transaction m a
querySingleRowWith qry params decoder = do
  queryWith qry params decoder >>= ensureSingleRow

-- TODO: implement via fold, so that the result doesn’t have to be realized in memory
querySingleRowMaybe ::
  ( MonadPostgres m,
    ToRow qParams,
    Typeable qParams,
    FromRow a,
    Typeable a,
    MonadThrow m
  ) =>
  Query ->
  qParams ->
  Transaction m (Maybe a)
querySingleRowMaybe qry params = do
  rows <- query qry params
  case rows of
    [] -> pure Nothing
    [one] -> pure (Just one)
    -- TODO: Should we MonadThrow this here? It’s really an implementation detail of MonadPostgres
    -- that a database function can error out, should probably handled by the instances.
    more -> throwM $ SingleRowError {numberOfRowsReturned = (List.length more)}

ensureSingleRow ::
  (MonadThrow m) =>
  [a] ->
  m a
ensureSingleRow = \case
  -- TODO: Should we MonadThrow this here? It’s really an implementation detail of MonadPostgres
  -- that a database function can error out, should probably handled by the instances.
  [] -> throwM (SingleRowError {numberOfRowsReturned = 0})
  [one] -> pure one
  more ->
    throwM $
      SingleRowError
        { numberOfRowsReturned =
            -- TODO: this is VERY bad, because it requires to parse the full database output, even if there’s 10000000000 elements
            List.length more
        }

ensureNoneOrSingleRow ::
  (MonadThrow m) =>
  [a] ->
  m (Maybe a)
ensureNoneOrSingleRow = \case
  -- TODO: Should we MonadThrow this here? It’s really an implementation detail of MonadPostgres
  -- that a database function can error out, should probably handled by the instances.
  [] -> pure Nothing
  [one] -> pure $ Just one
  more ->
    throwM $
      SingleRowError
        { numberOfRowsReturned =
            -- TODO: this is VERY bad, because it requires to parse the full database output, even if there’s 10000000000 elements
            List.length more
        }

-- | Run a query, passing parameters, and fold over the resulting rows.
--
-- This doesn’t have to realize the full list of results in memory,
-- rather results are streamed incrementally from the database.
--
-- When dealing with small results, it may be simpler (and perhaps faster) to use query instead.
--
-- The results are folded strictly into the Monoid returned by the decoder.
--
-- If you need more complex folding logic, use 'foldRowsWith' with a 'Fold'.
--
-- If you can, prefer aggregating in the database itself.
foldRowsWithMonoid ::
  forall row params m.
  ( MonadPostgres m,
    PG.ToRow params,
    Typeable row,
    Typeable params,
    Monoid row
  ) =>
  PG.Query ->
  params ->
  Decoder row ->
  Transaction m row
foldRowsWithMonoid qry params decoder = foldRowsWith qry params decoder Fold.mconcat

-- | Run a query, passing parameters, and fold over the resulting rows.
--
-- This doesn’t have to realize the full list of results in memory,
-- rather results are streamed incrementally from the database.
--
-- When dealing with small results, it may be simpler (and perhaps faster) to use query instead.
--
-- The results are folded strictly by the 'Fold.Fold' that is passed.
--
-- If you can, prefer aggregating in the database itself.
foldRowsWith ::
  forall row params m b.
  ( MonadPostgres m,
    PG.ToRow params,
    Typeable row,
    Typeable params
  ) =>
  PG.Query ->
  params ->
  Decoder row ->
  Fold.Fold row b ->
  Transaction m b
foldRowsWith qry params decoder = Fold.purely f
  where
    f :: forall x. (x -> row -> x) -> x -> (x -> b) -> Transaction m b
    f acc init extract = do
      x <- foldRowsWithAcc qry params decoder init (\a r -> pure $ acc a r)
      pure $ extract x

newtype Transaction m a = Transaction {unTransaction :: (ReaderT Connection m a)}
  deriving newtype
    ( Functor,
      Applicative,
      Monad,
      MonadThrow,
      MonadLogger,
      MonadIO,
      MonadUnliftIO,
      MonadTrans,
      Otel.MonadTracer
    )

-- | [Resource Pool](http://hackage.haskell.org/package/resource-pool-0.2.3.2/docs/Data-Pool.html) configuration.
data PoolingInfo = PoolingInfo
  { -- | Minimal amount of resources that are
    --   always available.
    numberOfStripes :: AtLeast 1 Int,
    -- | Time after which extra resources
    --   (above minimum) can stay in the pool
    --   without being used.
    unusedResourceOpenTime :: Seconds,
    -- | Max number of resources that can be
    --   in the Pool at any time
    maxOpenResourcesAcrossAllStripes :: AtLeast 1 Int
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON)

initMonadPostgres ::
  (Text -> IO ()) ->
  -- | Info describing the connection to the Postgres DB
  Postgres.ConnectInfo ->
  -- | Configuration info for pooling attributes
  PoolingInfo ->
  -- | Created Postgres connection pool
  ResourceT IO (Pool Postgres.Connection)
initMonadPostgres logInfoFn connectInfo poolingInfo = do
  (_releaseKey, connPool) <-
    Resource.allocate
      (logInfoFn "Creating Postgres Connection Pool" >> createPGConnPool)
      (\pool -> logInfoFn "Destroying Postgres Connection Pool" >> destroyPGConnPool pool)
  pure connPool
  where
    -- \| Create a Postgres connection pool
    createPGConnPool ::
      IO (Pool Postgres.Connection)
    createPGConnPool =
      Pool.newPool $
        Pool.defaultPoolConfig
          {- resource init action -} poolCreateResource
          {- resource destruction -} poolfreeResource
          ( poolingInfo.unusedResourceOpenTime.unSeconds
              & fromIntegral @Natural @Double
          )
          (poolingInfo.maxOpenResourcesAcrossAllStripes.unAtLeast)
      where
        poolCreateResource = Postgres.connect connectInfo
        poolfreeResource = Postgres.close

    -- \| Destroy a Postgres connection pool
    destroyPGConnPool ::
      -- \| Pool to be destroyed
      (Pool Postgres.Connection) ->
      IO ()
    destroyPGConnPool p = Pool.destroyAllResources p

-- | Improve a possible error message, by adding some context to it.
--
-- The given Exception type is caught, 'show'n and pretty-printed.
--
-- In case we get an `IOError`, we display it in a reasonable fashion.
addErrorInformation ::
  forall exc a.
  (Exception exc) =>
  Text.Text ->
  IO a ->
  IO a
addErrorInformation msg io =
  io
    & try @exc
    <&> first (showPretty >>> newError >>> errorContext msg)
    & try @IOError
    <&> first (showToError >>> errorContext "IOError" >>> errorContext msg)
    <&> join @(Either Error)
    >>= unwrapIOError

-- | Catch any Postgres exception that gets thrown,
-- print the query that was run and the query parameters,
-- then rethrow inside an 'Error'.
handlePGException ::
  forall a params m.
  ( ToRow params,
    MonadUnliftIO m,
    MonadLogger m
  ) =>
  PrettyPrintDatabaseQueries ->
  Text ->
  Query ->
  -- | Depending on whether we used `format` or `formatMany`.
  Either params (NonEmpty params) ->
  IO a ->
  Transaction m a
handlePGException prettyQuery queryType query' params io = do
  withRunInIO $ \unliftIO ->
    io
      `catches` [ Handler $ unliftIO . logQueryException @SqlError,
                  Handler $ unliftIO . logQueryException @QueryError,
                  Handler $ unliftIO . logQueryException @ResultError,
                  Handler $ unliftIO . logFormatException
                ]
  where
    -- TODO: use throwInternalError here (after pulling it into the MonadPostgres class)
    throwAsError = unwrapIOError . Left . newError
    throwErr err = liftIO $ throwAsError $ prettyErrorTree $ nestedMultiError "A Postgres query failed" err
    logQueryException :: (Exception e) => e -> Transaction m a
    logQueryException exc = do
      formattedQuery <-
        case params of
          Left one -> pgFormatQuery' prettyQuery query' one
          Right many -> pgFormatQueryMany' prettyQuery query' many
      throwErr
        ( singleError [fmt|Query Type: {queryType}|]
            :| [ nestedError "Exception" (exc & showPretty & newError & singleError),
                 nestedError "Query" (formattedQuery & bytesToTextUtf8Lenient & newError & singleError)
               ]
        )
    logFormatException :: FormatError -> Transaction m a
    logFormatException fe = throwErr (fe & showPretty & newError & singleError & singleton)

-- | Perform a Postgres action within a transaction
withPGTransaction ::
  -- | Postgres connection pool to be used for the action
  (Pool Postgres.Connection) ->
  -- | DB-action to be performed
  (Postgres.Connection -> IO a) ->
  -- | Result of the DB-action
  IO a
withPGTransaction connPool f =
  Pool.withResource
    connPool
    (\conn -> Postgres.withTransaction conn (f conn))

-- | `pg_formatter` is a perl script that does not support any kind of streaming.
-- Thus we initialize a pool with a bunch of these scripts running, waiting for input. This way we can have somewhat fast SQL formatting.
--
-- Call `initPgFormatPool` to initialize, then use `runPgFormat` to format some sql.
data PgFormatPool = PgFormatPool
  { pool :: Pool PgFormatProcess,
    pgFormat :: Tool
  }

data PgFormatProcess = PgFormatProcess
  { stdinHdl :: Handle,
    stdoutHdl :: Handle,
    stderrHdl :: Handle,
    procHdl :: ProcessHandle,
    startedAt :: Otel.Timestamp
  }

initPgFormatPool :: (HasField "pgFormat" tools Tool) => tools -> IO PgFormatPool
initPgFormatPool tools = do
  pool <-
    Pool.newPool
      ( Pool.defaultPoolConfig
          (pgFormatStartCommandWaitForInput tools)
          ( \pgFmt -> do
              Process.terminateProcess pgFmt.procHdl
              -- make sure we don’t leave any zombies
              _ <- forkIO $ do
                _ <- Process.waitForProcess pgFmt.procHdl
                pure ()
              pure ()
          )
          -- unused resource time
          100
          -- number of resources
          10
      )

  -- fill the pool with resources
  let go =
        Pool.tryWithResource pool (\_ -> go) >>= \case
          Nothing -> pure ()
          Just () -> pure ()
  _ <- go
  pure (PgFormatPool {pool, pgFormat = tools.pgFormat})

destroyPgFormatPool :: PgFormatPool -> IO ()
destroyPgFormatPool pool = Pool.destroyAllResources pool.pool

-- | Get the oldest resource from the pool, or stop if you find a resource that’s older than `cutoffPointMs`.
takeOldestResource :: PgFormatPool -> Arg "cutoffPointMs" Integer -> IO (PgFormatProcess, Pool.LocalPool PgFormatProcess)
takeOldestResource pool cutoffPointMs = do
  now <- Otel.getTimestamp
  mask_ $ do
    a <- Pool.takeResource pool.pool
    (putBack, res) <- go now [] a
    -- make sure we don’t leak any resources we didn’t use in the end
    for_ putBack $ \(x, xLocal) -> Pool.putResource xLocal x
    pure res
  where
    mkMs ts = (ts & Otel.timestampNanoseconds & toInteger) `div` 1000_000
    go now putBack a@(a', _) =
      if abs (mkMs now - mkMs a'.startedAt) > cutoffPointMs.unArg
        then pure (putBack, a)
        else
          Pool.tryTakeResource pool.pool >>= \case
            Nothing -> pure (putBack, a)
            Just b@(b', _) -> do
              if a'.startedAt < b'.startedAt
                then go now (b : putBack) a
                else go now (a : putBack) b

-- | Format the given SQL with pg_formatter. Will use the pool of already running formatters to speed up execution.
runPgFormat :: PgFormatPool -> ByteString -> IO (T3 "exitCode" ExitCode "formatted" ByteString "stderr" ByteString)
runPgFormat pool sqlStatement = do
  bracket
    (takeOldestResource pool 200)
    ( \(a, localPool) -> do
        -- we always destroy the resource, because the process exited
        Pool.destroyResource pool.pool localPool a
        -- create a new process to keep the pool “warm”
        new <- pgFormatStartCommandWaitForInput pool
        Pool.putResource localPool new
    )
    ( \(pgFmt, _localPool) -> do
        ByteString.hPut pgFmt.stdinHdl sqlStatement
        -- close stdin to make pg_formatter format (it exits …)
        -- issue: https://github.com/darold/pgFormatter/issues/333
        hClose pgFmt.stdinHdl
        formatted <- ByteString.hGetContents pgFmt.stdoutHdl
        errs <- ByteString.hGetContents pgFmt.stderrHdl
        exitCode <- Process.waitForProcess pgFmt.procHdl
        pure $
          T3
            (label @"exitCode" exitCode)
            (label @"formatted" formatted)
            (label @"stderr" errs)
    )

runPGTransactionImpl ::
  (MonadUnliftIO m) =>
  m (Pool Postgres.Connection) ->
  Transaction m a ->
  m a
{-# INLINE runPGTransactionImpl #-}
runPGTransactionImpl zoom (Transaction transaction) = do
  pool <- zoom
  withRunInIO $ \unliftIO ->
    withPGTransaction pool $ \conn -> do
      unliftIO $ runReaderT transaction conn

executeImpl ::
  (ToRow params, MonadUnliftIO m, MonadLogger m, Otel.MonadTracer m) =>
  m (DebugLogDatabaseQueries, PrettyPrintDatabaseQueries) ->
  Query ->
  params ->
  Transaction m (Label "numberOfRowsAffected" Natural)
{-# INLINE executeImpl #-}
executeImpl zoomDbOptions qry params =
  Otel.inSpan' "Postgres Query (execute)" Otel.defaultSpanArguments $ \span -> do
    (logDatabaseQueries, prettyQuery) <- lift @Transaction zoomDbOptions
    traceQueryIfEnabled span logDatabaseQueries prettyQuery qry (HasSingleParam params)
    conn <- Transaction ask
    PG.execute conn qry params
      & handlePGException prettyQuery "execute" qry (Left params)
      >>= toNumberOfRowsAffected "executeImpl"

executeImpl_ ::
  ( MonadUnliftIO m,
    MonadLogger m,
    Otel.MonadTracer m
  ) =>
  m (DebugLogDatabaseQueries, PrettyPrintDatabaseQueries) ->
  Query ->
  Transaction m (Label "numberOfRowsAffected" Natural)
{-# INLINE executeImpl_ #-}
executeImpl_ zoomDbOptions qry =
  Otel.inSpan' "Postgres Query (execute)" Otel.defaultSpanArguments $ \span -> do
    (logDatabaseQueries, prettyQuery) <- lift @Transaction zoomDbOptions
    traceQueryIfEnabled @() span logDatabaseQueries prettyQuery qry HasNoParams
    conn <- Transaction ask
    PG.execute_ conn qry
      & handlePGException prettyQuery "execute_" qry (Left ())
      >>= toNumberOfRowsAffected "executeImpl_"

executeManyImpl ::
  (ToRow params, MonadUnliftIO m, MonadLogger m, Otel.MonadTracer m) =>
  m (DebugLogDatabaseQueries, PrettyPrintDatabaseQueries) ->
  Query ->
  NonEmpty params ->
  Transaction m (Label "numberOfRowsAffected" Natural)
executeManyImpl zoomDbOptions qry params =
  Otel.inSpan' "Postgres Query (executeMany)" Otel.defaultSpanArguments $ \span -> do
    (logDatabaseQueries, prettyQuery) <- lift @Transaction zoomDbOptions
    traceQueryIfEnabled span logDatabaseQueries prettyQuery qry (HasMultiParams params)
    conn <- Transaction ask
    PG.executeMany conn qry (params & toList)
      & handlePGException prettyQuery "executeMany" qry (Right params)
      >>= toNumberOfRowsAffected "executeManyImpl"

toNumberOfRowsAffected :: (MonadIO m) => Text -> Int64 -> m (Label "numberOfRowsAffected" Natural)
toNumberOfRowsAffected functionName i64 =
  i64
    & intToNatural
    & annotate [fmt|{functionName}: postgres returned a negative number of rows affected: {i64}|]
    -- we throw this directly in IO here, because we don’t want to e.g. have to propagate MonadThrow through user code (it’s an assertion)
    & unwrapIOError
    & liftIO
    <&> label @"numberOfRowsAffected"

executeManyReturningWithImpl ::
  ( ToRow params,
    MonadUnliftIO m,
    MonadLogger m,
    Otel.MonadTracer m
  ) =>
  m (DebugLogDatabaseQueries, PrettyPrintDatabaseQueries) ->
  Query ->
  NonEmpty params ->
  Decoder r ->
  Transaction m [r]
{-# INLINE executeManyReturningWithImpl #-}
executeManyReturningWithImpl zoomDbOptions qry params (Decoder fromRow) = do
  Otel.inSpan' "Postgres Query (executeManyReturning)" Otel.defaultSpanArguments $ \span -> do
    (logDatabaseQueries, prettyQuery) <- lift @Transaction zoomDbOptions
    traceQueryIfEnabled span logDatabaseQueries prettyQuery qry (HasMultiParams params)
    conn <- Transaction ask
    PG.returningWith fromRow conn qry (params & toList)
      & handlePGException prettyQuery "executeManyReturning" qry (Right params)

foldRowsWithAccImpl ::
  ( ToRow params,
    MonadUnliftIO m,
    MonadLogger m,
    Otel.MonadTracer m
  ) =>
  m (DebugLogDatabaseQueries, PrettyPrintDatabaseQueries) ->
  Query ->
  params ->
  Decoder row ->
  a ->
  (a -> row -> Transaction m a) ->
  Transaction m a
{-# INLINE foldRowsWithAccImpl #-}
foldRowsWithAccImpl zoomDbOptions qry params (Decoder rowParser) accumulator f = do
  Otel.inSpan' "Postgres Query (foldRowsWithAcc)" Otel.defaultSpanArguments $ \span -> do
    (logDatabaseQueries, prettyQuery) <- lift @Transaction zoomDbOptions
    traceQueryIfEnabled span logDatabaseQueries prettyQuery qry (HasSingleParam params)
    conn <- Transaction ask
    withRunInIO
      ( \runInIO ->
          do
            PG.foldWithOptionsAndParser
              PG.defaultFoldOptions
              rowParser
              conn
              qry
              params
              accumulator
              (\acc row -> runInIO $ f acc row)
              & handlePGException prettyQuery "fold" qry (Left params)
              & runInIO
      )

pgFormatQueryNoParams' ::
  (MonadIO m, MonadLogger m) =>
  PrettyPrintDatabaseQueries ->
  Query ->
  Transaction m ByteString
pgFormatQueryNoParams' prettyQuery q = case prettyQuery of
  DontPrettyPrintDatabaseQueries -> pure q.fromQuery
  PrettyPrintDatabaseQueries pool -> lift $ pgFormatQueryByteString pool q.fromQuery

pgFormatQuery ::
  (ToRow params, MonadIO m) =>
  Query ->
  params ->
  Transaction m ByteString
pgFormatQuery qry params = Transaction $ do
  conn <- ask
  liftIO $ PG.formatQuery conn qry params

pgFormatQueryMany ::
  (MonadIO m, ToRow params) =>
  Query ->
  NonEmpty params ->
  Transaction m ByteString
pgFormatQueryMany qry params = Transaction $ do
  conn <- ask
  liftIO $
    PG.formatMany
      conn
      qry
      ( params
          -- upstream is partial on empty list, see https://github.com/haskellari/postgresql-simple/issues/129
          & toList
      )

queryWithImpl ::
  ( ToRow params,
    MonadUnliftIO m,
    MonadLogger m,
    Otel.MonadTracer m
  ) =>
  m (DebugLogDatabaseQueries, PrettyPrintDatabaseQueries) ->
  Query ->
  params ->
  Decoder r ->
  Transaction m [r]
{-# INLINE queryWithImpl #-}
queryWithImpl zoomDbOptions qry params (Decoder fromRow) = do
  Otel.inSpan' "Postgres Query (queryWith)" Otel.defaultSpanArguments $ \span -> do
    (logDatabaseQueries, prettyQuery) <- lift @Transaction zoomDbOptions
    traceQueryIfEnabled span logDatabaseQueries prettyQuery qry (HasSingleParam params)
    conn <- Transaction ask
    PG.queryWith fromRow conn qry params
      & handlePGException prettyQuery "query" qry (Left params)

queryWithImpl_ ::
  ( MonadUnliftIO m,
    MonadLogger m
  ) =>
  m PrettyPrintDatabaseQueries ->
  Query ->
  Decoder r ->
  Transaction m [r]
{-# INLINE queryWithImpl_ #-}
queryWithImpl_ zoomDbOptions qry (Decoder fromRow) = do
  prettyQuery <- lift @Transaction zoomDbOptions
  conn <- Transaction ask
  liftIO (PG.queryWith_ fromRow conn qry)
    & handlePGException prettyQuery "query" qry (Left ())

data SingleRowError = SingleRowError
  { -- | How many columns were actually returned by the query
    numberOfRowsReturned :: Int
  }
  deriving stock (Show)

instance Exception SingleRowError where
  displayException (SingleRowError {..}) = [fmt|Single row expected from SQL query result, {numberOfRowsReturned} rows were returned instead."|]

pgFormatQuery' ::
  ( MonadIO m,
    ToRow params,
    MonadLogger m
  ) =>
  PrettyPrintDatabaseQueries ->
  Query ->
  params ->
  Transaction m ByteString
pgFormatQuery' prettyQuery q p = case prettyQuery of
  DontPrettyPrintDatabaseQueries -> pgFormatQuery q p
  PrettyPrintDatabaseQueries pool ->
    pgFormatQuery q p
      >>= lift . pgFormatQueryByteString pool

pgFormatQueryMany' ::
  ( MonadIO m,
    ToRow params,
    MonadLogger m
  ) =>
  PrettyPrintDatabaseQueries ->
  Query ->
  NonEmpty params ->
  Transaction m ByteString
pgFormatQueryMany' prettyQuery q p = case prettyQuery of
  DontPrettyPrintDatabaseQueries -> pgFormatQueryMany q p
  PrettyPrintDatabaseQueries pool ->
    pgFormatQueryMany q p
      >>= lift . pgFormatQueryByteString pool

-- | Read the executable name "pg_format"
postgresToolsParser :: ToolParserT IO (Label "pgFormat" Tool)
postgresToolsParser = label @"pgFormat" <$> readTool "pg_format"

pgFormatQueryByteString ::
  ( MonadIO m,
    MonadLogger m
  ) =>
  PgFormatPool ->
  ByteString ->
  m ByteString
pgFormatQueryByteString pool queryBytes = do
  res <-
    liftIO $
      runPgFormat
        pool
        (queryBytes)
  case res.exitCode of
    ExitSuccess -> pure (res.formatted)
    ExitFailure status -> do
      logWarn [fmt|pg_format failed with status {status} while formatting the query, using original query string. Is there a syntax error?|]
      logDebug
        ( prettyErrorTree
            ( nestedMultiError
                "pg_format output"
                ( nestedError "stdout" (singleError (res.formatted & bytesToTextUtf8Lenient & newError))
                    :| [(nestedError "stderr" (singleError (res.stderr & bytesToTextUtf8Lenient & newError)))]
                )
            )
        )
      logDebug [fmt|pg_format stdout: stderr|]
      pure (queryBytes)

pgFormatStartCommandWaitForInput ::
  ( MonadIO m,
    HasField "pgFormat" tools Tool,
    MonadFail m
  ) =>
  tools ->
  m PgFormatProcess
pgFormatStartCommandWaitForInput tools = do
  do
    startedAt <- Otel.getTimestamp
    (Just stdinHdl, Just stdoutHdl, Just stderrHdl, procHdl) <-
      Process.createProcess
        ( ( Process.proc
              tools.pgFormat.toolPath
              [ "--no-rcfile",
                "-"
              ]
          )
            { Process.std_in = Process.CreatePipe,
              Process.std_out = Process.CreatePipe,
              Process.std_err = Process.CreatePipe
            }
        )

    pure PgFormatProcess {..}

data DebugLogDatabaseQueries
  = -- | Do not log the database queries
    DontLogDatabaseQueries
  | -- | Log the database queries as debug output;
    LogDatabaseQueries
  | -- | Log the database queries as debug output and additionally the EXPLAIN output (from the query analyzer, not the actual values after execution cause that’s a bit harder to do)
    LogDatabaseQueriesAndExplain
  deriving stock (Show, Enum, Bounded)

-- | Whether to pipe database queries thru `pg_format` before logging them. This takes a long (long! 200ms+) time per query, so should only be used in debugging environments where speed is not an issue.
data PrettyPrintDatabaseQueries
  = -- | Do not pretty-print database querios
    DontPrettyPrintDatabaseQueries
  | -- | Pretty-print database queries, slow
    PrettyPrintDatabaseQueries PgFormatPool

instance Show PrettyPrintDatabaseQueries where
  show DontPrettyPrintDatabaseQueries = "DontPrettyPrintDatabaseQueries"
  show (PrettyPrintDatabaseQueries _) = "PrettyPrintDatabaseQueries"

data HasQueryParams param
  = HasNoParams
  | HasSingleParam param
  | HasMultiParams (NonEmpty param)

-- | Log the postgres query depending on the given setting
traceQueryIfEnabled ::
  ( ToRow params,
    MonadUnliftIO m,
    MonadLogger m,
    Otel.MonadTracer m
  ) =>
  Otel.Span ->
  DebugLogDatabaseQueries ->
  PrettyPrintDatabaseQueries ->
  Query ->
  HasQueryParams params ->
  Transaction m ()
traceQueryIfEnabled span logDatabaseQueries prettyQuery qry params = do
  -- In case we have query logging enabled, we want to do that
  let formattedQuery =
        withEvent
          span
          "Query Format start"
          "Query Format end"
          $ case params of
            HasNoParams -> pgFormatQueryNoParams' prettyQuery qry
            HasSingleParam p -> pgFormatQuery' prettyQuery qry p
            HasMultiParams ps -> pgFormatQueryMany' prettyQuery qry ps

  let doLog errs = do
        Otel.addAttribute span "_.postgres.query" (errs.query & bytesToTextUtf8Lenient & Otel.toAttribute)
        for_ errs.explain $ \ex ->
          Otel.addAttribute span "_.postgres.explain" (Otel.toAttribute @Text ex)
  let doExplain = do
        q <- formattedQuery
        Otel.inSpan "Postgres EXPLAIN Query" Otel.defaultSpanArguments $ do
          queryWithImpl_
            (pure prettyQuery)
            ( "EXPLAIN "
                <> (
                     -- TODO: this is not nice, but the only way to get the `executeMany` form to work with this
                     -- because we need the query with all elements already interpolated.
                     Query q
                   )
            )
            (Dec.fromField @Text)
            <&> Text.intercalate "\n"
  case logDatabaseQueries of
    DontLogDatabaseQueries -> pure ()
    LogDatabaseQueries -> do
      q <- formattedQuery
      doLog (T2 (label @"query" q) (label @"explain" Nothing))
    LogDatabaseQueriesAndExplain -> do
      q <- formattedQuery
      -- XXX: stuff like `CREATE SCHEMA` cannot be EXPLAINed, so we should catch exceptions here
      -- and just ignore anything that errors (if it errors because of a problem with the query, it would have been caught by the query itself.
      ex <- doExplain
      doLog (T2 (label @"query" q) (label @"explain" (Just ex)))

-- | Add a start and end event to the span, and figure out how long the difference was.
--
-- This is more lightweight than starting an extra span for timing things.
withEvent :: (MonadIO f) => Otel.Span -> Text -> Text -> f b -> f b
withEvent span start end act = do
  let mkMs ts = (ts & Otel.timestampNanoseconds & toInteger) `div` 1000_000
  s <- Otel.getTimestamp
  Otel.addEvent
    span
    ( Otel.NewEvent
        { newEventName = start,
          newEventAttributes = mempty,
          newEventTimestamp = Just s
        }
    )
  res <- act
  e <- Otel.getTimestamp
  let tookMs =
        (mkMs e - mkMs s)
          -- should be small enough
          & fromInteger @Int
  Otel.addEvent
    span
    ( Otel.NewEvent
        { newEventName = end,
          newEventAttributes = HashMap.fromList [("took ms", Otel.toAttribute tookMs)],
          newEventTimestamp = Just e
        }
    )
  pure res

unzipPGArray ::
  forall l1 t1 l2 t2 r.
  ( HasField l1 r t1,
    HasField l2 r t2
  ) =>
  [r] ->
  (PGArray t1, PGArray t2)
{-# INLINEABLE unzipPGArray #-}
unzipPGArray xs =
  ( PGArray $ getField @l1 <$> xs,
    PGArray $ getField @l2 <$> xs
  )

unzip3PGArray ::
  forall l1 t1 l2 t2 l3 t3 r.
  ( HasField l1 r t1,
    HasField l2 r t2,
    HasField l3 r t3
  ) =>
  [r] ->
  (PGArray t1, PGArray t2, PGArray t3)
{-# INLINEABLE unzip3PGArray #-}
unzip3PGArray xs =
  ( PGArray $ getField @l1 <$> xs,
    PGArray $ getField @l2 <$> xs,
    PGArray $ getField @l3 <$> xs
  )

unzip4PGArray ::
  forall l1 t1 l2 t2 l3 t3 l4 t4 r.
  ( HasField l1 r t1,
    HasField l2 r t2,
    HasField l3 r t3,
    HasField l4 r t4
  ) =>
  [r] ->
  (PGArray t1, PGArray t2, PGArray t3, PGArray t4)
{-# INLINEABLE unzip4PGArray #-}
unzip4PGArray xs =
  ( PGArray $ getField @l1 <$> xs,
    PGArray $ getField @l2 <$> xs,
    PGArray $ getField @l3 <$> xs,
    PGArray $ getField @l4 <$> xs
  )

unzip5PGArray ::
  forall l1 t1 l2 t2 l3 t3 l4 t4 l5 t5 r.
  ( HasField l1 r t1,
    HasField l2 r t2,
    HasField l3 r t3,
    HasField l4 r t4,
    HasField l5 r t5
  ) =>
  [r] ->
  (PGArray t1, PGArray t2, PGArray t3, PGArray t4, PGArray t5)
{-# INLINEABLE unzip5PGArray #-}
unzip5PGArray xs =
  ( PGArray $ getField @l1 <$> xs,
    PGArray $ getField @l2 <$> xs,
    PGArray $ getField @l3 <$> xs,
    PGArray $ getField @l4 <$> xs,
    PGArray $ getField @l5 <$> xs
  )

instance (ToField t1) => ToRow (Label l1 t1) where
  toRow t2 = toRow $ PG.Only $ getField @l1 t2

instance (ToField t1, ToField t2) => ToRow (T2 l1 t1 l2 t2) where
  toRow t2 = toRow (getField @l1 t2, getField @l2 t2)

instance (ToField t1, ToField t2, ToField t3) => ToRow (T3 l1 t1 l2 t2 l3 t3) where
  toRow t3 = toRow (getField @l1 t3, getField @l2 t3, getField @l3 t3)
