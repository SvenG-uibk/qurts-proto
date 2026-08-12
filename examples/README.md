# Qurts-core Examples

Run a single example:

.\qurts -check examples\<filename>.qurts-core

Or through the full pipeline (parse, check, uncompute, compile to a circuit):

.\qurts examples\<filename>.qurts-core

Run all examples at once:

.\qurts -test examples

Files with _error in their name are expected to fail type-checking; everything else is expected
to succeed. `-test` exits non-zero if any result is unexpected. See the root readme.txt for the
full command list.

## Valid Examples

### example_and.qurts-core
Section 3.1, p. 9 — boolean AND via nested qif on two `&α qbit` references, returning an owned
`#α qbit`.

### example_bell.qurts-core
Bell pair: `H` on one qubit, then a qif-based CNOT (`[X]` under a borrowed control) onto a second,
returning both as a pair.

### example_valid.qurts-core
Section 3.1, p. 10 — borrows `p` under a fresh `α`, flips an ancilla `q` with qif, drops `q`,
ends `α`, applies `H` to `p`. The full borrow/uncompute/endlft cycle.

### example_final.qurts-core
Section 3.1 p. 12 and Section 4.2 p. 18 — the paper's central running example, used for the full
typing derivation.

### example_my_cnot.qurts-core
Section 3.1, p. 11 — `my_cnot(x, y)`: `x: &α qbit` as control, `y: #α qbit` as target; `qif x`
negates or passes `y` through. qif consuming an existing owned qubit rather than allocating a
fresh one.

### example_forget.qurts-core
Section 3.1, p. 12 — `forget(x)` takes `#α qbit`, returns `()`; `x` is dropped implicitly by
block cleanup since `α` is active. `#α qbit` is affine.

### example_reinitialise.qurts-core
Section 3.1, p. 12 — `reinitialise(x, y)`: `qif y` either drops `x` and returns a fresh `|0⟩`, or
returns `x` unchanged. `drop` is legal inside a qif branch; the two branches (`#⊤ qbit`,
`#α qbit`) unify via subtyping.

### example_pair.qurts-core
Pair typing rules (Fig. 15–17) — allocates two qubits, pairs them, destructures the pair, drops
one half, returns the other.

### example_call.qurts-core
Function call typing (Fig. 16, typing_call) — a helper `nott` applies `[X]` and returns;
`example_call` calls it. Multi-function programs, `as` coercion.

### example_if.qurts-core
Classical conditional typing (Fig. 16, typing_if) — a bool parameter selects one of two `#⊤ bool`
values via classical `if`.

### example_if_dynamic.qurts-core
Classical `if` on a *dynamic* (measured) condition — not a paper example, targets circuit/'s
`if_test` compilation path. Measures a Hadamard'd qubit into `b`, then classically flips a second
qubit iff `b` measured 1. Fixed two `checkExpr (EIf ...)` gaps to get this past the type checker
(condition must accept `#⊤bool`, not bare `bool`; the condition variable must be restored after,
same as qif does for its own control). Simulation confirms `b` and the flipped qubit always agree.

### example_copy.qurts-core
Copy typing (Fig. 16, typing_copy) — copies a reference `&α qbit`, drops the copy, reuses the
original as a qif control. References are Copy.

### example_copy_bool.qurts-core
Copy typing (Fig. 16, Fig. 14) — copies a bool, drops the copy, returns the original.

### example_copy_alias.qurts-core
Two references `y`/`z`, both `copy`d from the same `x`, passed into a Toffoli that reads all
three — exercises `Circuit.hs`'s alias-normalization (two qurts-core variables resolving to the
one physical qubit).

### example_leq.qurts-core
Subtyping, subty_shorten (Fig. 13) — `&α T ≤ &β T` when `β ≤ α`. Copies `x: &α qbit`, coerces
the copy to `&β qbit` via `as`.

### example_borrow_affine.qurts-core
Subtyping, subty_borrow_affine (Fig. 13) — borrows an owned `#⊥ qbit` under `γ`, coerces the
resulting `&γ (#⊥ qbit)` down to `&γ qbit` via `as`, then passes it to a function expecting
exactly that. Regression test for a bug where `isSubtype` demanded an extra (paper-unjustified)
condition on the discarded inner lifetime, rejecting this.

