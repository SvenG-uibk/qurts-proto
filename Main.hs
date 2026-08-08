module Main where

import System.Environment ( getArgs )
import System.Exit        ( exitFailure, ExitCode (..) )
import System.Directory   ( listDirectory, doesFileExist, createDirectoryIfMissing )
import System.FilePath    ( takeFileName, (</>) )
import System.Process     ( createProcess, proc, CreateProcess (..), StdStream (..)
                           , waitForProcess )
import System.IO          ( hClose, hPutStr )
import Control.Exception  ( try, IOException, evaluate )
import Data.List          ( isSuffixOf, isPrefixOf, isInfixOf, sort, intercalate )
import Control.Monad      ( when )

import QurtsGrammar.Par   ( pProgram, myLexer )
import QurtsGrammar.Print ( printTree )

import AbsQurtsToAst      ( convertProgram )
import TypeChecker        ( checkProgram )
import Uncompute          ( uncomputeProgram )
import PrettyAst          ( prettyProgram )
import Circuit             ( compileProgram, renderCircuit, Circuit )


main :: IO ()
main = do
  args <- getArgs
  case args of
    ["-parse",     file] -> parseFile file
    ["-check",     file] -> checkFile file
    ["-uncompute", file] -> uncomputeFile file
    ["-test",      dir]  -> testDir dir
    ["-v",         file] -> runPipeline True  False file
    ["-simulate",  file] -> runPipeline False True  file
    [file]                -> runPipeline False False file
    _                     -> usage

usage :: IO ()
usage = do
  putStrLn "Usage:"
  putStrLn "  qurts <file.qurts-core>            -- full pipeline (parse, check, uncompute,"
  putStrLn "                                         circuit); prints only the resulting"
  putStrLn "                                         circuit IR"
  putStrLn "  qurts -v <file.qurts-core>          -- full pipeline; pretty-printed output"
  putStrLn "                                         after every step"
  putStrLn "  qurts -simulate <file.qurts-core>   -- full pipeline; also runs the compiled"
  putStrLn "                                         circuit on Aer (1000 shots) and prints"
  putStrLn "                                         its outcome distribution"
  putStrLn "  qurts -parse <file.qurts-core>      -- parse only"
  putStrLn "  qurts -check <file.qurts-core>      -- parse and type check"
  putStrLn "  qurts -uncompute <file.qurts-core>  -- parse, check, uncompute; writes the"
  putStrLn "                                         re-translated qurts-core source to"
  putStrLn "                                         examples-uncomputed/"
  putStrLn "  qurts -test <directory>             -- parse+check every *.qurts-core in"
  putStrLn "                                         directory; files with _error in the"
  putStrLn "                                         name must fail, all others must succeed"
  exitFailure

die :: String -> IO a
die msg = putStrLn ("ERROR: " ++ msg) >> exitFailure

-- | readFile, but reporting a missing/unreadable file the same clean way
-- every other failure in this tool is reported, instead of leaking a raw
-- GHC IOException with a full HasCallStack backtrace -- confirmed
-- empirically, `qurts -check nonexistent.qurts-core` used to crash like
-- that. readFile itself is lazy (it may not actually touch the file until
-- the string it returns is forced), so the exception can't just be caught
-- around the readFile call -- `evaluate (length s)` forces the whole
-- string (and so the whole read) *inside* the try, where it can actually
-- be caught.
readFileOrDie :: FilePath -> IO String
readFileOrDie path = do
  result <- try (readFile path >>= \s -> evaluate (length s) >> return s) :: IO (Either IOException String)
  case result of
    Right contents -> return contents
    Left ex        -> die ("could not read " ++ path ++ ": " ++ show ex)

-- | Parse only -- lex, parse, print BNFC pretty print and our AST.
parseFile :: FilePath -> IO ()
parseFile file = do
  contents <- readFileOrDie file
  case pProgram (myLexer contents) of
    Left err -> die ("parse error: " ++ err)
    Right bnfcTree -> do
      putStrLn "Parse successful!\n"
      putStrLn "=== Pretty Printed ==="
      putStrLn (printTree bnfcTree)
      putStrLn ""
      putStrLn "=== Our AST ==="
      print (convertProgram bnfcTree)

-- | Parse then type check.
checkFile :: FilePath -> IO ()
checkFile file = do
  contents <- readFileOrDie file
  case pProgram (myLexer contents) of
    Left err -> die ("parse error: " ++ err)
    Right bnfcTree -> do
      putStrLn "Parse successful!"
      let tree = convertProgram bnfcTree
      putStrLn "=== Type Checking ==="
      case checkProgram tree of
        Left err -> die ("type error: " ++ show err)
        Right () -> putStrLn "Type check successful!"

