module Main where

import System.Environment (getArgs)
import QurtsGrammar.Par (pProgram, myLexer)
import AbsQurtsToAst (convertProgram)
import TypeChecker (checkProgram)
import PrettyAst (prettyProgram)

main :: IO ()
main = do
  [path] <- getArgs
  s <- readFile path
  case pProgram (myLexer s) of
    Left err -> putStrLn ("parse error: " ++ err)
    Right bnfcTree -> do
      let astTree = convertProgram bnfcTree
          printed = prettyProgram astTree
      putStrLn "=== pretty-printed ==="
      putStrLn printed
      putStrLn "=== re-parse + re-typecheck the printed output ==="
      case pProgram (myLexer printed) of
        Left err -> putStrLn ("RE-PARSE FAILED: " ++ err)
        Right bnfcTree2 -> do
          let astTree2 = convertProgram bnfcTree2
          case checkProgram astTree2 of
            Left err -> putStrLn ("RE-TYPECHECK FAILED: " ++ show err)
            Right () -> putStrLn "round-trip OK: printed output re-parses and re-typechecks"