### example_meas_any_lifetime.qurts-core
`typ_meas` (Fig. 5) — measures a `#⊤ qbit` (straight off `[0]()`) with no coercion first.
Regression test for a bug where `meas`/`U(x)` wrongly required exactly `#⊥ qbit` as input, instead
of `#𝔞 qbit` for any `𝔞` as the paper's rule actually allows.

### example_lifetime_transitivity.qurts-core
`typ_fn` (Fig. 8) — declares `alpha <= beta, beta <= gamma` (never `alpha <= gamma` directly) and
coerces a `#gamma qbit` down to `#alpha qbit`, which needs exactly that derived relation.
Regression test for a bug where `leq` only checked direct membership in the declared constraint
set, never its transitive closure, though Fig. 8 explicitly builds A as "the smallest preorder...
including" those constraints.

### example_cnot_reinit.qurts-core
Kengo's qif example from Section 5.1. Type-checks fine — the difficulty is in uncomputation:
dropping one half of a `[cnot]`-produced pair while the other half is still live needs the
split/merge pebble-game machinery, not handled yet (see uncompute/README.md).

### example_self_controlled_uncomp.qurts-core
From Kengo's email, not in the paper:

    // x, y: #'a qbit
    let (x, y) = [some classical circuit](x, y);
    newlft 'b (< 'a)
    let y: #'b qbit = qif (&'b x) { y } else { drop(y); |0> }

Uncomputing `drop y` means reversing a qif controlled by `x`, which itself came from the cnot —
the reverse circuit would need to be self-controlled. Same pebble-game gap as
`example_cnot_reinit`.

### example_section6_f.qurts-core
Section 6 — `f(mut x: qbit) -> (qbit, #'static qbit)` translated to qurts-core. Applies `H` to
`x` (making it linear, `#⊥ qbit`) and produces a fresh `|0⟩` with static lifetime (`#⊤ qbit`);
returns both. Mixes linear and always-affine qubits in one return type.

### example_grover.qurts-core
Fig. 2 + Appendix A — Grover's algorithm for 3 qubits, marked solution (`|111⟩`) hardcoded as a
truth table (`oracle`, `non_zero`) rather than a generic oracle; a direct phase oracle (`[Z]` on
a search qubit, no ancilla). Simulates to ~94.5% on `|111⟩` over 2000 shots. `&mut qbit` params
become owned `#⊥ qbit` mutated by shadowing; the loop is manually unrolled. `oracle`/`diffusion_phase`
declare `-> #bot qbit` (not `#alpha`): their own qif branches mix a `#bot`-tagged value with an
untouched one, and `#bot` is the most precise type the automatic lifetime-intersection (`grover.txt`
point 9) can derive there — matches what their own call sites were already narrowing down to
immediately afterward anyway.

### example_grover2.qurts-core
Same algorithm, via the textbook `|−⟩` phase-kickback ancilla instead: a dedicated qubit prepared
in `|−⟩` (via bare `H`, which forfeits its own droppability), XORed against by the oracle, and
disposed of with `meas` rather than `drop` (its own state is never touched by a diagonal phase, so
nothing needs uncomputing). Simulates to ~938/1000 on `|111⟩`. `kickback_and`/`kickback_all_zero`
declare `-> #bot qbit`, same reason as `example_grover.qurts-core`'s `oracle` above.

