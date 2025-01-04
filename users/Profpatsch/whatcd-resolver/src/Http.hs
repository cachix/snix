{-# LANGUAGE QuasiQuotes #-}

module Http
  ( doRequestJson,
    RequestOptions (..),
    mkRequestOptions,
    httpJson,
    Http.httpBS,
    Http.Request,
    Http.setRequestMethod,
    Http.setQueryString,
    Http.setRequestBodyLBS,
    Http.setRequestHeader,
    Http.getResponseStatus,
    Http.getResponseHeader,
    Http.getResponseHeaders,
    Http.getResponseBody,
  )
where

import AppT
import Data.Aeson qualified as Json
import Data.Aeson.BetterErrors qualified as Json
import Data.CaseInsensitive (CI (original))
import Data.Char qualified as Char
import Data.Error.Tree
import Data.List qualified as List
import Data.Text qualified as Text
import Data.Text.Punycode qualified as Punycode
import Json qualified
import Json.Enc qualified as Enc
import Label
import MyPrelude
import Network.HTTP.Client
import Network.HTTP.Client qualified as Http
import Network.HTTP.Simple qualified as Http
import Network.HTTP.Types.Status (Status (..))
import Network.Wai.Parse qualified as Wai
import Optional
import Pretty
import Prelude hiding (span)

data RequestOptions = RequestOptions
  { method :: ByteString,
    host :: Text,
    port :: Optional Int,
    path :: Optional [Text],
    headers :: Optional [Http.Header],
    usePlainHttp :: Optional Bool
  }

mkRequestOptions :: (HasField "method" r ByteString, HasField "host" r Text) => r -> RequestOptions
mkRequestOptions opts =
  RequestOptions
    { method = opts.method,
      port = defaults,
      host = opts.host,
      path = defaults,
      headers = defaults,
      usePlainHttp = defaults
    }

httpJson ::
  ( MonadThrow m,
    MonadOtel m
  ) =>
  (Optional (Label "contentType" ByteString)) ->
  Json.Parse ErrorTree b ->
  Http.Request ->
  m b
httpJson opts parser req = inSpan' "HTTP Request (JSON)" $ \span -> do
  let opts' = opts.withDefault (label @"contentType" "application/json")
  Http.httpBS req
    >>= assertM
      span
      ( \resp -> do
          let statusCode = resp & Http.responseStatus & (.statusCode)
              contentType =
                resp
                  & Http.responseHeaders
                  & List.lookup "content-type"
                  <&> Wai.parseContentType
                  <&> (\(ct, _mimeAttributes) -> ct)
          if
            | statusCode == 200,
              Just ct <- contentType,
              ct == opts'.contentType ->
                Right $ (resp & Http.responseBody)
            | statusCode == 200,
              Just otherType <- contentType ->
                Left [fmt|Server returned a non-json body, with content-type "{otherType}"|]
            | statusCode == 200,
              Nothing <- contentType ->
                Left [fmt|Server returned a body with unspecified content type|]
            | code <- statusCode -> Left $ AppExceptionPretty [[fmt|Server returned an non-200 error code, code {code}:|], pretty resp]
      )
    >>= \body -> do
      val <-
        Json.eitherDecodeStrict body
          & first (\err -> AppExceptionTree $ nestedError "HTTP response was not valid JSON" (err & stringToText & newError & singleError))
          & orAppThrow span

      let res = Json.parseValue parser val
      case res of
        Left e -> do
          let prettyErr = Json.parseErrorTreeValCtx "could not parse HTTP response" val e
          appThrow span (AppExceptionTree prettyErr)
        Right a -> pure a

doRequestJson ::
  (MonadOtel m) =>
  RequestOptions ->
  Enc.Enc ->
  m (Response ByteString)
doRequestJson opts val = inSpan' "HTTP Request (JSON)" $ \span -> do
  addAttribute span "request.xh" (requestToXhCommandLine opts val)
  resp <-
    defaultRequest {secure = not (opts & optsUsePlainHttp)}
      & Http.setRequestHost (opts & optsHost)
      & Http.setRequestPort (opts & optsPort)
      -- TODO: is this automatically escaped by the library?
      & Http.setRequestPath (opts & optsPath)
      & Http.setRequestHeaders (opts & optsHeaders)
      & Http.setRequestMethod opts.method
      & Http.setRequestBodyLBS (Enc.encToBytesUtf8Lazy val)
      & Http.httpBS
  let code = resp & Http.getResponseStatus & (.statusCode)
  let msg = resp & Http.getResponseStatus & (.statusMessage) & bytesToTextUtf8Lenient
  addAttribute
    span
    "request.response.status"
    ([fmt|{code} {msg}|] :: Text)
  pure resp

optsHost :: RequestOptions -> ByteString
optsHost opts =
  if opts.host & Text.isAscii
    then opts.host & textToBytesUtf8
    else opts.host & Punycode.encode

optsUsePlainHttp :: RequestOptions -> Bool
optsUsePlainHttp opts = opts.usePlainHttp.withDefault False

optsPort :: RequestOptions -> Int
optsPort opts = opts.port.withDefault (if opts & optsUsePlainHttp then 80 else 443)

optsPath :: RequestOptions -> ByteString
optsPath opts = opts.path.withDefault [] & Text.intercalate "/" & ("/" <>) & textToBytesUtf8

optsHeaders :: RequestOptions -> [Http.Header]
optsHeaders opts = opts.headers.withDefault []

-- | Create a string that can be pasted on the command line to invoke the same HTTP request via the `xh` tool (curl but nicer syntax)
requestToXhCommandLine :: RequestOptions -> Enc.Enc -> Text
requestToXhCommandLine opts val = do
  let protocol = if opts & optsUsePlainHttp then "http" :: Text else "https"
  let url = [fmt|{protocol}://{opts & optsHost}:{opts & optsPort}{opts & optsPath}|]
  let headers = opts & optsHeaders <&> \(hdr, v) -> hdr.original <> ":" <> v

  prettyArgsForBash $
    mconcat
      [ ["xh", url],
        headers <&> bytesToTextUtf8Lenient,
        ["--raw"],
        [val & Enc.encToBytesUtf8 & bytesToTextUtf8Lenient]
      ]

-- | Pretty print a command line in a way that can be copied to bash.
prettyArgsForBash :: [Text] -> Text
prettyArgsForBash = Text.intercalate " " . map simpleBashEscape

-- | Simple escaping for bash words. If they contain anything that’s not ascii chars
-- and a bunch of often-used special characters, put the word in single quotes.
simpleBashEscape :: Text -> Text
simpleBashEscape t = do
  case Text.find (not . isSimple) t of
    Just _ -> escapeSingleQuote t
    Nothing -> t
  where
    -- any word that is just ascii characters is simple (no spaces or control characters)
    -- or contains a few often-used characters like - or .
    isSimple c =
      Char.isAsciiLower c
        || Char.isAsciiUpper c
        || Char.isDigit c
        -- These are benign, bash will not interpret them as special characters.
        || List.elem c ['-', '.', ':', '/']
    -- Put the word in single quotes
    -- If there is a single quote in the word,
    -- close the single quoted word, add a single quote, open the word again
    escapeSingleQuote t' = "'" <> Text.replace "'" "'\\''" t' <> "'"
