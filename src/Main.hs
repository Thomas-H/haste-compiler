module Main (main) where
import GHC
import GHC.Paths (libdir)
import HscMain
import DynFlags hiding (flags)
import TidyPgm
import CorePrep
import CoreToStg
import StgSyn (StgBinding)
import HscTypes
import GhcMonad
import Control.Applicative
import System.Environment (getArgs)
import Control.Monad (when)
import CodeGen.Javascript
import Args

argSpecs :: [ArgSpec Config]
argSpecs = [
    ArgSpec { optName = "debug",
              updateCfg = \cfg _ -> cfg {ppOpts  = pretty},
              info = "Output indented, fairly readable code, with all " ++
                     "external names included in comments."},
    ArgSpec { optName = "start=asap",
              updateCfg = \cfg _ -> cfg {appStart = startASAP},
              info = "Start program immediately instead of on document load."},
    ArgSpec { optName = "out=",
              updateCfg = \cfg outfile -> cfg {outFile = const $ head outfile},
              info = "Write the JS blob to <arg>."},
    ArgSpec { optName = "libinstall",
              updateCfg = \cfg _ -> cfg {targetLibPath = sysLibPath,
                                         performLink   = False},
              info = "Install all compiled modules into the user's jsmod "
                     ++ "library\nrather than linking them together into a JS"
                     ++ "blob."},
    ArgSpec { optName = "opt-vague-ints",
              updateCfg = \cfg _ -> cfg {wrapIntMath = id},
              info = "Int math has 53 bits of precision, but gives incorrect "
                     ++ "results rather than properly wrapping around when "
                     ++ "those 53 bits are exceeded. Bitwise operations still "
                     ++ "only work on the lowest 32 bits. This option should "
                     ++ "give a substantial performance boost for Int math "
                     ++ "heavy code."},
    ArgSpec { optName = "opt-tce",
              updateCfg = \cfg _ -> cfg {doTCE = True},
              info = "Perform tail call elimination."},
    ArgSpec { optName = "verbose",
              updateCfg = \cfg _ -> cfg {verbose = True},
              info = "Display even the most obnoxious warnings."}
  ]

main :: IO ()
main = do
  argRes <- handleArgs defConfig argSpecs <$> getArgs
  case argRes of
    Left help -> putStrLn help
    Right (cfg, ghcargs) ->
      defaultErrorHandler defaultLogAction $ runGhc (Just libdir) $ do
        let ghcargs' = if doTCE cfg
                          then "-DTCE" : ghcargs
                          else ghcargs
        dynflags <- getSessionDynFlags
        (dynflags', files, _) <- parseDynamicFlags dynflags (map noLoc ghcargs')
        _ <- setSessionDynFlags dynflags' {ghcLink = NoLink}
        let files' = map unLoc files

        ts <- mapM (flip guessTarget Nothing) files'
        setTargets ts
        _ <- load LoadAllTargets
        deps <- depanal [] False
        mapM_ (compile cfg dynflags') deps
        when (performLink cfg) $ liftIO $ do
          flip mapM_ files' $ \file -> do
            putStrLn $ "Linking " ++ outFile cfg file
            link cfg file

compile :: (GhcMonad m) => Config -> DynFlags -> ModSummary -> m ()
compile cfg dynflags modSummary = do
  case ms_hsc_src modSummary of
    HsBootFile -> liftIO $ putStrLn $ "Skipping boot " ++ myName
    _          -> do
      (pgm, name) <- prepare dynflags modSummary
      let theCode    = generate cfg name pgm
          targetpath = (targetLibPath cfg)
      liftIO $ putStrLn $ "Compiling " ++ myName ++ " into " ++ targetpath
      liftIO $ writeModule targetpath theCode
  where
    myName = moduleNameString $ moduleName $ ms_mod modSummary

prepare :: (GhcMonad m) => DynFlags -> ModSummary -> m ([StgBinding], ModuleName)
prepare dynflags theMod = do
  env <- getSession
  let name = moduleName $ ms_mod theMod
  pgm <- parseModule theMod
    >>= typecheckModule
    >>= desugarModule
    >>= liftIO . hscSimplify env . coreModule
    >>= liftIO . tidyProgram env
    >>= prepPgm . fst
    >>= liftIO . coreToStg dynflags
  return (pgm, name)
  where
    prepPgm tidy = liftIO $ do
      prepd <- corePrepPgm dynflags (cg_binds tidy) (cg_tycons tidy)
      return prepd
