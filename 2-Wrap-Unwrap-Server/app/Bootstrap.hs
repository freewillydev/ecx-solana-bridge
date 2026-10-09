{-# LANGUAGE GADTs #-}
-- Fresh generated custody only, before installation. No customer or runtime entry.
-- Reuse token administration's closed, saved-before-send ATA operation; never mint.
module Bootstrap (canonicalMint,interface,validateOrigin,setupConfig,bind,complete,initializeBackup,agreedOrigin) where
import qualified Bridge.Config as C
import Bridge.Domain (units)
import Bridge.File (hashHandle)
import System.IO (withBinaryFile,IOMode(ReadMode))
import qualified Data.ByteString as B
import System.Process (proc,withCreateProcess,CreateProcess(..),StdStream(..),waitForProcess,getProcessExitCode,getPid)
import System.Posix.Signals (signalProcess,sigKILL)
import System.Timeout (timeout)
import System.Environment (getEnvironment)
import System.Exit (ExitCode(..))
import System.Info (arch)
import Bridge.Wire (Profile(..),InterfaceConfig(..))
import Bridge.Error
import qualified Bridge.AdminStatus as AS
import Bridge.AdminKey (readPrivate,savePrivate,withFamily)
import Bridge.RPC
import qualified Bridge.Solana as S
import Bridge.SolanaDeposit (transactionKeys,lamportEffect,lamportBefore)
import qualified SetupPaths
import Bridge.Signer (verifySigningKey)
import qualified Token
import qualified Token.Network as TN
import qualified Token.Signing as TS
import qualified Token.Operation as TO
import Control.Exception (bracket,onException)
import Control.Monad (forM_,when)
import Data.Aeson
import qualified Data.ByteString.Lazy as L
import qualified Data.Text as T
import qualified Data.Set as Set
import Data.Word (Word64)
import Data.String (fromString)
import Data.List (isPrefixOf)
import Network.HTTP.Client (closeManager,parseRequest,secure,path,queryString,requestHeaders)
import System.Directory (doesFileExist)
import System.FilePath ((</>))

canonicalMint :: T.Text
canonicalMint="EVHqNdzjCupKi4rQkbuYw52sa1m8A7jeUAMP23S9AVVq"
interface :: Maybe T.Text -> Value
interface origin=toJSON $ (C.defaultInterface CanonicalBeta)
  {publicOrigin=origin,jupiterUrl=Just ("https://jup.ag/swap/SOL-"<>canonicalMint)}
validateOrigin :: Maybe T.Text -> IO ()
validateOrigin origin=forM_ origin $ \url->do
  require (T.length url<=2048 && T.all (\c->c>' ' && c<'\DEL') url
    && not(T.any (`elem` ("?#@"::String)) url)) "invalid_public_origin"
  endpoint<-parseRequest (T.unpack url)
  require (secure endpoint && path endpoint=="/" && queryString endpoint=="" && null(requestHeaders endpoint)) "invalid_public_origin"

readRecord :: FromJSON a => FilePath -> IO a
readRecord path=readPrivate path >>= either (const $ reject "invalid_bootstrap_record") pure . eitherDecodeStrict'
writeRecord :: ToJSON a => FilePath -> a -> IO ()
writeRecord path=savePrivate path . L.toStrict . encode

setupConfig :: FilePath -> IO C.Config
setupConfig directory=do
  pending<-doesFileExist (directory</>"bootstrap.json")
  if pending then do
    c<-readRecord (directory</>"bootstrap.json")
    C.validateSetupConfig c
    require (C.profile c==CanonicalBeta && C.mint c==canonicalMint
      && T.null(C.solanaHistoryStart c) && T.null(C.solanaOperatingHistoryStart c)) "fresh_canonical_setup_required"
    pure c
  else C.loadConfig (directory</>"signer.json")

-- Seal the full setup before node mutation, not just before Solana signing.
bind :: FilePath -> IO ()
bind directory=do
  pending<-doesFileExist (directory</>"bootstrap.json")
  when pending $ do
    records<-mapM (readRecord . (directory</>)) ["bootstrap.json","setup.json","sources.json","interface.json"] :: IO [Value]
    publish (directory</>"bootstrap-bound.json") (toJSON records)

publish :: FilePath -> Value -> IO ()
publish path value=do
  exists<-doesFileExist path
  if exists then readRecord path >>= \saved->require (saved==value) "bootstrap_saved_configuration_changed"
    else writeRecord path value

-- Holding this setup lock cannot open the runtime signer. Once services exist,
-- Configure.start never calls this operation or reuses the setup signing key.
complete :: FilePath -> IO ()
complete directory=do
  pending<-doesFileExist (directory</>"bootstrap.json")
  when pending $ withFamily (directory</>"bootstrap") $ do
    c<-setupConfig directory
    sources<-readRecord (directory</>"sources.json") :: IO Value
    key<-fieldValue "solana.keypair.json" sources
    verifySigningKey (C.custodyOwner c) key
    setupSdk<-SetupPaths.sdkPath
    expected<-TO.runSafe (TO.Request $ Token.AssociatedAddress setupSdk (C.custodyOwner c) canonicalMint)
    require (C.custodyAta c==expected) "bootstrap_ata_mismatch"
    bind directory
    let completed=directory</>"bootstrap-complete.json"
    exists<-doesFileExist completed
    ready<-if exists then readRecord completed else do
      finalized<-evalSetup (FundCustody directory c key)
      writeRecord completed finalized
      pure finalized
    C.validateConfig ready
    _<-C.loadInterface ready (Just $ directory</>"interface.json")
    require (ready {C.solanaHistoryStart="",C.solanaOperatingHistoryStart=""}==c) "bootstrap_identity_changed"
    worker<-fieldValue "native-worker.auth" sources
    signer<-fieldValue "native-signer.auth" sources
    publish (directory</>"worker.json") (toJSON $ ready {C.nativeCookie=worker,C.nativeUnlockFile=Nothing})
    publish (directory</>"signer.json") (toJSON $ ready {C.nativeCookie=signer})

data Setup a where
  FundCustody :: FilePath -> C.Config -> FilePath -> Setup C.Config

evalSetup :: Setup a -> IO a
evalSetup (FundCustody directory c key)=bracket newRpcManager closeManager $ \manager->do
  verifier<-maybe (reject "independent_rpc_required") pure (C.solanaVerifierRpc c)
  independentHttps (C.solanaRpc c) verifier
  let endpoints=[C.solanaRpc c,verifier]
      call url=rpc manager url Nothing
      options=object ["commitment" .= String "finalized","encoding" .= String "jsonParsed"]
      account url address=call url "getAccountInfo" [toJSON address,options] >>= fieldValue "value"
      owner=C.custodyOwner c
      ata=C.custodyAta c
      fee=fromIntegral(units $ C.maxSolFee c)::Word64
  forM_ endpoints $ \url->do
    genesis<-call url "getGenesisHash" [] >>= parseValue parseJSON
    require (genesis==S.solanaGenesis CanonicalBeta) "wrong_solana_genesis"
    mint<-account url canonicalMint
    _<-parseValue (S.inspectMint $ Just 8) mint
    pure ()
  putStrLn $ "Fund SOL fees at: "<>T.unpack owner
  putStrLn $ "Fund canonical wrapped ECX inventory at owner: "<>T.unpack owner<>" (ATA "<>T.unpack ata<>")"
  putStrLn "Suggested SOL funding: 0.01 SOL. Startup never buys or mints wrapped ECX."
  forM_ endpoints $ \url->do
    payer<-account url owner
    require (payer/=Null) "fund_solana_owner_then_rerun_start"
    program<-fieldValue "owner" payer :: IO T.Text
    executable<-fieldValue "executable" payer
    balance<-fieldValue "lamports" payer :: IO Integer
    require (program=="11111111111111111111111111111111" && not executable) "invalid_bootstrap_payer"
    require (balance>=toInteger(units $ C.maxSolAccountRent c)+toInteger fee) "fund_solana_owner_then_rerun_start"
  let attempt=directory</>"ata-creation.json"
  saved<-doesFileExist attempt
  accounts<-mapM (\url->account url ata) endpoints
  when (not saved && all (==Null) accounts) $ do
    rent<-call (C.solanaRpc c) "getMinimumBalanceForRentExemption" [toJSON (165::Int),object ["commitment" .= String "finalized"]] >>= parseValue parseJSON
    require (rent>0 && rent<=fromIntegral(units $ C.maxSolAccountRent c)) "bootstrap_rent_exceeds_limit"
    recent<-TO.runSafe (TO.Request $ TN.RecentBlockhash TN.Mainnet (C.solanaRpc c))
    let request=Token.Associated owner canonicalMint ata owner rent recent
    setupSdk<-SetupPaths.sdkPath
    unsigned<-TO.runSafe (TO.Request $ Token.Prepare setupSdk request)
    _<-TO.runCritical (TO.Request $ TN.Sign setupSdk TN.Mainnet (C.solanaRpc c) fee request unsigned key attempt)
    pure ()
  hasAttempt<-doesFileExist attempt
  when hasAttempt $ do
    archived<-readRecord attempt :: IO TS.Saved
    case TS.savedRequest archived of
      Token.Associated payer mint address holder rent _->require
        (payer==owner && holder==owner && mint==canonicalMint && address==ata
          && rent>0 && rent<=fromIntegral(units $ C.maxSolAccountRent c)) "bootstrap_attempt_identity_changed"
      _->reject "bootstrap_requires_ata_operation"
    -- Submit rechecks the saved signature/status and sends identical bytes only.
    result<-TO.runCritical (TO.Request $ TN.Submit TN.Mainnet (C.solanaRpc c) fee attempt)
    status<-fieldValue "status" result :: IO T.Text
    require (status/="failed") "ata_creation_failed_requires_reviewed_token_recovery"
    require (status=="finalized") "ata_creation_pending_rerun_start_no_new_transaction"
    otherStatus<-TO.runSafe (TO.Request $ TN.InspectSaved TN.Mainnet verifier attempt)
    require (otherStatus==AS.Finalized) "ata_verifier_pending_rerun_start"
  _<-S.solanaIdentity manager (C.solanaSettings c)
  forM_ endpoints $ \url->account url ata >>= either reject (const $ pure ()) . S.inspectTokenAccount canonicalMint owner
  operating<-agreedOrigin endpoints (\url->call url) owner
  token<-agreedOrigin endpoints (\url->call url) ata
  forM_ [(owner,operating),(ata,token)] $ \(address,origin)->forM_ endpoints $ \url->do
    tx<-S.finalizedTransactionWith (call url) origin
    effect<-either reject pure (lamportEffect origin address tx)
    require (units(lamportBefore effect)==0) "bootstrap_opening_balance_requires_earlier_history"
  pure c {C.solanaHistoryStart=token,C.solanaOperatingHistoryStart=operating}

-- Only for a wallet just generated by this setup, never restored custody.
-- Enumerate bounded history independently; a disagreement cannot establish origins.
agreedOrigin :: [String] -> (String -> T.Text -> [Value] -> IO Value) -> T.Text -> IO T.Text
agreedOrigin endpoints call address=do
  histories<-mapM (\url->collect (call url) Nothing Set.empty [] (0::Int)) endpoints
  case histories of
    [first,second] | not(null first) && first==second -> do
      let (origin,_,_)=last first
      forM_ endpoints $ \url->do
        transaction<-call url "getTransaction" [toJSON origin,object ["commitment" .= String "finalized","encoding" .= String "json","maxSupportedTransactionVersion" .= (0::Int)]]
        require (transaction/=Null) "bootstrap_origin_history_unavailable"
        tx<-fieldValue "transaction" transaction
        signatures<-fieldValue "signatures" tx :: IO [T.Text]
        keys<-either reject pure (transactionKeys transaction)
        require (take 1 signatures==[origin] && address `elem` keys) "bootstrap_origin_identity_mismatch"
      pure origin
    _->reject "bootstrap_history_not_yet_agreed_rerun_start"
 where
  collect request before seen accumulated pages=do
    require (pages<10) "bootstrap_history_too_large_use_reviewed_recovery"
    page<-S.solanaAddressHistoryWith request address before Nothing >>= parseValue parseJSON
    let ids=map S.historySignature page
    require (length page<=100 && Set.size(Set.fromList ids)==length ids && all (`Set.notMember` seen) ids) "bootstrap_history_repeated_page"
    let combined=accumulated<>[(S.historySignature entry,S.historySlot entry,S.historyFailed entry) | entry<-page]
        slots=[slot | (_,slot,_)<-combined]
    require (and $ zipWith (>=) slots (drop 1 slots)) "bootstrap_history_out_of_order"
    if null page then pure accumulated else
      collect request (Just $ last ids) (Set.union seen $ Set.fromList ids) combined (pages+1)

-- Only a fresh repository is initialized. An existing matching repository is
-- harmless on replay; a different password/repository never causes replacement.
initializeBackup :: FilePath -> IO ()
initializeBackup directory=do
  pending<-doesFileExist (directory</>"bootstrap.json")
  when pending $ do
    setup<-readRecord (directory</>"setup.json") :: IO Value
    sources<-readRecord (directory</>"sources.json") :: IO Value
    executable<-fieldValue "restic" setup
    root<-fieldValue "sourceRoot" setup
    method<-fieldValue "method" setup :: IO String
    let pinsPath=if method=="bundle" then root</>"share/toolchains.json" else root</>"2-Wrap-Unwrap-Server/build/toolchains.json"
    pins<-B.readFile pinsPath >>= either (const $ reject "invalid_toolchain_pins") pure . eitherDecodeStrict'
    reviewed<-fieldValue "restic-reviewed" pins :: IO Value
    expected<-fieldValue (fromString arch) reviewed :: IO T.Text
    actual<-withBinaryFile executable ReadMode hashHandle
    require (actual==expected) "unreviewed_restic_binary"
    repository<-fieldValue "backup.repository" sources
    password<-fieldValue "backup.password" sources
    environment<-getEnvironment
    let clean=filter (\(name,_)->not ("RESTIC_" `isPrefixOf` name)) environment
        run args=withCreateProcess ((proc executable ("--no-cache":args))
          {env=Just $ [("RESTIC_REPOSITORY_FILE",repository),("RESTIC_PASSWORD_FILE",password)]<>clean
          ,std_in=NoStream,std_out=NoStream,std_err=NoStream,close_fds=True}) $ \_ _ _ process->do
            let kill=do
                  running<-getProcessExitCode process
                  when (running==Nothing) $ getPid process >>= mapM_ (signalProcess sigKILL)
                expired=do
                  kill
                  putStrLn "Backup server did not respond within 30 seconds. Check its URL/access, then rerun the same start command; saved wallets and settings are preserved."
                  reject "backup_setup_timeout"
            (timeout (30*1000000) (waitForProcess process) >>= maybe expired pure) `onException` kill
    putStrLn "Checking encrypted backup access (30-second limit per request)..."
    readable<-run ["cat","config"]
    when (readable/=ExitSuccess) $ do
      putStrLn "Opening existing repository failed; initializing the requested new repository..."
      created<-run ["init"]
      require (created==ExitSuccess) "backup_initialization_failed_use_new_repository_or_advanced_setup"
    verified<-run ["cat","config"]
    require (verified==ExitSuccess) "backup_repository_not_readable"
    putStrLn "Encrypted backup repository is readable. Continuing node setup."
