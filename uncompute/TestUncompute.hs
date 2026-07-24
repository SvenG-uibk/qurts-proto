module Main where

import System.Environment (getArgs)
import QurtsGrammar.Par (pProgram, myLexer)
import AbsQurtsToAst (convertProgram)
import TypeChecker (checkProgram)
import Uncompute (uncomputeProgram)
import PrettyAst (prettyProgram)

main :: IO ()
main = do
  [path] <- getArgs
  s <- readFile path
  case pProgram (myLexer s) of
    Left err -> putStrLn ("parse error: " ++ err)
    Right bnfcTree -> do
      let astTree = convertProgram bnfcTree
      case checkProgram astTree of
        Left err -> putStrLn ("input does not type check: " ++ show err)
        Right () -> case uncomputeProgram astTree of
          Left err -> putStrLn ("uncompute FAILED: " ++ err)
          Right newTree -> do
            let printed = prettyProgram newTree
            putStrLn "=== uncomputed program ==="
            putStrLn printed
            case pProgram (myLexer printed) of
              Left err -> putStrLn ("RE-PARSE FAILED: " ++ err)
              Right bnfcTree2 -> case checkProgram (convertProgram bnfcTree2) of
                Left err -> putStrLn ("RE-TYPECHECK FAILED: " ++ show err)
                Right () -> putStrLn "round-trip OK: uncomputed output re-parses and re-typechecks"
