{-# LANGUAGE  FunctionalDependencies #-}
{-# LANGUAGE  TypeFamilyDependencies #-}
module Main (main) where

import Config (readConfig, siteDomain, serverPort)
import Data.Kind (Type)

main :: IO ()
main = do
  config <- readConfig
  putStrLn ("Configuration collected for " ++ siteDomain config
    ++ " on port " ++ show (serverPort config) ++ ".")
  -- Pass config to the server when its startup is implemented.

-- | never allow unwrapping more than 10% of the total supply, per week
-- | multi-sig server co-ordination setup
-- | mint/burns happen off server

-- | TODO: wECX <-> ECX bridge
-- | TODO: periodic revenue sweep (ie the 1% fee) to the "owner" wallet

{-
1-Make-Wrapped-ECX
2-Wrap-Unwrap-Server / "2-wrap-unwrap-bridge"
3-Create-CPMM-Poo

-}

-- The operation type and its severity determine each other.
class  DoThing (a :: Severity) (b :: Type) | b -> a, a -> b where
  type Command a b = (c :: Type) | c -> a b
  criticalUpdate :: ( Command Critical SafeOperation ~ DSL Critical
                    , Command Critical CriticalOperation ~ DSL Critical
                    )
                    => Command Critical b -> Input Critical b -> DSL Critical
  safeUpdate :: (a ~ Safe) => Input Safe b -> Command a b -> DSL Safe
  runSafe :: (a ~ Safe) => Input Safe b -> Command Safe b -> b

instance DoThing Critical CriticalOperation where
  type Command Critical CriticalOperation = DSL Critical
  criticalUpdate command (InputCritical _) = command
  safeUpdate input command = command

instance DoThing Safe SafeOperation where
  type Command Safe SafeOperation = DSL Safe
  criticalUpdate command (InputCritical _) = command
  safeUpdate input command = command

data Severity = Critical | Safe

data CriticalOperation where
  Wrap :: CriticalOperation

data SafeOperation where
  UpdateStatus :: SafeOperation

-- Pattern matching on Input brings the stored constraint into scope.
data Input (a :: Severity) (b :: Type) where
  InputCritical :: ( DoThing a b) =>
                   b -> Input Critical b
  InputSafe :: (DoThing a b) => b -> Input Safe b

data DSL a where
  RequiredOperation :: DSL a
  WrapEcx :: DSL Critical
  StatusUpdate :: DSL Safe
  SafeWrap :: DSL Safe


evalDSLCritical :: (Command Critical SafeOperation ~ DSL Critical) => Input Critical CriticalOperation -> Command Critical CriticalOperation -> DSL Critical
evalDSLCritical input command = case criticalUpdate command input of
    WrapEcx -> WrapEcx
    RequiredOperation -> RequiredOperation

evalDSLSafe :: (Command Critical SafeOperation ~ DSL Critical) => Input a SafeOperation -> Command a SafeOperation -> DSL Safe
evalDSLSafe input@(InputCritical b) a = case criticalUpdate a input of
  WrapEcx -> SafeWrap
  RequiredOperation -> RequiredOperation
evalDSLSafe input@(InputSafe b) (a :: d) = case runSafe input a of
    UpdateStatus -> StatusUpdate









{- GOAL

1. Ideally, it would reach a point where it is very easy to upgrade the server

-- just wipe it completely and re-run the install script
2. Ideally, if you used the same initial parameters,
it would just restore all of your coins (on both ECX and sol).

-}




{- EXPLORE

[9/26/2026 5:14 PM] Paul Sztorc: If you want to do the same as I did, use:
https://www.orca.so/create-pool
[9/26/2026 5:14 PM] Paul Sztorc: You could also try
https://raydium.io/clmm/create-pool/
or
https://www.meteora.ag/create/dlmm/standard

But I haven't tested either

 firewall (?)
     - Ddos protection / cloudflare (?)
     - periodic database backups

-}
