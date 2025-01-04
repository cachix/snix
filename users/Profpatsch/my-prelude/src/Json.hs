{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE UndecidableInstances #-}

module Json where

import Data.Aeson (FromJSON (parseJSON), ToJSON (toEncoding, toJSON), Value (..), withObject)
import Data.Aeson qualified as Json
import Data.Aeson.BetterErrors qualified as Json
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types qualified
import Data.Error.Tree
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Data.Vector qualified as Vector
import FieldParser (FieldParser)
import FieldParser qualified as Field
import Label
import MyPrelude
import Pretty

-- | Use a "Data.Aeson.BetterErrors" parser to implement 'FromJSON'’s 'parseJSON' method.
--
-- @
-- instance FromJSON Foo where
--   parseJSON = Json.toParseJSON parseFoo
-- @
toParseJSON ::
  -- | the error type is 'Error', if you need 'ErrorTree' use 'toParseJSONErrorTree'
  Json.Parse Error a ->
  Value ->
  Data.Aeson.Types.Parser a
toParseJSON = Json.toAesonParser prettyError

-- | Use a "Data.Aeson.BetterErrors" parser to implement 'FromJSON'’s 'parseJSON' method.
--
-- @
-- instance FromJSON Foo where
--   parseJSON = Json.toParseJSON parseFoo
-- @
toParseJSONErrorTree ::
  -- | the error type is 'ErrorTree', if you need 'Error' use 'toParseJSON'
  Json.Parse ErrorTree a ->
  Value ->
  Data.Aeson.Types.Parser a
toParseJSONErrorTree = Json.toAesonParser prettyErrorTree

-- | Convert a 'Json.ParseError' to a corresponding 'ErrorTree'
--
-- TODO: build a different version of 'Json.displayError' so that we can nest 'ErrorTree' as well
parseErrorTree :: Error -> Json.ParseError ErrorTree -> ErrorTree
parseErrorTree contextMsg errs =
  errs
    & Json.displayError prettyErrorTree
    & Text.intercalate "\n"
    & newError
    -- We nest this here because the json errors is multiline, so the result looks like
    --
    -- @
    -- contextMsg
    -- \|
    -- `- At the path: ["foo"]["bar"]
    --   Type mismatch:
    --   Expected a value of type object
    --   Got: true
    -- @
    & singleError
    & nestedError contextMsg

-- | Convert a 'Json.ParseError' to a corresponding 'ErrorTree'
--
-- This version shows some of the value at the path where the error occurred.
parseErrorTreeValCtx :: Error -> Json.Value -> Json.ParseError ErrorTree -> ErrorTree
parseErrorTreeValCtx contextMsg origValue errs = do
  let ctxPath = case errs of
        Json.BadSchema path _spec -> Just path
        _ -> Nothing
  let getSubset (Json.Object o) (Json.ObjectKey k) = o & KeyMap.lookup (Key.fromText k)
      getSubset (Json.Array a) (Json.ArrayIndex k) = a Vector.!? k
      getSubset _ _ = Nothing
  let go v = \case
        IsEmpty -> v
        IsNonEmpty (p :| path) -> case getSubset v p of
          Nothing -> v
          Just v' -> go v' path

  ( ( errs
        & Json.displayError prettyErrorTree
        & Text.intercalate "\n"
        & newError
    )
      :| ( maybe
             []
             ( \ctx ->
                 [ go origValue ctx
                     & Pretty.showPrettyJson
                     & newError
                 ]
             )
             ctxPath
         )
    )
    -- We nest this here because the json errors is multiline, so the result looks like
    --
    -- @
    -- contextMsg
    -- \|
    -- `- At the path: ["foo"]["bar"]
    --   Type mismatch:
    --   Expected a value of type object
    --   Got: true
    -- @
    & errorTree contextMsg

-- | Lift the parser error to an error tree
asErrorTree :: (Functor m) => Json.ParseT Error m a -> Json.ParseT ErrorTree m a
asErrorTree = Json.mapError singleError

-- | Parse the json array into a 'Set'.
asArraySet ::
  (Ord a, Monad m) =>
  Json.ParseT err m a ->
  Json.ParseT err m (Set a)
asArraySet inner = Set.fromList <$> Json.eachInArray inner

-- | Parse the json object into a 'Map'.
asObjectMap ::
  (Monad m) =>
  Json.ParseT err m a ->
  Json.ParseT err m (Map Text a)
asObjectMap inner = Map.fromList <$> Json.eachInObject inner

-- | Parse as json array and count the number of elements in the array.
countArrayElements :: (Monad m) => Json.ParseT Error m Natural
countArrayElements = Field.toJsonParser ((jsonArray <&> Vector.length) >>> Field.integralToNatural)
  where
    -- I don’t want to add this to the FieldParser module, cause users should not be dealing with arrays manually.
    jsonArray :: FieldParser Json.Value (Vector Json.Value)
    jsonArray = Field.FieldParser $ \case
      Json.Array vec -> Right vec
      _ -> Left "Not a json array"

-- | Parse as json number and convert it to a 'Double'. Throws an error if the number does not fit into a 'Double'.
asDouble :: (Monad m) => Json.ParseT Error m Double
asDouble =
  Field.toJsonParser
    ( Field.jsonNumber
        >>> Field.boundedScientificRealFloat @Double
    )

asInt :: (Monad m) => Json.ParseT Error m Int
asInt =
  Field.toJsonParser
    ( Field.jsonNumber
        >>> Field.boundedScientificIntegral @Int "Cannot parse into Int"
    )

-- | Json string containing a UTC timestamp,
-- @yyyy-mm-ddThh:mm:ss[.sss]Z@ (ISO 8601:2004(E) sec. 4.3.2 extended format)
asUtcTime :: (Monad m) => Json.ParseT Error m UTCTime
asUtcTime = Field.toJsonParser (Field.jsonString >>> Field.utcTime)

-- | Json string containing a UTC timestamp.
-- | Accepts multiple timezone formats.
-- Do not use this if you can force the input to use the `Z` UTC notation (e.g. in a CSV), use 'utcTime' instead.
--
-- Accepts
--
-- * UTC timestamps: @yyyy-mm-ddThh:mm:ss[.sss]Z@
-- * timestamps with time zone: @yyyy-mm-ddThh:mm:ss[.sss]±hh:mm@
--
-- ( both ISO 8601:2004(E) sec. 4.3.2 extended format)
--
-- The time zone of the second kind of timestamp is taken into account, but normalized to UTC (it’s not preserved what the original time zone was)
asUtcTimeLenient :: (Monad m) => Json.ParseT Error m UTCTime
asUtcTimeLenient = Field.toJsonParser (Field.jsonString >>> Field.utcTimeLenient)

-- | Parse a key from the object, à la 'Json.key', return a labelled value.
--
-- We don’t provide a version that infers the json object key,
-- since that conflates internal naming with the external API, which is dangerous.
--
-- @@
-- do
--   txt <- keyLabel @"myLabel" "jsonKeyName" Json.asText
--   pure (txt :: Label "myLabel" Text)
-- @@
keyLabel ::
  forall label err m a.
  (Monad m) =>
  Text ->
  Json.ParseT err m a ->
  Json.ParseT err m (Label label a)
keyLabel = do
  keyLabel' (Proxy @label)

-- | Parse a key from the object, à la 'Json.key', return a labelled value.
-- Version of 'keyLabel' that requires a proxy.
--
-- @@
-- do
--   txt <- keyLabel' (Proxy @"myLabel") "jsonKeyName" Json.asText
--   pure (txt :: Label "myLabel" Text)
-- @@
keyLabel' ::
  forall label err m a.
  (Monad m) =>
  Proxy label ->
  Text ->
  Json.ParseT err m a ->
  Json.ParseT err m (Label label a)
keyLabel' Proxy key parser = label @label <$> Json.key key parser

-- | Parse an optional key from the object, à la 'Json.keyMay', return a labelled value.
--
-- We don’t provide a version that infers the json object key,
-- since that conflates internal naming with the external API, which is dangerous.
--
-- @@
-- do
--   txt <- keyLabelMay @"myLabel" "jsonKeyName" Json.asText
--   pure (txt :: Label "myLabel" (Maybe Text))
-- @@
keyLabelMay ::
  forall label err m a.
  (Monad m) =>
  Text ->
  Json.ParseT err m a ->
  Json.ParseT err m (Label label (Maybe a))
keyLabelMay = do
  keyLabelMay' (Proxy @label)

-- | Parse an optional key from the object, à la 'Json.keyMay', return a labelled value.
-- Version of 'keyLabelMay' that requires a proxy.
--
-- @@
-- do
--   txt <- keyLabelMay' (Proxy @"myLabel") "jsonKeyName" Json.asText
--   pure (txt :: Label "myLabel" (Maybe Text))
-- @@
keyLabelMay' ::
  forall label err m a.
  (Monad m) =>
  Proxy label ->
  Text ->
  Json.ParseT err m a ->
  Json.ParseT err m (Label label (Maybe a))
keyLabelMay' Proxy key parser = label @label <$> Json.keyMay key parser

-- NOTE: keyRenamed Test in "Json.JsonTest", due to import cycles.

-- | Like 'Json.key', but allows a list of keys that are tried in order.
--
-- This is intended for renaming keys in an object.
-- The first key is the most up-to-date version of a key, the others are for backward-compatibility.
--
-- If a key (new or old) exists, the inner parser will always be executed for that key.
keyRenamed :: (Monad m) => NonEmpty Text -> Json.ParseT err m a -> Json.ParseT err m a
keyRenamed (newKey :| oldKeys) inner =
  keyRenamedTryOldKeys oldKeys inner >>= \case
    Nothing -> Json.key newKey inner
    Just parse -> parse

-- | Like 'Json.keyMay', but allows a list of keys that are tried in order.
--
-- This is intended for renaming keys in an object.
-- The first key is the most up-to-date version of a key, the others are for backward-compatibility.
--
-- If a key (new or old) exists, the inner parser will always be executed for that key.
keyRenamedMay :: (Monad m) => NonEmpty Text -> Json.ParseT err m a -> Json.ParseT err m (Maybe a)
keyRenamedMay (newKey :| oldKeys) inner =
  keyRenamedTryOldKeys oldKeys inner >>= \case
    Nothing -> Json.keyMay newKey inner
    Just parse -> Just <$> parse

-- | Helper function for 'keyRenamed' and 'keyRenamedMay' that returns the parser for the first old key that exists, if any.
keyRenamedTryOldKeys :: (Monad m) => [Text] -> Json.ParseT err m a -> Json.ParseT err m (Maybe (Json.ParseT err m a))
keyRenamedTryOldKeys oldKeys inner = do
  oldKeys & traverse tryOld <&> catMaybes <&> nonEmpty <&> \case
    Nothing -> Nothing
    Just (old :| _moreOld) -> Just old
  where
    tryOld key =
      Json.keyMay key (pure ()) <&> \case
        Just () -> Just $ Json.key key inner
        Nothing -> Nothing

-- | A simple type isomorphic to `()` that that transforms to an empty json object and parses
data EmptyObject = EmptyObject
  deriving stock (Show, Eq)

instance FromJSON EmptyObject where
  -- allow any fields, as long as its an object
  parseJSON = withObject "EmptyObject" (\_ -> pure EmptyObject)

instance ToJSON EmptyObject where
  toJSON EmptyObject = Object mempty
  toEncoding EmptyObject = toEncoding $ Object mempty

-- | Create a json array from a list of json values.
mkJsonArray :: [Value] -> Value
mkJsonArray xs = xs & Vector.fromList & Array
