{-# LANGUAGE StaticPointers, GADTs, DuplicateRecordFields, OverloadedStrings #-}
-- Cabal tracks SDK inputs and builds it once, for the runtime through this build-support package.
module SetupHooks (setupHooks) where

import Control.Monad (when)
import Distribution.Simple.SetupHooks
import Distribution.Simple.LocalBuildInfo (withOptimization)
import Distribution.Simple.Compiler (OptimisationLevel(..))
import Distribution.Utils.Path (getSymbolicPath, makeSymbolicPath, makeRelativePathEx)
import Data.List.NonEmpty (NonEmpty((:|)))
import System.Directory (copyFile, createDirectoryIfMissing, makeAbsolute, doesFileExist, findExecutable, getHomeDirectory)
import System.Environment (lookupEnv, getEnvironment)
import System.FilePath ((</>), takeDirectory)
import System.Info (os)
import System.Process (callProcess, createProcess, proc, waitForProcess, readCreateProcess, env)
import System.Exit (ExitCode(..))

setupHooks :: SetupHooks
setupHooks = noSetupHooks
  { buildHooks = noBuildHooks { preBuildComponentRules = Just sdkRules } }

sdkRules :: PreBuildComponentRules
sdkRules = rules (static ()) $ \PreBuildComponentInputs{targetInfo=target,localBuildInfo=local} -> do
  when (componentName (targetComponent target) == CLibName LMainLibName) $ do
    let directory = autogenComponentModulesDir local (targetCLBI target)
        output name = Location directory (makeRelativePathEx name)
        dependency name = FileDependency (Location (makeSymbolicPath "..") (makeRelativePathEx name))
    registerRule_ "solana-sdk" $ staticRule
      (mkCommand (static Dict) (static buildSdk) (getSymbolicPath directory, withOptimization local == MaximumOptimisation))
      (map dependency ["solana-helper/Cargo.toml", "solana-helper/Cargo.lock",
                       "solana-helper/src/lib.rs", "rust-toolchain.toml"])
      (output "Bridge/SDKBuild.hs" :| [output sdkName])
    registerRule_ "browser" $ staticRule
      (mkCommand (static Dict) (static buildBrowser) (getSymbolicPath directory))
      (map dependency ["web/Main.hs", "web/Browser.hs", "rebuild/src/Bridge/Domain.hs", "rebuild/src/Bridge/Wire.hs",
                       "web/ecx-browser.cabal", "web/cabal.project", "web/cabal.project.freeze",
                       "web/index.html", "web/style.css"])
      (output "Bridge/BrowserBuild.hs" :| map output ["web/index.html", "web/style.css", "web/dist/wallet.js"])

sdkName :: FilePath
sdkName = "libecx_solana_sdk." <> if os == "darwin" then "dylib" else "so"

buildSdk :: (FilePath, Bool) -> IO ()
buildSdk (directory, release) = do
  destination <- makeAbsolute directory
  source <- makeAbsolute "../solana-helper"
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

-- A separate compiler graph keeps native RPC/database libraries out of the
-- browser. Both graphs are built by this Cabal entry point, with one job each.
buildBrowser :: FilePath -> IO ()
buildBrowser directory = do
  destination <- makeAbsolute directory
  source <- makeAbsolute "../web"
  home <- getHomeDirectory
  compiler <- lookupEnv "ECX_GHC_JS" >>= maybe
    (findExecutable "javascript-unknown-ghcjs-ghc" >>= maybe
      (pure $ home </> ".local/share/ecx-ghc-js-9.12.2/bin/javascript-unknown-ghcjs-ghc") pure) pure
  exists <- doesFileExist compiler
  when (not exists) $ ioError $ userError "Install GHC JavaScript 9.12.2 or set ECX_GHC_JS to its compiler path."
  cache <- lookupEnv "ECX_BROWSER_BUILD_DIR" >>= maybe
    (pure $ destination </> "browser-build") makeAbsolute
  environment <- getEnvironment
  emcc <- findExecutable "emcc"
  emsdk <- lookupEnv "ECX_EMSDK" >>= maybe (pure $ home </> ".local/share/ecx-emsdk") pure
  let extras = case emcc of
        Just _ -> []
        Nothing -> [("EM_CONFIG", emsdk </> ".emscripten")]
      paths = takeDirectory compiler : [emsdk </> "upstream/emscripten" | emcc==Nothing]
      childEnv = ("PATH", concatMap (<> ":") paths <> maybe "" id (lookup "PATH" environment))
        : extras <> filter (\(key,_) -> key/="PATH" && key `notElem` map fst extras) environment
      args = ["exe:ecx-browser", "--project-dir=" <> source, "--builddir=" <> cache,
              "--with-compiler=" <> compiler,
              "--with-hc-pkg=" <> (takeDirectory compiler </> "javascript-unknown-ghcjs-ghc-pkg"), "-j1"]
      command action = (proc "cabal" (action:args)){env=Just childEnv}
  (_,_,_,process) <- createProcess (command "build")
  status <- waitForProcess process
  when (status/=ExitSuccess) $ ioError $ userError "GHC JavaScript browser build failed."
  binary <- readCreateProcess (command "list-bin") ""
  let executable = reverse $ dropWhile (\c -> c=='\r' || c=='\n') $ reverse binary
  direct <- doesFileExist (executable </> "all.js")
  let artifact = (if direct then executable else executable <> ".jsexe") </> "all.js"
      assets = destination </> "web"
  complete <- doesFileExist artifact
  when (not complete) $ ioError $ userError "Browser linker did not produce all.js; discard only its incomplete local executable output and rebuild."
  createDirectoryIfMissing True (assets </> "dist")
  createDirectoryIfMissing True (destination </> "Bridge")
  copyFile artifact (assets </> "dist/wallet.js")
  mapM_ (\name -> copyFile (source </> name) (assets </> name)) ["index.html", "style.css"]
  writeFile (destination </> "Bridge/BrowserBuild.hs") $ unlines
    [ "module Bridge.BrowserBuild (browserAssetsDirectory) where"
    , "browserAssetsDirectory :: FilePath"
    , "browserAssetsDirectory = " <> show assets ]
