# Qurts-core Examples

Run a single example:

.\qurts check examples\<filename>.qurts-core

Run all examples at once (24/24 should pass):

.\qurts test examples

Files with `_error` in their name are expected to fail type-checking; all others are expected to succeed. The test command exits with a non-zero status if any result is unexpected.

## Valid Examples

### example_and.qurts-core
Section 3.1, p. 9 (Boolean AND)

Implements "and(x, y)" using nested qif. Both inputs are immutable references &α qbit; the result is an owned qubit #α qbit. This is the primary example of building a quantum boolean function from qif.

### example_valid.qurts-core
Section 3.1, p. 10 (left—valid uncomputation example)

A function that borrows p under a fresh lifetime alpha, conditionally flips an ancilla qubit q with qif, then drops q (uncomputation), ends α, and applies H to p. Demonstrates the full borrow/uncompute/endlft cycle without a linearity violation.

### example_final.qurts-core
Section 3.1, p. 12 (toy example) and Section 4.2, p. 18 (formal walkthrough)

The central running example of the paper, used to illustrate the full typing derivation.

### example_my_cnot.qurts-core
Section 3.1, p. 11

my_cnot(x, y) takes a reference x: &α qbit (control) and an owned qubit y: #α qbit (target). Uses qif x to either negate y or pass it through unchanged. Demonstrates qif consuming an existing owned qubit rather than allocating a fresh one.

### example_forget.qurts-core
Section 3.1, p. 12

forget(x) takes an owned qubit x: #α qbit and returns (). The qubit is implicitly dropped by the block cleanup, which is valid because α is an active lifetime. Demonstrates that #α qbit is affine (droppable) when its lifetime is active.

### example_reinitialise.qurts-core
Section 3.1, p. 12

reinitialise(x, y) uses qif y to either drop x and return a fresh |0⟩, or return x unchanged. Demonstrates that drop is permitted inside a qif branch (it is a purely quantum statement). The two branches have types #⊤ qbit and #α qbit, which are compatible via subtyping.

### example_pair.qurts-core
not explicitely in paper — Typing rules — pair introduction and elimination (Figures 15–17)

Allocates two qubits, packs them into a pair (x, y), destructs the pair, drops one component, and returns the other. Tests pair construction (EPair) and pair destructuring (SLetPair).

### example_call.qurts-core
Typing rules — function call (Figure 16, typing_call)

Defines a helper nott that applies [not] and returns the result, then calls it from example_call. Tests multi-function programs, as coercion, and the ECall typing rule.

### example_if.qurts-core
Typing rules — classical conditional (Figure 16, typing_if)

A function taking a bool that returns one of two #⊤ bool values via classical if. Tests the classical EIf branch with a Copy type.

### example_copy.qurts-core
Typing rules — copy (Figure 16, typing_copy); Section 3.1 (references are Copy)

Copies an immutable reference &α qbit (which is Copy), drops the copy immediately, then uses the original reference as a qif control. Tests that copy does not consume the variable and that references remain usable after being copied.

### example_copy_bool.qurts-core
Typing rules — copy (Figure 16); Figure 14 (bool is Copy)

Copies a bool, drops the copy, and returns the original. Tests the isCopy check for the bool base type.

### example_leq.qurts-core
Subtyping — subty_shorten (Figure 13): &α T ≤ &β T when β ≤ α

Takes x: &α qbit with a constraint β ≤ α, copies x to get another reference, coerces it to &β qbit via as, and returns it. Tests lifetime shortening — a reference valid for a longer lifetime can be used as one valid for a shorter lifetime.

### example_cnot_reinit
Kengo's qif example from section 5.1 - the "complicated qif" isnt actually here problematic here, but during uncomputation. on the other hand, we claim (and have soundness proof), that all our typechecked programs relate to a circuit (uncomputable)

### example_self_controlled_uncomp
this is the example from Kengo's email, not in the paper

```
// x, y: #'a qbit
let (x, y) = [some classical circuit] (x, y);
newlft 'b (< 'a)
let y: #'b qbit = qif (&'b x) { y } else { drop(y); |0> }
```

the hard part for uncomputation will be the drop y3, as it requires reversing the qif, which is controlled by x2, which came from cnot x,y, it follows that the reverse circuit would need to be self-controlled

### example_section6_f
from section 6

