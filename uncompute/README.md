# uncompute

Automatic uncomputation for qurts-core. Takes a type-checked program and rewrites each `drop x`
into the reversed sequence of operations that produced `x`, in place of the `drop` itself.
Reversal happens exactly where the source wrote `drop` (not the paper's more flexible
pebble-game placement).

## Files

- **GateInverse.hs** — inverse-lookup tables for `EU` (`unitaryInverse`) and `EC`
  (`classicalInverse`). Returns `Nothing` for unrecognised names rather than assuming self-inverse.
- **PrettyAst.hs** — renders an `Ast.hs` `Program` back to qurts-core source, so this pass's
  output can be re-parsed and re-type-checked.
- **TestPrint.hs** — parse → convert → pretty-print → re-check, one file, to stdout.
- **TestUncompute.hs** — same, through the uncomputation pass.
- **UncomputeMain.hs** — batch driver: runs the pipeline over a directory (or one file) and
  writes the files that succeed to an output directory.

## Building and running

    ghc -i. -ibnfc -ibnfc/bnfc-output -iuncompute -itypeChecker uncompute/TestPrint.hs uncompute/PrettyAst.hs typeChecker/AbsQurtsToAst.hs typeChecker/Ast.hs typeChecker/TypeChecker.hs -o uncompute/testprint
    ./uncompute/testprint.exe examples/example_grover_amplified.qurts-core

    ghc -i. -ibnfc -ibnfc/bnfc-output -iuncompute -itypeChecker uncompute/UncomputeMain.hs uncompute/Uncompute.hs uncompute/GateInverse.hs uncompute/PrettyAst.hs typeChecker/AbsQurtsToAst.hs typeChecker/Ast.hs typeChecker/TypeChecker.hs -o uncompute/uncompute-main
    ./uncompute/uncompute-main.exe                              # examples/ -> examples-uncomputed/
    ./uncompute/uncompute-main.exe some-dir some-other-dir
    ./uncompute/uncompute-main.exe examples/example_final.qurts-core out

Per file: `OK <file> -> <outdir>/<file>`, or `SKIP <file>: <reason>`. `_error` files are skipped
silently. Exits 0 regardless of SKIP count — partial coverage is expected, not a failure.

## Coverage

25 of 30 non-`_error` examples uncompute successfully. Handled:

- `EU`/`EC` gate chains on a single tracked value, back to `[0]()`.
- bare renames, `&borrow`s, `copy`/`true`/`false`/`()`/`meas(_)`, pair-destructure of a literal pair.
- a whole pair, when both components are trivially droppable.
- a function parameter whose static type is bool/unit/`&T`/a droppable pair of those.
- `qif`, first version: a qif's own result gets dropped later, and each branch computed it from
  self-contained state (`example_final`, `example_valid`, `example_qif_reversal`).
- function calls, first version: a callee's body is resolved inline, the same way a qif branch
  resolves into its own statements. `renames` translates the callee's parameter names back to
  whatever the caller passed; `planCallCopies` inserts a copy ahead of a call when a later
  reversal needs to reuse a reference the call would otherwise consume. Composition across
  nested calls is recursive by construction (`example_nested_call_reversal` confirms it two
  levels deep).

Not handled:

- A `drop` inside a qif branch (`example_reinitialise`).
- A qif branch (or callee) whose result depends on a reference created *locally* — inside that
  branch or callee — rather than reused from outer scope (`example_grover_amplified`'s `oracle`,
  `example_self_controlled_uncomp`). "Just regenerate the local setup" doesn't work:
  `typ_qif`'s rule ties the reconstructed result's type to the control's own lifetime. A fresh
  lifetime for the regenerated borrow traps the result in local scope; reusing the existing
  outer lifetime leaves the regenerated qubit frozen with no way to reverse it early. This needs
  the paper's split/merge pebble-game machinery (Section 5.1), not a statement-level rewrite.
- Reversing a value whose branches aren't self-contained, or one half of a jointly-computed pair
  while its sibling is still live (`example_cnot_reinit`).

Both of the last two need the same pebble-game machinery — a shared circuit graph tracked across
branches/pairs, not the per-chain `Origin` values this pass uses everywhere else. This is why 5
of 30 examples stay `SKIP`.
