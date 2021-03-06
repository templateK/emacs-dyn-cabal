{-# LANGUAGE DataKinds                #-}
{-# LANGUAGE FlexibleContexts         #-}
{-# LANGUAGE MultiParamTypeClasses    #-}
{-# LANGUAGE OverloadedStrings        #-}
{-# LANGUAGE QuasiQuotes              #-}
{-# LANGUAGE ScopedTypeVariables      #-}


module CabalTarget
  ( getCabalTarget
  ) where


import           Control.Lens
import           Control.Monad.Catch
import           Data.ByteString                                      (ByteString)
import qualified Data.ByteString.Char8                         as C8
import           Distribution.ModuleName                       hiding (main)
import           Distribution.PackageDescription
import           Distribution.PackageDescription.Parsec
import           Distribution.Simple.Utils
import           Distribution.Types.ForeignLib
import           Distribution.Types.UnqualComponentName
import           Distribution.Types.PackageName
import           Distribution.Types.GenericPackageDescription
import qualified Distribution.Types.Lens                       as L

import           System.FilePath
import           Data.List
import           Data.Ord
import           Data.Foldable
import           Data.Maybe


data ExeComp = ExeComp
  { exeCompName    :: String
  , exeCompMainIs  :: String
  , exeCompModules :: [ModuleName]
  , exeCompSrcs    :: [FilePath]
  } deriving (Show)


data FibComp = FibComp
  { fibCompName    :: String
  , fibCompModules :: [ModuleName]
  , fibCompSrcs    :: [FilePath]
  } deriving (Show)


data TstComp = TstComp
  { tstCompName    :: String
  , tstCompMainIs  :: TestSuiteInterface
  , tstCompModules :: [ModuleName]
  , tstCompSrcs    :: [FilePath]
  } deriving (Show)


data BchComp = BchComp
  { bchCompName    :: String
  , bchCompMainIs  :: BenchmarkInterface
  , bchCompModules :: [ModuleName]
  , bchCompSrcs    :: [FilePath]
  } deriving (Show)


-- | getCabalTarget Guesses appropriate cabal target and returns cabal target string
-- | cabalPathBS  : File Path of Cabal Configuration File
-- | hsFilePathBS : File Path of Haskell Source File
getCabalTarget :: ByteString -> ByteString -> IO (Maybe ByteString)
getCabalTarget cabalPathBS hsFilePathBS = do
  let cabalPath     = fromUTF8BS cabalPathBS
      hsFilePath    = fromUTF8BS hsFilePathBS
      prjRoot       = dropFileName cabalPath
      (pwd, hsFile) = splitFileName hsFilePath
      relPath       = joinPath $ splitPath pwd \\ splitPath prjRoot
      hsFileRelPath = relPath </> hsFile

  -- TODO: Instead swallow IO error, we must express the error explicitly via Either
  --       or any other mechanism.
  cabalContentBs <- catchIOError (C8.readFile cabalPath) (return . const mempty)
  let genPkgsDesc = fromMaybe emptyGenericPackageDescription
                              $ parseGenericPackageDescriptionMaybe cabalContentBs

  let gpkg = genPkgsDesc ^. L.packageDescription . to package . gpkgLens
      libs = genPkgsDesc ^? L.condLibrary . _Just . to condTreeData . libsLens
      exes = genPkgsDesc ^. L.condExecutables ^.. traverse . _2 . to condTreeData . exesLens
      fibs = genPkgsDesc ^. L.condForeignLibs ^.. traverse . _2 . to condTreeData . fibsLens
      bchs = genPkgsDesc ^. L.condBenchmarks ^.. traverse . bchsLens
      tsts = genPkgsDesc ^. L.condTestSuites ^.. traverse . tstsLens

  -- NOTE: Foreign library loading can be down via cabal new-repl --repl-options=-fobject-code
  --       that is not a edm-haskell's concern currently.

  let match = [ mkExeExact  "exe:"   hsFileRelPath exes
              , mkTstExact  "test:"  hsFileRelPath tsts
              , mkBchExact  "bench:" hsFileRelPath bchs
              , if relPath `isAnySubdirOf` libs then Just ("lib:" <> gpkg) else Nothing
              , mkExeTarget "exe:"   hsFileRelPath exes
              , mkTstTarget "test:"  hsFileRelPath tsts
              , mkFibTarget "flib:"  relPath       fibs
              , mkBchTarget "bench:" hsFileRelPath bchs
              ]
  return $ toUTF8BS <$> asum match
  where
    gpkgLens = L.pkgName . to unPackageName
    libsLens = L.hsSourceDirs . to (fmap normalise)
    exesLens = runGetter $ ExeComp
               <$> Getter ( L.exeName        . to unUnqualComponentName )
               <*> Getter ( L.modulePath     . to normalise             )
               <*> Getter (                    to exeModules            )
               <*> Getter ( L.hsSourceDirs   . to (fmap normalise)      )

    fibsLens = runGetter $ FibComp
               <$> Getter ( L.foreignLibName . to unUnqualComponentName )
               <*> Getter (                    to foreignLibModules     )
               <*> Getter ( L.hsSourceDirs   . to (fmap normalise)      )

    bchsLens = runGetter $ BchComp
               <$> Getter ( _1 . to unUnqualComponentName                               )
               <*> Getter ( _2 . to condTreeData . L.benchmarkInterface                 )
               <*> Getter ( _2 . to condTreeData .                  to benchmarkModules )
               <*> Getter ( _2 . to condTreeData . L.hsSourceDirs . to (fmap normalise) )

    tstsLens = runGetter $ TstComp
               <$> Getter ( _1 . to unUnqualComponentName                               )
               <*> Getter ( _2 . to condTreeData . L.testInterface                      )
               <*> Getter ( _2 . to condTreeData .                  to testModules      )
               <*> Getter ( _2 . to condTreeData . L.hsSourceDirs . to (fmap normalise) )


isAnySubdirOf :: FilePath -> Maybe [FilePath] -> Bool
isAnySubdirOf p = maybe False (p `hasSuperDir`)


-- NOTE: Does exe component has also combinatoric problem?
mkExeTarget :: String -> FilePath -> [ExeComp] -> Maybe String
mkExeTarget prefix relPathFile comps = (<>) prefix . exeCompName <$> exactOrClosest
  where
    -- NOTE: -- If main-is field is set, then exact match is must be prioritized.
    -- TODO: What if mains-is set and there's no match?
    --       Should we return empty string or just make best guess?
    --       Currently we just return best match.
    hsFile           = takeFileName relPathFile
    relPath          = dropFileName relPathFile
    exactOrClosest   = asumOf each (mainIsSameParent, closestParent)
    closestParent    = firstOf traverse parentCandidates
    mainIsSameParent = findOf traverse  ((== hsFile) . exeCompMainIs) parentCandidates
    parentCandidates = getCandiates comps relPath exeCompSrcs


mkExeExact :: String -> FilePath -> [ExeComp] -> Maybe String
mkExeExact prefix relPathFile comps =
  (prefix <>) . exeCompName <$> findOf traverse (\comp -> exeCompMainIs comp == relPathFile) comps


mkTstExact :: String -> FilePath -> [TstComp] -> Maybe String
mkTstExact prefix relPathFile comps =
  (prefix <>) . tstCompName <$> findOf traverse ((==) relPathFile . tstInfToFilePath . tstCompMainIs) comps
  where
    tstInfToFilePath :: TestSuiteInterface -> String
    tstInfToFilePath (TestSuiteExeV10 _ filePath) = filePath
    -- tstInfToFilePath (TestSuiteLibV09 _ mdlName)  = toFilePath mdlName <> ".hs"
    tstInfToFilePath _                            = ""


mkBchExact :: String -> FilePath -> [BchComp] -> Maybe String
mkBchExact prefix relPathFile comps =
  (prefix <>) . bchCompName <$> findOf traverse ((==) relPathFile . bchInfToFilePath . bchCompMainIs) comps
  where
    bchInfToFilePath :: BenchmarkInterface -> String
    bchInfToFilePath (BenchmarkExeV10 _ filePath) = filePath
    bchInfToFilePath _                            = ""
  -- if relPathFile `elem` fmap exeCompMainIs comps
  -- then Just $ prefix <> exeCompName comps
  -- else Nothing
-- >>> takeFileName "lib/Foo.hs"
-- "Foo.hs"
-- it :: FilePath
--
-- >>> dropFileName "lib/Foo.hs"
-- "lib/"
-- it :: FilePath

-- NOTE: Longest path is the closest path to the target path.
-- ex) The closest path to "app/mkCabalTarget/bar/wat" is "app/mkCabalTarget/bar"
--     among "app", "app/mkCabalTarget" and "app/mkCabalTarget/bar".
getCandiates :: [a] -> FilePath -> (a -> [FilePath]) -> [a]
getCandiates [] _ _         = []
getCandiates cs path getter = sortByLengthDescend getter cs ^.. traverse . filtered ((path `hasSuperDir`) . getter)
  where
    sortByLengthDescend :: (a1 -> [[a]]) -> [a1] -> [a1]
    sortByLengthDescend _ [] = []
    sortByLengthDescend f as = sortOn (Down . safeMaximum . fmap length . f) as

    safeMaximum :: [Int] -> Int
    safeMaximum [] = 0
    safeMaximum as = maximum as


mkFibTarget :: String -> FilePath -> [FibComp] -> Maybe String
mkFibTarget prefix relPath comps = (<>) prefix . fibCompName <$> closestParent
  where
    closestParent    = firstOf traverse parentCandidates
    parentCandidates = getCandiates comps relPath fibCompSrcs


-- TODO: more precise implementation needs.
mkBchTarget :: String -> FilePath -> [BchComp] -> Maybe String
mkBchTarget prefix relPath comps = (<>) prefix . bchCompName <$> exactOrClosest
  where
    exactOrClosest   = asumOf each (mainIsSameParent, closestParent)
    mainIsSameParent = findOf traverse (matchBenchComp relPath) parentCandidates
    closestParent    = firstOf traverse parentCandidates
    parentCandidates = getCandiates comps relPath bchCompSrcs

    matchBenchComp :: FilePath -> BchComp -> Bool
    matchBenchComp replPathFile comp =
      matchExact replPathFile bchCompHsFileName (bchCompSrcs comp) (bchCompModules comp)
      where
        bchCompHsFileName  = case bchCompMainIs comp of
          (BenchmarkExeV10 _ hsName) -> hsName
          _   -> ""
          -- (BenchmarkUnsupported _)   -> ""


mkTstTarget :: String -> FilePath -> [TstComp] -> Maybe String
mkTstTarget prefix relPath comps = (<>) prefix . tstCompName <$> exactOrClosest
  where
    exactOrClosest   = asumOf each (mainIsSameParent, closestParent)
    mainIsSameParent = findOf traverse (matchTestComp relPath) parentCandidates
    closestParent    = firstOf traverse parentCandidates
    parentCandidates = getCandiates comps relPath tstCompSrcs

    matchTestComp :: FilePath -> TstComp -> Bool
    matchTestComp replPathFile comp =
      matchExact replPathFile tstCompHsFileName (tstCompSrcs comp) (tstCompModules comp)
      where
        -- TODO : Figure out what is like setting TestSuiteLibV09.
        tstCompHsFileName  = case tstCompMainIs comp of
            (TestSuiteExeV10 _ hsName) -> hsName
            _ -> ""
            -- (TestSuiteLibV09 _ moduleName) -> dropExtension relPathFile == toFilePath moduleName
            -- (TestSuiteUnsupported _)       -> ""


matchExact :: FilePath -> FilePath -> [FilePath] -> [ModuleName] -> Bool
matchExact relPathFile interfaceFileName hsSrcPaths compModuleNames =
  hsFileName == interfaceFileName || elemOf traverse relPathWithoutExt srcRelCompRelCombi
  where
    -- NOTE: How do we deal with combinatoric explosion with hs-source-dirs and component path?
    --       What is the legit cases of this situation?
    --       Are all of the combinations of a module Path with different hs-source-dirs valid
    --       cabal configuration?  For now, we just assume that all of the combinations are valid.
    srcRelCompRelCombi = [ srcRel </> compRel | srcRel <- hsSrcPaths
                                              , compRel <- toFilePath <$> compModuleNames ]
    hsFileName         = takeFileName relPathFile
    relPathWithoutExt  = dropExtension relPathFile


hasSuperDir :: FilePath -> [FilePath] -> Bool
hasSuperDir p = anyOf traverse (p `isSubDirOf`)


isSubDirOf :: FilePath -> FilePath -> Bool
isSubDirOf child parent = length parent' == length (takeWhile id commonPath)
    where
    child'     = splitDirectories child
    parent'    = splitDirectories parent
    commonPath = zipWith (==) child' parent'
