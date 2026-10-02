-- Certificate-only regression for HSEC-2026-0008; no chain or wallet client.
module Main (main) where
import qualified Data.ByteString as BS
import Data.Default (def)
import Data.PEM (pemParseBS,pemContent)
import Data.X509 (SignedCertificate,decodeSignedCertificate,CertificateChain(..))
import Data.X509.CertificateStore (makeCertificateStore)
import Data.X509.Validation (validateDefault,FailedReason(..))
import System.Environment (getArgs)
import System.FilePath ((</>))
import Control.Monad (unless)

certificate :: FilePath -> IO SignedCertificate
certificate path = do
  bytes <- BS.readFile path
  pems <- either fail pure (pemParseBS bytes)
  case pems of
    [pem]->either fail pure (decodeSignedCertificate $ pemContent pem)
    _->fail "one fixture certificate required"

main :: IO ()
main = do
  [directory] <- getArgs
  root <- certificate (directory </> "root.pem")
  issuer <- certificate (directory </> "issuer.pem")
  let check name = do
        leaf <- certificate (directory </> name<>".pem")
        validateDefault (makeCertificateStore [root]) def (name,BS.empty) (CertificateChain [leaf,issuer])
  valid <- check "good.allowed.example"
  outside <- check "evil.other.example"
  excluded <- check "blocked.allowed.example"
  let invalidName (InvalidName _) = True; invalidName _ = False
  unless (null valid && any invalidName outside && any invalidName excluded)
    (fail "X.509 permitted/excluded DNS constraints failed")
  putStrLn "Permitted DNS accepted; outside and excluded DNS rejected"
