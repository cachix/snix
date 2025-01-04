{-# LANGUAGE QuasiQuotes #-}

module Debug where

import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Debug.Trace as Debug
import PossehlAnalyticsPrelude
import Pretty qualified

-- | 'Debug.trace' a showable value when (and only if!) it is evaluated, and pretty print it.
traceShowPretty :: (Show a) => a -> a
traceShowPretty a = Debug.trace (textToString $ Pretty.showPretty a) a

-- | 'Debug.trace' a showable value when (and only if!) it is evaluated, and pretty print it. In addition, the given prefix is put before the value for easier recognition.
traceShowPrettyPrefix :: (Show a) => Text -> a -> a
traceShowPrettyPrefix prefix a = Debug.trace ([fmt|{prefix}: {Pretty.showPretty a}|]) a

-- | Display non-printable characters as their unicode Control Pictures
-- https://en.wikipedia.org/wiki/Unicode_control_characters#Control_pictures
--
-- Not all implemented.
putStrLnShowNPr :: Text -> IO ()
putStrLnShowNPr t =
  Text.IO.putStrLn $
    -- newlines will actually print a newline for convenience
    t
      & Text.replace "\n" "␤\n"
      & Text.replace "\r\n" "␤\n"
      & Text.replace "\t" "␉"
