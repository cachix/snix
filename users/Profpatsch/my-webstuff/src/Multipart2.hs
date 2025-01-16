{-# LANGUAGE QuasiQuotes #-}

module Multipart2 where

import Control.Monad.Logger (MonadLogger)
import Control.Selective (Selective)
import Data.ByteString.Lazy qualified as Lazy
import Data.DList (DList)
import Data.DList qualified as DList
import Data.Error.Tree
import Data.Functor.Compose
import Data.List qualified as List
import FieldParser
import Label
import Network.Wai qualified as Wai
import Network.Wai.Parse qualified as Wai
import PossehlAnalyticsPrelude
import ValidationParseT

data FormFields = FormFields
  { inputs :: [Wai.Param],
    files :: [MultipartFile Lazy.ByteString]
  }

-- | A parser for a HTTP multipart form (a form sent by the browser)
newtype MultipartParseT m a = MultipartParseT
  { unMultipartParseT ::
      FormFields ->
      m (Validation (NonEmpty Error) a)
  }
  deriving
    (Functor, Applicative, Selective)
    via (ValidationParseT FormFields m)

-- | After parsing a form, either we get the result or a list of form fields that failed.
--
-- Using this via Applicative you get either a valid result (@Just a@), or a list of validation errors.
newtype FormValidation a
  = FormValidation
      (DList FormValidationResult, Maybe a)
  deriving (Functor, Applicative, Selective) via (Compose ((,) (DList FormValidationResult)) Maybe)
  deriving stock (Show)

data FormValidationResult = FormValidationResult
  { hasError :: Maybe Error,
    formFieldName :: ByteString,
    originalValue :: ByteString
  }
  deriving stock (Show)

mkFormValidationResult ::
  ( HasField "formFieldName" form ByteString,
    HasField "originalValue" form ByteString
  ) =>
  form ->
  Maybe Error ->
  FormValidationResult
mkFormValidationResult form err =
  FormValidationResult
    { hasError = err,
      formFieldName = form.formFieldName,
      originalValue = form.originalValue
    }

eitherToFormValidation ::
  ( HasField "formFieldName" form ByteString,
    HasField "originalValue" form ByteString
  ) =>
  form ->
  Either Error a ->
  FormValidation a
eitherToFormValidation form = \case
  Left err ->
    FormValidation $ (DList.singleton $ mkFormValidationResult form (Just err), Nothing)
  Right a ->
    FormValidation $ ((DList.singleton $ mkFormValidationResult form Nothing), Just a)

failFormValidation ::
  ( HasField "formFieldName" form ByteString,
    HasField "originalValue" form ByteString
  ) =>
  form ->
  Error ->
  FormValidation a
failFormValidation form err =
  FormValidation (DList.singleton $ mkFormValidationResult form (Just err), Nothing)

-- | Parse the multipart form or throw a user error with a descriptive error message.
parseMultipartOrThrow ::
  (MonadLogger m, MonadIO m) =>
  (ErrorTree -> m a) ->
  MultipartParseT m a ->
  Wai.Request ->
  m a
parseMultipartOrThrow throwF parser req = do
  -- TODO: this throws all errors with `error`, so leads to 500 on bad input …
  formFields <-
    liftIO $
      Wai.parseRequestBodyEx
        Wai.defaultParseRequestBodyOptions
        Wai.lbsBackEnd
        req
  parser.unMultipartParseT
    FormFields
      { inputs = fst formFields,
        files = map fileDataToMultipartFile $ snd formFields
      }
    >>= \case
      Failure errs -> throwF (errorTree "Cannot parse the multipart form" errs)
      Success a -> pure a

-- | Parse the field out of the multipart message
field :: (Applicative m) => ByteString -> FieldParser ByteString a -> MultipartParseT m a
field fieldName fieldParser = MultipartParseT $ \mp ->
  mp.inputs
    & findMaybe (\input -> if fst input == fieldName then Just (snd input) else Nothing)
    & annotate [fmt|Field "{fieldName}" does not exist in the multipart form|]
    >>= runFieldParser fieldParser
      & eitherToListValidation
      & pure

-- | Parse the field out of the multipart message
fieldMay :: (Applicative m) => ByteString -> FieldParser ByteString a -> MultipartParseT m (Maybe a)
fieldMay fieldName fieldParser = MultipartParseT $ \mp ->
  mp.inputs
    & findMaybe (\input -> if fst input == fieldName then Just (snd input) else Nothing)
    & \case
      Nothing -> pure $ Success Nothing
      Just b ->
        b
          & runFieldParser fieldParser
          & eitherToListValidation
          <&> Just
          & pure

-- | Parse the field out of the multipart message
-- TODO: what is this for??
field' :: (Applicative m) => ByteString -> FieldParser ByteString a -> MultipartParseT m (FormValidation a)
field' fieldName fieldParser = MultipartParseT $ \mp ->
  mp.inputs
    & findMaybe (\input -> if fst input == fieldName then Just $ snd input else Nothing)
    & annotate [fmt|Field "{fieldName}" does not exist in the multipart form|]
    <&> ( \originalValue ->
            originalValue
              & runFieldParser fieldParser
              & eitherToFormValidation
                ( T2
                    (label @"formFieldName" fieldName)
                    (label @"originalValue" originalValue)
                )
        )
    & eitherToListValidation
    & pure

-- | Parse the field out of the multipart message, and into a 'Label' of the given name.
fieldLabel :: forall lbl m a. (Applicative m) => ByteString -> FieldParser ByteString a -> MultipartParseT m (Label lbl a)
fieldLabel fieldName fieldParser = label @lbl <$> field fieldName fieldParser

-- | Parse the field out of the multipart message, and into a 'Label' of the given name.
fieldLabel' :: forall lbl m a. (Applicative m) => ByteString -> FieldParser ByteString a -> MultipartParseT m (FormValidation (Label lbl a))
fieldLabel' fieldName fieldParser = fmap (label @lbl) <$> field' fieldName fieldParser

-- | parse all fields out of the multipart message, with the same parser
allFields :: (Applicative m) => FieldParser (T2 "key" ByteString "value" ByteString) b -> MultipartParseT m [b]
allFields fieldParser = MultipartParseT $ \mp ->
  mp.inputs
    <&> tupToT2 @"key" @"value"
    & traverseValidate (runFieldParser fieldParser)
    & eitherToValidation
    & pure

tupToT2 :: forall l1 l2 t1 t2. (t1, t2) -> T2 l1 t1 l2 t2
tupToT2 (a, b) = T2 (label a) (label b)

-- | Parse a file by name out of the multipart message
file ::
  (Applicative m) =>
  ByteString ->
  MultipartParseT m (MultipartFile Lazy.ByteString)
file fieldName = MultipartParseT $ \mp ->
  mp.files
    & List.find (\input -> input.multipartNameAttribute == fieldName)
    & annotate [fmt|File "{fieldName}" does not exist in the multipart form|]
    & ( \case
          Left err -> Failure (singleton err)
          Right filePath -> Success filePath
      )
    & pure

-- | Return all files from the multipart message
allFiles ::
  (Applicative m) =>
  MultipartParseT m [MultipartFile Lazy.ByteString]
allFiles = MultipartParseT $ \mp -> do
  pure $ Success $ mp.files

-- | Ensure there is exactly one file and return it (ignoring the field name)
exactlyOneFile ::
  (Applicative m) =>
  MultipartParseT m (MultipartFile Lazy.ByteString)
exactlyOneFile = MultipartParseT $ \mp ->
  mp.files
    & \case
      [] -> pure $ failParse "Expected to receive a file, but the multipart form did not contain any files"
      [file_] -> pure $ Success file_
      more -> pure $ failParse [fmt|Expected to receive exactly one file, but the multipart form contained {List.length more} files|]
  where
    -- \| Fail to parse the multipart form with the given error message.
    failParse :: Text -> Validation (NonEmpty Error) a
    failParse = Failure . singleton . newError

newtype GetFileContent backend m content = GetFileContent
  {unGetFileContent :: (Wai.Request -> m (Either Error content))}

-- | A file field in a multipart message.
data MultipartFile content = MultipartFile
  { -- | @name@ attribute of the corresponding HTML @\<input\>@
    multipartNameAttribute :: ByteString,
    -- | name of the file on the client's disk
    fileNameOnDisk :: ByteString,
    -- | MIME type for the file
    fileMimeType :: ByteString,
    -- | Content of the file
    content :: content
  }

-- | Convert the multipart library struct of a multipart file to our own.
fileDataToMultipartFile ::
  Wai.File Lazy.ByteString ->
  (MultipartFile Lazy.ByteString)
fileDataToMultipartFile (multipartNameAttribute, file_) = do
  MultipartFile
    { multipartNameAttribute,
      fileNameOnDisk = file_.fileName,
      fileMimeType = file_.fileContentType,
      content = file_.fileContent
    }
