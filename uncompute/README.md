# uncompute

Automatic uncomputation for qurts-core (not part of the parser/type checker):

Takes an already type-checked qurts-core program and (eventually) rewrites each drop x into the reversed sequence of operations that produced x, replacing the drop itself entirely (see "Current coverage" for why no drop needs to remain) — starting with the naive strategy (uncompute as late as possible and simply by inversing all operations in reverse order), not the paper's more general pebble-game strategies, and setting qif aside for now.

## Files

- **GateInverse.hs** — a lookup table for the inverse of a named single-qubit gate as used via EU (bare H(x)-style syntax). Returns Nothing for any gate name it doesn't recognise — deliberately does **not** fall back to assuming self-inverse, since gate names are just uninterpreted text in Ast.hs and guessing wrong would silently generate an incorrect reversal. Only covers EU; EC ([c](x)-style classical injections like not/cnot) needs separate treatment later, since those can be arbitrary user-defined bijections rather than a small fixed gate set.

- **PrettyAst.hs** — the reverse of AbsQurtsToAst.hs: renders an Ast.hs Program back to qurts-core concrete syntax text. Purpose is debugging/understanding and, once the uncomputation pass exists, letting its output be fed straight back through pProgram/checkProgram as a correctness check.

- **TestPrint.hs** — a small standalone smoke test: parses a .qurts-core file, converts to Ast, pretty-prints it, then re-parses and re-typechecks the printed output to confirm. Already ran this on the current 24 examples; currently all of them re-parse and type check even after adding an extra parse-reverse step using PrettyAst.

- **TestUncompute.hs** — single-file smoke test for the uncomputation pass itself: parse, type check, uncompute, pretty-print, then re-parse + re-typecheck the printed output as a round-trip sanity check. Prints everything to stdout; doesn't write files. Good for poking at one file at a time while developing the pass.

- **UncomputeMain.hs** — the batch driver: runs that same parse/check/uncompute/round-trip-check pipeline over every `*.qurts-core` file in a directory (or a single file), and writes the ones that make it through all the way to an output directory as qurts-core source.

## Building and running

From the repo root:


ghc -i. -ibnfc -ibnfc/bnfc-output -iuncompute uncompute/TestPrint.hs uncompute/PrettyAst.hs AbsQurtsToAst.hs Ast.hs TypeChecker.hs -o uncompute/testprint
./uncompute/testprint.exe examples/example_grover_amplified.qurts-core


Prints the pretty-printed program, then reports whether re-parsing and re-typechecking that printed output succeeded.

To build and run the batch driver:


ghc -i. -ibnfc -ibnfc/bnfc-output -iuncompute uncompute/UncomputeMain.hs uncompute/Uncompute.hs uncompute/GateInverse.hs uncompute/PrettyAst.hs AbsQurtsToAst.hs Ast.hs TypeChecker.hs -o uncompute/uncompute-main
./uncompute/uncompute-main.exe                              # examples/ -> examples-uncomputed/
./uncompute/uncompute-main.exe some-dir some-other-dir       # explicit input/output dirs
./uncompute/uncompute-main.exe examples/example_final.qurts-core out  # single file


For each input file it prints one status line:

- `OK    <file> -> <outdir>/<file>` — parsed, type checked, uncomputed, and the uncomputed output re-parsed + re-typechecked cleanly; written out.
- `SKIP  <file>: <reason>` — failed at some stage (parse, type check, the uncomputation pass itself, or the round-trip re-check); nothing is written for that file. Files with `_error` in their name are skipped silently first, since they're not supposed to type check in the first place.

Exits 0 as long as nothing crashed outright — partial coverage (some files SKIPped) is the expected current state of the pass, not a test failure; see "Not built yet" below and each SKIP reason for why.

## Current coverage

Running `uncompute-main` against `examples/` gets **11 of the 19** non-`_error` files uncomputed successfully (see `SKIP` reasons below for the rest). `DefMap`'s `Origin` type (see `Uncompute.hs`) currently traces a `drop x` back through:

