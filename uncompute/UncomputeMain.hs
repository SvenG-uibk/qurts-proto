-- Batch driver for the uncomputation pass.
--
-- For every *.qurts-core file in an input directory (or a single input
-- file), runs the full pipeline -- parse, type check, uncompute, pretty
-- print -- and, as a correctness check, re-parses and re-type-checks the
-- printed output before trusting it. Files that make it through all of
-- that are written out as qurts-core source into an output directory
-- (default: examples-uncomputed), mirroring the input file names.
--
-- Files with "_error" in their name are skipped without comment: those are
-- deliberately not supposed to type check, so there is nothing to uncompute.
-- Everything else that fails is reported with the pipeline stage it failed
-- at and the reason, rather than silently dropped -- most of the current
-- examples are expected to fail inside Uncompute itself, since the pass
-- only reverses drops whose entire definition chain is EU/copy/bool/unit,
-- not qif, calls, pairs, or classical injections yet (see uncompute/README.md).
module Main where

import System.Environment  (getArgs)
import System.Directory    ( listDirectory, doesDirectoryExist, doesFileExist
                            , createDirectoryIfMissing )
import System.Exit         (exitFailure)
import System.FilePath     (takeFileName, (</>))
import Data.List           (isSuffixOf, isInfixOf, sort)
import Control.Monad       (forM)

import QurtsGrammar.Par (pProgram, myLexer)
import AbsQurtsToAst     (convertProgram)
import TypeChecker        (checkProgram)
import Uncompute           (uncomputeProgram)
import PrettyAst           (prettyProgram)

defaultInputDir, defaultOutputDir :: FilePath
defaultInputDir  = "examples"
defaultOutputDir = "examples-uncomputed"

main :: IO ()
main = do
  args <- getArgs
  (inputPath, outputDir) <- case args of
        []          -> return (defaultInputDir, defaultOutputDir)
        [inp]       -> return (inp, defaultOutputDir)
        [inp, outp] -> return (inp, outp)
        _           -> do
          putStrLn "Usage: uncompute-main [input-dir-or-file] [output-dir]"
          putStrLn "  defaults: input=examples output=examples-uncomputed"
          exitFailure
          return ("", "")
  isDir  <- doesDirectoryExist inputPath
  isFile <- doesFileExist inputPath
  files <-
    if isDir then do
      entries <- listDirectory inputPath
      return [ inputPath </> f
             | f <- sort entries
             , ".qurts-core" `isSuffixOf` f
             , not ("_error" `isInfixOf` f)
             ]
    else if isFile then
      return [inputPath]
    else do
      putStrLn ("no such file or directory: " ++ inputPath)
      exitFailure
      return []
  createDirectoryIfMissing True outputDir
  results <- forM files (processFile outputDir)
  let total = length results
      ok    = length (filter id results)
  putStrLn ""
  putStrLn ("=== " ++ show ok ++ "/" ++ show total ++ " uncomputed successfully into " ++ outputDir ++ " ===")
  -- Not a pass/fail test suite: SKIPs are the documented, expected scope
  -- limit of the pass (qif/calls/pairs not handled yet, see uncompute/README.md),
  -- not a broken run, so exit 0 as long as nothing crashed outright.

-- | Run the full pipeline on one file and report a single status line.
-- Returns True iff an uncomputed file was written out.
processFile :: FilePath -> FilePath -> IO Bool
processFile outputDir path = do
  let name = takeFileName path
  contents <- readFile path
  case pProgram (myLexer contents) of
    Left err -> skip name ("parse error: " ++ err)
    Right bnfcTree -> do
      let astTree = convertProgram bnfcTree
      case checkProgram astTree of
        Left err -> skip name ("does not type check: " ++ show err)
        Right () -> case uncomputeProgram astTree of
          Left err -> skip name ("uncompute failed: " ++ err)
          Right newTree -> do
            let printed = prettyProgram newTree
            case pProgram (myLexer printed) of
              Left err -> skip name ("uncomputed output failed to re-parse (bug in Uncompute/PrettyAst): " ++ err)
              Right bnfcTree2 -> case checkProgram (convertProgram bnfcTree2) of
                Left err -> skip name ("uncomputed output failed to re-type-check (bug in Uncompute): " ++ show err)
                Right () -> do
                  let outPath = outputDir </> name
                  writeFile outPath printed
                  putStrLn ("OK    " ++ name ++ " -> " ++ outPath)
                  return True

skip :: String -> String -> IO Bool
skip name msg = putStrLn ("SKIP  " ++ name ++ ": " ++ msg) >> return False
