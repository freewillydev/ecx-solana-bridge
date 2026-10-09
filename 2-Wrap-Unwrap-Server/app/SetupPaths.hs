-- Build-tree fallbacks support developers; installed setup uses its own bundle.
module SetupPaths (bundleRoot,sdkPath) where
import Bridge.SDKBuild (sdkLibraryPath)
import System.Environment (getExecutablePath)
import System.Directory (canonicalizePath,doesFileExist)
import System.FilePath ((</>),takeDirectory)

bundleRoot :: IO (Maybe FilePath)
bundleRoot=do
  root<-takeDirectory . takeDirectory <$> (getExecutablePath >>= canonicalizePath)
  exists<-doesFileExist(root</>"manifest.sha256")
  pure(if exists then Just root else Nothing)

sdkPath :: IO FilePath
sdkPath=maybe sdkLibraryPath (</>"lib/libecx_solana_sdk.so") <$> bundleRoot
