Lexer and parser: see bnfc/readme.txt.

Build:

ghc -ibnfc -ibnfc/bnfc-output -iuncompute -icircuit -itypeChecker Main.hs typeChecker/AbsQurtsToAst.hs typeChecker/Ast.hs typeChecker/TypeChecker.hs uncompute/Uncompute.hs uncompute/GateInverse.hs uncompute/PrettyAst.hs circuit/Circuit.hs -o qurts

AbsQurtsToAst.hs converts bnfc's generated parse tree into Ast.hs's own syntax, which follows the paper.

Usage:

.\qurts <flags> examples\example_***.qurts-core

no flags     full pipeline (parse, check, uncompute, circuit); prints the circuit as a Qiskit
             diagram (needs python+qiskit on PATH; falls back to the raw IR otherwise)
-v           full pipeline, pretty-printed output after every step
-simulate    full pipeline; also runs the compiled circuit on Aer (1000 shots) and prints its
             outcome distribution (needs qiskit-aer too; see circuit/README.md)
-parse       parse only
-check       parse and type check
-uncompute   parse, check, uncompute; writes the result to examples-uncomputed/
-test        full pipeline over every *.qurts-core file in a directory, as a table

Files with _error in their name are expected to fail type-checking; everything else must succeed
at parse+check -- that's what -test's pass/fail and exit code track. The UNCOMPUTE/CIRCUIT columns
are informational (known gaps, not regressions) -- see uncompute/README.md and circuit/README.md.

TODO

Uncomputation pass (uncompute/Uncompute.hs) -- the real gap. Everything else builds on a naive
per-statement rewrite; what's missing is the paper's split/merge pebble game (Section 5.1):
splitting a pebble on the qif control into |0>/|1>-guarded fragments and merging them back, so a
drop can be reversed even when it's nested inside a qif branch, depends on a reference created
locally inside that branch/callee, or needs one half of a jointly-computed pair while the other
half is still live. This is what's blocking 5 of 30 examples (see uncompute/README.md).

Circuit backend (circuit/) -- smaller gaps on top of an otherwise complete compiler:
- circuit correctness is currently checked by hand-picked spot simulations (Bell state, Toffoli
  truth table, Grover peak at |111>, ...), not an automated regression suite that simulates every
  compiled example and checks its output distribution.
- simulation of output circuits can be added if we want that

Type checker: audited rule-by-rule against every typing judgement in the paper (Figs. 5-8,
13-17), not just spot-checked. Found and fixed several real gaps along the way -- most
notably, `let`-rebinding a still-live name used to silently discard it with no error at all
(a genuine "invalid discard", Definition 2.1), and several of Section 3.2.1's own lifetime
well-formedness assumptions (a lifetime variable can't be reused after ending, a function can't
end one of its own external generic lifetimes, the lifetime preorder must be identical before
and after a block) went entirely unchecked. Two remaining questions came out of that audit where
the paper's own formal rule looks stricter than what its own multi-function Grover example
actually needs (qif's two branches, and stmt_borrow's own external-lifetime restriction) --
see kengo.txt for the details; not fixed since it's not yet clear which side of that gap is
"wrong". The core syntax (Fig. 3) and full subtyping lattice (Fig. 13 -- shorten, reborrow,
double-affine, borrow-affine, affine-borrow, tuple, unit) are otherwise implemented and exercised
by the examples. Loops, recursion, mutable variables, and algebraic data types are explicitly out
of scope -- the paper itself lists them as not present in Qurts-core (Section 7, future work).
Same for full Qurts's sugar layer (automatic lifetime/copy/drop inference): the paper treats that
as a separate future compiler; this project targets Qurts-core, the explicit core calculus.
