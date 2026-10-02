{-# LANGUAGE DataKinds,GADTs,TypeOperators,ScopedTypeVariables #-}
module Bridge.Signer (runSigner) where

import Bridge.Config
import Bridge.Types
import Bridge.Operation.Internal hiding (command)
import Bridge.Ledger.Model
import Bridge.Native
import Bridge.NativePayment
import Bridge.NativeReplacement
import Bridge.Solana (solanaCall,solanaIdentity)
import Bridge.SolanaHelper
import Bridge.SolanaPayment
import Bridge.Payment (payoutReference)
import Bridge.Postgres.Schema hiding (deploymentFingerprint)
import qualified Bridge.Postgres.Schema as Schema
import Bridge.Postgres.Catalog (verifyReadRole)
import qualified Bridge.Postgres.Maintenance as Maintenance
import qualified Bridge.Postgres.Preparation as Preparation
import qualified Bridge.Postgres.Replacement as Replacement
import qualified Bridge.Postgres.Order as Order
import Bridge.Postgres.Custody (freshC)
import Bridge.RPC (newRpcManager)
import Bridge.Observer (epochSeconds)
import Bridge.Operator (runSigningServer)
import Control.Exception (bracket)
import Control.Monad (when)
import Data.Aeson
import qualified Data.ByteString as BS
import qualified Data.Text.Encoding as TE
import qualified Data.Text as T
import Data.Text (Text)
import GHC.Generics (Generic)
import System.IO (withBinaryFile,IOMode(ReadMode))
import System.FilePath (isAbsolute)
import System.Posix.Files (getFileStatus,fileMode)
import Data.Bits ((.&.))
import qualified Database.PostgreSQL.Simple as PG
import qualified Database.PostgreSQL.Simple.Transaction as Tx
import qualified Opaleye as O
import Network.HTTP.Client (Manager,closeManager)

-- Only the signer receives this private file. It holds no broadcast endpoint.
data SignerConfig = SignerConfig
  { nativeSigningCookie :: FilePath, solanaSigningKey :: FilePath }
  deriving (Generic)
instance FromJSON SignerConfig where
  parseJSON=genericParseJSON defaultOptions{rejectUnknownFields=True}

-- The socket accepts durable identifiers only, never a plan, key, raw bytes,
-- arbitrary method or executable callback. The result type stays in the DSL.
data Decision = InitialNative NativePlan NativeDraft | InitialSolana SolanaPlan HelperRequest
  | ReplacementNative [NativeSigned] NativeDraft | ReplacementDraft [NativeSigned] Amount deriving (Eq)

runSigner :: PG.ConnectInfo -> Config -> FilePath -> IO ()
runSigner settings cfg privateFile = do
  require (profile cfg `elem` [L2LSignetDevnet,ECXBetanetDevnet]) "signer_public_test_profile_required"
  mode <- fileMode <$> getFileStatus privateFile
  require (mode .&. 0o077==0) "unsafe_signer_config_permissions"
  bytes <- withBinaryFile privateFile ReadMode (\h->BS.hGet h 4097)
  require (BS.length bytes<=4096) "signer_config_too_large"
  private <- either (const $ reject "invalid_signer_config") pure (eitherDecodeStrict' bytes)
  require (all isAbsolute [nativeSigningCookie private,solanaSigningKey private]
    && nativeSigningCookie private/=nativeCookie cfg
    && signerAuthFile cfg `notElem` [nativeSigningCookie private,solanaSigningKey private,privateFile]) "separate_signer_authority_required"
  Maintenance.verifySigner cfg (solanaSigningKey private)
  bracket (PG.connect settings) PG.close $ \c->
    Tx.withTransactionMode (Tx.TransactionMode Tx.RepeatableRead Tx.ReadOnly) c (verifyReadRole c)
  bracket newRpcManager closeManager $ \manager ->
    runSigningServer cfg (evaluateSigner settings manager cfg private)

-- Each read transaction ends before RPC/FFI. Re-read the exact authorization
-- before returning any signature; an intervening cancellation withholds it.
evaluateSigner :: PG.ConnectInfo -> Manager -> Config -> SignerConfig -> SigningOperation a -> IO a
evaluateSigner settings manager cfg private command = do
  before <- readDecision settings cfg command
  result <- case before of
    InitialNative plan draft->do
      _ <- nativeIdentity manager signingCfg
      toJSON <$> signNativeDraft (nativeCall manager signingCfg) plan draft
    InitialSolana plan request->do
      _ <- solanaIdentity manager cfg
      let limits=cfg{maxSolFee=solPlanFeeLimit plan,maxSolAccountRent=solPlanRentLimit plan}
      toJSON <$> prepareSolanaSigned (solanaCall manager cfg)
        (\actual->require (actual==request) "saved_solana_request_mismatch"
          >> signSolanaSdk cfg (solanaSigningKey private) actual) limits plan
    ReplacementDraft family fee->do
      _ <- nativeIdentity manager signingCfg
      toJSON <$> draftNativeReplacementWith (nativeCall manager signingCfg) cfg family fee
    ReplacementNative family draft->do
      _ <- nativeIdentity manager signingCfg
      toJSON <$> signNativeReplacementDraftWith (nativeCall manager signingCfg) cfg family draft
  after <- readDecision settings cfg command
  require (before==after) "signing_decision_changed"
  case command of SignPrepared{}->pure result; SignReplacement{}->pure result; DraftReplacement{}->pure result
 where signingCfg=cfg{nativeCookie=nativeSigningCookie private}

-- Opaleye access implements precisely these closed signer DSL operations.
readDecision :: PG.ConnectInfo -> Config -> SigningOperation a -> IO Decision
readDecision settings cfg command = bracket (PG.connect settings) PG.close $ \c->
  Tx.withTransactionMode (Tx.TransactionMode Tx.RepeatableRead Tx.ReadOnly) c $ do
    metadata <- O.runSelect c (O.selectTable deploymentTable) :: IO [Deployment]
    row <- case metadata of
      [r] | deploymentSingleton r==1 && deploymentSchemaVersion r==18
          && Schema.deploymentFingerprint r==fingerprint cfg->pure r
      _->reject "ledger_profile_or_schema_mismatch"
    let identity=case command of SignPrepared value _ _->value; SignReplacement value _->value; DraftReplacement value _ _->value
    require (identity==fingerprint cfg) "signer_profile_mismatch"
    when (backupRequired cfg) $ require (deploymentBackupSequence row>=deploymentCriticalSequence row) "signing_backup_required"
    now <- epochSeconds
    freshC c now
    case command of
      SignPrepared _ intent generation->do
        require (generation>=0 && not(T.null intent) && T.length intent<=256) "invalid_signing_decision"
        Order.checkIntakeReadyC c now
        (prepared,policy) <- Preparation.signingDecisionC c cfg intent generation
        let ob=preparationObligation prepared
        draft <- maybe (reject "preparation_draft_required") pure (preparationDraft prepared)
        case preparationChain prepared of
          "Native"->do
            plan <- stored(preparationPolicy prepared)
            value <- stored draft
            require (planProfile plan==profile cfg && planDepth plan==nativeDepth policy
              && planRecipient plan==obligationRecipient ob && units(planAmount plan)==obligationAmount ob
              && units(planFeeLimit plan)==preparationFeeLimit prepared) "saved_native_policy_mismatch"
            pure(InitialNative plan value)
          "Solana"->do
            plan <- stored(preparationPolicy prepared)
            request <- stored draft
            limit <- either reject pure(solanaOperatingLimit plan)
            require (solPlanFingerprint plan==fingerprint cfg && solanaCommitment policy=="finalized"
              && solPlanRecipient plan==obligationRecipient ob && units(solPlanAmount plan)==obligationAmount ob
              && solPlanReference plan==payoutReference cfg ob && units limit==preparationFeeLimit prepared
              && request==solanaPayoutRequest cfg plan) "saved_solana_policy_mismatch"
            pure(InitialSolana plan request)
          _->reject "wrong_destination_chain"
      DraftReplacement _ parent fee->do
        require (units fee>0 && deploymentPaused row==1) "invalid_native_replacement_draft"
        (_,members) <- Replacement.contextC c cfg parent
        pure(ReplacementDraft members fee)
      SignReplacement _ sequenceNo->do
        require (sequenceNo>0) "invalid_signing_decision"
        (family,draft) <- Replacement.signingContextC c cfg sequenceNo
        members <- mapM (stored . attemptPolicy) family
        pure(ReplacementNative members draft)
 where stored :: FromJSON a => Text -> IO a
       stored=either (const $ reject "invalid_saved_payment") pure . eitherDecodeStrict' . TE.encodeUtf8
