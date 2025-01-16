{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE ViewPatterns #-}

module MyPrelude
  ( -- * Text conversions
    Text,
    ByteString,
    Word8,
    fmt,
    textToString,
    stringToText,
    stringToBytesUtf8,
    showToText,
    textToBytesUtf8,
    textToBytesUtf8Lazy,
    bytesToTextUtf8,
    bytesToTextUtf8Lazy,
    bytesToTextUtf8Lenient,
    bytesToTextUtf8LenientLazy,
    bytesToTextUtf8Unsafe,
    bytesToTextUtf8UnsafeLazy,
    toStrict,
    toLazy,
    toStrictBytes,
    toLazyBytes,
    charToWordUnsafe,

    -- * IO
    putStrLn,
    putStderrLn,
    exitWithMessage,

    -- * WIP code
    todo,

    -- * Records
    HasField,

    -- * Control flow
    doAs,
    (&),
    (<&>),
    (<|>),
    foldMap1,
    foldMap',
    join,
    when,
    unless,
    guard,
    ExceptT (..),
    runExceptT,
    MonadThrow,
    throwM,
    MonadIO,
    liftIO,
    MonadReader,
    asks,
    Bifunctor,
    first,
    second,
    bimap,
    both,
    foldMap,
    fold,
    foldl',
    fromMaybe,
    mapMaybe,
    findMaybe,
    Traversable,
    for,
    for_,
    traverse,
    traverse_,
    traverseFold,
    traverseFold1,
    traverseFoldDefault,
    MonadTrans,
    lift,

    -- * Kinds
    Type,

    -- * Data types
    Coercible,
    coerce,
    Proxy (Proxy),
    Map,
    annotate,
    Validation (Success, Failure),
    failure,
    successes,
    failures,
    traverseValidate,
    traverseValidateM,
    traverseValidateM_,
    eitherToValidation,
    eitherToListValidation,
    validationToEither,
    These (This, That, These),
    eitherToThese,
    eitherToListThese,
    validationToThese,
    thenThese,
    thenValidate,
    thenValidateM,
    NonEmpty ((:|)),
    pattern IsEmpty,
    pattern IsNonEmpty,
    singleton,
    nonEmpty,
    nonEmptyDef,
    overNonEmpty,
    zipNonEmpty,
    zipWithNonEmpty,
    zip3NonEmpty,
    zipWith3NonEmpty,
    zip4NonEmpty,
    toList,
    lengthNatural,
    maximum1,
    minimum1,
    maximumBy1,
    minimumBy1,
    Vector,
    Generic,
    Lift,
    Semigroup,
    sconcat,
    Monoid,
    mconcat,
    ifTrue,
    ifExists,
    sintersperse,
    mintersperse,
    Void,
    absurd,
    Identity (Identity, runIdentity),
    Natural,
    naturalToInteger,
    intToNatural,
    integerToBounded,
    integerToBoundedClamped,
    Scientific,
    Contravariant,
    contramap,
    (>$<),
    (>&<),
    module Divisive,
    Profunctor,
    dimap,
    lmap,
    rmap,
    Semigroupoid,
    Category,
    (>>>),
    (&>>),
    cconst,
    Any,

    -- * Enum definition
    inverseFunction,
    inverseMap,
    enumerateAll,

    -- * Map helpers
    mapFromListOn,
    mapFromListOnMerge,

    -- * Error handling
    HasCallStack,
    module Data.Error,
    symbolText,
  )
where

import Control.Applicative ((<|>))
import Control.Category (Category, (>>>))
import Control.Category qualified as Category
import Control.Foldl.NonEmpty qualified as Foldl1
import Control.Monad (guard, join, unless, when)
import Control.Monad.Catch (MonadThrow (throwM))
import Control.Monad.Except
  ( ExceptT (..),
    runExceptT,
  )
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Identity (Identity (Identity))
import Control.Monad.Reader (MonadReader, asks)
import Control.Monad.Trans (MonadTrans (lift))
import Data.Bifunctor (Bifunctor, bimap, first, second)
import Data.ByteString
  ( ByteString,
  )
import Data.ByteString.Lazy qualified
import Data.Char qualified
import Data.Coerce (Coercible, coerce)
import Data.Data (Proxy (Proxy))
import Data.Error
import Data.Foldable (Foldable (foldMap', toList), fold, foldl', for_, sequenceA_, traverse_)
import Data.Foldable qualified as Foldable
import Data.Function ((&))
import Data.Functor ((<&>))
import Data.Functor.Contravariant (Contravariant (contramap), (>$<))
import Data.Functor.Identity (Identity (runIdentity))
import Data.Kind (Type)
import Data.List (zip4)
import Data.List qualified as List
import Data.List.NonEmpty (NonEmpty ((:|)), nonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict
  ( Map,
  )
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Maybe qualified as Maybe
import Data.Profunctor (Profunctor, dimap, lmap, rmap)
import Data.Scientific (Scientific)
import Data.Semigroup (sconcat)
import Data.Semigroup.Foldable (Foldable1 (fold1, toNonEmpty), foldMap1)
import Data.Semigroup.Traversable (Traversable1)
import Data.Semigroupoid (Semigroupoid (o))
import Data.Text
  ( Text,
  )
import Data.Text qualified
import Data.Text.Encoding qualified
import Data.Text.Encoding.Error qualified
import Data.Text.Lazy qualified
import Data.Text.Lazy.Encoding qualified
import Data.These (These (That, These, This))
import Data.Traversable (for)
import Data.Vector (Vector)
import Data.Void (Void, absurd)
import Data.Word (Word8)
import Divisive
import GHC.Exception (errorCallWithCallStackException)
import GHC.Exts (Any, RuntimeRep, TYPE, raise#)
import GHC.Generics (Generic)
import GHC.Natural (naturalToInteger)
import GHC.Records (HasField)
import GHC.Stack (HasCallStack)
import GHC.TypeLits
import GHC.Utils.Encoding qualified as GHC
import Language.Haskell.TH.Syntax (Lift)
import PyF (fmt)
import System.Exit qualified
import System.IO qualified
import Validation
  ( Validation (Failure, Success),
    eitherToValidation,
    failure,
    failures,
    successes,
    validationToEither,
  )

-- | Mark a `do`-block with the type of the Monad/Applicativ it uses.
-- Only intended for reading ease and making code easier to understand,
-- especially do-blocks that use unconventional monads (like Maybe or List).
--
-- Example:
--
-- @
-- doAs @Maybe $ do
--  a <- Just 'a'
--  b <- Just 'b'
--  pure (a, b)
-- @
doAs :: forall m a. m a -> m a
doAs = id

-- | Forward-applying 'contramap', like '&'/'$' and '<&>'/'<$>' but for '>$<'.
(>&<) :: (Contravariant f) => f b -> (a -> b) -> f a
(>&<) = flip contramap

infixl 5 >&<

-- | Forward semigroupoid application. The same as '(>>>)', but 'Semigroupoid' is not a superclass of 'Category' (yet).
--
-- Specialized examples:
--
-- @
-- for functions : (a -> b) -> (b -> c) -> (a -> c)
-- for Folds: Fold a b -> Fold b c -> Fold a c
-- @
(&>>) :: (Semigroupoid s) => s a b -> s b c -> s a c
(&>>) = flip Data.Semigroupoid.o

-- like >>>
infixr 1 &>>

-- | Categorical constant function,
-- like 'const' but works for anything that’s a category and profunctor.
cconst :: (Category c, Profunctor c) => b -> c a b
cconst b = Category.id & rmap (\_ -> b)

-- | encode a Text to a UTF-8 encoded Bytestring
textToBytesUtf8 :: Text -> ByteString
textToBytesUtf8 = Data.Text.Encoding.encodeUtf8

-- | encode a lazy Text to a UTF-8 encoded lazy Bytestring
textToBytesUtf8Lazy :: Data.Text.Lazy.Text -> Data.ByteString.Lazy.ByteString
textToBytesUtf8Lazy = Data.Text.Lazy.Encoding.encodeUtf8

bytesToTextUtf8 :: ByteString -> Either Error Text
bytesToTextUtf8 = first exceptionToError . Data.Text.Encoding.decodeUtf8'

bytesToTextUtf8Lazy :: Data.ByteString.Lazy.ByteString -> Either Error Data.Text.Lazy.Text
bytesToTextUtf8Lazy = first exceptionToError . Data.Text.Lazy.Encoding.decodeUtf8'

-- | decode a Text from a ByteString that is assumed to be UTF-8 (crash if that is not the case)
bytesToTextUtf8Unsafe :: ByteString -> Text
bytesToTextUtf8Unsafe = Data.Text.Encoding.decodeUtf8

-- | decode a Text from a ByteString that is assumed to be UTF-8 (crash if that is not the case)
bytesToTextUtf8UnsafeLazy :: Data.ByteString.Lazy.ByteString -> Data.Text.Lazy.Text
bytesToTextUtf8UnsafeLazy = Data.Text.Lazy.Encoding.decodeUtf8

-- | decode a Text from a ByteString that is assumed to be UTF-8,
-- replace non-UTF-8 characters with the replacment char U+FFFD.
bytesToTextUtf8Lenient :: Data.ByteString.ByteString -> Data.Text.Text
bytesToTextUtf8Lenient =
  Data.Text.Encoding.decodeUtf8With Data.Text.Encoding.Error.lenientDecode

-- | decode a lazy Text from a lazy ByteString that is assumed to be UTF-8,
-- replace non-UTF-8 characters with the replacment char U+FFFD.
bytesToTextUtf8LenientLazy :: Data.ByteString.Lazy.ByteString -> Data.Text.Lazy.Text
bytesToTextUtf8LenientLazy =
  Data.Text.Lazy.Encoding.decodeUtf8With Data.Text.Encoding.Error.lenientDecode

-- | Make a lazy 'Text' strict.
toStrict :: Data.Text.Lazy.Text -> Text
toStrict = Data.Text.Lazy.toStrict

-- | Make a strict 'Text' lazy.
toLazy :: Text -> Data.Text.Lazy.Text
toLazy = Data.Text.Lazy.fromStrict

-- | Make a lazy 'ByteString' strict.
toStrictBytes :: Data.ByteString.Lazy.ByteString -> ByteString
toStrictBytes = Data.ByteString.Lazy.toStrict

-- | Make a strict 'ByteString' lazy.
toLazyBytes :: ByteString -> Data.ByteString.Lazy.ByteString
toLazyBytes = Data.ByteString.Lazy.fromStrict

-- | Convert a (performant) 'Text' into an (imperformant) list-of-char 'String'.
--
-- Some libraries (like @time@ or @network-uri@) still use the `String` as their interface. We only want to convert to string at the edges, otherwise use 'Text'.
--
-- ATTN: Don’t use `String` in code if you can avoid it, prefer `Text` instead.
textToString :: Text -> String
textToString = Data.Text.unpack

-- | Convert an (imperformant) list-of-char 'String' into a (performant) 'Text' .
--
-- Some libraries (like @time@ or @network-uri@) still use the `String` as their interface. We want to convert 'String' to 'Text' as soon as possible and only use 'Text' in our code.
--
-- ATTN: Don’t use `String` in code if you can avoid it, prefer `Text` instead.
stringToText :: String -> Text
stringToText = Data.Text.pack

-- | Encode a String to an UTF-8 encoded Bytestring
--
-- ATTN: Don’t use `String` in code if you can avoid it, prefer `Text` instead.
stringToBytesUtf8 :: String -> ByteString
-- TODO(Profpatsch): use a stable interface
stringToBytesUtf8 = GHC.utf8EncodeByteString

-- | Like `show`, but generate a 'Text'
--
-- ATTN: This goes via `String` and thus is fairly inefficient.
-- We should add a good display library at one point.
--
-- ATTN: unlike `show`, this forces the whole @'a
-- so only use if you want to display the whole thing.
showToText :: (Show a) => a -> Text
showToText = stringToText . show

-- | Unsafe conversion between 'Char' and 'Word8'. This is a no-op and
-- silently truncates to 8 bits Chars > '\255'. It is provided as
-- convenience for ByteString construction.
--
-- Use if you want to get the 'Word8' representation of a character literal.
-- Don’t use on arbitrary characters!
--
-- >>> charToWordUnsafe ','
-- 44
charToWordUnsafe :: Char -> Word8
{-# INLINE charToWordUnsafe #-}
charToWordUnsafe = fromIntegral . Data.Char.ord

pattern IsEmpty :: [a]
pattern IsEmpty <- (null -> True)
  where
    IsEmpty = []

pattern IsNonEmpty :: NonEmpty a -> [a]
pattern IsNonEmpty n <- (nonEmpty -> Just n)
  where
    IsNonEmpty n = toList n

{-# COMPLETE IsEmpty, IsNonEmpty #-}

-- | Single element in a (non-empty) list.
singleton :: a -> NonEmpty a
singleton a = a :| []

-- | If the given list is empty, use the given default element and return a non-empty list.
nonEmptyDef :: a -> [a] -> NonEmpty a
nonEmptyDef def xs =
  xs & nonEmpty & \case
    Nothing -> def :| []
    Just ne -> ne

-- | If the list is not empty, run the given function with a NonEmpty list, otherwise just return []
overNonEmpty :: (Applicative f) => (NonEmpty a -> f [b]) -> [a] -> f [b]
overNonEmpty f xs = case xs of
  IsEmpty -> pure []
  IsNonEmpty xs' -> f xs'

-- | Zip two non-empty lists.
zipNonEmpty :: NonEmpty a -> NonEmpty b -> NonEmpty (a, b)
{-# INLINE zipNonEmpty #-}
zipNonEmpty ~(a :| as) ~(b :| bs) = (a, b) :| zip as bs

-- | Zip two non-empty lists, combining them with the given function
zipWithNonEmpty :: (a -> b -> c) -> NonEmpty a -> NonEmpty b -> NonEmpty c
{-# INLINE zipWithNonEmpty #-}
zipWithNonEmpty = NonEmpty.zipWith

-- | Zip three non-empty lists.
zip3NonEmpty :: NonEmpty a -> NonEmpty b -> NonEmpty c -> NonEmpty (a, b, c)
{-# INLINE zip3NonEmpty #-}
zip3NonEmpty ~(a :| as) ~(b :| bs) ~(c :| cs) = (a, b, c) :| zip3 as bs cs

-- | Zip three non-empty lists, combining them with the given function
zipWith3NonEmpty :: (a -> b -> c -> d) -> NonEmpty a -> NonEmpty b -> NonEmpty c -> NonEmpty d
{-# INLINE zipWith3NonEmpty #-}
zipWith3NonEmpty f ~(x :| xs) ~(y :| ys) ~(z :| zs) = f x y z :| zipWith3 f xs ys zs

-- | Zip four non-empty lists
zip4NonEmpty :: NonEmpty a -> NonEmpty b -> NonEmpty c -> NonEmpty d -> NonEmpty (a, b, c, d)
{-# INLINE zip4NonEmpty #-}
zip4NonEmpty ~(a :| as) ~(b :| bs) ~(c :| cs) ~(d :| ds) = (a, b, c, d) :| zip4 as bs cs ds

-- | We don’t want to use Foldable’s `length`, because it is too polymorphic and can lead to bugs.
-- Only list-y things should have a length.
class (Foldable f) => Lengthy f

instance Lengthy []

instance Lengthy NonEmpty

instance Lengthy Vector

lengthNatural :: (Lengthy f) => f a -> Natural
lengthNatural xs =
  xs
    & Foldable.length
    -- length can never be negative or something went really, really wrong
    & fromIntegral @Int @Natural

-- | @O(n)@. Get the maximum element from a non-empty structure (strict).
maximum1 :: (Foldable1 f, Ord a) => f a -> a
maximum1 = Foldl1.fold1 Foldl1.maximum

-- | @O(n)@. Get the maximum element from a non-empty structure, using the given comparator (strict).
maximumBy1 :: (Foldable1 f) => (a -> a -> Ordering) -> f a -> a
maximumBy1 f = Foldl1.fold1 (Foldl1.maximumBy f)

-- | @O(n)@. Get the minimum element from a non-empty structure (strict).
minimum1 :: (Foldable1 f, Ord a) => f a -> a
minimum1 = Foldl1.fold1 Foldl1.minimum

-- | @O(n)@. Get the minimum element from a non-empty structure, using the given comparator (strict).
minimumBy1 :: (Foldable1 f) => (a -> a -> Ordering) -> f a -> a
minimumBy1 f = Foldl1.fold1 (Foldl1.minimumBy f)

-- | Annotate a 'Maybe' with an error message and turn it into an 'Either'.
annotate :: err -> Maybe a -> Either err a
annotate err = \case
  Nothing -> Left err
  Just a -> Right a

-- | Map the same function over both sides of a Bifunctor (e.g. a tuple).
both :: (Bifunctor bi) => (a -> b) -> bi a a -> bi b b
both f = bimap f f

-- | Find the first element for which pred returns `Just a`, and return the `a`.
--
-- Example:
-- @
-- >>> :set -XTypeApplications
-- >>> import qualified Text.Read
--
-- >>> findMaybe (Text.Read.readMaybe @Int) ["foo"]
-- Nothing
-- >>> findMaybe (Text.Read.readMaybe @Int) ["foo", "34.40", "34", "abc"]
-- Just 34
findMaybe :: (Foldable t) => (a -> Maybe b) -> t a -> Maybe b
findMaybe mPred list =
  let pred' x = Maybe.isJust $ mPred x
   in case Foldable.find pred' list of
        Just a -> mPred a
        Nothing -> Nothing

-- | 'traverse' with a function returning 'Either' and collect all errors that happen, if they happen.
--
-- Does not shortcut on error, so will always traverse the whole list/'Traversable' structure.
--
-- This is a useful error handling function in many circumstances,
-- because it won’t only return the first error that happens, but rather all of them.
traverseValidate :: forall t a err b. (Traversable t) => (a -> Either err b) -> t a -> Either (NonEmpty err) (t b)
traverseValidate f as =
  as
    & traverse @t @(Validation _) (eitherToListValidation . f)
    & validationToEither

-- | 'traverse' with a function returning 'm Either' and collect all errors that happen, if they happen.
--
-- Does not shortcut on error, so will always traverse the whole list/'Traversable' structure.
--
-- This is a useful error handling function in many circumstances,
-- because it won’t only return the first error that happens, but rather all of them.
traverseValidateM :: forall t m a err b. (Traversable t, Applicative m) => (a -> m (Either err b)) -> t a -> m (Either (NonEmpty err) (t b))
traverseValidateM f as =
  as
    & traverse @t @m (\a -> a & f <&> eitherToListValidation)
    <&> sequenceA @t @(Validation _)
    <&> validationToEither

-- | 'traverse_' with a function returning 'm Either' and collect all errors that happen, if they happen.
--
-- Does not shortcut on error, so will always traverse the whole list/'Traversable' structure.
--
-- This is a useful error handling function in many circumstances,
-- because it won’t only return the first error that happens, but rather all of them.
traverseValidateM_ :: forall t m a err. (Traversable t, Applicative m) => (a -> m (Either err ())) -> t a -> m (Either (NonEmpty err) ())
traverseValidateM_ f as =
  as
    & traverse @t @m (\a -> a & f <&> eitherToListValidation)
    <&> sequenceA_ @t @(Validation _)
    <&> validationToEither

-- | Like 'eitherToValidation', but puts the Error side into a NonEmpty list
-- to make it combine with other validations.
--
-- See also 'validateEithers', if you have a list of Either and want to collect all errors.
eitherToListValidation :: Either a c -> Validation (NonEmpty a) c
eitherToListValidation = first singleton . eitherToValidation

-- | Convert an 'Either' to a 'These'.
eitherToThese :: Either err a -> These err a
eitherToThese (Left err) = This err
eitherToThese (Right a) = That a

-- | Like 'eitherToThese', but puts the Error side into a NonEmpty list
-- to make it combine with other theses.
eitherToListThese :: Either err a -> These (NonEmpty err) a
eitherToListThese (Left e) = This (singleton e)
eitherToListThese (Right a) = That a

-- | Convert a 'Validation' to a 'These'.
validationToThese :: Validation err a -> These err a
validationToThese (Failure err) = This err
validationToThese (Success a) = That a

-- | Nested '>>=' of a These inside some other @m@.
--
-- Use if you want to collect errors and successes, and want to chain multiple function returning 'These'.
thenThese ::
  (Monad m, Semigroup err) =>
  (a -> m (These err b)) ->
  m (These err a) ->
  m (These err b)
thenThese f x = do
  th <- x
  join <$> traverse f th

-- | Nested validating bind-like combinator.
--
-- Use if you want to collect errors, and want to chain multiple functions returning 'Validation'.
thenValidate ::
  (a -> Validation err b) ->
  Validation err a ->
  Validation err b
thenValidate f = \case
  Success a -> f a
  Failure err -> Failure err

-- | Nested validating bind-like combinator inside some other @m@.
--
-- Use if you want to collect errors, and want to chain multiple functions returning 'Validation'.
thenValidateM ::
  (Monad m) =>
  (a -> m (Validation err b)) ->
  m (Validation err a) ->
  m (Validation err b)
thenValidateM f x =
  eitherToValidation <$> do
    x' <- validationToEither <$> x
    case x' of
      Left err -> pure $ Left err
      Right a -> validationToEither <$> f a

-- | Put the text to @stderr@.
putStderrLn :: Text -> IO ()
putStderrLn msg =
  System.IO.hPutStrLn System.IO.stderr $ textToString msg

exitWithMessage :: Text -> IO a
exitWithMessage msg = do
  putStderrLn msg
  System.Exit.exitWith $ System.Exit.ExitFailure (-1)

-- | Run some function producing applicative over a traversable data structure,
-- then collect the results in a Monoid.
--
-- Very helpful with side-effecting functions returning @(Validation err a)@:
--
-- @
-- let
--   f :: Text -> IO (Validation (NonEmpty Error) Text)
--   f t = pure $ if t == "foo" then Success t else Failure (singleton ("not foo: " <> t))
--
-- in traverseFold f [ "foo", "bar", "baz" ]
--   == Failure ("not foo bar" :| ["not foo baz"])
-- @
--
-- … since @(Semigroup err => Validation err a)@ is a @Semigroup@/@Monoid@ itself.
traverseFold :: (Applicative ap, Traversable t, Monoid m) => (a -> ap m) -> t a -> ap m
{-# INLINE traverseFold #-}
traverseFold f xs =
  -- note: could be weakened to (Foldable t) via `getAp . foldMap (Ap . f)`
  fold <$> traverse f xs

-- | Like 'traverseFold', but fold over a semigroup instead of a Monoid, by providing a starting element.
traverseFoldDefault :: (Applicative ap, Traversable t, Semigroup m) => m -> (a -> ap m) -> t a -> ap m
{-# INLINE traverseFoldDefault #-}
traverseFoldDefault def f xs = foldDef def <$> traverse f xs
  where
    foldDef = foldr (<>)

-- | Same as 'traverseFold', but with a 'Semigroup' and 'Traversable1' restriction.
traverseFold1 :: (Applicative ap, Traversable1 t, Semigroup s) => (a -> ap s) -> t a -> ap s
{-# INLINE traverseFold1 #-}
-- note: cannot be weakened to (Foldable1 t) because there is no `Ap` for Semigroup (No `Apply` typeclass)
traverseFold1 f xs = fold1 <$> traverse f xs

-- | Use this in places where the code is still to be implemented.
--
-- It always type-checks and will show a warning at compile time if it was forgotten in the code.
--
-- Use instead of 'error' and 'undefined' for code that hasn’t been written.
--
-- Uses the same trick as https://hackage.haskell.org/package/protolude-0.3.0/docs/src/Protolude.Error.html#error
{-# WARNING todo "'todo' (undefined code) remains in code" #-}
todo :: forall (r :: RuntimeRep). forall (a :: TYPE r). (HasCallStack) => a
todo = raise# (errorCallWithCallStackException "This code was not yet implemented: TODO" ?callStack)

-- | Convert an integer to a 'Natural' if possible
--
-- Named the same as the function from "GHC.Natural", but does not crash.
intToNatural :: (Integral a) => a -> Maybe Natural
intToNatural i =
  if i < 0
    then Nothing
    else Just $ fromIntegral i

-- | Convert an Integer to a bounded type if possible.
--
-- taken from 'Scientific.toBoundedInteger'.
integerToBounded :: forall i. (Bounded i, Integral i) => Integer -> Maybe i
integerToBounded i
  | i < iMinBound || i > iMaxBound = Nothing
  | otherwise = Just $ fromInteger i
  where
    iMinBound = toInteger (minBound :: i)
    iMaxBound = toInteger (maxBound :: i)

-- | Convert an Integer to a bounded type, clamping to the bounds if necessary.
integerToBoundedClamped :: forall i. (Bounded i, Integral i) => Integer -> i
integerToBoundedClamped i
  | i < iMinBound = minBound
  | i > iMaxBound = maxBound
  | otherwise = fromInteger i
  where
    iMinBound = toInteger (minBound :: i)
    iMaxBound = toInteger (maxBound :: i)

-- | @inverseFunction f@ creates a function that is the inverse of a given function
-- @f@. It does so by constructing 'M.Map' internally for each value @f a@. The
-- implementation makes sure that the 'M.Map' is constructed only once and then
-- shared for every call.
--
-- __Memory usage note:__ don't inverse functions that have types like 'Int'
-- as their result. In this case the created 'M.Map' will have huge size.
--
-- The complexity of reversed mapping is \(\mathcal{O}(\log n)\).
--
-- __Performance note:__ make sure to specialize monomorphic type of your functions
-- that use 'inverseFunction' to avoid 'M.Map' reconstruction.
--
-- One of the common 'inverseFunction' use-case is inverting the 'show' or a 'show'-like
-- function.
--
-- >>> data Color = Red | Green | Blue deriving (Show, Enum, Bounded)
-- >>> parse = inverseFunction show :: String -> Maybe Color
-- >>> parse "Red"
-- Just Red
-- >>> parse "Black"
-- Nothing
--
-- __Correctness note:__ 'inverseFunction' expects /injective function/ as its argument,
-- i.e. the function must map distinct arguments to distinct values.
--
-- Typical usage of this function looks like this:
--
-- @
-- __data__ GhcVer
--    = Ghc802
--    | Ghc822
--    | Ghc844
--    | Ghc865
--    | Ghc881
--    __deriving__ ('Eq', 'Ord', 'Show', 'Enum', 'Bounded')
--
-- showGhcVer :: GhcVer -> 'Text'
-- showGhcVer = \\__case__
--    Ghc802 -> "8.0.2"
--    Ghc822 -> "8.2.2"
--    Ghc844 -> "8.4.4"
--    Ghc865 -> "8.6.5"
--    Ghc881 -> "8.8.1"
--
-- parseGhcVer :: 'Text' -> 'Maybe' GhcVer
-- parseGhcVer = 'inverseFunction' showGhcVer
--
-- Taken from relude’s @Relude.Extra.Enum@.
inverseFunction ::
  forall a k.
  (Bounded a, Enum a, Ord k) =>
  (a -> k) ->
  (k -> Maybe a)
inverseFunction f k = Map.lookup k $ inverseMap f

-- | Like `inverseFunction`, but instead of returning the function
-- it returns a mapping from all possible outputs to their possible inputs.
--
-- This has the same restrictions of 'inverseFunction'.
inverseMap :: forall a k. (Bounded a, Enum a, Ord k) => (a -> k) -> Map k a
inverseMap f = enumerateAll <&> (\a -> (f a, a)) & Map.fromList

-- | All possible values in this enum.
enumerateAll :: (Enum a, Bounded a) => [a]
enumerateAll = [minBound .. maxBound]

-- | Create a 'Map' from a list of values, extracting the map key from each value. Like 'Map.fromList'.
--
-- Attention: if the key is not unique, the earliest value with the key will be in the map.
mapFromListOn :: (Ord key) => (a -> key) -> [a] -> Map key a
mapFromListOn f xs = xs <&> (\x -> (f x, x)) & Map.fromList

-- | Create a 'Map' from a list of values, merging multiple values at the same key with '<>' (left-to-right)
--
-- `f` has to extract the key and value. Value must be mergable.
--
-- Attention: if the key is not unique, the earliest value with the key will be in the map.
mapFromListOnMerge :: (Ord key, Semigroup s) => (a -> (key, s)) -> [a] -> Map key s
mapFromListOnMerge f xs =
  xs
    <&> (\x -> f x)
    & Map.fromListWith
      -- we have to flip (`<>`) because `Map.fromListWith` merges its values “the other way around”
      (flip (<>))

-- | If the predicate is true, return the @m@, else 'mempty'.
--
-- This can be used (together with `ifExists`) to e.g. create lists with optional elements:
--
-- >>> import Data.Monoid (Sum(..))
--
-- >>> :{ mconcat [
--   ifTrue (1 == 1) [1],
--   [2, 3, 4],
--   ifTrue False [5],
-- ]
-- :}
-- [1,2,3,4]
--
-- Or any other Monoid:
--
-- >>> mconcat [ Sum 1, ifTrue (1 == 1) (Sum 2), Sum 3 ]

-- Sum {getSum = 6}
ifTrue :: (Monoid m) => Bool -> m -> m
ifTrue pred' m = if pred' then m else mempty

-- | If the given @Maybe@ is @Just@, return the result of `f` wrapped in `pure`, else return `mempty`.

-- This can be used (together with `ifTrue`) to e.g. create lists with optional elements:
--
-- >>> import Data.Monoid (Sum(..))
--
-- >>> :{ mconcat [
-- unknown command '{'
--
-- Or any other Monoid:
--
-- >>> mconcat [ Sum 1, ifExists id (Just 2), Sum 3 ]
-- Sum {getSum = 6}
ifExists :: (Monoid (f b), Applicative f) => (a -> b) -> Maybe a -> f b
ifExists f m = m & foldMap @Maybe (pure . f)

-- | Intersperse a monoidal value between each element of a list.
--
-- Generalization of 'Data.List.intersperse' to any 'Foldable' and 'Semigroup'.
sintersperse :: (Foldable1 t, Semigroup m) => m -> t m -> m
sintersperse sep xs = xs & toNonEmpty & NonEmpty.intersperse sep & sconcat

-- | Intersperse a monoidal value between each element of a list. If the list is empty, return 'mempty'.
--
-- Generalization of 'Data.List.intersperse' to any 'Foldable' and 'Monoid'.
mintersperse :: (Foldable t, Monoid m) => m -> t m -> m
mintersperse sep xs = xs & toList & List.intersperse sep & mconcat

-- | Get the text of a symbol via TypeApplications
symbolText :: forall sym. (KnownSymbol sym) => Text
symbolText = do
  symbolVal (Proxy :: Proxy sym)
    & stringToText
