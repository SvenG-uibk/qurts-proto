# Qurts-core Examples

Run a single example:

.\qurts -check examples\<filename>.qurts-core

Or through the full pipeline (parse, check, uncompute, compile to a circuit):

.\qurts examples\<filename>.qurts-core

Run all examples at once (28/28 should pass):

.\qurts -test examples

Files with _error in their name are expected to fail type-checking; everything else is expected
to succeed. `-test` exits non-zero if any result is unexpected. See the root readme.txt for the
full command list.

## Valid Examples

### example_and.qurts-core
Section 3.1, p. 9 — boolean AND via nested qif on two `&α qbit` references, returning an owned
`#α qbit`.

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
Classical `if` on a *dynamic* (measured) condition, not a paper example — targets circuit/'s
if_test gap. Measures a Hadamard'd qubit into `b`, then classically applies `[X]` to a second
qubit iff `b` measured 1 (the canonical `c_if`/`if_test` use case), returning `(b, y1)`. Getting
this past the type checker needed two fixes to `checkExpr (EIf ...)`, both gaps relative to the
paper rather than deliberate restrictions: it matched the condition against literal `TyBool`, but
`meas`/`true`/`false` all produce `#⊤bool` (Fig. 15) with no subtyping rule down to bare `bool`
(Fig. 13) — so only a bare-`bool` *parameter* like `example_if`'s could ever satisfy it; and it
never restored the condition variable afterward the way `qif` restores its own control variable,
even though `expr_classical_if`'s Γ+Δ split is identical to `expr_quantum_if`'s. Simulating the
compiled circuit confirms the fix: `b`'s measurement and `y1`'s final value always agree (only
`00`/`11` outcomes, ~50/50, across 2000 shots) — see `circuit/README.md`'s "Coverage" section.

### example_copy.qurts-core
Copy typing (Fig. 16, typing_copy) — copies a reference `&α qbit`, drops the copy, reuses the
original as a qif control. References are Copy.

### example_copy_bool.qurts-core
Copy typing (Fig. 16, Fig. 14) — copies a bool, drops the copy, returns the original.

### example_leq.qurts-core
Subtyping, subty_shorten (Fig. 13) — `&α T ≤ &β T` when `β ≤ α`. Copies `x: &α qbit`, coerces
the copy to `&β qbit` via `as`.

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
Fig. 2 + Appendix A — Grover's algorithm for 3 qubits, marked solution hardcoded as a truth
table rather than a generic oracle. `oracle` marks `|111⟩` via nested qif (3-input AND);
`non_zero` marks everything but `|000⟩` (3-input OR) for the diffusion reflection; `phase` is a
single `[Z]`. The phase is applied as `let tmp1 = phase<alpha1>(tmp1)` — Section 3.1's
phase-kickback trick, expressed as "drop a `#α` value while `α` is still active" rather than an
explicit inverse circuit.

**Previously a known bug**, found via the uncompute/circuit pipeline: applying the phase as a
*rebind* put `[Z]` into `tmp1`'s own reversible history, so `Uncompute.hs` reversed `drop tmp1`
right through it, cancelling the phase (`Z·Z = I`) and simulating to a uniform distribution
instead of a peak at `|111⟩`. Fixed by teaching `Uncompute.hs` that a diagonal gate (`Z` here)
never needs to be undone to return a value to `|0⟩` — see `circuit/README.md`'s "Fixed" section
for the full writeup. Simulating the compiled circuit now confirms the fix: ~94.5% on `|111⟩`
over 2000 shots.

Translation notes: `&mut qbit` params become owned `#⊥ qbit` params mutated by shadowing;
`for _ in 0..2` is manually unrolled; the paper's 3-way destructure becomes two nested pair
destructures.

### example_grover_amplified.qurts-core
Not from the paper — amplitude amplification (Brassard–Høyer–Mosca–Tapp 2000) applied to the
same 3-qubit search. Instead of the paper's fixed 2 iterations, the count is derived from the
number of marked solutions M: θ = arcsin(√(M/N)), r = round(π/(4θ) − 1/2). This oracle marks
M=2 solutions (`(x∨y) ∧ (¬x∨¬y) ∧ z`), giving r=1 — one iteration, not two; reusing r=2 would
over-rotate past the amplitude peak.

`oracle` is built clause by clause (`clause_or2`, `clause_nand2`, `clause_unit`,
`all_satisfied3`) rather than as one hardcoded truth table, since qif can't return a reference as
part of its result (Fig. 7: Purely Quantum excludes booleans and references) — each clause has
to be its own function call, not an inline nested qif sharing scope. `phase`, `non_zero`,
`grover_diffusion` are reused verbatim from `example_grover.qurts-core`.

Ends by measuring `x`, `y`, `z` and returning three bools — amplitude amplification only makes
measuring a solution *likely*, not certain. Assumes M is known in advance.

### example_grover_amplified2.qurts-core
`example_grover_amplified` extended to 4 qubits, a unique solution of a 6-clause formula, needing
3 iterations. Built the same clause-by-clause way, with two more clause helpers (`clause_impl`,
`clause_or2_neg_second`).

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

## Error Examples

Expected to fail type-checking.

### example_error.qurts-core
Section 3.1, p. 10–11 — linearity violation. `q` is consumed by the first qif and dropped, then
borrowed again for a second qif. Error: `UnboundVariable (Var "q")`.

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
