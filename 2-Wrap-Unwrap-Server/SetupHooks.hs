{-# LANGUAGE StaticPointers, GADTs, DuplicateRecordFields, OverloadedStrings #-}
-- Cabal tracks SDK inputs and builds it once, before compiling the main library.
module SetupHooks (setupHooks) where

import Control.Monad (when)
import Distribution.Simple.SetupHooks
import Distribution.Simple.LocalBuildInfo (withOptimization)
import Distribution.Simple.Compiler (OptimisationLevel(..))
import Distribution.Utils.Path (getSymbolicPath, makeSymbolicPath, makeRelativePathEx)
import Data.List.NonEmpty (NonEmpty((:|)))
import System.Directory (copyFile, createDirectoryIfMissing, makeAbsolute)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.Info (os)
import System.Process (callProcess)

setupHooks :: SetupHooks
setupHooks = noSetupHooks
  { buildHooks = noBuildHooks { preBuildComponentRules = Just sdkRules } }

sdkRules :: PreBuildComponentRules
sdkRules = rules (static ()) $ \PreBuildComponentInputs{targetInfo=target,localBuildInfo=local} -> do
  when (componentName (targetComponent target) == CLibName LMainLibName) $ do
    let directory = autogenComponentModulesDir local (targetCLBI target)
        output name = Location directory (makeRelativePathEx name)
        dependency name = FileDependency (Location (makeSymbolicPath ".") (makeRelativePathEx name))
    registerRule_ "solana-sdk" $ staticRule
      (mkCommand (static Dict) (static buildSdk) (getSymbolicPath directory, withOptimization local == MaximumOptimisation))
      (map dependency ["solana-helper/Cargo.toml", "solana-helper/Cargo.lock",
                       "solana-helper/src/lib.rs", "rust-toolchain.toml"])
      (output "Bridge/SDKBuild.hs" :| [output sdkName])

sdkName :: FilePath
sdkName = "libecx_solana_sdk." <> if os == "darwin" then "dylib" else "so"

buildSdk :: (FilePath, Bool) -> IO ()
buildSdk (directory, release) = do
  destination <- makeAbsolute directory
  source <- makeAbsolute "solana-helper"
  target <- lookupEnv "CARGO_TARGET_DIR" >>= maybe
    (pure $ destination </> "cargo") makeAbsolute
  callProcess "cargo" $ ["build", "--locked", "--manifest-path", source </> "Cargo.toml",
                      "--target-dir", target, "--lib", "-j1"] <> ["--release" | release]
  createDirectoryIfMissing True (destination </> "Bridge")
  copyFile (target </> (if release then "release" else "debug") </> sdkName) (destination </> sdkName)
  -- Development/test paths only. Deployed custody still requires explicit config.
  writeFile (destination </> "Bridge/SDKBuild.hs") $ unlines
    [ "module Bridge.SDKBuild (sdkLibraryPath, sdkSourceDirectory, sdkTargetDirectory) where"
    , "sdkLibraryPath, sdkSourceDirectory, sdkTargetDirectory :: FilePath"
    , "sdkLibraryPath = " <> show (destination </> sdkName)
    , "sdkSourceDirectory = " <> show source
    , "sdkTargetDirectory = " <> show target ]
