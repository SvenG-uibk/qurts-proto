Lexer and parser: see bnfc/readme.txt (shouldn't normally need changes).

Build:

ghc -ibnfc -ibnfc/bnfc-output -iuncompute -icircuit -itypeChecker Main.hs typeChecker/AbsQurtsToAst.hs typeChecker/Ast.hs typeChecker/TypeChecker.hs uncompute/Uncompute.hs uncompute/GateInverse.hs uncompute/PrettyAst.hs circuit/Circuit.hs -o qurts

bnfc generates its own Ident-wrapped/split types and constructor names; AbsQurtsToAst.hs (in typeChecker/) converts those into Ast.hs's own syntax, which follows the paper closely.

Usage:

.\qurts <flags> examples\example_and.qurts-core

no flags   --full pipeline (parse, check, uncompute, circuit); prints the resulting circuit
             as an actual Qiskit diagram (shells out to `python circuit/build_circuit.py`,
             needs python+qiskit on PATH; falls back to the raw IR if that's unavailable)
             might need to run "chcp 65001" once per session (windows) for circiut representation
-v         --full pipeline; pretty-printed output after every step
-parse     --parse only
-check     --parse and type check
-uncompute --parse, check, uncompute; writes the re-translated source to examples-uncomputed/
-test      --run the full pipeline over every *.qurts-core file in a directory, printed as a
             table (FILE / RESULT / UNCOMPUTE / CIRCUIT); needs an input directory

Files with _error in their name are expected to fail type-checking; all others must succeed at
parse+check -- that's what `-test`'s PASS/FAIL and exit code are keyed on. The UNCOMPUTE and
CIRCUIT columns (OK / FAIL: <reason> / - not attempted) are informational: partial uncompute/
circuit coverage is documented, expected scope, not a regression, so it doesn't affect PASS/FAIL
or the exit code. See uncompute/README.md and circuit/README.md for what's covered and why.
