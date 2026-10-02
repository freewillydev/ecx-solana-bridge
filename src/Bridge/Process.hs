{-# LANGUAGE ScopedTypeVariables #-}
module Bridge.Process (runBounded,runBoundedWithEnvironment) where

import Bridge.Types
import Control.Concurrent.Async (concurrently)
import Control.Exception (bracket, try, IOException)
import Control.Monad (unless)
import qualified Data.ByteString as BS
import System.Exit (ExitCode(..))
import System.IO (Handle,hClose)
import System.Process
import System.Timeout (timeout)
import System.Posix.Signals (signalProcessGroup,sigKILL)

-- Fixed program paths and argument vectors only. Never invoke a shell.
runBounded :: Int -> Int -> FilePath -> [String] -> BS.ByteString -> IO BS.ByteString
runBounded = runProcessBounded Nothing

-- Explicit child environment for database tools: no global environment
-- mutation or shell, and credentials are never included in argument vectors.
runBoundedWithEnvironment :: [(String,String)] -> Int -> Int -> FilePath -> [String] -> BS.ByteString -> IO BS.ByteString
runBoundedWithEnvironment environment = runProcessBounded (Just environment)

runProcessBounded :: Maybe [(String,String)] -> Int -> Int -> FilePath -> [String] -> BS.ByteString -> IO BS.ByteString
runProcessBounded environment seconds limit program args input = do
  result <- timeout (seconds*1000000) $ bracket acquire cleanup $ \(hin,hout,herr,ph) ->
    case (hin,hout,herr) of
      (Just i,Just o,Just e) -> do
        ((stdout,_),code) <- concurrently
          (concurrently (readLimit o) (readLimit e))
          (BS.hPut i input >> hClose i >> waitForProcess ph)
        unless (code==ExitSuccess) (reject "subprocess_failed")
        pure stdout
      _ -> reject "subprocess_pipes_unavailable"
  maybe (reject "subprocess_timeout") pure result
 where
  acquire = createProcess (proc program args) { std_in=CreatePipe,std_out=CreatePipe,std_err=CreatePipe,close_fds=True,create_group=True,env=environment }
  cleanup (i,o,e,ph) = do
    status <- getProcessExitCode ph
    case status of
      Nothing -> do
        terminateProcess ph
        exited <- timeout 1000000 (waitForProcess ph)
        case exited of
          Just _ -> pure ()
          Nothing -> do
            pid <- getPid ph
            case pid of Just p -> signalProcessGroup sigKILL p; Nothing -> pure ()
            _ <- waitForProcess ph
            pure ()
      Just _ -> pure ()
    mapM_ (\h -> case h of Just x -> do { _ <- try (hClose x) :: IO (Either IOException ()); pure () }; Nothing -> pure ()) [i,o,e]
  readLimit :: Handle -> IO BS.ByteString
  readLimit h = go 0 []
   where
    go n chunks = do
      b <- BS.hGetSome h 4096
      let total=n+BS.length b
      require (total<=limit) "subprocess_output_too_large"
      if BS.null b then pure (BS.concat (reverse chunks)) else go total (b:chunks)