### example_grover_original.qurts-core
Reconstructed from git history — the paper's own ancilla/phase/drop encoding (temporary boolean
ancilla, phased via a rebind through `[Z]`, then `drop`ped). Briefly gave a *uniform* distribution
while the diagonal-gate skip was removed (full/faithful reversal correctly cancels its own phase
kickback along with everything else) — kept during that period specifically to demonstrate that
was still legal, if pointless. Now that the skip is reinstated (see
`uncompute/GateInverse.hs`'s module note), `drop tmp`'s `[Z]` is correctly left un-reversed again,
and this simulates back to a peak at `|111⟩` (~941/1000), matching the paper's own construction.

### example_diagonal_skip_counterexample_error.qurts-core
Not from the paper — the counterexample that originally motivated removing the diagonal-gate
uncompute skip (see `uncompute/GateInverse.hs`'s module note), now kept as a regression test for
the type-checker fix it led to. Puts a control qubit `c` in superposition (`H`), then `qif`s on
it: one branch runs `H` then `Z` on a fresh ancilla, the other branch does nothing. Used to
type-check — `typ_qif`'s own retagging accepted a `#⊥`-tagged branch (produced by the bare-EU
`H`/`Z` chain) merged against a `#⊤`-tagged sibling via an ad hoc subtyping search that Fig. 15's
actual `EXPR QUANTUM IF` rule never licenses (it requires the *literal same* `T` from both
branches, exactly like `EXPR CLASSICAL IF` beside it) — and, with the diagonal skip reinstated,
that let the `drop` silently leave the ancilla entangled with `c` (measuring `H(c)` afterward came
out ~50/50 instead of deterministic, an invalid discard, Definition 2.1). `checkExpr (EQIf ...)`
(`TypeChecker.hs`) now infers the *intersection* of the two branches' lifetimes automatically
(mirroring Rust's own if/else lifetime inference — `grover.txt` point 9) rather than requiring a
literal match, so the qif itself now type-checks (`meet(⊥,⊤) = ⊥`, the most precise type actually
derivable) — but the subsequent `drop result;` still correctly fails, with `CannotDrop (TyBang
LBottom TyQBit)`: `#⊥` is never active (`canDrop`'s own `drop_own` rule), so it was never droppable
regardless of this qif change. A more precise rejection than the earlier `TypeMismatch`, at exactly
the point droppability is actually claimed rather than at the qif itself — see `grover.txt` points
8–9 for the full history.

### example_grover_amplified.qurts-core
Not from the paper — amplitude amplification (Brassard–Høyer–Mosca–Tapp 2000): iteration count
derived from the number of marked solutions (M=2 here, so 1 iteration, not the paper's fixed 2).
`oracle` is built clause by clause (`clause_or2`, `clause_nand2`, `clause_unit`, `all_satisfied3`)
since qif can't return a reference (Fig. 7 excludes booleans/references from Purely Quantum), so
each clause needs its own function call. Ends by measuring and returning three bools.

### example_grover_amplified2.qurts-core
`example_grover_amplified` extended to 4 qubits, a unique solution of a 6-clause formula, needing
3 iterations. Two more clause helpers (`clause_impl`, `clause_or2_neg_second`).

### example_ec_reversal.qurts-core
Targets uncompute/'s EC reversal, not a language feature. Initializes a qubit at `|0⟩`, flips it
twice via `[X]`, drops it — exercises `Uncompute.hs`'s `FromClassicalGate` chain recursing
through two applications, not just one.

### example_qif_reversal.qurts-core
Targets uncompute/'s qif reversal. Structurally close to `example_final` (qif on a fresh `#⊥`
qubit) but drops the control after the value that needs it, combined with `example_final`'s
branch shape — a combination neither existing paper example covers alone. Exercises
`hasLaterEndlft` and `collectDeferredBorrows` together.

### example_nested_call_reversal.qurts-core
Targets uncompute/'s call reversal through multiple call boundaries. `example_nested_call_reversal`
calls `middle`, which calls `innermost`, whose qif is controlled by a parameter two call
boundaries from its only top-level name. Confirms `renames`/`rcCopies` composition works two
levels deep, not just one.

### example_qif_pair_return.qurts-core
Fig. 9's "simulation qif" rule (p. 17-18) explicitly describes `qif p { let t1 = (y,x); t1 } else
{ let t0 = (x,y); t0 }` as a controlled-swap — a qif whose branches return a *pair*, swapped by
control. Type-checks fine (nothing in Figs. 5-8/13-17 restricts qif's return type to bool/qbit)
and needs no uncomputation. Compiles to a single SWAP gate between the two variables' qubits,
gated on the control (see `circuit/README.md`'s "Fixed: a qif returning a pair" section) — the
`RKind`/`classifyReturn` machinery previously only handled a branch returning one fresh or
threaded-through qubit. Simulating gives only the two outcomes a controlled-swap should produce
(`p=0,a=0,b=1` and `p=1,a=1,b=0`, each ~50%), confirming the fix against Fig. 9's own prediction.

## Error Examples

Expected to fail type-checking.

### example_error.qurts-core
Inspired by Section 3.1's "uncomputability via types" discussion (p. 10–11), but not a literal
transcription of it (see `example_uncomputability_error.qurts-core` for that): `q` is consumed by
the first qif, explicitly dropped while its lifetime is still active, then a second qif tries to
borrow the now-gone `q`. Error: `UnboundVariable (Var "q")`.

### example_uncomputability_error.qurts-core
A literal transcription of Section 3.1's actual "uncomputability via types" example (p. 10–11):
`q` is computed under `&alpha p`, `alpha` is ended, then `q` is borrowed *again* under a fresh
`beta` to control a second qif, without ever being dropped. Since `q`'s own type is still tagged
`#alpha qbit` and `alpha` is no longer active, `q` can never be legally dropped again -- it's stuck
unconsumed at the end of the block, exactly as the paper describes ("q cannot be dropped"). Error:
`LinearityViolation "Variable not consumed after block: Var \"q\""`.

### example_freeze_error.qurts-core
Borrow freeze (typing_letref, Fig. 17) — `r = &α p` freezes `p` for `α`; the program then
accesses `p` directly while frozen. Error: `VariableFrozen (Var "p") (Lifetime "alpha")`.

### example_copy_qubit_error.qurts-core
Fig. 14 — qbit is not Copy (no-cloning). Attempts to copy an owned `#⊤ qbit`. Error:
`OtherError "Type is not Copy: TyBang LTop TyQBit"`.

### example_qif_pq_error.qurts-core
qif PQ restriction (Fig. 16, typing_qif) — a `meas` call inside a qif branch. Error:
`NotPurelyQuantum "qif then-branch contains measurement or classical if"`.

### example_qif_call_pq_error.qurts-core
Same restriction, via a function call — calls a non-PQ function (one containing `meas`) from
inside a qif branch; the PQ check propagates through calls. Same error as above.

### example_external_endlft_error.qurts-core
stmt_end_lifetime's `α ∉ A_ex,Π,f` premise (Fig. 16) — tries to `endlft` a lifetime that's the
function's own signature parameter rather than one it introduced itself with `newlft`. Only the
caller may end an external lifetime. Error: `"cannot endlft ..."`.

### example_lifetime_restart_error.qurts-core
Section 3.2.1's own assumption ("a lifetime variable cannot be restarted after it has ended") —
`newlft`s, `endlft`s, then `newlft`s the same name again. Error: `"...may only ever be used
once..."`.

### example_lifetime_keyword_error.qurts-core
`newlft`/`endlft` take a lifetime *variable* (Fig. 3's own footnote), never the special `bot`/`top`
atoms — those exist only in types (`#top T`). Error: `"'bot' is ... not a variable"`.

### example_ec_arity_error.qurts-core
`expr_lifted`'s own arity — applies `[cnot]` (a 2-qubit gate) to a single qubit. Regression test
for a bug where `[c](x)`'s argument shape (single qubit vs. same-lifetime pair) was accepted
regardless of whether `c` itself was 1- or 2-qubit, so a mismatch type-checked, passed uncompute,
and only ever crashed `build_circuit.py` with a raw Python `ValueError` at the very last stage.

### example_leq_external_error.qurts-core
stmt_lft_ineq's own `α, β ∉ A_ex,Π,f` premise (Fig. 16) — `evil_leq<a,b|>` asserts `a <= b;` about
its *own* external parameters in its body, then coerces accordingly; `example_leq_external_error`
calls it with two lifetimes actually related the *other* way. Regression test for a genuine
soundness hole, not just an over-strict rule: expr_function's caller-side check only ever verifies
a callee's *signature*-declared constraints, never anything asserted in the callee's own body, so
the caller had no way to see — or refute — the invented relationship. Previously type-checked
outright; before this fix it was only ever caught by chance, by Uncompute's own defensive
re-type-check, with a confusing `ReferenceStillInContext` far from the actual mistake.

### example_self_pair_error.qurts-core
expr_tuple (Fig. 15) — `(x, x)`, the same variable used for both halves of a pair. Regression
test for a direct no-cloning violation, the most severe bug found this session: `checkExpr (EPair
x0 x1)` looked both variables up *before* removing either, so `x0 == x1` silently passed both
lookups while the variable was still Active both times. Confirmed end to end: `let p = (x,x); let
(a,b) = p; ...meas both...` compiled to a circuit with *one* physical qubit measured twice,
reported as two independent qubits — perfectly correlated 00/11 results, never 01/10, over 1000
shots.
