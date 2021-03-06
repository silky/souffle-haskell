{-# LANGUAGE DataKinds, TypeFamilies, DeriveGeneric, DeriveAnyClass, TypeApplications #-}

module Main ( main ) where

-- NOTE: This is a helper script for importing all Souffle headers into
-- this repository. This is done in order to make Haskell libraries that
-- use souffle-haskell "self-contained", meaning users of the packages
-- using those libraries are not required to have souffle (headers) installed.

import System.Directory
import System.FilePath
import System.Process
import Control.Monad
import Control.Monad.Extra
import Control.Applicative
import Data.List
import Data.Maybe
import Data.Void
import GHC.Generics
import qualified Text.Megaparsec as P
import qualified Text.Megaparsec.Char as P
import qualified Language.Souffle.Interpreted as Souffle
import Language.Souffle.Experimental


data Includes = Includes FilePath FilePath
  deriving (Eq, Show, Generic, Souffle.Marshal, FactMetadata)

data TransitivelyIncludes = TransitivelyIncludes FilePath FilePath
  deriving (Eq, Show, Generic, Souffle.Marshal, FactMetadata)

newtype TopLevelInclude = TopLevelInclude FilePath
  deriving (Eq, Show, Generic, Souffle.Marshal, FactMetadata)

newtype RequiredInclude = RequiredInclude FilePath
  deriving (Eq, Show, Generic, Souffle.Marshal, FactMetadata)

data Handle = Handle

instance Souffle.Program Handle where
  type ProgramFacts Handle =
    [ TopLevelInclude
    , Includes
    , TransitivelyIncludes
    , RequiredInclude
    ]
  programName = const "required_include"

instance Souffle.Fact Includes where
  type FactDirection Includes = 'Souffle.Input
  factName = const "includes"

instance Souffle.Fact TransitivelyIncludes where
  type FactDirection TransitivelyIncludes = 'Souffle.Internal
  factName = const "transitively_includes"

instance Souffle.Fact TopLevelInclude where
  type FactDirection TopLevelInclude = 'Souffle.Input
  factName = const "top_level_include"

instance Souffle.Fact RequiredInclude where
  type FactDirection RequiredInclude = 'Souffle.Output
  factName = const "required_include"

dlProgram :: DSL Handle 'Definition ()
dlProgram = do
  Predicate includes <- predicateFor @Includes
  Predicate transitivelyIncludes <- predicateFor @TransitivelyIncludes
  Predicate topLevelInclude <- predicateFor @TopLevelInclude
  Predicate requiredInclude <- predicateFor @RequiredInclude

  file1 <- var "file1"
  file2 <- var "file2"
  file3 <- var "file3"

  requiredInclude(file1) |-
    topLevelInclude(file1)
  requiredInclude(file1) |- do
    topLevelInclude(file2)
    transitivelyIncludes(file2, file1)

  transitivelyIncludes(file1, file2) |-
    includes(file1, file2)
  transitivelyIncludes(file1, file2) |- do
    includes(file1, file3)
    transitivelyIncludes(file3, file2)


run :: String -> IO ()
run = callCommand

runWithResult :: String -> IO String
runWithResult s = case words s of
  (program:args) -> readProcess program args ""
  _ -> error "Passed empty string to 'runWithResult'. Aborting."

headerDir :: FilePath
headerDir = "cbits/souffle/"

main :: IO ()
main = do
  pwd <- getCurrentDirectory
  gitRoot <- getGitRootDirectory
  when (pwd /= gitRoot) $
    putStrLn "You need to run this script in the root directory of this repo! Aborting."

  run "git submodule update --init --recursive"
  run $ "rm -rf " <> headerDir <> "*.h"
  run $ "cp souffle/LICENSE " <> headerDir
  files <- copyHeaders
  putStrLn "Replace 'install-includes' in your package.yaml with the following:"
  putStrLn . unlines $ map ("  - souffle/" <>) files

getGitRootDirectory :: IO FilePath
getGitRootDirectory =
  filter (/= '\n') <$> runWithResult "git rev-parse --show-toplevel"

parseIncludes :: String -> [FilePath]
parseIncludes s = either (const []) catMaybes $ P.runParser parser "" s where
  parser :: P.Parsec Void String [Maybe FilePath]
  parser = many (includeParser <|> skipRestOfLine) <* P.eof
  includeParser = do
    P.chunk "#include" *> P.space1
    P.lookAhead (P.char '"' <|> P.char '<') >>= \case
      '"' -> do
        include <- P.between quotes quotes $ P.takeWhile1P Nothing (/= '"')
        void skipRestOfLine
        pure $ Just include
      _ -> pure Nothing
  quotes = P.char '"'
  skipRestOfLine = Nothing <$ (P.takeWhileP Nothing (/= '\n') *> P.newline)

parseIncludesInHeader :: FilePath -> IO [Includes]
parseIncludesInHeader file = f <$> readFile file where
  f = map ((file `Includes`) . normalizeFilePath dir) . parseIncludes
  dir = takeDirectory file

normalizeFilePath :: FilePath -> FilePath -> FilePath
normalizeFilePath dir file = normalize $ dir </> file' where
  file' = if "souffle/" `isPrefixOf` file then file \\ "souffle/" else file
  normalize = withExplodedPath (reverse . removeParentDirRefs . reverse)
  removeParentDirRefs = \case
    ("../":_:xs) -> removeParentDirRefs xs
    (x:xs) -> x:removeParentDirRefs xs
    [] -> []

copyHeaders :: IO [FilePath]
copyHeaders = do
  headers <- filter (".h" `isSuffixOf`) . lines
          <$> runWithResult "find souffle -type f"
  includes <- concatMapM parseIncludesInHeader headers
  traverse copyHeader =<< computeRequiredIncludes includes

computeRequiredIncludes :: [Includes] -> IO [FilePath]
computeRequiredIncludes includes = do
  requiredIncludes <- runSouffleInterpreted Handle dlProgram $ \case
    Nothing -> error "Failed to load Souffle program. Aborting."
    Just prog -> do
      Souffle.addFacts prog [ TopLevelInclude "souffle/src/SouffleInterface.h"
                            , TopLevelInclude "souffle/src/CompiledSouffle.h"
                            ]
      Souffle.addFacts prog includes
      Souffle.run prog
      Souffle.getFacts prog
  pure $ map (\(RequiredInclude include) -> include) requiredIncludes

copyHeader :: FilePath -> IO FilePath
copyHeader file = do
  header <- head . filter (file `isSuffixOf`) . lines
        <$> runWithResult "find souffle/ -type f"
  let header' = withExplodedPath (drop 2) header
      dir = headerDir </> takeDirectory header'
      destination = replaceDirectory header' dir
  createDirectoryIfMissing True dir
  copyFile header destination
  pure header'

withExplodedPath :: ([FilePath] -> [FilePath]) -> FilePath -> FilePath
withExplodedPath f = joinPath . f . splitPath