-- | Parse, check, uncompute, re-translate to qurts-core source, and write
-- the result into examples-uncomputed/ (mirroring uncompute/UncomputeMain.hs's
-- own per-file behaviour, including its round-trip re-parse/re-check --
-- an uncomputed program that doesn't check is a bug in Uncompute/PrettyAst,
-- and this is the cheapest place to catch it).
uncomputeFile :: FilePath -> IO ()
uncomputeFile file = do
  contents <- readFileOrDie file
  case pProgram (myLexer contents) of
    Left err -> die ("parse error: " ++ err)
    Right bnfcTree -> do
      let ast = convertProgram bnfcTree
      case checkProgram ast of
        Left err -> die ("does not type check: " ++ show err)
        Right () -> case uncomputeProgram ast of
          Left err -> die ("uncompute failed: " ++ err)
          Right unc -> do
            let printed = prettyProgram unc
            case pProgram (myLexer printed) of
              Left err -> die ("uncomputed output failed to re-parse (bug in Uncompute/PrettyAst): " ++ err)
              Right bnfcTree2 -> case checkProgram (convertProgram bnfcTree2) of
                Left err -> die ("uncomputed output failed to re-type-check (bug in Uncompute): " ++ show err)
                Right () -> do
                  createDirectoryIfMissing True "examples-uncomputed"
                  let outPath = "examples-uncomputed" </> takeFileName file
                  writeFile outPath printed
                  putStrLn ("wrote " ++ outPath)

-- | Full pipeline: parse, check, uncompute, compile to a circuit, then hand
-- the circuit off to circuit/build_circuit.py to render as an actual Qiskit
-- circuit diagram (not our own internal IR -- that IR is just the
-- interchange format between this stage and Qiskit, see circuit/Circuit.hs).
-- Quiet by default (only the diagram goes to stdout); -v prints a
-- pretty-printed snapshot after every step along the way; -simulate also
-- runs the compiled circuit on Aer and prints its outcome distribution
-- (see showCircuit).
runPipeline :: Bool -> Bool -> FilePath -> IO ()
runPipeline verbose simulate file = do
  contents <- readFileOrDie file
  case pProgram (myLexer contents) of
    Left err -> die ("parse error: " ++ err)
    Right bnfcTree -> do
      let ast = convertProgram bnfcTree
      when verbose $ do
        putStrLn "=== Parsed ==="
        putStrLn (prettyProgram ast)
        putStrLn "=== Our AST ==="
        print ast
        putStrLn ""
      case checkProgram ast of
        Left err -> die ("does not type check: " ++ show err)
        Right () -> do
          when verbose $ putStrLn "=== Type check: OK ===\n"
          case uncomputeProgram ast of
            Left err -> die ("uncompute failed: " ++ err)
            Right unc -> do
              when verbose $ do
                putStrLn "=== Uncomputed ==="
                putStrLn (prettyProgram unc)
              -- Re-type-check the reconstructed program before trusting it
              -- enough to compile/run: uncomputeFile (-uncompute) already
              -- does this (its own "correctness check... before trusting
              -- it"), but this path -- the *default* invocation, -v, and
              -- -simulate -- didn't, meaning a bug in Uncompute.hs that
              -- produced a structurally-valid but ill-typed reconstruction
              -- could have compiled and *run* silently, with no error at
              -- all, since Circuit.hs's own checks are structural (do the
              -- locations line up), not a full type-check. Confirmed this
              -- was a real gap, not just a hypothetical one: -test's own
              -- per-file check (testFile, below) had the identical
              -- omission, so its "circuit: OK" column was never actually
              -- backed by this verification either -- only -uncompute's
              -- own dedicated path was checking it, for the *same*
              -- programs -test and this path also process.
              case checkProgram unc of
                Left err -> die ("uncomputed output failed to re-type-check (bug in Uncompute): " ++ show err)
                Right () -> case compileProgram unc of
                  Left err -> die ("circuit compilation failed: " ++ err)
                  Right circ -> do
                    when verbose $ putStrLn "=== Circuit ==="
                    showCircuit simulate circ

