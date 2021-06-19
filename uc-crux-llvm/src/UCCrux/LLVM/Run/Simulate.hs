{-
Module       : UCCrux.LLVM.Run.Simulate
Description  : Run the simulator once.
Copyright    : (c) Galois, Inc 2021
License      : BSD3
Maintainer   : Langston Barrett <langston@galois.com>
Stability    : provisional
-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module UCCrux.LLVM.Run.Simulate
  ( UCCruxSimulationResult (..),
    runSimulator,
  )
where

{- ORMOLU_DISABLE -}
import           Prelude hiding (log)

import           Control.Lens ((^.), view, to)
import           Control.Monad (void, unless)
import           Control.Monad.IO.Class (liftIO)
import           Data.IORef
import           Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import           Data.Set (Set)
import qualified Data.Text as Text

import qualified Text.LLVM.AST as L

import           Data.Parameterized.Ctx (Ctx)

import qualified What4.Interface as What4
import qualified What4.ProgramLoc as What4

-- crucible
import qualified Lang.Crucible.CFG.Core as Crucible
import qualified Lang.Crucible.FunctionHandle as Crucible
import qualified Lang.Crucible.Backend as Crucible
import qualified Lang.Crucible.Simulator as Crucible
import qualified Lang.Crucible.Types as CrucibleTypes

-- crucible-llvm
import           Lang.Crucible.LLVM (llvmGlobalsToCtx)
import qualified Lang.Crucible.LLVM.Errors as LLVMErrors
import           Lang.Crucible.LLVM.Intrinsics (register_llvm_overrides)
import           Lang.Crucible.LLVM.MemModel (LLVMAnnMap)
import           Lang.Crucible.LLVM.Translation (transContext, llvmMemVar, llvmTypeCtx)

import           Lang.Crucible.LLVM.MemModel.Partial (BoolAnn(BoolAnn))
import           Lang.Crucible.LLVM.Extension (LLVM)

-- crux
import qualified Crux
import qualified Crux.Types as Crux

import           Crux.Config.Common (CruxOptions)
import           Crux.Log (outputHandle)

 -- crux-llvm
import           Crux.LLVM.Config (LLVMOptions(..))
import           Crux.LLVM.Overrides (ArchOk)
import           Crux.LLVM.Simulate (setupSimCtxt, registerFunctions)

 -- local
import           UCCrux.LLVM.Classify (classifyAssertion, classifyBadBehavior)
import           UCCrux.LLVM.Classify.Types (Located(Located), Explanation(..), Uncertainty(..))
import           UCCrux.LLVM.Constraints (Constraints, returnConstraints, relationalConstraints)
import           UCCrux.LLVM.Context.App (AppContext, log)
import           UCCrux.LLVM.Context.Function (FunctionContext, functionName)
import           UCCrux.LLVM.Context.Module (ModuleContext, llvmModule, moduleTranslation)
import           UCCrux.LLVM.Errors.Panic (panic)
import           UCCrux.LLVM.Logging (Verbosity(Hi))
import           UCCrux.LLVM.Overrides.Skip (SkipOverrideName, unsoundSkipOverrides)
import           UCCrux.LLVM.Overrides.Unsound (UnsoundOverrideName, unsoundOverrides)
import           UCCrux.LLVM.FullType.Type (FullType, MapToCrucibleType)
import           UCCrux.LLVM.PP (ppRegMap)
import           UCCrux.LLVM.Run.Unsoundness (Unsoundness(Unsoundness))
import           UCCrux.LLVM.Setup (setupExecution, SetupResult(SetupResult))
import           UCCrux.LLVM.Setup.Assume (assume)
import           UCCrux.LLVM.Setup.Monad (ppSetupError)
{- ORMOLU_ENABLE -}

simulateLLVM ::
  ArchOk arch =>
  AppContext ->
  ModuleContext m arch ->
  FunctionContext m arch argTypes ->
  Crucible.HandleAllocator ->
  IORef [Located (Explanation m arch argTypes)] ->
  IORef (Set SkipOverrideName) ->
  IORef (Set UnsoundOverrideName) ->
  Constraints m argTypes ->
  Crucible.CFG LLVM blocks (MapToCrucibleType arch argTypes) ret ->
  LLVMOptions ->
  Crux.SimulatorCallback msgs
simulateLLVM appCtx modCtx funCtx halloc explRef skipOverrideRef unsoundOverrideRef constraints cfg llvmOpts =
  Crux.SimulatorCallback $ \sym _maybeOnline ->
    do
      let trans = modCtx ^. moduleTranslation
      let llvmCtxt = trans ^. transContext
      let memOptions = memOpts llvmOpts
      bbMapRef <- newIORef (Map.empty :: LLVMAnnMap sym)
      let ?lc = llvmCtxt ^. llvmTypeCtx
      let ?recordLLVMAnnotation = \an bb -> modifyIORef bbMapRef (Map.insert an bb)
      let ?intrinsicsOpts = intrinsicsOpts llvmOpts
      let ?memOpts = memOptions
      let simctx =
            (setupSimCtxt halloc sym memOptions (llvmMemVar llvmCtxt))
              { Crucible.printHandle = view outputHandle ?outputConfig
              }

      unless (null (constraints ^. relationalConstraints)) $
        panic "simulateLLVM" ["Unimplemented: relational constraints"]

      setupResult <-
        liftIO $ setupExecution appCtx modCtx funCtx sym constraints
      (mem, argAnnotations, assumptions, argShapes, args) <-
        case setupResult of
          Left err -> panic "setupExecution" [show (ppSetupError err)]
          Right (SetupResult mem anns assumptions, (argShapes, args)) ->
            pure (mem, anns, assumptions, argShapes, args)

      -- Assume all predicates necessary to satisfy the deduced preconditions
      assume (funCtx ^. functionName) sym assumptions

      skipReturnValueAnnotations <- newIORef Map.empty

      let globSt = llvmGlobalsToCtx llvmCtxt mem
      let initSt =
            Crucible.InitialState simctx globSt Crucible.defaultAbortHandler CrucibleTypes.UnitRepr $
              Crucible.runOverrideSim CrucibleTypes.UnitRepr $
                do
                  -- TODO(lb): This could be more lazy: We could install only
                  -- those functions that are used by the program. It's an open
                  -- question whether this would be faster: it would mean more
                  -- superfluous errors when the program inevitably calls
                  -- functions that haven't yet been installed, but would mean
                  -- faster startup time generally, especially for large
                  -- programs where the vast majority of functions wouldn't be
                  -- called from any particular function. Needs some
                  -- benchmarking.
                  registerFunctions llvmOpts (modCtx ^. llvmModule) trans Nothing
                  let uOverrides = unsoundOverrides trans unsoundOverrideRef
                  sOverrides <-
                    unsoundSkipOverrides
                      modCtx
                      sym
                      trans
                      skipOverrideRef
                      skipReturnValueAnnotations
                      (constraints ^. returnConstraints)
                      (L.modDeclares (modCtx ^. llvmModule))
                  register_llvm_overrides
                    (modCtx ^. llvmModule)
                    []
                    (uOverrides ++ sOverrides)
                    llvmCtxt
                  liftIO $ (appCtx ^. log) Hi $ "Running " <> funCtx ^. functionName <> " on arguments..."
                  printed <- ppRegMap modCtx funCtx sym mem args
                  mapM_ (liftIO . (appCtx ^. log) Hi . Text.pack . show) printed
                  void $ Crucible.callCFG cfg args

      -- Diagnose errors and write back the results so they can be read in the
      -- outer loop
      let explainFailure _ gl =
            do
              bb <- readIORef bbMapRef
              let loc = gl ^. Crucible.labeledPredMsg . to Crucible.simErrorLoc
              case flip Map.lookup bb . BoolAnn
                =<< What4.getAnnotation sym (gl ^. Crucible.labeledPred) of
                Nothing ->
                  case What4.getAnnotation sym (gl ^. Crucible.labeledPred) of
                    Just _ ->
                      panic "simulateLLVM" ["Unexplained error: no error for annotation."]
                    Nothing ->
                      modifyIORef explRef . (:) $
                        case gl ^. Crucible.labeledPredMsg . to Crucible.simErrorReason of
                          Crucible.ResourceExhausted msg ->
                            Located loc (ExExhaustedBounds msg)
                          Crucible.AssertFailureSimError msg _ ->
                            if "Call to assert" `isInfixOf` msg -- HACK
                              then
                                classifyAssertion
                                  sym
                                  (gl ^. Crucible.labeledPred)
                                  loc
                              else
                                Located
                                  loc
                                  (ExUncertain (UMissingAnnotation (gl ^. Crucible.labeledPredMsg)))
                          _ ->
                            Located
                              loc
                              (ExUncertain (UMissingAnnotation (gl ^. Crucible.labeledPredMsg)))
                Just badBehavior ->
                  do
                    -- Helpful for debugging:
                    -- putStrLn "~~~~~~~~~~~"
                    -- putStrLn (show (LLVMErrors.ppBB badBehavior))

                    liftIO $ (appCtx ^. log) Hi ("Explaining error: " <> Text.pack (show (LLVMErrors.explainBB badBehavior)))
                    skipped <- readIORef skipOverrideRef
                    retAnns <- readIORef skipReturnValueAnnotations
                    classifyBadBehavior
                      appCtx
                      modCtx
                      funCtx
                      sym
                      mem
                      skipped
                      (gl ^. Crucible.labeledPredMsg)
                      args
                      (Map.union argAnnotations retAnns)
                      argShapes
                      badBehavior
                      >>= modifyIORef explRef . (:)
              return mempty

      return (Crux.RunnableState initSt, explainFailure)

-- NOTE(lb): The explicit kind signature here is necessary for GHC 8.6
-- compatibility.
data UCCruxSimulationResult m arch (argTypes :: Ctx (FullType m)) = UCCruxSimulationResult
  { unsoundness :: Unsoundness,
    explanations :: [Located (Explanation m arch argTypes)]
  }

runSimulator ::
  ( Crux.Logs msgs,
    Crux.SupportsCruxLogMessage msgs,
    ArchOk arch
  ) =>
  AppContext ->
  ModuleContext m arch ->
  FunctionContext m arch argTypes ->
  Crucible.HandleAllocator ->
  Constraints m argTypes ->
  Crucible.CFG LLVM blocks (MapToCrucibleType arch argTypes) ret ->
  CruxOptions ->
  LLVMOptions ->
  IO (UCCruxSimulationResult m arch argTypes)
runSimulator appCtx modCtx funCtx halloc preconditions cfg cruxOpts llvmOpts =
  do
    explRef <- newIORef []
    skipOverrideRef <- newIORef Set.empty
    unsoundOverrideRef <- newIORef Set.empty
    cruxResult <-
      Crux.runSimulator
        cruxOpts
        ( simulateLLVM
            appCtx
            modCtx
            funCtx
            halloc
            explRef
            skipOverrideRef
            unsoundOverrideRef
            preconditions
            cfg
            llvmOpts
        )
    unsoundness' <-
      Unsoundness
        <$> readIORef unsoundOverrideRef
          <*> readIORef skipOverrideRef
    UCCruxSimulationResult unsoundness'
      <$> case cruxResult of
        Crux.CruxSimulationResult Crux.ProgramIncomplete _ ->
          pure
            [ Located
                What4.initializationLoc
                (ExUncertain (UTimeout (funCtx ^. functionName)))
            ]
        _ -> readIORef explRef
