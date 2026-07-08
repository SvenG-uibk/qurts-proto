module Main where

import System.Environment ( getArgs )
import System.Exit        ( exitFailure )
import System.Directory   ( listDirectory, doesFileExist )
import Data.List          ( isSuffixOf, isInfixOf, sort )

import QurtsGrammar.Par   ( pProgram, myLexer )
import QurtsGrammar.Print ( printTree )

import AbsQurtsToAst      ( convertProgram )
import TypeChecker        ( checkProgram )


main :: IO ()
main = do
  args <- getArgs
  case args of
    ["parse", file] -> parseFile file
    ["check", file] -> checkFile file
    ["test",  dir]  -> testDir dir
    _               -> do
      putStrLn "Usage:"
      putStrLn "  qurts parse <file.qurts-core>   -- parse and print AST"
      putStrLn "  qurts check <file.qurts-core>   -- parse and type check"
      putStrLn "  qurts test  <directory>          -- run all *.qurts-core files;"
      putStrLn "                                       files with _error in name must fail,"
      putStrLn "                                       all others must succeed"
      exitFailure

-- | Parse only — lex, parse, print BNFC pretty print and our AST
parseFile :: FilePath -> IO ()
parseFile file = do
  contents <- readFile file
  let tokens = myLexer contents
  case pProgram tokens of
    Left err -> do
      putStrLn "Parse error:"
      putStrLn err
      exitFailure
    Right bnfcTree -> do
      putStrLn "Parse successful!\n"
      putStrLn "=== Pretty Printed ==="
      putStrLn (printTree bnfcTree)
      putStrLn ""
      putStrLn "=== Our AST ==="
      let tree = convertProgram bnfcTree
      print tree

-- | Parse then type check
checkFile :: FilePath -> IO ()
checkFile file = do
  contents <- readFile file
  let tokens = myLexer contents
  case pProgram tokens of
    Left err -> do
      putStrLn "Parse error:"
      putStrLn err
      exitFailure
    Right bnfcTree -> do
      putStrLn "Parse successful!"
      let tree = convertProgram bnfcTree
      putStrLn "=== Type Checking ==="
      case checkProgram tree of
        Left err -> do
          putStrLn "Type error:"
          print err
          exitFailure
        Right () ->
          putStrLn "Type check successful!"

-- | Run all *.qurts-core files in a directory.
-- Convention: files with "_error" in their name are expected to fail type-checking;
-- all other files are expected to succeed.
testDir :: FilePath -> IO ()
testDir dir = do
  allFiles <- listDirectory dir
  let files = sort [ dir ++ "/" ++ f | f <- allFiles, ".qurts-core" `isSuffixOf` f ]
  results  <- mapM runTest files
  let passed = length (filter id results)
      total  = length results
  putStrLn ""
  putStrLn $ "=== " ++ show passed ++ "/" ++ show total ++ " passed ==="
  if passed == total
    then putStrLn "All tests passed!"
    else do
      putStrLn "Some tests FAILED."
      exitFailure

-- | Run a single test file and print the result.
-- Returns True if the outcome matches the expectation.
-- For _error files: if a <name>.expected sidecar file exists, the actual error
-- message must contain the expected substring; otherwise any error suffices.
runTest :: FilePath -> IO Bool
runTest file = do
  let expectError  = "_error" `isInfixOf` file
      base         = take (length file - length ".qurts-core") file
      expectedFile = base ++ ".expected"
  contents <- readFile file
  let outcome = case pProgram (myLexer contents) of
        Left  err  -> Left ("Parse error: " ++ err)
        Right bnfc -> case checkProgram (convertProgram bnfc) of
          Left  err  -> Left (show err)
          Right ()   -> Right ()
  mWant <- if expectError
             then do exists <- doesFileExist expectedFile
                     if exists then fmap (Just . trim) (readFile expectedFile)
                               else return Nothing
             else return Nothing
  let (ok, label) = case (expectError, mWant, outcome) of
        (False, _,         Right ())                      -> (True,  "PASS")
        (True,  Nothing,   Left  _)                       -> (True,  "PASS (expected error)")
        (True,  Just want, Left  got) | want `isInfixOf` got
                                                          -> (True,  "PASS (expected: " ++ want ++ ")")
        (True,  Just want, Left  got)                     -> (False, "FAIL (expected \""
                                                                ++ want ++ "\", got: " ++ got ++ ")")
        (False, _,         Left  e)                       -> (False, "FAIL (unexpected error: " ++ e ++ ")")
        (True,  _,         Right ())                      -> (False, "FAIL (expected to fail but succeeded)")
  putStrLn $ label ++ "  " ++ file
  return ok

trim :: String -> String
trim = f . f
  where f = reverse . dropWhile (`elem` " \t\n\r")
