{-# LANGUAGE CPP,
             FlexibleInstances,
             OverlappingInstances,
             MultiParamTypeClasses,
             TypeSynonymInstances,
             UndecidableInstances #-}

-- | Measure CPU time for individual phases of the Agda pipeline.

module Agda.TypeChecking.Monad.Benchmark
  ( module Agda.Benchmarking
  , getBenchmark
  , updateBenchmarkingStatus
  -- , benchmarking
  , billTo, billPureTo
  , print
  ) where

import Prelude hiding (print)

import qualified Control.Exception as E (evaluate)
import Control.Monad.State

import Data.List

import qualified Text.PrettyPrint.Boxes as Boxes

import Agda.Benchmarking

import Agda.TypeChecking.Monad.Base
import{-# SOURCE #-} Agda.TypeChecking.Monad.Options
import qualified Agda.TypeChecking.Monad.State as TCState

import Agda.Utils.Benchmark (MonadBench(..))
import qualified Agda.Utils.Benchmark as B

import Agda.Utils.Monad
import Agda.Utils.Pretty (prettyShow)

#include "undefined.h"
import Agda.Utils.Impossible

-- | We store benchmark statistics in an IORef.
--   This enables benchmarking pure computation, see
---  ''Agda.Benchmarking''.
instance MonadTCM tcm => MonadBench Phase tcm where
  getBenchmark = liftIO $ getBenchmark
  putBenchmark = liftIO . putBenchmark

-- -- | We store benchmark statistics in the TCM.
-- instance MonadTCM tcm => MonadBench Phase tcm where
--   getBenchmark    = liftTCM $ TCState.getBenchmark
--   modifyBenchmark = liftTCM . TCState.modifyBenchmark

benchmarkKey :: String
benchmarkKey = "profile"

benchmarkLevel :: Int
benchmarkLevel = 7

-- | When verbosity is set or changes, we need to turn benchmarking on or off.
updateBenchmarkingStatus :: TCM ()
-- {-# SPECIALIZE updateBenchmarkingStatus :: TCM () #-}
-- updateBenchmarkingStatus :: (HasOptions m, MonadBench a m) => m ()
updateBenchmarkingStatus =
  B.setBenchmarking =<< hasVerbosity benchmarkKey benchmarkLevel

-- | Check whether benchmarking is activated.
{-# SPECIALIZE benchmarking :: TCM Bool #-}
benchmarking :: MonadTCM tcm => tcm Bool
benchmarking = liftTCM $ hasVerbosity benchmarkKey benchmarkLevel

-- | Prints the accumulated benchmark results. Does nothing if
-- profiling is not activated at level 7.
print :: MonadTCM tcm => tcm ()
print = liftTCM $ whenM benchmarking $ do
  b <- getBenchmark
  reportSLn benchmarkKey benchmarkLevel $ prettyShow b

-- | Bill a computation to a specific account.
billTo :: MonadTCM tcm => Account -> tcm a -> tcm a
billTo account m = B.billTo account m

-- | Bill a pure computation to a specific account.
{-# SPECIALIZE billPureTo :: Account -> a -> TCM a #-}
billPureTo :: MonadTCM tcm => Account -> a -> tcm a
billPureTo k a = billTo k $ return a
