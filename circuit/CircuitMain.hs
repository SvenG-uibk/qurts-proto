-- Driver: parse -> type-check -> uncompute -> compile-to-circuit-IR, for a
-- single qurts-core file, writing the flat text IR to stdout (or a file).
-- The uncomputation step matters: we compile the *uncomputed* program,
-- whose drops have already become reversals-to-|0> (or classical no-ops),
-- so the circuit never has to discard a non-|0> qubit. See Circuit.hs.
module Main where

import System.Environment (getArgs)
import System.Exit        (exitFailure)

import QurtsGrammar.Par (pProgram, myLexer)
import AbsQurtsToAst     (convertProgram)
import TypeChecker        (checkProgram)
import Uncompute           (uncomputeProgram)
import Circuit             (compileProgram, renderCircuit)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [inp]      -> run inp Nothing
    [inp, out] -> run inp (Just out)
    _          -> do
      putStrLn "Usage: circuit-main <input.qurts-core> [output.ir]"
      exitFailure

run :: FilePath -> Maybe FilePath -> IO ()
run inp mout = do
  contents <- readFile inp
  case pProgram (myLexer contents) of
    Left err -> die ("parse error: " ++ err)
    Right tree -> do
      let ast = convertProgram tree
      case checkProgram ast of
        Left err -> die ("does not type check: " ++ show err)
        Right () -> case uncomputeProgram ast of
          Left err -> die ("uncompute failed: " ++ err)
          Right unc -> case compileProgram unc of
            Left err -> die ("compile failed: " ++ err)
            Right circ -> do
              let ir = renderCircuit circ
              case mout of
                Nothing  -> putStr ir
                Just out -> writeFile out ir >> putStrLn ("wrote " ++ out)

die :: String -> IO ()
die msg = putStrLn ("ERROR: " ++ msg) >> exitFailure
