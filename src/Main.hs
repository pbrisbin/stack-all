{-# LANGUAGE OverloadedStrings, CPP #-}

import Control.Monad.Extra
import Data.Either
import Data.Ini.Config
import Data.List.Extra
import Data.Maybe
import Data.Tuple (swap)
import SimpleCmd
import SimpleCmdArgs
import System.Directory
import System.Exit
import System.FilePath
import System.IO
import System.Process
import qualified Data.Text.IO as T

import MajorVer
import Paths_stack_all (version)
import Snapshots

defaultOldestLTS :: MajorVer
defaultOldestLTS = LTS 18

data VersionLimit = DefaultLimit | Oldest MajorVer | AllVersions

data CommandOpt = CreateConfig | DefaultResolver | MakeStackLTS
  deriving Eq

showOpt :: CommandOpt -> String
showOpt c =
  "--" ++
  case c of
    CreateConfig -> "create-config"
    DefaultResolver -> "default-resolver"
    MakeStackLTS -> "make-lts"

main :: IO ()
main = do
  hSetBuffering stdout NoBuffering
  simpleCmdArgs' (Just version) "Build over Stackage versions"
    "stack-all builds projects easily across different Stackage versions" $
    run <$>
    optional
    (flagWith' CreateConfig 'c' "create-config" "Create a project .stack-all file" <|>
     flagWith' DefaultResolver 'd' "default-resolver" ("Update" +-+ stackYaml +-+ "resolver") <|>
     flagWith' MakeStackLTS 's' "make-lts" "Create a stack-ltsXX.yaml file") <*>
    switchWith 'k' "keep-going" "Keep going even if an LTS fails" <*>
    switchWith 'D' "debug" "Verbose stack build output on error" <*>
    switchLongWith "refresh-cache" "Force refresh of stackage snapshots.json cache" <*>
    optional (readMajor <$> strOptionWith 'n' "newest" "MAJOR" "Newest LTS release to build from") <*>
    (Oldest . readMajor <$> strOptionWith 'o' "oldest" "MAJOR" "Oldest compatible LTS release" <|>
     flagWith DefaultLimit AllVersions 'a' "all-lts" "Try to build back to LTS 1 even") <*>
    many (strArg "MAJORVER... [COMMAND...]")

stackYaml :: FilePath
stackYaml = "stack.yaml"

run :: Maybe CommandOpt -> Bool ->Bool -> Bool -> Maybe MajorVer
    -> VersionLimit -> [String] -> IO ()
run mcommand keepgoing debug refresh mnewest verlimit verscmd = do
  whenJustM findStackProjectDir setCurrentDirectory
  (versions, cargs) <- getVersionsCmd
  case mcommand of
    Just command -> do
      unless (null cargs) $
        error' $ "cannot combine" +-+ showOpt command +-+ "with stack commands:" +-+ unwords cargs
      case command of
        CreateConfig -> do
          unless (null versions) $
            error' "cannot combine --create-config with major versions"
          case verlimit of
            Oldest oldest -> createStackAll (Just oldest) mnewest
            _ -> createStackAll Nothing mnewest
        DefaultResolver ->
          stackDefaultResolver versions
        MakeStackLTS ->
          if null versions
            then error' "--make-lts needs an LTS major version"
            else makeStackLTS refresh versions
    Nothing -> do
      configs <- readStackConfigs
      let newestFilter = maybe id (filter . (>=)) mnewest
      mapM_ (runStack configs keepgoing debug refresh $ if null cargs then ["build"] else cargs) (newestFilter versions)
  where
    findStackProjectDir :: IO (Maybe FilePath)
    findStackProjectDir = do
      haveStackYaml <- doesFileExist stackYaml
      mcwdir <- Just <$> getCurrentDirectory
      if haveStackYaml
        then return mcwdir
        else
        if mcwdir /= Just "/"
          then withCurrentDirectory ".." findStackProjectDir
          else do
          putStrLn $ stackYaml +-+ "not found"
          haveCabalFile <- doesFileExistWithExtension "." ".cabal"
          if haveCabalFile
            then do
            -- FIXME take suggested extra-deps into stack.yaml
            -- FIXME stack init content too verbose
            unlessM (cmdBool "stack" ["init"]) $ do
              snap <- latestLtsSnapshot refresh
              writeFile stackYaml $ "resolver: " ++ snap ++ "\n"
            return mcwdir
            else do
            putStrLn "no package/project found"
            return Nothing

    getVersionsCmd :: IO ([MajorVer],[String])
    getVersionsCmd = do
      let partitionMajors = swap . partitionEithers . map eitherReadMajorAlias
          (verlist,cmds) = partitionMajors verscmd
      allMajors <- getMajorVers
      versions <-
        if null verlist then
          case verlimit of
            DefaultLimit -> do
              (newestLTS, oldestLTS) <- readNewestOldestLTS
              return $ case mnewest of
                         Just newest ->
                           if newest < oldestLTS
                           then filter (inRange newest (LTS 1)) allMajors
                           else filter (inRange newest oldestLTS) allMajors
                         Nothing -> filter (inRange newestLTS oldestLTS) allMajors
            AllVersions -> return allMajors
            Oldest ver -> return $ filter (inRange Nightly ver) allMajors
        else nub <$> mapM resolveMajor verlist
      return (versions,cmds)
      where
        inRange :: MajorVer -> MajorVer -> MajorVer -> Bool
        inRange newest oldest v = v >= oldest && v <= newest

readStackConfigs :: IO [MajorVer]
readStackConfigs = do
 sort . mapMaybe readStackConf <$> listDirectory "."
 where
   readStackConf :: FilePath -> Maybe MajorVer
   readStackConf "stack-lts.yaml" = error' "unversioned stack-lts.yaml is unsupported"
   readStackConf f =
     stripPrefix "stack-" f >>= stripSuffix ".yaml" >>= readCompactMajor

readNewestOldestLTS :: IO (MajorVer,MajorVer)
readNewestOldestLTS = do
  haveConfig <- doesFileExist stackAllFile
  if haveConfig then
    readIniConfig stackAllFile $
    section "versions" $ do
    mnewest <- fmap readMajor <$> fieldMbOf "newest" string
    moldest <- fmap readMajor <$> fieldMbOf "oldest" string
    return (fromMaybe Nightly mnewest, fromMaybe defaultOldestLTS moldest)
    else return (Nightly, defaultOldestLTS)
  where
    readIniConfig :: FilePath -> IniParser a -> IO a
    readIniConfig inifile iniparser = do
      ini <- T.readFile inifile
      return $ either error id $ parseIniFile ini iniparser

stackAllFile :: FilePath
stackAllFile = ".stack-all"

createStackAll :: Maybe MajorVer -> Maybe MajorVer -> IO ()
createStackAll Nothing Nothing =
  error' "creating .stack-all requires --oldest LTS and/or --newest LTS"
createStackAll moldest mnewest = do
  exists <- doesFileExist stackAllFile
  if exists then error' $ stackAllFile ++ " already exists"
    else do
    allMajors <- getMajorVers
    writeFile stackAllFile $
      "[versions]\n" ++
      case mnewest of
        Nothing -> ""
        Just newest ->
          "newest = " ++ showMajor newest ++ "\n"
      ++
      case moldest of
        Nothing -> ""
        Just oldest ->
          let older =
                let molder = listToMaybe $ dropWhile (>= oldest) allMajors
                in maybe "" (\s -> showMajor s ++ " too old") molder
          in "# " ++ older ++ "\noldest = " ++ showMajor oldest ++ "\n"

stackDefaultResolver :: [MajorVer] -> IO ()
stackDefaultResolver vers = do
  unlessM (doesFileExist stackYaml) $
    error' $ "no" +-+ stackYaml +-+ "present"
  case vers of
    [ver] ->
      whenJustM (latestMajorSnapshot False ver) $ \latest ->
      cmd_ "sed" ["-i", "-e", "s/\\(resolver:\\) .*/\\1 " ++ latest ++ "/", stackYaml]
    _ -> error' "only specify one major version for default resolver"

makeStackLTS :: Bool -> [MajorVer] -> IO ()
makeStackLTS refresh vers = do
  configs <- readStackConfigs
  forM_ vers $ \ver -> do
    let newfile = configFile ver
    if ver `elem` configs
      then do
      error' $ newfile ++ " already exists!"
      else do
      let mcurrentconfig = find (ver <=) (delete Nightly configs)
      case mcurrentconfig of
        Nothing -> copyFile stackYaml newfile
        Just conf -> do
          let origfile = configFile conf
          copyFile origfile newfile
      whenJustM (latestMajorSnapshot refresh ver) $ \latest ->
        cmd_ "sed" ["-i", "-e", "s/\\(resolver:\\) .*/\\1 " ++ latest ++ "/", newfile]

configFile :: MajorVer -> FilePath
configFile ver = "stack-" ++ showCompact ver <.> "yaml"

runStack :: [MajorVer] -> Bool -> Bool -> Bool -> [String]
           -> MajorVer -> IO ()
runStack configs keepgoing debug refresh command ver = do
  let mcfgver =
        case ver of
          Nightly | Nightly `elem` configs -> Just Nightly
          _ ->
            case sort (filter (ver <=) (delete Nightly configs)) of
              [] -> Nothing
              (cfg:_) -> Just cfg
  latest <- latestMajorSnapshot refresh ver
  case latest of
    Nothing -> error' $ "no snapshot not found for " ++ showMajor ver
    Just minor -> do
      let opts = ["-v" | debug] ++ ["--resolver", minor] ++
                 maybe [] (\f -> ["--stack-yaml", configFile f]) mcfgver
      putStrLn $ "# " ++ minor
      if debug
        then debugBuild $ opts ++ command
        else do
        ok <- cmdBool "stack" $ opts ++ command
        unless (ok || keepgoing) $ do
          putStr "\nsnapshot-pkg-db: "
          cmd_ "stack" $ "--silent" : opts ++ ["path", "--snapshot-pkg-db"]
          error' $ "failed for " ++ showMajor ver
      putStrLn ""
  where
    debugBuild :: [String] -> IO ()
    debugBuild args = do
      putStr $ "stack " ++ unwords args
      (ret,out,err) <- readProcessWithExitCode "stack" args ""
      putStrLn "\n"
      unless (null out) $ putStrLn out
      unless (ret == ExitSuccess) $ do
        -- stack verbose includes info line with all stackages (> 500kbytes)
        mapM_ putStrLn $ filter ((<10000) . length) . lines $ err
        error' $ showMajor ver ++ " build failed"


#if !MIN_VERSION_simple_cmd(0,2,4)
filesWithExtension :: FilePath -- directory
                   -> String   -- file extension
                   -> IO [FilePath]
filesWithExtension dir ext =
  filter (ext `isExtensionOf`) <$> listDirectory dir

-- looks in dir for a unique file with given extension
fileWithExtension :: FilePath -- directory
                  -> String   -- file extension
                  -> IO (Maybe FilePath)
fileWithExtension dir ext = do
  files <- filesWithExtension dir ext
  case files of
       [file] -> return $ Just $ dir </> file
       [] -> return Nothing
       _ -> putStrLn ("More than one " ++ ext ++ " file found!") >> return Nothing
#endif

-- looks in current dir for a unique file with given extension
doesFileExistWithExtension :: FilePath -> String -> IO Bool
doesFileExistWithExtension dir ext = do
  mf <- fileWithExtension dir ext
  case mf of
    Nothing -> return False
    Just f -> doesFileExist f

#if !MIN_VERSION_filepath(1,4,2)
isExtensionOf :: String -> FilePath -> Bool
isExtensionOf ext@('.':_) = isSuffixOf ext . takeExtensions
isExtensionOf ext         = isSuffixOf ('.':ext) . takeExtensions
#endif