- `let`-bound `EU` chains (`H(x)`-style), terminating in `[0]()`.
- `[1]()`: gets a `[not]` flip inserted where the drop used to be — see the note below on why this must be `EC`'s `[not]`, not `EU`'s bare gate syntax.
- bare renames (`let y = x`).
- `&borrow` bindings (`let y = &a x`) — a reference is always droppable (Fig. 6's Drop trait), no gate ever produced it, so this is a no-op.
- pair-destructure of a *literal* pair construction (`let (y0,y1) = p` where `p` was itself bound to `(x0,x1)`) — decomposes into two independently-reversible chains, one per component.
- `copy`/`true`/`false`/`()` — Drop-trait values, also no-ops.

**A real bug was caught and fixed while wiring up `UncomputeMain.hs`**: an earlier version of the reversal logic treated a `[1]()` origin as a no-op base case, identical to `[0]()`. That's wrong — a qubit that's never been flipped away from `|1⟩` is not safe to drop as-is; treating it as such would have silently generated an invalid reversal. Confirmed the fix is real by round-tripping `example_pair.qurts-core` (the only shipped example that exercises this: `drop b` where `b` traces back to `[1]()` via a literal-pair destructure) — the tool now emits `let rev0 = [not](b)` in place of the bare `drop b`, and that output re-parses and re-type-checks.

**No explicit `drop` is emitted at all for the reconstructed value, by design, not as a leftover gap.** The guiding principle: the type checker accepting a program is exactly the statement "a correct uncomputation exists for this program" — so once reversal has produced a variable of the same (already-droppable) type `x` always had, that program *is* a correctly-uncomputed one already, and nothing further needs to be written for the type checker to accept it. Concretely, `TypeChecker.hs`'s `checkBlock` implicitly drops any droppable variable still active at the end of a block (its own comment: "Droppable active variables ... are implicitly dropped at end of scope") — so appending an explicit `SDrop` after the reversal would just be redundant ceremony, not a requirement. This was checked, not assumed: a hand-edited `example_pair.qurts-core` with the trailing `drop` removed after `[not]` still type-checks under `qurts check`. The pass used to append one anyway; that's been removed, so `example_copy_bool.qurts-core`'s trivial case (`drop b2` where `b2 = copy b`, nothing to reverse) now simply has that statement disappear entirely, and `example_pair.qurts-core` ends in `let rev0 = [not](b) ; a` with no drop of `rev0` at all.

**Why the fix-up flip has to be `EC`'s `[not]`, not `EU`'s bare gate syntax (also verified empirically, not just reasoned about)**: `EU` requires its argument to be *exactly* `#⊥ qbit` and returns `#⊥ qbit` again (`expr_unitary` in TypeChecker.hs), and `canDrop` refuses `#⊥` unconditionally (`⊥` is never active). The only way out would be an `x as #𝔞 qbit` cast to widen it back to something droppable, but `isSubtype`'s `subty_shorten` rule for `#𝔠 T ≤ #𝔟 T` requires `𝔟 ≤ 𝔠`, i.e. widening `#⊥` to `#⊤` needs `⊤ ≤ ⊥`, which `leq` never grants. Confirmed directly: `x0 as #bot qbit ; let x1 = H(x0) ; x1 as #top qbit ;` fails with `TypeMismatch (TyBang LTop TyQBit) (TyBang LBottom TyQBit)` under `qurts check`. So a bare-`EU` chain can never actually reach a `drop` in any type-checked program — the `EU` branch of `reverseFrom` exists for chains that pass *through* `H(x)` on the way to somewhere else already-droppable, not for reaching droppability in the first place. `EC`'s typing rule (`expr_lifted`) instead preserves whatever lifetime the argument already has (`TyBang a TyQBit -> TyBang a TyQBit` for *any* `a`), so `[not](x)` can be applied directly to an already-droppable `#⊤`/`#𝛼` qubit with no cast dance at all — which is exactly the situation a `[1]()` sitting under an active lifetime is in.

**A second real bug was caught the same way, by actually reading the output rather than trusting the `OK`/`SKIP` count**: `uncomputeStmts` only ever walked the function body's *top-level* statement list. A `drop` sitting inside a qif/if branch's own nested block (not a top-level `drop` of a qif's *result* — an actual `drop` statement written inside one of the branches, like `example_reinitialise.qurts-core`'s `drop x` inside its qif's true-branch) was never looked at, and the pass would report the whole file `OK` and write it out completely unchanged, `drop` and all — a false positive, not a real success. Fixed by having `uncomputeStmts` check every non-drop statement for a nested `drop` (recursing through `EQIf`/`EIf` branch blocks) and fail loudly if it finds one, instead of silently skipping past it. This flipped `example_reinitialise.qurts-core` from a false `OK` to an honest `SKIP` (qif, same root cause as the other qif failures below) — coverage dropped from 12/19 to 11/19 as a result, which is the correct direction: fewer files, but every remaining `OK` is now one the pass actually looked at in full, not just at the top level.

## Bugs found in a follow-up audit (worse than the ones above: silently wrong, not loudly rejected)

Asked to double-check the pass for more mistakes, rather than take the existing `OK`/`SKIP` split at face value. Both of these produce a *type-checking, `OK`-reported* program that is nonetheless semantically wrong — the most serious class of bug for this project, since the whole point is that `drop` being physically safe can't be read off the type alone.

- **Stale name resolution (silently skips a needed reversal).** The chain-following logic (`EVar`/`EU`/pair-destructure) used to be *lazy*: it stored the raw source `Expr` and re-looked-up referenced variable names by their *current* (latest) binding, only at the moment a `drop` actually needed them. But `EVar`/`EU`/`EC` all consume (free) the name they reference (`TypeChecker.hs`'s `removeVar`), so qurts-core legally allows that name to be *rebound* to something unrelated before the eventual `drop`. Concretely:

  ```
  let x = [1]() ; let y = x ; let x = [0]() ; drop x ; drop y ;
  ```

  `y` genuinely holds the old, never-flipped `|1⟩` value. The lazy version resolved `y`'s chain through *whichever* binding of `"x"` was live at `drop y`'s position — the fresh `|0⟩` one — and concluded, wrongly, that `drop y` needed no reversal at all. It silently discarded a never-flipped qubit and reported `OK`. Verified with the exact program above: the old pass emitted `drop y` unchanged (i.e. nothing). Same hazard existed for pair components (`let p = (x0,x1) ; let x1 = [0]() ; let (a,b) = p ; drop b`) since destructuring used the same lazy name lookup.

  Fixed by making `Origin` (formerly a thin wrapper around a raw `Expr`) *eagerly* resolved: `resolveExpr`/`resolveVar` chase through renames, gates, and literal-pair components immediately, at the point a binding is recorded, using only the bindings in effect *then*. The result is a self-contained value with no variable names left to look up later, so no subsequent rebinding of that name can affect it. Re-verified both hazard programs above: `drop y` / `drop b` now correctly produce `let rev0 = [not](y)` / `let rev0 = [not](b)`.

- **Generated names can collide with real ones (also silent, or a spurious rejection).** The fix-up/reversal steps this pass inserts are named `rev0`, `rev1`, ... by an incrementing counter, with no check against what the *source* program itself already calls things. `TypeChecker.hs`'s `insertVar` has no protection against rebinding — it unconditionally overwrites whatever was bound to a name — so if a real program happens to declare its own `rev0` anywhere in the same function, this pass's generated `rev0` would silently clobber it (or vice versa, depending on write order), corrupting whatever the user's `rev0` was for. Verified with:

  ```
  fn f < | > () -> # top bool {
      let x = [0]() ; let y = [1]() ; let p = (x, y) ; let (a, b) = p ;
      let rev0 = true ;
      drop a ; drop b ;
      rev0
  }
  ```

  The user's `rev0 : bool` is meant to be the return value; the pass's own generated `rev0` (from reversing `b`) silently overwrote it with a qubit. This particular case was caught downstream by the round-trip re-type-check (`ReturnTypeMismatch`) rather than passing through undetected — but that's `UncomputeMain.hs`/`TestUncompute.hs` acting as a safety net, not the pass itself being correct, and a differently-shaped collision could plausibly still type-check by accident. Fixed by collecting every variable name bound anywhere in the function (parameters, plus every `let`/`&borrow`/pair-destructure target, including inside nested qif/if branches — see `boundVarsStmt`) before reversal starts, and having `freshVar` skip any candidate name already in that set. Re-verified: the program above now correctly produces `rev1` instead of `rev0`, leaving the user's `rev0` untouched.

Neither of these showed up in the 19-example suite (none of them happen to rebind a name mid-chain or declare a `revN`-shaped variable) — both were found by deliberately constructing the adversarial case and running it through the real pipeline, the same way the `[1]()` and nested-qif-drop bugs above were found. Coverage of `examples/` is unchanged at 11/19 either way; these fixes are about not silently mishandling programs the existing suite doesn't happen to exercise.

## Cross-checked against the paper (arXiv:2411.10835, "Qurts: Automatic Quantum Uncomputation by Affine Types with Lifetime", Hirata & Heunen — `qurts.pdf` in the repo root)

Re-read the paper specifically for Fig. 6's Drop trait and the worked examples in Section 3.1, to check for gaps this pass's own test suite wouldn't surface — twice now (see below for a third finding from a second pass). All three are traceable directly to Drop-trait rules the pass wasn't applying in full generality. None show up as a coverage-count change (still 11/19) since none of the 24 shipped examples happen to exercise them — each was found by writing the case the paper's rule implies should work, and checking it against the real pipeline.

- **`drop_tuple` (Fig. 6): `T0:Drop, T1:Drop ⊢ T0×T1:Drop`.** A tuple is droppable whenever *both* components are, independent of any gate history — dropping `(x, y)` should be exactly as trivial as dropping `x` and `y` separately would be, when both individually need no reversal. `reverseOrigin`'s `FromPair` case previously refused *every* whole-pair drop unconditionally, on the theory that a pair always needs "split apart, reverse each half independently" treatment. That's only true when a component actually needs real reversal work (which does require destructuring first, since `EU`/`EC` apply to a named qubit, not "half of variable `p`"); when both halves are already trivial, refusing was needlessly conservative. Fixed with an `isTriviallyDroppable` check (true for `FromInit0`/`FromTrivial`/`FromBorrow`, and recursively for `FromPair` of such) that lets the whole-pair case succeed as a no-op when it applies. Verified both directions: `let p = (x, y) ; drop p` with `x` from `[0]()` and `y : bool` — previously `SKIP`ped, now correctly `OK` with the `drop p` line gone; and `let p = (x, y) ; drop p` with `x` from `[0]()` and `y` from `[1]()` (needs real reversal, can't be done without destructuring first) still correctly `SKIP`s, confirming the fix didn't overreach.

- **Bare-parameter drops weren't tracked at all.** The paper's own canonical `forget` example (Section 3.1, "Dropping variables": `fn forget<'a!='0>(x: #'a qbit) { drop x; }`) drops a function parameter directly, no local `let` in between. `DefMap` was only ever populated from `SLetExpr`/`SLetRef`/`SLetPair` targets — a parameter's name was *never* recorded, so `drop b` on a plain `bool`/`unit`/`&T` parameter (unconditionally droppable per Fig. 6, no lifetime tracking needed to know that) was reported as an untraceable chain, identical to how a genuinely-unknowable parameter is reported, even though it needs zero reversal. (The paper's own `forget` example still isn't handled after this fix — `#'a qbit` droppability depends on whether `'a` is active at the drop site, which requires lifetime-state tracking this pass doesn't do, so a bare qubit parameter is correctly left untracked rather than guessed at.) Fixed by seeding `DefMap` from the function signature: any parameter whose *static* type is bool/unit/`&T`/a droppable pair thereof gets a trivial `Origin` up front, via a new `staticallyDroppableOrigin :: Type -> Maybe Origin`. Verified: `fn f(b: bool) -> #top qbit { drop b; [0]() }` — type-checked before, `SKIP`ped before this fix, now correctly produces `OK` with the `drop b` line gone.

- **`meas(x)` conflated "measurement can't be reversed" with "its output needs reversal before dropping."** `expr_measure`'s typing rule fixes `meas(x)`'s result type to *exactly* `#⊤bool`, unconditionally, regardless of what was measured or what happened to `x` beforehand — so a variable bound to `meas(x)` is exactly as trivially droppable as a literal `true`/`false`, by the same `drop_bool` rule, no different treatment needed. `resolveExpr` had no case for `EMeas`, so it fell to the generic `FromUnhandled` bucket and got the message "not reversible at all, not just unsupported" — true about recovering the *pre-measurement qubit*, but a non-sequitur about whether the *resulting bool* needs reversal (it never does). Fixed by giving `EMeas` its own `resolveExpr` case returning `FromTrivial`, same as `ETrue`/`EFalse`/`ECopy` (which is sound for the same underlying reason `ECopy` already was: `EMeas`'s result type is always classical, so there's no no-cloning/dirty-state concern regardless of provenance). `describeExpr`'s now-unreachable `EMeas` case was removed, same as `EPair`'s was when it got its own `FromPair` treatment earlier. Verified: `let x1 = H(x) ; let y = meas(x1) ; drop y` — previously `SKIP`ped with a misleading "not reversible" message, now correctly `OK` with the `drop y` line gone.

**One more candidate found, not implemented — flagging for a decision rather than silently building it.** A function call whose *declared return type* is bool/unit is, by the same `drop_bool`/`drop_unit` reasoning as above, trivially droppable regardless of what the callee's body does — this is a different, much narrower question than "reversing a call" (undoing whatever qubit-producing effect the callee had), which is a genuinely large separate feature. But acting on it requires threading a whole-program `FuncName → return-type` environment through `resolveExpr`/`recordBinding`/`uncomputeStmts`/`uncomputeBlock`/`uncomputeFunction`/`uncomputeProgram` (currently each function is processed independently, with no visibility into other functions' signatures) — a meaningfully bigger, more invasive change than the three above, and not motivated by any of the 24 shipped examples (none call a function returning bool/unit and then drop the result) or by an explicit paper rule the way `EMeas`'s fixed return type was (it's an inference from combining `expr_function`'s generic return type with Fig. 6, not a rule the paper states directly). Didn't implement it without checking first.

## Not built yet

- **qif** (`example_final`, `example_reinitialise`, `example_self_controlled_uncomp`, `example_valid`) — needs the paper's split/merge pebble-game rule; a genuinely separate, substantial piece of the algorithm, not attempted here. This now includes drops nested inside qif branches, not just top-level drops of a qif's result (see above).
- **Function calls** (`example_grover*`, all via the `phase` callee) — reversing a call means the callee's own body must be reversible too (presumably restricted to purely-quantum functions, which `TypeChecker.hs` already has the `isPurelyQuantumExpr`/`isPurelyQuantumBlock` machinery to identify) and then inlining/splicing its reversed body at the call site. Not attempted here.
- **`EC` applied to anything other than fixing up a bare `[1]()`** (`example_cnot_reinit`'s `drop x2`, where `x2` comes from destructuring `res = [cnot](p)` — not a literal pair, so `recordBinding` can't decompose it) — `GateInverse.hs` only has an inverse table for `EU`'s small fixed gate set; `EC`'s classical injections (`not`, `cnot`, ...) can be arbitrary user-defined bijections, so a real fix needs its own inverse mechanism, plus logic for reversing one half of a jointly-transformed pair while its sibling stays live. Harder than the `EU` case and not attempted here.

These three are the reason the last 8 of 19 examples stay `SKIP`; each is a genuine algorithmic feature (not a plumbing gap), so tackling them is a separate decision from what this pass/driver already does.