-- | Render a compiled Circuit the way Qiskit itself represents it: pipe our
-- flat IR into circuit/build_circuit.py (over stdin, via its "-" filename)
-- and let it print the ASCII circuit diagram it draws from the actual
-- qiskit.QuantumCircuit it builds. When `simulate` is set, also passes
-- --simulate (with a fixed 1000 shots, matching the -simulate flag's own
-- one job) so build_circuit.py additionally runs the circuit on Aer and
-- prints its outcome distribution -- for a different shot count, run
-- `python circuit/build_circuit.py <ir-file> --simulate --shots=N` directly
-- (see circuit/README.md). Deliberately does *not* capture the child's
-- stdout/stderr as a pipe and re-print it -- earlier versions did, and it
-- mangled the box-drawing characters into mojibake on Windows (GHC's own
-- console-codepage handling doesn't agree with a byte-for-byte forward
-- through a pipe). Instead the child inherits our real stdout/stderr
-- directly, so Python's own native Windows-console writing (which talks to
-- the console API directly and doesn't depend on the console's codepage at
-- all) does the job -- no forwarding to get wrong.
-- Requires `python` on PATH with qiskit installed (see circuit/README.md);
-- if that's not available, fails loudly with what went wrong and falls
-- back to printing our own IR, so the tool still gives you *something*.
showCircuit :: Bool -> Circuit -> IO ()
showCircuit simulate circ = do
  let ir = renderCircuit circ
  result <- try (runBuildCircuit simulate ir) :: IO (Either IOException ExitCode)
  case result of
    Right ExitSuccess -> return ()
    Right (ExitFailure _) -> do
      putStrLn "(circuit/build_circuit.py failed to render the Qiskit circuit -- see its output above)"
      putStrLn "--- falling back to the raw circuit IR ---"
      putStr ir
    Left ex -> do
      putStrLn ("(could not run `python circuit/build_circuit.py` (" ++ show ex ++ "); "
                 ++ "is python on PATH, with qiskit installed?)")
      putStrLn "--- falling back to the raw circuit IR ---"
      putStr ir

-- | Run build_circuit.py, feeding it `ir` over stdin; its stdout/stderr
-- inherit ours directly (see showCircuit for why).
runBuildCircuit :: Bool -> String -> IO ExitCode
runBuildCircuit simulate ir = do
  let simArgs = if simulate then ["--simulate", "--shots=1000"] else []
  (Just hin, Nothing, Nothing, ph) <- createProcess
    (proc "python" (["circuit/build_circuit.py", "-", "--draw"] ++ simArgs)) { std_in = CreatePipe }
  hPutStr hin ir
  hClose hin
  waitForProcess ph