The paper's function f(mut x: qbit) -> (qbit, #'static qbit) translated to Qurts-core. Applies H to x (making it linear, #⊥ qbit) and also produces a fresh |0⟩ with static lifetime (#⊤ qbit). Returns the pair. Demonstrates a function that mixes linear (#⊥) and always-affine (#⊤) qubits in its return type.

### example_grover.qurts-core
Fig. 2 (Grover's algorithm for 3 qubits in Qurts), plus Appendix A's desugaring of that figure

The "stupid" variant of Grover's algorithm, where the marked solution is available as a hardcoded truth table rather than passed in as a generic oracle. oracle hardcodes the target |111⟩ via nested qif (3-input AND, mirroring example_and.qurts-core), non_zero marks everything except |000⟩ (3-input OR) for the diffusion reflection, and phase is a one-line [Z] gate application.

Appendix A spells out exactly what qif &oracle(&x,&y,&z) { phase(𝜋) } desugars to, and Section 3.1 explains the key step: "Calling [phase()] within the qif causes the Z gate to be applied to the qubit owned by tmp." That is the crux of the whole example:
- the Z gate is applied **directly to oracle's own result qubit** (tmp), and drop tmp only reverses oracle's construction of tmp, not the Z gate applied on top of it. Since oracle is a self-inverse boolean circuit (nested qif, XOR-style) and Z is a separate, later operation on the same qubit, reversing just the former leaves the phase imprinted on x,y,z while tmp itself cleanly resets to |0⟩ — this is the standard phase-kickback trick, expressed here purely through the type system's "drop a #α value while α is still active" rule rather than any explicit inverse-circuit code.
- Since qurts-core's qif requires both branches to be Purely Quantum and can't return (), and there's no bare scalar-multiplication expression either, this whole qif { phase() } else { noop } step collapses to a single phase<alpha>(tmp) call (implemented as [Z], a generic-lifetime EC application so tmp keeps its #α tag and stays droppable) — no borrowing of tmp itself is needed, since the paper confirms that's exactly what the sugar reduces to anyway.

Everything else follows the paper's own translation notes for unrolling into qurts-core:
- x: &mut qbit params become owned x: #⊥ qbit params, mutated by shadowing (let x = H(x) ; for each x.H(), since qurts-core has no &mut).
- for _ in 0..2 is manually unrolled into two copies of the loop body, since qurts-core has no loop construct.
- let x,y,z = grover_diffusion(x,y,z) (the paper's 3-way destructuring sugar) becomes two nested-pair destructures, since qurts-core's let (_,_) = _ only handles 2-tuples; returning three qubits likewise needs a nested pair (x,y),z.

### example_grover_amplified.qurts-core
not from the paper — general amplitude amplification (Brassard–Høyer–Mosca–Tapp 2000), applied to the same 3-qubit search as example_grover.qurts-core

The "smart" counterpart to example_grover.qurts-core: instead of copying the paper's fixed iteration count, the number of Grover iterations is derived from the number of marked solutions M. Model the state as a rotation by angle θ = arcsin(√(M/N)) per iteration (N=8 here); the optimal iteration count is r = round(π/(4θ) − 1/2). For M=1 (the single |111⟩ solution in example_grover.qurts-core) this gives θ≈20.7° and r=round(2.174−0.5)=2 — the paper's for _ in 0..2 is already this formula's answer, it just isn't derived there. This example's oracle (below) marks M=2 solutions, giving θ=arcsin(√(2/8))=30° and r=round(1.5−0.5)=1 — so grover_amplified unrolls the oracle+diffusion loop **once**, not twice. Reusing example_grover.qurts-core's r=2 here would over-rotate past the amplitude peak and make the result *less* likely to be a solution, which is the point of the example: r must track M, not be copy-pasted between oracles.

oracle marks exactly the satisfying assignments of the 3-variable CNF formula (x∨y) ∧ (¬x∨¬y) ∧ (z) — "exactly one of x,y is true, and z is true" — which has exactly M=2 solutions, x=0,y=1,z=1 and x=1,y=0,z=1. Unlike a flat hardcoded truth table, oracle is now built *from the clauses*, the way it would need to be if the solution weren't already known: clause_or2, clause_nand2, and clause_unit each compute one clause's own "violated" bit from only the variables that clause mentions, and all_satisfied3 ANDs the three "not violated" bits together. oracle itself just wires these together — copys of x/y/z into each clause function (since each is a separate function call, consuming its arguments), then borrows of the three clause results into all_satisfied3. This sidesteps a real qurts-core restriction: qif requires both branches to be Purely Quantum, which excludes references entirely (Fig. 7: "does not include any booleans or references"), so a reference like x can never be threaded through as part of a qif's own return value — only owned qubits can. Trying to compute all three clauses via *inline* nested qifs inside one function hits this immediately (a qif on x silently drops y and z from scope, since only its own control variable survives it — see below); factoring each clause out into its own top-level function avoids it, because ordinary sequential statements (copy, function calls) don't have that problem, only qif/if branches do. phase, non_zero, and grover_diffusion are reused verbatim from example_grover.qurts-core, since the diffusion operator (reflection about the uniform superposition) doesn't depend on M or on which states are marked.

Building oracle had me thinking that I found a bug: **a qif expression preserves only its own control variable across itself — every other droppable variable in scope (even one untouched by either branch) is silently dropped**, because checkExpr EQIf only ever explicitly re-inserts the control (insertVar x ty, after both branches are checked); everything else is whatever the *last-checked* branch's own end-of-block cleanup leaves behind, and that cleanup drops any Active binding that isn't the block's own retVar. this is NOT what the rust-like scope would do, which is supposedly used in the paper. After some checking, im quite sure this is NOT a bug in the typechecker though: this only applies to full qurts. in qurts-core, we are doing it correctly and the idea was to hide this from the programmer in full-qurts.

Unlike example_grover.qurts-core (which mirrors the paper's Fig. 2 and leaves the qubits amplified but unmeasured), grover_amplified ends by calling meas on x, y, z and returning #⊤ bool * #⊤ bool * #⊤ bool. This is the point being illustrated: amplitude amplification only makes measuring a solution *likely* (probability sin²((2r+1)θ), close to but not exactly 1 for integer r), not certain — so a real usage has to measure and get a classical result, rather than staying in the amplified-but-unread quantum state as in the paper.

I didnt do quantum counting yet, will just assume that the number of solutions is known, quantum counting would be done fully seperately anyway

### example_grover_amplified2.qurts-core
expanded example_grover_amplified to 4 qubits and three iterations (because I cant get three iterations with just three qubits)

oracle marks the unique solution of (x∨y) ∧ (¬x∨¬y) ∧ (z) ∧ (¬x∨w) ∧ (x∨¬w) ∧ (y∨¬z) — verified by brute force to be exactly one assignment, x=0,y=1,z=1,w=0 — built the same clause-by-clause way as example_grover_amplified.qurts-core's oracle: clause_or2, clause_nand2, clause_unit, clause_impl (¬a∨b), and clause_or2_neg_second (a∨¬b) each check one clause from only the variables it mentions, all_satisfied6 ANDs the six results, and oracle just wires copys of x,y,z,w into the six clause calls and borrows of the six results into the checker. Same reasoning as before for why it's structured this way instead of inline qifs: references can't be threaded through a qif's own return value (Purely Quantum excludes them), so each clause has to be its own function call, not nested qifs sharing scope. The x=0,y=1,z=1,w=0 solution never appears in the code itself, only in this description as a post-hoc check.

## Error Examples

These programs are expected to fail with a type error.

### example_error.qurts-core
Section 3.1, p. 10–11 (right — the linearity violation example)

Expected error: UnboundVariable (Var "q")

After q is consumed by the first qif and then dropped, the program attempts to borrow q again under β for a second qif. Since q has been removed from the context, this is an unbound variable error. Demonstrates that a qubit cannot be used after it has been consumed.

### example_freeze_error.qurts-core
Typing rules — borrow freeze (typing_letref, Figure 17)

Expected error: VariableFrozen (Var "p") (Lifetime "alpha")

Creates a borrow r = &α p, which freezes p for the duration of α. The program then tries to access p directly while it is frozen. Demonstrates that a borrowed variable cannot be used as long as the borrow is alive.

### example_copy_qubit_error.qurts-core
Figure 14 — qbit is not Copy (no-cloning theorem)

Expected error: OtherError "Type is not Copy: TyBang LTop TyQBit"

Attempts to copy an owned qubit #⊤ qbit. Since qbit is not in the Copy trait (reflecting the quantum no-cloning theorem), this is rejected. Demonstrates that copy enforces the Copy trait and that owned qubits are linear.

### example_qif_pq_error.qurts-core
Typing rules — qif PQ restriction (Figure 16, typing_qif)

Expected error: NotPurelyQuantum "qif then-branch contains measurement or classical if"

Puts a meas call directly inside a qif branch. Since meas is a classical operation, the branch is not Purely Quantum (PQ), violating the PQ restriction on qif. Demonstrates that measurements cannot appear inside quantum conditionals.

### example_qif_call_pq_error.qurts-core
Typing rules — qif PQ restriction (Figure 16, typing_qif)

Expected error: NotPurelyQuantum "qif then-branch contains measurement or classical if"

Calls a non-PQ function (one that contains meas) from inside a qif branch. The PQ check propagates through function calls via the pqFuncs set, so calling a non-PQ function also violates the PQ restriction. Demonstrates that the PQ check is not purely syntactic but tracks which functions are PQ.
