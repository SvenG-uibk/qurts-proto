# uncompute

Automatic uncomputation for qurts-core (not part of the parser/type checker):

Takes an already type-checked qurts-core program and (eventually) rewrites each drop x into the reversed sequence of operations that produced x, followed by a drop of the now |0⟩ qubit — starting with the naive strategy (uncompute as late as possible and simply by inversing all operations in reverse order), not the paper's more general pebble-game strategies, and setting qif aside for now.

## Files

- **GateInverse.hs** — a lookup table for the inverse of a named single-qubit gate as used via EU (bare H(x)-style syntax). Returns Nothing for any gate name it doesn't recognise — deliberately does **not** fall back to assuming self-inverse, since gate names are just uninterpreted text in Ast.hs and guessing wrong would silently generate an incorrect reversal. Only covers EU; EC ([c](x)-style classical injections like not/cnot) needs separate treatment later, since those can be arbitrary user-defined bijections rather than a small fixed gate set.

- **PrettyAst.hs** — the reverse of AbsQurtsToAst.hs: renders an Ast.hs Program back to qurts-core concrete syntax text. Purpose is debugging/understanding and, once the uncomputation pass exists, letting its output be fed straight back through pProgram/checkProgram as a correctness check.

- **TestPrint.hs** — a small standalone smoke test: parses a .qurts-core file, converts to Ast, pretty-prints it, then re-parses and re-typechecks the printed output to confirm. Already ran this on the current 24 examples; currently all of them re-parse and type check even after adding an extra parse-reverse step using PrettyAst.

## Building and running

From the repo root:


ghc -i. -ibnfc -ibnfc/bnfc-output -iuncompute uncompute/TestPrint.hs uncompute/PrettyAst.hs AbsQurtsToAst.hs Ast.hs TypeChecker.hs -o uncompute/testprint
./uncompute/testprint.exe examples/example_grover_amplified.qurts-core


Prints the pretty-printed program, then reports whether re-parsing and re-typechecking that printed output succeeded.

## Not built yet

- The actual uncomputation pass (walking the def-map backward from each drop, generating the reversed statement sequence, splicing it in).
- qif handling (the paper's split/merge pebble-game rule).
