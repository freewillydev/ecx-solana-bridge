module Bridge.Error (BridgeError(..),reject,require) where
import Control.Exception (Exception,throwIO)
import Control.Monad (unless)
import Data.Text (Text)

data BridgeError = BridgeError Text deriving (Eq,Show)
instance Exception BridgeError
reject :: Text -> IO a
reject = throwIO . BridgeError
require :: Bool -> Text -> IO ()
require ok problem = unless ok (reject problem)