-- | One pipeline stage's outcome for the -test table. StageNA covers both
-- "never attempted" (an earlier stage already failed, or this is an
-- _error file that's never meant to get this far) and "attempted but the
-- stage before it in the table -- uncompute for circuit's row -- failed,
-- so there's nothing to feed it."
data Stage = StageOK | StageFail String | StageNA

stageLabel :: Stage -> String
stageLabel StageOK       = "OK"
stageLabel (StageFail e) = "FAIL: " ++ e
stageLabel StageNA       = "-"

stageOk :: Stage -> Bool
stageOk StageOK = True
stageOk _       = False

data TestRow = TestRow
  { rowFile        :: FilePath
  , rowExpectError :: Bool
  , rowOk          :: Bool     -- parse+check matched expectation (drives PASS/FAIL and the exit code)
  , rowLabel       :: String   -- PASS / PASS (expected error) / FAIL (...)
  , rowUncompute   :: Stage
  , rowCircuit     :: Stage
  }

-- | Run the full pipeline (parse, check, uncompute, circuit) over every
-- *.qurts-core file in a directory and print one row per file. Convention,
-- unchanged from before: files with "_error" in their name are expected to
-- fail type-checking (and never proceed further); all other files are
-- expected to succeed at parse+check -- that's what PASS/FAIL and the exit
-- code are still keyed on. Uncompute/circuit are reported alongside for
-- visibility but don't affect PASS/FAIL: partial coverage there is
-- documented, expected scope (see uncompute/README.md, circuit/README.md),
-- not a regression -- this table is for seeing the current shape of that
-- coverage at a glance, not for it to start failing the moment a
-- not-yet-handled example is added.
testDir :: FilePath -> IO ()
testDir dir = do
  allFiles <- listDirectory dir
  let files = sort [ dir ++ "/" ++ f | f <- allFiles, ".qurts-core" `isSuffixOf` f ]
  rows <- mapM testFile files
  putStrLn (formatTable rows)
  let passed  = length (filter rowOk rows)
      total   = length rows
      nonErr  = filter (not . rowExpectError) rows
      uncOk   = length (filter (stageOk . rowUncompute) nonErr)
      circOk  = length (filter (stageOk . rowCircuit)   nonErr)
  putStrLn ""
  putStrLn $ "=== " ++ show passed ++ "/" ++ show total ++ " passed (parse+check) ==="
  putStrLn $ "=== " ++ show uncOk ++ "/" ++ show (length nonErr) ++ " uncompute, "
             ++ show circOk ++ "/" ++ show (length nonErr) ++ " compile to a circuit "
             ++ "(informational -- doesn't affect pass/fail) ==="
  if passed == total
    then putStrLn "All tests passed!"
    else do
      putStrLn "Some tests FAILED."
      exitFailure

-- | Run one file through the pipeline and build its table row.
-- For _error files: if a <name>.expected sidecar file exists, the actual
-- error message must contain the expected substring; otherwise any error
-- suffices. Non-error files that parse+check successfully go on to
-- uncompute and (if that succeeds) circuit compilation, purely to fill in
-- those two columns -- their outcome never changes rowOk/the exit code.
testFile :: FilePath -> IO TestRow
testFile file = do
  let expectError  = "_error" `isInfixOf` file
      base         = take (length file - length ".qurts-core") file
      expectedFile = base ++ ".expected"
  contents <- readFileOrDie file
  case pProgram (myLexer contents) of
    Left err -> return (TestRow file expectError False ("FAIL (parse error: " ++ err ++ ")") StageNA StageNA)
    Right bnfcTree -> do
      let ast = convertProgram bnfcTree
      case checkProgram ast of
        Left err
          | expectError -> do
              mWant <- do exists <- doesFileExist expectedFile
                          if exists then fmap (Just . trim) (readFile expectedFile) else return Nothing
              let got = show err
              return $ case mWant of
                Nothing                          -> TestRow file expectError True "PASS (expected error)" StageNA StageNA
                Just want | want `isInfixOf` got  -> TestRow file expectError True ("PASS (expected: " ++ want ++ ")") StageNA StageNA
                          | otherwise             -> TestRow file expectError False
                                                        ("FAIL (expected \"" ++ want ++ "\", got: " ++ got ++ ")") StageNA StageNA
          | otherwise ->
              return (TestRow file expectError False ("FAIL (unexpected error: " ++ show err ++ ")") StageNA StageNA)
        Right ()
          | expectError ->
              return (TestRow file expectError False "FAIL (expected to fail but succeeded)" StageNA StageNA)
          | otherwise -> do
              -- Re-type-check the uncomputed program before trusting it
              -- enough to compile -- see runPipeline's identical addition
              -- for why: this UNCOMPUTE/CIRCUIT column pair used to report
              -- "OK" off of nothing stronger than "didn't return an error",
              -- the same gap runPipeline had, for the exact same programs.
              -- A re-type-check failure here means Uncompute.hs produced
              -- ill-typed output, so it's reported as an uncompute failure
              -- (circuit was never legitimately reachable), not a circuit one.
              let (uncStage, circStage) = case uncomputeProgram ast of
                    Left err  -> (StageFail err, StageNA)
                    Right unc -> case checkProgram unc of
                      Left err -> (StageFail ("reconstructed program failed to re-type-check (bug in Uncompute): " ++ show err), StageNA)
                      Right () -> case compileProgram unc of
                        Left err -> (StageOK, StageFail err)
                        Right _  -> (StageOK, StageOK)
              return (TestRow file expectError True "PASS" uncStage circStage)

-- | Render the table: FILE, RESULT and UNCOMPUTE are column-aligned, padded
-- to at least their header's own width so "OK"/"-" line up under it;
-- CIRCUIT trails as free text. UNCOMPUTE's width deliberately ignores FAIL
-- messages (only "OK"/"-" -- always short -- feed into it), and RESULT's
-- width does the same for any "FAIL (...)" label: a FAIL reason can be
-- arbitrarily long (e.g. a full TypeError's own show output), and padTo
-- only ever pads up, never truncates, so that one row's CIRCUIT just starts
-- further right instead of every row (including all the plain "PASS" ones)
-- paying column-width tax for the rare long one. Confirmed this matters in
-- practice, not just in theory: TypeChecker.hs's own "not a known classical
-- injection for [c](x)" error message alone is long enough to blow every
-- row in the table out past 500 columns before this exclusion was added.
formatTable :: [TestRow] -> String
formatTable rows = intercalate "\n" (header : sep : map formatRow rows)
  where
    fileW  = maximum (length "FILE"   : map (length . rowFile)  rows)
    lblW   = maximum (length "RESULT" : [ length (rowLabel r) | r <- rows, not ("FAIL" `isPrefixOf` rowLabel r) ])
    uncW   = maximum [length "UNCOMPUTE", length "OK", length "-"]
    header = padTo fileW "FILE" ++ "  " ++ padTo lblW "RESULT" ++ "  " ++ padTo uncW "UNCOMPUTE" ++ "  CIRCUIT"
    sep    = replicate (length header) '-'
    formatRow r = padTo fileW (rowFile r) ++ "  " ++ padTo lblW (rowLabel r) ++ "  "
                  ++ padTo uncW (stageLabel (rowUncompute r)) ++ "  " ++ stageLabel (rowCircuit r)

padTo :: Int -> String -> String
padTo n s = s ++ replicate (max 0 (n - length s)) ' '

trim :: String -> String
trim = f . f
  where f = reverse . dropWhile (`elem` " \t\n\r")
