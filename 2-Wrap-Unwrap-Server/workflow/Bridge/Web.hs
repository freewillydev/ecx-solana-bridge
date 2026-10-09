{-# LANGUAGE ConstraintKinds, DataKinds, RankNTypes #-}
module Bridge.Web (customerApplication,publicApplication,boundedApplication,runPublicServer,rateLimitedApplication,fundingApplication) where
import Bridge.API
import Bridge.Operation (Plan,Caller(Customer),CustomerOperations,CustomerRead(PublicConfig),safe)
import Bridge.Credentials (protectedSignerFile,readFundingConfig)
import Bridge.Error
import Control.Concurrent.STM
import Control.Exception (bracket,catch)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (encode,object,(.=),eitherDecodeStrict',withObject,(.:))
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteArray as BA
import qualified Data.ByteArray.Encoding as Hex
import Crypto.KDF.PBKDF2 (Parameters(..),fastPBKDF2_SHA256)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Bridge.Wire (PublicReport(..),PublicAssetReport(..),Availability(..))
import Bridge.Domain (Asset(Sol),parseUnits,renderCoins,units)
import qualified Data.ByteString as BS
import Data.IORef (newIORef,atomicModifyIORef')
import Data.Text (Text)
import qualified Network.HTTP.Types as HTTP
import Network.Wai
import Servant
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.Environment (lookupEnv)
import GHC.Clock (getMonotonicTimeNSec)
import Network.Wai.Handler.Warp (runSettings,setHost,setPort,setTimeout,defaultSettings)
import Network.Wai.Handler.WarpTLS (runTLS,tlsSettings)

customerApplication :: CustomerOperations => (forall a. Plan 'Customer a -> IO a) -> IO Application
customerApplication evaluate = boundedApplication 32 "server_busy" (customerRoutes evaluate)

customerRoutes :: CustomerOperations => (forall a. Plan 'Customer a -> IO a) -> Application
customerRoutes evaluate = serve customerAPI (hoistServer customerAPI interpret customerServer)
 where
  interpret :: forall a. Plan 'Customer a -> Handler a
  interpret plan = do
    result<-liftIO $ (Right <$> evaluate plan) `catch` (\(BridgeError code)->pure $ Left code)
    either (\code->throwError err409 {errBody=encode $ object ["error" .= code],errHeaders=[("Content-Type","application/json")]}) pure result

-- Exactly three static resources, built from Haskell/HTML/CSS by root Cabal.
-- A requested path is never joined to a filesystem path.
publicApplication :: CustomerOperations => FilePath -> (forall a. Plan 'Customer a -> IO a) -> IO Application
publicApplication assets evaluate = do
  let files=[([],"index.html","text/html; charset=utf-8"),(["style.css"],"style.css","text/css; charset=utf-8"),
             (["wallet.js"],"dist/wallet.js","text/javascript; charset=utf-8")]
  mapM_ (\(_,file,_)->doesFileExist (assets</>file) >>= flip require "browser_assets_missing") files
  site<-fundingApplication (evaluate $ safe PublicConfig) $ \request respond->
    case [(file,mime)|(path,file,mime)<-files,pathInfo request==path,requestMethod request=="GET"] of
      [(file,mime)]->respond $ responseFile HTTP.status200 [("Content-Type",mime)] (assets</>file) Nothing
      _ | pathInfo request==["info"] && requestMethod request=="GET"->do
            c<-evaluate (safe PublicConfig)
            respond $ responseLBS HTTP.status200 [("Content-Type","text/html; charset=utf-8"),("Cache-Control","no-store")] $
              BL.fromStrict $ TE.encodeUtf8 $ page "Info" "Bridge information" $
              "<p>"<>escapeHTML (reason $ pubAvailability c)<>"</p>"<>reportHTML (pubReport c)
        | otherwise->customerRoutes evaluate request respond
  boundedApplication 32 "server_busy" site

-- Both HTTP surfaces share the same bounded body and concurrency behavior.
-- This middleware carries no operation or evaluation authority.
boundedApplication :: Int -> Text -> Application -> IO Application
boundedApplication capacity busy app = do
  active<-newTVarIO (0::Int)
  let acquire=atomically $ do
        n<-readTVar active
        if n>=capacity then pure False else writeTVar active (n+1) >> pure True
      release admitted=when admitted $ atomically (modifyTVar' active (subtract 1))
  pure $ \request respond->bracket acquire release $ \admitted->do
    let headers=[("Cache-Control","no-store"),("Referrer-Policy","no-referrer"),("X-Content-Type-Options","nosniff"),
          ("Content-Security-Policy","default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")]
        answer=respond . mapResponseHeaders (headers<>)
        bad status code=answer $ responseLBS status [("Content-Type","application/json")] (encode $ object ["error" .= (code::Text)])
    if not admitted then bad HTTP.status503 busy
    else if lookup "Sec-Fetch-Site" (requestHeaders request)==Just "cross-site" && requestMethod request/="GET" then bad HTTP.status403 "cross_origin_request"
    else do
      result<-(Right <$> consume request 0 []) `catch` (\(BridgeError code)->pure $ Left code)
      case result of
        Left code->bad HTTP.status413 code
        Right bytes->do
          body<-newIORef bytes
          app (setRequestBodyChunks (atomicModifyIORef' body $ \b->(BS.empty,b)) request) answer
 where
  consume request total chunks = do
    bytes<-getRequestBodyChunk request
    let size=total+BS.length bytes
    require (size<=4096) "request_too_large"
    if BS.null bytes then pure (BS.concat $ reverse chunks) else consume request size (bytes:chunks)

-- TLS terminates at the existing Servant application, without a forwarding hop.
-- Absent TLS stays loopback-only; partial TLS configuration must never downgrade.
runPublicServer :: Int -> Application -> IO ()
runPublicServer port app = do
  certificate<-lookupEnv "ECX_PUBLIC_TLS_CERT"
  key<-lookupEnv "ECX_PUBLIC_TLS_KEY"
  let settings=setPort port $ setTimeout 65 defaultSettings
  case (certificate,key) of
    (Nothing,Nothing)->runSettings (setHost "127.0.0.1" settings) app
    (Just cert,Just secret)->do
      require (cert/=secret) "public_tls_files_must_differ"
      protectedSignerFile cert False False
      protectedSignerFile secret True False
      limited<-rateLimitedApplication (toInteger <$> getMonotonicTimeNSec) app
      runTLS (tlsSettings cert secret) (setHost "*4" settings) limited
    _->reject "public_tls_requires_certificate_and_key"

-- Two constant-space, atomic admission budgets; no attacker-controlled IP map.
-- These are global limits, not provider quotas or network-level DDoS protection.
rateLimitedApplication :: IO Integer -> Application -> IO Application
rateLimitedApplication clock app = do
  arrivals<-newTVarIO (0,0)
  pure $ \request respond->do
    now<-clock
    accepted<-atomically $ do
      (allAt,orderAt)<-readTVar arrivals
      let creating=requestMethod request=="POST" && filter (/="") (pathInfo request)==["api","v1","orders"]
          nextAll=max now allAt+33333334
          nextOrder=if creating then max now orderAt+2000000000 else orderAt
          allowed=nextAll<=now+60*33333334 && (not creating || nextOrder<=now+4000000000)
      if allowed then writeTVar arrivals (nextAll,nextOrder) >> pure True else pure False
    if accepted then app request respond else respond $
      responseLBS HTTP.status429 [("Content-Type","application/json"),("Cache-Control","no-store"),("Retry-After","2")]
        "{\"error\":\"request_rate_limited\"}"

-- Read-only funding view. No session, mutation, wallet RPC or signer capability.
-- PublicConfig follows the same safe DSL/Opaleye snapshot as the customer report.
fundingApplication :: IO PublicConfiguration -> Application -> IO Application
fundingApplication configuration fallback=do
  file<-lookupEnv "ECX_FUNDING_CONFIG"
  case file of
    Nothing->pure $ \request respond->if pathInfo request/=["funding"] then fallback request respond else
      respond $ responseLBS (if requestMethod request=="GET" then HTTP.status503 else HTTP.status405)
        [("Content-Type","text/html; charset=utf-8"),("Cache-Control","no-store"),("Allow","GET")]
        (BL.fromStrict $ TE.encodeUtf8 $ page "Funding" "Bridge funding"
          "<p>The operator has not configured this optional funding page. Customer wrapping and unwrapping use the Bridge tab.</p>")
    Just path->do
      value<-readFundingConfig path >>= either (const $ reject "invalid_funding_configuration") pure . eitherDecodeStrict'
      (saltText,hashText,native,owner,mint,ata)<-either (const $ reject "invalid_funding_configuration") pure $
        parseEither (withObject "funding" $ \o->(,,,,,) <$> o .: "salt" <*> o .: "hash" <*> o .: "nativeAddress" <*> o .: "owner" <*> o .: "mint" <*> o .: "ata") value
      let decode text= either (const $ reject "invalid_funding_hash") pure (Hex.convertFromBase Hex.Base16 (TE.encodeUtf8 text))
      salt<-decode saltText; expected<-decode hashText
      require (BS.length salt==32 && BS.length expected==32 && all (\v->not(T.null v) && T.length v<=128) [native,owner,mint,ata]) "invalid_funding_configuration"
      next<-newTVarIO 0
      pure $ \request respond->if pathInfo request/=["funding"] then fallback request respond else do
        let headers=[("Cache-Control","no-store"),("Content-Type","text/html; charset=utf-8"),("X-Content-Type-Options","nosniff"),("Referrer-Policy","no-referrer"),("Content-Security-Policy","default-src 'none'; style-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")]
            reply status extra body=respond $ responseLBS status (headers<>extra) body
        if requestMethod request/="GET" then reply HTTP.status405 [("Allow","GET")] "Read-only page" else do
          now<-toInteger <$> getMonotonicTimeNSec
          admitted<-atomically $ do
            at<-readTVar next
            if at>now then pure False else writeTVar next (now+2000000000) >> pure True
          if not admitted then reply HTTP.status429 [("Retry-After","2")] "Wait two seconds before trying again." else do
            let supplied=do
                  raw<-lookup "Authorization" (requestHeaders request)
                  bytes<-BS.stripPrefix "Basic " raw
                  if BS.length bytes>1024 then Nothing else either (const Nothing) Just (B64.decode bytes)
                valid=case supplied of
                  Just bytes->let (name,rest)=BS.break (==58) bytes
                                  actual=fastPBKDF2_SHA256 (Parameters 600000 32) (BS.drop 1 rest) salt::BS.ByteString
                              in name=="operator" && not(BS.null rest) && BA.constEq actual expected
                  Nothing->False
            if not valid then reply HTTP.status401 [("WWW-Authenticate","Basic realm=\"Bridge funding\", charset=\"UTF-8\"")] "Authentication required." else do
              c<-configuration
              if pubCustodyOwner c/=owner || pubMint c/=mint then reply HTTP.status503 [] "Funding configuration does not match this bridge." else
                reply HTTP.status200 [] $ BL.fromStrict $ TE.encodeUtf8 $ page "Funding" "Bridge funding" $
                  "<p>Operator deposits only. Funding does not automatically allocate treasury. Use the existing operator allocation workflow after confirmation and reconciliation.</p>"<>
                  row "ECX network" (T.pack $ show $ pubProfile c)<>row "ECX address" native<>
                  row "Solana network" (pubSolanaCluster c)<>row "SOL owner" owner<>row "Wrapped ECX mint" mint<>row "Wrapped ECX token account" ata<>
                  row "Readiness" (reason $ pubAvailability c)<>
                  reportHTML (pubReport c)
 where
  row label value="<h2>"<>label<>"</h2><p>"<>escapeHTML value<>"</p>"

-- The static bridge page uses the same three links and shared stylesheet.
page :: Text -> Text -> Text -> Text
page active title body=
  "<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content=\"width=device-width,initial-scale=1\"><title>"<>title<>
  "</title><link rel=stylesheet href=/style.css></head><body><main><nav aria-label=\"Main navigation\">"<>
  T.concat ["<a href=\""<>url<>"\""<>(if label==active then " aria-current=page" else "")<>">"<>label<>"</a>" | (label,url)<-[("Bridge","/"),("Info","/info"),("Funding","/funding")]]<>
  "</nav><h1>"<>title<>"</h1><section class=card>"<>body<>"</section></main></body></html>"

escapeHTML :: Text -> Text
escapeHTML=T.concatMap $ \c->case c of '&'->"&amp;"; '<'->"&lt;"; '>'->"&gt;"; '"'->"&quot;"; '\''->"&#39;"; _->T.singleton c


reportHTML :: Maybe PublicReport -> Text
reportHTML Nothing="<p>Reserve observations are unavailable. Do not infer readiness from this page.</p>"
reportHTML (Just report)=
  "<h2>Recorded reserves</h2><p>Custody observations are "<>(if reportCustodyFresh report then "fresh" else "stale")<>
  ". Observation time (Unix seconds): "<>maybe "unavailable" (T.pack.show) (reportCustodyAt report)<>
  ". These are recorded totals; deposits need confirmation and explicit allocation.</p>"<>
  "<div class=report-table><table><tr><th>Asset</th><th>Reserve</th><th>Available treasury</th><th>Held</th><th>Liabilities</th><th>Earned fees</th></tr>"<>
  T.concat ["<tr><td>"<>T.pack(show $ reportAsset a)<>"</td>"<>
    T.concat ["<td>"<>maybe "unknown" (coins $ reportAsset a) value<>"</td>" | value<-[reportReserve a,Just $ reportFloat a,Just $ reportHeld a,Just $ reportLiability a,Just $ reportFees a]]<>"</tr>" | a<-reportAssets report]<>
  "</table></div><p>Completed transfers (24h): "<>T.pack(show $ reportWraps24h report)<>" wraps, "<>T.pack(show $ reportUnwraps24h report)<>" unwraps.</p>"
 where
  coins asset value=escapeHTML $ either (const "unavailable") (format asset) (parseUnits value)
  format Sol amount=let raw=T.justifyRight 10 '0' (T.pack $ show $ units amount); (whole,fraction)=T.splitAt (T.length raw-9) raw in whole<>"."<>fraction
  format _ amount=renderCoins amount
