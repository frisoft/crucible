{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoMonoLocalBinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# Language RankNTypes, ImplicitParams, TypeApplications, MultiWayIf #-}
{-# Language OverloadedStrings, FlexibleContexts, ScopedTypeVariables #-}

{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}

module Crux
  ( runSimulator
  , postprocessSimResult
  , loadOptions
  , mkOutputConfig
  , defaultOutputConfig
  , SimulatorCallbacks(..)
  , SimulatorHooks(..)
  , RunnableState(..)
  , pattern RunnableState
  , Explainer
  , CruxOptions(..)
  , SomeOnlineSolver(..)
  , Crux(..)
  , module Crux.Config
  , module Crux.Log
  ) where

import qualified Control.Exception as Ex
import           Control.Lens
import           Control.Monad ( unless, void, when )
import qualified Data.Aeson as JSON
import           Data.Foldable
import           Data.Functor.Contravariant ( (>$<) )
import           Data.Functor.Contravariant.Divisible ( divide )
import           Data.Generics.Product.Fields (field)
import           Data.IORef
import           Data.Maybe ( fromMaybe )
import           Data.Proxy ( Proxy(..) )
import qualified Data.Sequence as Seq
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Version (Version)
import           Data.Void (Void)
import qualified Lumberjack as LJ
import           Prettyprinter
import qualified System.Console.ANSI as AC
import           System.Console.Terminal.Size (Window(Window), size)
import           System.Directory (createDirectoryIfMissing)
import           System.Exit (exitSuccess, ExitCode(..), exitFailure, exitWith)
import           System.FilePath ((</>))
import           System.IO ( Handle, hPutStr, stdout, stderr )

import           Data.Parameterized.Classes
import           Data.Parameterized.Nonce (newIONonceGenerator, NonceGenerator)
import           Data.Parameterized.Some ( Some(..) )

import           Lang.Crucible.Backend
import           Lang.Crucible.Backend.Online
import qualified Lang.Crucible.Backend.Simple as CBS
import           Lang.Crucible.CFG.Extension
import           Lang.Crucible.Simulator
import           Lang.Crucible.Simulator.BoundedExec
import           Lang.Crucible.Simulator.BoundedRecursion
import           Lang.Crucible.Simulator.PathSatisfiability
import           Lang.Crucible.Simulator.PathSplitting
import           Lang.Crucible.Simulator.PositionTracking
import           Lang.Crucible.Simulator.Profiling
import           Lang.Crucible.Types


import           What4.Config (Opt, ConfigOption, setOpt, getOptionSetting, verbosity, extendConfig)
import qualified What4.Expr.Builder as WEB
import           What4.FunctionName (FunctionName)
import           What4.Interface (IsExprBuilder, getConfiguration)
import           What4.InterpretedFloatingPoint (IsInterpretedFloatExprBuilder)
import           What4.Protocol.Online (OnlineSolver)
import qualified What4.Solver as WS
import           What4.Solver.CVC4 (cvc4Timeout)
import           What4.Solver.Yices (yicesEnableMCSat, yicesGoalTimeout)
import           What4.Solver.Z3 (z3Timeout)

import           Crux.Config
import           Crux.Config.Common
import           Crux.Config.Doc
import qualified Crux.Config.Load as Cfg
import qualified Crux.Config.Solver as CCS
import           Crux.FormatOut ( sayWhatFailedGoals, sayWhatResultStatus )
import           Crux.Goal
import           Crux.Log -- for the export list
import           Crux.Log as Log
import           Crux.Report
import           Crux.Types

pattern RunnableState :: forall sym . () => forall ext personality . (IsSyntaxExtension ext) => ExecState (personality sym) sym ext (RegEntry sym UnitType) -> RunnableState sym
pattern RunnableState es = RunnableStateWithExtensions es []

-- | A crucible @ExecState@ that is ready to be passed into the simulator.
--   This will usually, but not necessarily, be an @InitialState@.
data RunnableState sym where
  RunnableStateWithExtensions :: (IsSyntaxExtension ext)
                              => ExecState (personality sym) sym ext (RegEntry sym UnitType)
                              -> [ExecutionFeature (personality sym) sym ext (RegEntry sym UnitType)]
                              -> RunnableState sym

-- | Individual crux tools will generally call the @runSimulator@ combinator to
--   handle the nitty-gritty of setting up and running the simulator. Tools
--   provide @SimulatorCallbacks@ to hook into the simulation process at three
--   points:
--
--   * Before simulation begins, to set up global variables, register override
--     functions, construct the initial program entry point, and generally do
--     any necessary language-specific setup (i.e., to produce a 'RunnableState')
--   * When simulation ends with an assertion failure ('Explainer')
--   * When simulation ends, regardless of the outcome, to interpret the results.
--
--   All of these callbacks have access to the symbolic backend.
newtype SimulatorCallbacks msgs r
  = SimulatorCallbacks
    { getSimulatorCallbacks ::
        forall sym t st fs.
          ( IsSymInterface sym
          , Logs msgs
          , sym ~ WEB.ExprBuilder t st fs
          ) =>
          IO (SimulatorHooks sym t r)
    }

-- | See 'SimulatorCallbacks'
data SimulatorHooks sym t r =
  SimulatorHooks
    { setupHook :: sym -> Maybe (SomeOnlineSolver sym) -> IO (RunnableState sym)
    , onErrorHook :: sym -> IO (Explainer sym t Void)
    , resultHook :: sym -> CruxSimulationResult -> IO r
    }

-- | Given the result of a simulation and proof run, report the overall
--   status, generate user-consumable reports and compute the exit code.
postprocessSimResult ::
  Logs msgs =>
  Bool -> CruxOptions -> CruxSimulationResult -> IO ExitCode
postprocessSimResult showFailedGoals opts res =
  do -- print goals that failed and overall result
     logSimResult showFailedGoals res

     -- Generate report
     generateReport opts res

     return $! computeExitCode res


-- | Load crux generic and the provided options, and provide them to
--   the given continuation.
--
--   IMPORTANT:  This processes options like @help@ and @version@, which
--   just print something and exit, so this function may never call
--   its continuation.
loadOptions ::
  SupportsCruxLogMessage msgs =>
  (Maybe OutputOptions -> OutputConfig msgs) ->
  Text {- ^ Name -} ->
  Version ->
  Config opts ->
  (Logs msgs => (CruxOptions, opts) -> IO a) ->
  IO a
loadOptions mkOutCfg nm ver config cont =
  do let optSpec = cfgJoin cruxOptions config
     (copts, opts) <- Cfg.loadConfig nm optSpec
     case opts of
       Cfg.ShowHelp ->
          do let ?outputConfig = mkOutCfg (Just (defaultOutputOptions copts))
             showHelp nm optSpec
             exitSuccess
       Cfg.ShowVersion ->
          do let ?outputConfig = mkOutCfg (Just (defaultOutputOptions copts))
             showVersion nm ver
             exitSuccess
       Cfg.Options (cruxWithoutColorOptions, os) files ->
          do let crux = set (field @"outputOptions" . field @"colorOptions") copts cruxWithoutColorOptions
             let ?outputConfig = mkOutCfg (Just (outputOptions crux))
             crux' <- postprocessOptions crux { inputFiles = files ++ inputFiles crux }
             cont (crux', os)

 `Ex.catch` \(e :: Ex.SomeException) ->
   do let ?outputConfig = mkOutCfg Nothing
      case (Ex.fromException e :: Maybe ExitCode) of
        Just exitCode -> exitWith exitCode
        Nothing -> logException e >> exitFailure


showHelp ::
  Logs msgs =>
  SupportsCruxLogMessage msgs =>
  Text -> Config opts -> IO ()
showHelp nm cfg = do
  -- Ideally, this would be done in the log handler.  We will soon try to change
  -- the logging mechanism so thaat it prefers 'Doc' over 'Text' so that layout
  -- decisions can be delayed to the log handlers.
  outWidth <- maybe 80 (\(Window _ w) -> w) <$> size
  let opts = LayoutOptions $ AvailablePerLine outWidth 0.98
  sayCrux (Log.Help (LogDoc (layoutPretty opts (configDocs nm cfg))))


showVersion ::
  Logs msgs =>
  SupportsCruxLogMessage msgs =>
  Text -> Version -> IO ()
showVersion nm ver = sayCrux (Log.Version nm ver)


-- | Create an OutputConfig for Crux, based on an indication of whether colored
-- output should be used, the normal and error output handles, and the parsed
-- CruxOptions.
--
-- If no CruxOptions are available (i.e. Nothing, as used in the preliminary
-- portions of loadOptions), then a default output stance is applied; the
-- default stance is described along with the individual option below.
--
-- The following CruxOptions affect the generated OutputConfig:
--
--  * noColorsErr    (default stance: False when the error handle supports
--    colors, as reported by System.Console.ANSI.hSupportsANSIColor)
--  * noColorsOut    (default stance: False when the output handle supports
--    colors, as reported by System.Console.ANSI.hSupportsANSIColor)
--  * printFailures  (default stance: True)
--  * quietMode      (default stance: False)
--  * simVerbose     (default stance: False)
mkOutputConfig ::
  JSON.ToJSON msgs =>
  (Handle, Bool) -> (Handle, Bool) ->
  (msgs -> SayWhat) -> Maybe OutputOptions ->
  OutputConfig msgs
mkOutputConfig (outHandle, outWantsColor) (errHandle, errWantsColor) logMessageToSayWhat opts =
  let consensusBetween wants maybeRefuses = wants && not (fromMaybe False maybeRefuses)
      copts = colorOptions <$> opts
      outSpec = (outHandle, consensusBetween outWantsColor (Cfg.noColorsOut <$> copts))
      errSpec@(_, errShouldColor) = (errHandle, consensusBetween errWantsColor (Cfg.noColorsErr <$> copts))
      lgWhat = let la = LJ.LogAction $ logToStd outSpec errSpec
                   -- TODO simVerbose may not be the best setting to use here...
                   baseline = if maybe False ((> 1) . simVerbose) opts
                              then Noisily
                              else Simply
               in if beQuiet
                  then logfltr OK >$< la
                  else logfltr baseline >$< la
      beQuiet = maybe False quietMode opts
      logfltr allowed = \case
        SayNothing -> SayNothing
        w@(SayWhat lvl _ _) -> if lvl >= allowed then w else SayNothing
        SayMore m1 m2 -> case (logfltr allowed m1, logfltr allowed m2) of
          (SayNothing, SayNothing) -> SayNothing
          (SayNothing, m) -> m
          (m, SayNothing) -> m
          (m1', m2') -> SayMore m1' m2'

      printFails = maybe True printFailures opts
      printVars = maybe False printSymbolicVars opts
      lgGoal = sayWhatFailedGoals printFails printVars >$< lgWhat
      splitResults r@(CruxSimulationResult _cmpl gls) = (snd <$> gls, r)
  in OutputConfig
     { _outputHandle = outHandle
     , _quiet = beQuiet
     , _logMsg = logMessageToSayWhat >$< lgWhat
     , _logExc = let seeRed = AC.hSetSGR errHandle
                              [ AC.SetConsoleIntensity AC.BoldIntensity
                              , AC.SetColor AC.Foreground AC.Vivid AC.Red]
                     seeCalm = AC.hSetSGR errHandle [AC.Reset]
                     dispExc = hPutStr errHandle . Ex.displayException
                 in if errShouldColor
                    then LJ.LogAction $ \e -> Ex.bracket_ seeRed seeCalm $ dispExc e
                    else LJ.LogAction $ dispExc
     , _logSimResult = \showDetails ->
                         if showDetails
                         then divide splitResults
                              lgGoal
                              (sayWhatResultStatus >$< lgWhat)
                         else sayWhatResultStatus >$< lgWhat
     , _logGoal = Seq.singleton >$< lgGoal
     }

defaultOutputConfig ::
  JSON.ToJSON msgs =>
  (msgs -> SayWhat) -> IO (Maybe OutputOptions -> OutputConfig msgs)
defaultOutputConfig logMessagesToSayWhat = do
  outWantsColor <- AC.hSupportsANSIColor stdout
  errWantsColor <- AC.hSupportsANSIColor stderr
  return $ Crux.mkOutputConfig (stdout, outWantsColor) (stderr, errWantsColor) logMessagesToSayWhat


--------------------------------------------------------------------------------

-- | For a given configuration, compute the 'FloatModeRepr'
--
-- Note that this needs to be CPS-ed because of the type parameter to the float
-- mode.  Also note that we can't use this function in
-- 'withSelectedOnlineBackend', unfortunately, because that function requires a
-- 'IsInterpretedFloatExprBuilder' constraint that we don't seem to have a way
-- to capture in this CPS-ed style.
withFloatRepr ::
  CCS.HasDefaultFloatRepr solver =>
  proxy s ->
  CruxOptions ->
  [solver] ->
  (forall fm .
    IsInterpretedFloatExprBuilder (WEB.ExprBuilder s CBS.SimpleBackendState (Flags fm)) =>
    FloatModeRepr fm ->
    IO a) ->
  IO a
withFloatRepr proxy cruxOpts selectedSolvers k =
  case floatMode cruxOpts of
    "real" -> k FloatRealRepr
    "ieee" -> k FloatIEEERepr
    "uninterpreted" -> k FloatUninterpretedRepr
    "default" -> case selectedSolvers of
                   [oneSolver] -> CCS.withDefaultFloatRepr proxy oneSolver k
                   _           -> k FloatUninterpretedRepr
    fm -> fail ("Unknown floating point mode: " ++ fm ++ "; expected one of [real|ieee|uninterpreted|default]")

floatReprString :: FloatModeRepr fm -> String
floatReprString floatRepr =
  case floatRepr of
    FloatRealRepr -> "real"
    FloatIEEERepr -> "ieee"
    FloatUninterpretedRepr -> "uninterpreted"

-- | Parse through the options structure to determine which online backend to
-- instantiate (including the chosen floating point mode).
--
-- The choice of solver is provided as a separate argument (the
-- 'CCS.SolverOnline').  This function dispatches primarily on floating point
-- mode.  An explicit floating point mode can be provided if it has to match
-- another solver that has already started.  This code is slightly complicated
-- and duplicated because it is very hard to quantify over 'FloatModeRepr's in
-- such a way that captures the necessary 'IsInterpretedFloatExprBuilder'
-- constraints.
withSelectedOnlineBackend ::
  Logs msgs =>
  SupportsCruxLogMessage msgs =>
  CruxOptions ->
  NonceGenerator IO scope ->
  CCS.SolverOnline ->
  Maybe String ->
  -- The string is an optional explicitly-requested float mode that supersedes the choice in
  -- the configuration (probably due to using two different online connections)
  (forall solver fm .
    ( OnlineSolver solver
    , IsInterpretedFloatExprBuilder (OnlineBackend scope solver (Flags fm))
    ) =>
    FloatModeRepr fm -> OnlineBackend scope solver (Flags fm) -> IO a) -> IO a
withSelectedOnlineBackend cruxOpts nonceGen selectedSolver maybeExplicitFloatMode k =
  case fromMaybe (floatMode cruxOpts) maybeExplicitFloatMode of
    "real" -> withOnlineBackendFM FloatRealRepr
    "ieee" -> withOnlineBackendFM FloatIEEERepr
    "uninterpreted" -> withOnlineBackendFM FloatUninterpretedRepr
    "default" ->
      case selectedSolver of
        CCS.Yices -> withOnlineBackendFM FloatRealRepr
        CCS.CVC4 -> withOnlineBackendFM FloatRealRepr
        CCS.STP -> withOnlineBackendFM FloatRealRepr
        CCS.Z3 -> withOnlineBackendFM FloatIEEERepr
    fm -> fail ("Unknown floating point mode: " ++ fm ++ "; expected one of [real|ieee|uninterpreted|default]")
  where
    unsatCoreFeat | unsatCores cruxOpts
                  , not (yicesMCSat cruxOpts) = ProduceUnsatCores
                  | otherwise                 = NoUnsatFeatures

    extraFeatures = onlineProblemFeatures cruxOpts

    withOnlineBackendFM floatRepr =
      case selectedSolver of
        CCS.Yices -> withYicesOnlineBackend floatRepr nonceGen unsatCoreFeat extraFeatures $ \sym -> do
          symCfg sym yicesEnableMCSat (yicesMCSat cruxOpts)
          case goalTimeout cruxOpts of
            Just s -> symCfg sym yicesGoalTimeout (floor s)
            Nothing -> return ()
          k floatRepr sym
        CCS.CVC4 -> withCVC4OnlineBackend floatRepr nonceGen unsatCoreFeat extraFeatures $ \sym -> do
          case goalTimeout cruxOpts of
            Just s -> symCfg sym cvc4Timeout (floor (s * 1000))
            Nothing -> return ()
          k floatRepr sym
        CCS.Z3 -> withZ3OnlineBackend floatRepr nonceGen unsatCoreFeat extraFeatures $ \sym -> do
          case goalTimeout cruxOpts of
            Just s -> symCfg sym z3Timeout (floor (s * 1000))
            Nothing -> return ()
          k floatRepr sym
        CCS.STP -> do
          -- We don't have a timeout option for STP
          case goalTimeout cruxOpts of
            Just _ -> sayCrux (Log.UnsupportedTimeoutFor "STP")
            Nothing -> return ()
          withSTPOnlineBackend floatRepr nonceGen (k floatRepr)

symCfg :: (IsExprBuilder sym, Opt t a) => sym -> ConfigOption t -> a -> IO ()
symCfg sym x y =
  do opt <- getOptionSetting x (getConfiguration sym)
     _   <- setOpt opt y
     pure ()


data ProfData sym = ProfData
  { inFrame          :: forall a. FunctionName -> IO a -> IO a
  , profExecFeatures :: [GenericExecutionFeature sym]
  , writeProf        :: IO ()
  }

noProfiling :: ProfData sym
noProfiling = ProfData
  { inFrame           = \_ x -> x
  , profExecFeatures  = []
  , writeProf         = pure ()
  }

setupProfiling :: IsSymInterface sym => sym -> CruxOptions -> IO (ProfData sym)
setupProfiling sym cruxOpts =
  do tbl <- newProfilingTable

     when (profileSolver cruxOpts) $
       startRecordingSolverEvents sym tbl

     let profSource = case inputFiles cruxOpts of
                        [f] -> f
                        _ -> "multiple files"

         profOutFile = outDir cruxOpts </> "report_data.js"
         saveProf = writeProfileReport profOutFile "crux profile" profSource
         profOpts = ProfilingOptions
                      { periodicProfileInterval = profileOutputInterval cruxOpts
                      , periodicProfileAction = saveProf
                      }

         profFilt = EventFilter
                      { recordProfiling = profileCrucibleFunctions cruxOpts
                      , recordCoverage = branchCoverage cruxOpts
                      }

     pfs <- execFeatureIf (profileCrucibleFunctions cruxOpts || branchCoverage cruxOpts)
                          (profilingFeature tbl profFilt (Just profOpts))

     pure ProfData
       { inFrame = \str -> inProfilingFrame tbl str Nothing
       , profExecFeatures = pfs
       , writeProf = saveProf tbl
       }

execFeatureIf ::
  Bool ->
  IO (GenericExecutionFeature sym) ->
  IO [GenericExecutionFeature sym]
execFeatureIf b m = if b then (:[]) <$> m else pure []

execFeatureMaybe ::
  Maybe a ->
  (a -> IO (GenericExecutionFeature sym)) ->
  IO [GenericExecutionFeature sym]
execFeatureMaybe mb m =
  case mb of
    Nothing -> pure []
    Just a  -> (:[]) <$> m a


-- | Common setup for all solver connections
setupSolver :: (IsExprBuilder sym, sym ~ WEB.ExprBuilder t st fs) => CruxOptions -> Maybe FilePath -> sym -> IO ()
setupSolver cruxOpts mInteractionFile sym = do
  mapM_ (symCfg sym solverInteractionFile) (fmap T.pack mInteractionFile)

  -- Turn on hash-consing, if enabled
  when (hashConsing cruxOpts) (WEB.startCaching sym)

  let outOpts = outputOptions cruxOpts
  -- The simulator verbosity is one less than our verbosity.
  -- In this way, we can say things, without the simulator also
  -- being verbose
  symCfg sym verbosity $ toInteger $ if simVerbose outOpts > 1
                                       then simVerbose outOpts - 1
                                       else 0

-- | A GADT to capture the online solver constraints when we need them
data SomeOnlineSolver sym where
  SomeOnlineSolver :: (sym ~ OnlineBackend scope solver fs
                      , OnlineSolver solver
                      ) => SomeOnlineSolver sym

-- | Common code for initializing all of the requested execution features
--
-- This function is a bit funny because one feature, path satisfiability
-- checking, requires on online solver while the others do not.  In order to
-- maximally reuse code, we pass in the necessary online constraints as an extra
-- argument when we have them available (i.e., when we build an online solver)
-- and elide them otherwise.
setupExecutionFeatures :: (IsSymInterface sym)
                       => CruxOptions
                       -> sym
                       -> Maybe (SomeOnlineSolver sym)
                       -> IO
                       ([GenericExecutionFeature sym], ProfData sym)
setupExecutionFeatures cruxOpts sym maybeOnline = do
  -- Setup profiling
  let profiling = isProfiling cruxOpts
  profInfo <- if profiling then setupProfiling sym cruxOpts
                           else pure noProfiling

  -- Global timeout
  tfs <- execFeatureMaybe (globalTimeout cruxOpts) timeoutFeature

  -- Loop bound
  bfs <- execFeatureMaybe (loopBound cruxOpts) $ \i ->
          boundedExecFeature (\_ -> return (Just i)) True {- side cond: yes -}

  -- Recursion bound
  rfs <- execFeatureMaybe (recursionBound cruxOpts) $ \i ->
          boundedRecursionFeature (\_ -> return (Just i)) True {- side cond: yes -}

  -- Check path satisfiability
  psat_fs <- case maybeOnline of
    Just SomeOnlineSolver ->
      do enableOpt <- getOptionSetting enableOnlineBackend (getConfiguration sym)
         _ <- setOpt enableOpt (checkPathSat cruxOpts)
         execFeatureIf (checkPathSat cruxOpts)
           $ pathSatisfiabilityFeature sym (considerSatisfiability sym)
    Nothing -> return []

  -- Position tracking
  trackfs <- positionTrackingFeature sym

  return (concat [tfs, profExecFeatures profInfo, bfs, rfs, psat_fs, [trackfs]], profInfo)

-- | Select the What4 solver adapter for the user's solver choice (used for
-- offline solvers)
withSolverAdapter :: CCS.SolverOffline -> (WS.SolverAdapter st -> a) -> a
withSolverAdapter solverOff k =
  case solverOff of
    CCS.Boolector -> k WS.boolectorAdapter
    CCS.DReal -> k WS.drealAdapter
    CCS.SolverOnline CCS.CVC4 -> k WS.cvc4Adapter
    CCS.SolverOnline CCS.STP -> k WS.stpAdapter
    CCS.SolverOnline CCS.Yices -> k WS.yicesAdapter
    CCS.SolverOnline CCS.Z3 -> k WS.z3Adapter

withSolverAdapters :: [CCS.SolverOffline] -> ([WS.SolverAdapter st] -> a) -> a
withSolverAdapters solverOffs k =
  foldr go base solverOffs $ []
  where
    base adapters = k adapters
    go nextOff withAdapters adapters = withSolverAdapter nextOff (\adapter -> withAdapters (adapter:adapters))

-- | Parse through all of the user-provided options and start up the verification process
--
-- This figures out which solvers need to be run, and in which modes.  It takes
-- as arguments some of the results of common setup code.  It also tries to
-- minimize code duplication between the different verification paths (e.g.,
-- online vs offline solving).
runSimulator ::
  Logs msgs =>
  SupportsCruxLogMessage msgs =>
  CruxOptions ->
  SimulatorCallbacks msgs r ->
  IO r
runSimulator cruxOpts simCallback = do
  sayCrux (Log.Checking (inputFiles cruxOpts))
  createDirectoryIfMissing True (outDir cruxOpts)
  Some (nonceGen :: NonceGenerator IO s) <- newIONonceGenerator
  case CCS.parseSolverConfig cruxOpts of
    Right (CCS.SingleOnlineSolver onSolver) ->
      withSelectedOnlineBackend cruxOpts nonceGen onSolver Nothing $ \_ sym -> do
        let monline = Just SomeOnlineSolver
        setupSolver cruxOpts (onlineSolverOutput cruxOpts) sym
        (execFeatures, profInfo) <- setupExecutionFeatures cruxOpts sym monline
        doSimWithResults cruxOpts simCallback sym execFeatures profInfo monline (proveGoalsOnline sym)
    Right (CCS.OnlineSolverWithOfflineGoals onSolver offSolver) ->
      withSelectedOnlineBackend cruxOpts nonceGen onSolver Nothing $ \_ sym -> do
        let monline = Just SomeOnlineSolver
        setupSolver cruxOpts (pathSatSolverOutput cruxOpts) sym
        (execFeatures, profInfo) <- setupExecutionFeatures cruxOpts sym monline
        withSolverAdapter offSolver $ \adapter -> do
          -- We have to add the configuration options from the solver adapter,
          -- since they weren't included in the symbolic backend configuration
          -- with the initial setup of the online solver (since it could have
          -- been a different solver)
          extendConfig (WS.solver_adapter_config_options adapter) (getConfiguration sym)
          doSimWithResults cruxOpts simCallback sym execFeatures profInfo monline (proveGoalsOffline [adapter])
    Right (CCS.OnlyOfflineSolvers offSolvers) -> do
      withFloatRepr (Proxy @s) cruxOpts offSolvers $ \floatRepr -> do
        withSolverAdapters offSolvers $ \adapters -> do
          sym <- CBS.newSimpleBackend floatRepr nonceGen
          setupSolver cruxOpts Nothing sym
          -- Since we have a bare SimpleBackend here, we have to initialize it
          -- with the options taken from the solver adapter (e.g., solver path)
          extendConfig (WS.solver_adapter_config_options =<< adapters) (getConfiguration sym)
          (execFeatures, profInfo) <- setupExecutionFeatures cruxOpts sym Nothing
          doSimWithResults cruxOpts simCallback sym execFeatures profInfo Nothing (proveGoalsOffline adapters)
    Right (CCS.OnlineSolverWithSeparateOnlineGoals pathSolver goalSolver) -> do
      -- This case is probably the most complicated because it needs two
      -- separate online solvers.  The two must agree on the floating point
      -- mode.
      withSelectedOnlineBackend cruxOpts nonceGen pathSolver Nothing $ \floatRepr1 pathSatSym -> do
        setupSolver cruxOpts (pathSatSolverOutput cruxOpts) pathSatSym
        (execFeatures, profInfo) <- setupExecutionFeatures cruxOpts pathSatSym (Just SomeOnlineSolver)
        withSelectedOnlineBackend cruxOpts nonceGen goalSolver (Just (floatReprString floatRepr1)) $ \floatRepr2 goalSym -> do
          setupSolver cruxOpts (onlineSolverOutput cruxOpts) goalSym
          -- NOTE: We pass in an explicit requested float mode in our second
          -- online solver connection instantiation to ensure that both solvers
          -- use the same float mode, so no mismatch here should be possible.
          case testEquality floatRepr1 floatRepr2 of
            Just Refl ->
              doSimWithResults cruxOpts simCallback pathSatSym execFeatures profInfo (Just SomeOnlineSolver) (proveGoalsOnline goalSym)
            Nothing -> fail "Impossible: the argument interpretation produced two different float modes"

    Left rsns -> fail ("Invalid solver configuration:\n" ++ unlines rsns)


-- | Core invocation of the symbolic execution engine
--
-- This is separated out so that we don't have to duplicate the code sequence in
-- 'runSimulator'.  The strategy used to ultimately discharge proof obligations
-- is a parameter to allow this code to use either an online or offline solver
-- connection.
--
-- The main work in this function is setting up appropriate solver frames and
-- traversing the goals tree, as well as handling some reporting.
doSimWithResults ::
  sym ~ WEB.ExprBuilder t st fs =>
  IsSymInterface sym =>
  Logs msgs =>
  SupportsCruxLogMessage msgs =>
  CruxOptions ->
  SimulatorCallbacks msgs r ->
  sym ->
  [GenericExecutionFeature sym] ->
  ProfData sym ->
  Maybe (SomeOnlineSolver sym) ->
  ProverCallback sym
    {- ^ The function to use to prove goals; this is intended to be
         one of 'proveGoalsOffline' or 'proveGoalsOnline' -} ->
  IO r
doSimWithResults cruxOpts simCallback sym execFeatures profInfo monline goalProver = do
  compRef <- newIORef ProgramComplete
  glsRef <- newIORef Seq.empty

  frm <- pushAssumptionFrame sym

  SimulatorHooks setup onError interpretResult <-
    getSimulatorCallbacks simCallback
  inFrame profInfo "<Crux>" $ do
    -- perform tool-specific setup
    RunnableStateWithExtensions initSt exts <- setup sym monline
    explainFailure <- onError sym

    -- execute the simulator
    case pathStrategy cruxOpts of
      AlwaysMergePaths ->
        do res <- executeCrucible (map genericToExecutionFeature execFeatures ++ exts) initSt
           void $ resultCont compRef glsRef frm explainFailure (Result res)
      SplitAndExploreDepthFirst ->
        do (i,ws) <- executeCrucibleDFSPaths
                         (map genericToExecutionFeature execFeatures ++ exts)
                         initSt
                         (resultCont compRef glsRef frm explainFailure . Result)
           sayCrux (Log.TotalPathsExplored i)
           unless (null ws) $
             sayCrux (Log.PathsUnexplored (Seq.length ws))

  sayCrux Log.SimulationComplete
  when (isProfiling cruxOpts) $ writeProf profInfo
  result <- CruxSimulationResult <$> readIORef compRef <*> readIORef glsRef
  interpretResult sym result

 where
 failfast = proofGoalsFailFast cruxOpts

 resultCont compRef glsRef frm explainFailure (Result res) =
   do timedOut <-
        case res of
          TimeoutResult {} ->
            do sayCrux Log.SimulationTimedOut
               writeIORef compRef ProgramIncomplete
               return True
          _ -> return False
      popUntilAssumptionFrame sym frm
      let ctx = execResultContext res
      inFrame profInfo "<Prove Goals>" $ do
        todo <- getProofObligations sym
        sayCrux $ Log.ProofObligations (LogProofObligation <$> maybe [] goalsToList todo)
        when (isJust todo) $ sayCrux Log.AttemptingProvingVCs
        (nms, proved) <- goalProver cruxOpts ctx explainFailure todo
        mgt <- provedGoalsTree sym proved
        case mgt of
          Nothing -> return (not timedOut)
          Just gt ->
            do modifyIORef glsRef (Seq.|> (nms,gt))
               return (not (timedOut || (failfast && disprovedGoals nms > 0)))

isProfiling :: CruxOptions -> Bool
isProfiling cruxOpts =
  profileCrucibleFunctions cruxOpts || profileSolver cruxOpts || branchCoverage cruxOpts

computeExitCode :: CruxSimulationResult -> ExitCode
computeExitCode (CruxSimulationResult cmpl gls) = maximum . (base:) . fmap f . toList $ gls
 where
 base = case cmpl of
          ProgramComplete   -> ExitSuccess
          ProgramIncomplete -> ExitFailure 1
 f (nms,_gl) =
  let tot = totalProcessedGoals nms
      proved = provedGoals nms
  in if proved == tot then
       ExitSuccess
     else
       ExitFailure 1
