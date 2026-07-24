# uncompute

Automatic uncomputation for qurts-core (not part of the parser/type checker). Takes an already type-checked program and rewrites each `drop x` into the reversed sequence of operations that produced `x`, in place of the `drop` itself — no trailing `drop` is emitted, since `TypeChecker.hs`'s `checkBlock` already implicitly drops any droppable variable still active at the end of a block, so once the reversed value has the same droppable type `x` always had, nothing further needs writing. Naive strategy only: reversal happens exactly where the source already wrote `drop` (not the paper's more flexible pebble-game placement), and `qif` is set aside entirely.

## Files

- **GateInverse.hs** — inverse-lookup tables: `unitaryInverse` for `EU` (bare `H(x)`-style gates: `I`, `X`, `Y`, `Z`, `H`, `S`/`Sdg`, `T`/`Tdg`) and `classicalInverse` for `EC` (`[c](x)`-style lifted classical injections: `not`, `cnot`, `swap`, `Z`, all self-inverse). Both return `Nothing` for unrecognised names rather than assuming self-inverse — names are uninterpreted text, and a gate/injection can be arbitrary.
- **PrettyAst.hs** — the reverse of `AbsQurtsToAst.hs`: renders an `Ast.hs` `Program` back to qurts-core source, so this pass's output can be fed straight back through `pProgram`/`checkProgram`.
- **TestPrint.hs** — smoke test: parse → convert → pretty-print → re-parse/re-typecheck one file, to stdout.
- **TestUncompute.hs** — same pipeline through the uncomputation pass itself (parse → check → uncompute → pretty-print → re-parse/re-typecheck), one file, to stdout.
- **UncomputeMain.hs** — batch driver: runs that pipeline over every `*.qurts-core` file in a directory (or a single file) and writes the ones that succeed to an output directory.

## Building and running

    ghc -i. -ibnfc -ibnfc/bnfc-output -iuncompute uncompute/TestPrint.hs uncompute/PrettyAst.hs AbsQurtsToAst.hs Ast.hs TypeChecker.hs -o uncompute/testprint
    ./uncompute/testprint.exe examples/example_grover_amplified.qurts-core

    ghc -i. -ibnfc -ibnfc/bnfc-output -iuncompute uncompute/UncomputeMain.hs uncompute/Uncompute.hs uncompute/GateInverse.hs uncompute/PrettyAst.hs AbsQurtsToAst.hs Ast.hs TypeChecker.hs -o uncompute/uncompute-main
    ./uncompute/uncompute-main.exe                              # examples/ -> examples-uncomputed/
    ./uncompute/uncompute-main.exe some-dir some-other-dir       # explicit input/output dirs
    ./uncompute/uncompute-main.exe examples/example_final.qurts-core out  # single file

Per file: `OK <file> -> <outdir>/<file>` (parsed, checked, uncomputed, round-trip re-verified, written), or `SKIP <file>: <reason>` (nothing written). Files with `_error` in their name are skipped silently. Exits 0 regardless of `SKIP` count — partial coverage is expected, not a failure.

## Current coverage

12 of the 20 non-`_error` examples uncompute successfully (run the tool for per-file `SKIP` reasons). `Uncompute.hs`'s `DefMap`/`Origin` traces a `drop x` back through:

- `let`-bound `EU` chains (`H(x)`-style) and `EC` chains (`[not](x)`-style, names in `classicalInverseTable`) on a single already-tracked value, terminating in `[0]()` (see `example_ec_reversal.qurts-core`).
- `[1]()` — gets a `[not]` flip inserted via `EC`, not `EU` (see `example_pair.qurts-core`): `EU` is pinned to exactly `#⊥ qbit` in and out, and `#⊥` can never be widened back to a droppable type, so it can never itself reach a `drop`; `EC` preserves whatever lifetime the argument already has, so it can.
- bare renames, `&borrow` bindings, `copy`/`true`/`false`/`()`/`meas(_)` results, and pair-destructure of a *literal* pair construction — all Drop-trait (Fig. 6), no reversal needed.
- a whole (non-destructured) pair, when both components are themselves trivially droppable (Fig. 6's `drop_tuple`).
- a function parameter whose *static* type is bool/unit/`&T`/a droppable pair thereof (no lifetime tracking needed to know that; a bare qubit parameter is left untracked, since that depends on lifetime activity this pass doesn't track).

Not covered: reversing one half of a jointly-computed pair while its sibling is still live (e.g. `[cnot](p)` then dropping only one of its two destructured outputs — `example_cnot_reinit`). This isn't a smaller version of the `EC` case above: a 2-qubit entangling gate's two outputs aren't independently reversible, so this needs the same split/merge pebble-game reasoning `qif` does (the paper's Section 5.1 `split` rule is used for exactly this), and is bucketed with qif's future work rather than treated separately.

`Origin` resolves eagerly — at the point each binding is recorded, not by looking a name up again later — and `freshVar` avoids every name already bound anywhere in the function. Both are load-bearing for correctness, not just style: qurts-core frees a name for reuse once it's consumed (`EVar`/`EU`/`EC` all call `removeVar`), so a lazy, name-keyed lookup or an unchecked fresh-name counter can silently produce wrong output on programs that rebind a name or already use a `revN`-shaped name.

## Not built yet

- **qif** — needs the paper's split/merge pebble-game rule; a separate, substantial piece of the algorithm. Covers both drops nested inside qif branches and reversing one half of a jointly-computed pair (see above).
- **Function calls** — reversing a call means the callee's body must be reversible too (presumably restricted to purely-quantum functions, which `TypeChecker.hs`'s `isPurelyQuantumExpr`/`isPurelyQuantumBlock` already identifies) and inlining the reversed body at the call site. Deprioritized: the only examples that need it (`example_grover*`, via `non_zero`/`oracle`) are themselves built entirely out of `qif`, so this can't show progress until qif exists anyway.

These two are why the remaining 8 of 20 examples stay `SKIP`.
