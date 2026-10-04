{-# LANGUAGE StaticPointers, GADTs, DuplicateRecordFields, OverloadedStrings #-}
-- Cabal tracks SDK inputs and builds it once, for the runtime through this build-support package.
module SetupHooks (setupHooks) where

import Control.Monad (forM, forM_, unless, when)
import Distribution.Simple.SetupHooks
import Distribution.Simple.LocalBuildInfo (withOptimization)
import Distribution.Simple.Compiler (OptimisationLevel(..))
import Distribution.Utils.Path (getSymbolicPath, makeSymbolicPath, makeRelativePathEx)
import Data.List.NonEmpty (NonEmpty((:|)))
import System.Directory (copyFile, createDirectoryIfMissing, makeAbsolute, doesFileExist, findExecutable, getHomeDirectory)
import System.Environment (lookupEnv, getEnvironment)
import System.FilePath ((</>), takeDirectory, isAbsolute)
import System.Info (os)
import System.IO (readFile')
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
    registerRule_ "browser" $ dynamicRule (static Dict)
      (mkCommand (static Dict) (static browserDependencies) ())
      (mkCommand (static Dict) (static buildBrowser) (getSymbolicPath directory))
      (map dependency browserSources)
      (output "Bridge/BrowserBuild.hs" :| map (output . ("web" </>)) (browserManifest : browserArtifacts))

browserSources, browserArtifacts :: [FilePath]
browserSources = ["web/Main.hs", "web/Browser.hs", "src/Bridge/Domain.hs", "src/Bridge/Wire.hs",
  "web/ecx-browser.cabal", "web/cabal.project", "web/cabal.project.freeze", "web/index.html", "web/style.css"]
browserArtifacts = ["index.html", "style.css", "dist/wallet.js"]
browserManifest :: FilePath
browserManifest = "manifest.sha256"

browserDependencies :: () -> IO ([Dependency], Maybe FilePath)
browserDependencies () = do
  bundle <- lookupEnv "ECX_BROWSER_PREBUILT"
  forM_ bundle $ \path -> unless (isAbsolute path) $
    ioError $ userError "ECX_BROWSER_PREBUILT must be an absolute bundle directory."
  pure ([FileDependency (Location (makeSymbolicPath path) (makeRelativePathEx name))
        | path <- maybe [] pure bundle, name <- browserManifest : browserArtifacts], bundle)

-- Fixed names are data, never commands or paths read from a supplied manifest.
browserDigests :: FilePath -> [FilePath] -> IO [String]
browserDigests root names = forM names $ \name -> do
  output <- readCreateProcess (proc "openssl" ["dgst", "-sha256", "-r", root </> name]) ""
  case words output of
    hash:_ | length hash==64 && all (`elem` ("0123456789abcdef" :: String)) hash -> pure (hash <> "  " <> name)
    _ -> ioError $ userError ("Invalid SHA-256 result for browser input: " <> name)

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
buildBrowser :: FilePath -> Maybe FilePath -> IO ()
buildBrowser directory bundle = do
  selected <- lookupEnv "ECX_BROWSER_PREBUILT"
  unless (selected==bundle) $ ioError $ userError "Browser bundle selection changed; use a separate Cabal build directory."
  destination <- makeAbsolute directory
  root <- makeAbsolute ".."
  let assets = destination </> "web"
  inputs <- browserDigests root browserSources
  let manifest path = do
        outputs <- browserDigests path browserArtifacts
        pure $ unlines $ "ecx-browser-sha256-v1" : map ("source " <>) inputs <> map ("artifact " <>) outputs
  expected <- case bundle of
    Nothing -> compileBrowser destination >> pure Nothing
    Just path -> do
      saved <- readFile' (path </> browserManifest)
      actual <- manifest path
      unless (saved==actual) $ ioError $ userError "Prebuilt browser source/artifact manifest mismatch."
      createDirectoryIfMissing True (assets </> "dist")
      mapM_ (\name -> copyFile (path </> name) (assets </> name)) browserArtifacts
      pure (Just saved)
  after <- browserDigests root browserSources
  unless (inputs==after) $ ioError $ userError "Browser sources changed during the build."
  actual <- manifest assets
  unless (maybe True (==actual) expected) $ ioError $ userError "Prebuilt browser changed while copying."
  writeFile (assets </> browserManifest) actual
  createDirectoryIfMissing True (destination </> "Bridge")
  writeFile (destination </> "Bridge/BrowserBuild.hs") $ unlines
    [ "module Bridge.BrowserBuild (browserAssetsDirectory) where"
    , "browserAssetsDirectory :: FilePath"
    , "browserAssetsDirectory = " <> show assets ]

compileBrowser :: FilePath -> IO ()
compileBrowser destination = do
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
  copyFile artifact (assets </> "dist/wallet.js")
  mapM_ (\name -> copyFile (source </> name) (assets </> name)) ["index.html", "style.css"]
