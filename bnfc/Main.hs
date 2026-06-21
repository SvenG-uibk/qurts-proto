module Main where

import System.Environment ( getArgs )
import System.Exit        ( exitFailure )

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
    _               -> do
      putStrLn "Usage:"
      putStrLn "  qurts parse <file.qurts-core>   -- parse and print AST"
      putStrLn "  qurts check <file.qurts-core>   -- parse and type check"
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