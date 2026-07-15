# Qurts-core Examples

Run a single example:

.\qurts check examples\<filename>.qurts-core

Run all examples at once (22/22 should pass):

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
not explicitely in paper
Typing rules — pair introduction and elimination (Figures 15–17)

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
// x, y: #’a qbit
let (x, y) = [some classical circuit] (x, y);
newlft ‘b (< ‘a)
let y: #’b qbit = qif (&’b x) { y } else { drop(y); |0> }
```
the hard part for uncomputation will be the drop y3, as it requires reversing the qif, which is controlled by x2, which came from cnot x,y, it follows that the reverse circuit would need to be self-controlled

### example_section6_f
from section 6

The paper's function `f(mut x: qbit) -> (qbit, #'static qbit)` translated to Qurts-core. Applies H to x (making it linear, #⊥ qbit) and also produces a fresh |0⟩ with static lifetime (#⊤ qbit). Returns the pair. Demonstrates a function that mixes linear (#⊥) and always-affine (#⊤) qubits in its return type.

### example_grover.qurts-core
Fig. 2 (Grover's algorithm for 3 qubits in Qurts), plus Appendix A's desugaring of that figure

The "stupid" variant of Grover's algorithm, where the marked solution is available as a hardcoded truth table rather than passed in as a generic oracle. None of `oracle`, `non_zero`, or `phase` are stubs — all three are complete, working implementations: `oracle` hardcodes the target `|111⟩` via nested qif (3-input AND, mirroring `example_and.qurts-core`), `non_zero` marks everything except `|000⟩` (3-input OR) for the diffusion reflection, and `phase` is a one-line `[Z]` gate application. `Z` is a real gate here in exactly the same sense `H` is elsewhere in these examples: gate names passed to `EU`/`EC` (`H(x)`, `[not](x)`, `[Z](a)`, ...) are uninterpreted labels, not a registered/built-in set, so there's nothing missing or stubbed-out about calling `Z`. What qurts-core doesn't have is the paper's *abstract* `phase(π)` — a bare 0-qubit expression, since every expression form in the grammar takes exactly one qubit argument. Per Appendix A, that construct compiles down to a `Z` gate on a specific qubit anyway, so `phase` just is that compiled form.

Appendix A spells out exactly what `qif &oracle(&x,&y,&z) { phase(𝜋) }` desugars to, and Section 3.1 explains the key step: "Calling [phase()] within the qif causes the Z gate to be applied to the qubit owned by tmp. The drop statement... uncomputes the temporary qubit... by applying the reverse operation of the function call [to oracle] to r and tmp." That is the crux of the whole example, and it's the opposite of what a first attempt might guess:
- The phase does **not** get attached to some fresh scratch ancilla that's copied from the oracle's result and then discarded — copying-then-uncomputing that copy would cancel the very phase it was meant to apply (running the copy step backwards undoes it exactly).
- Instead, the Z gate is applied **directly to `oracle`'s own result qubit** (`tmp`), and `drop tmp` only reverses `oracle`'s construction of `tmp`, not the Z gate applied on top of it. Since `oracle` is a self-inverse boolean circuit (nested qif, XOR-style) and Z is a separate, later operation on the same qubit, reversing just the former leaves the phase imprinted on `x,y,z` while `tmp` itself cleanly resets to `|0⟩` — this is the standard phase-kickback trick, expressed here purely through the type system's "drop a `#α` value while `α` is still active" rule rather than any explicit inverse-circuit code.
- Since qurts-core's `qif` requires both branches to be Purely Quantum and can't return `()`, and there's no bare scalar-multiplication expression either, this whole `qif { phase() } else { noop }` step collapses to a single `phase<alpha>(tmp)` call (implemented as `[Z]`, a generic-lifetime EC application so `tmp` keeps its `#α` tag and stays droppable) — no borrowing of `tmp` itself is needed, since the paper confirms that's exactly what the sugar reduces to anyway.

An earlier draft of this example got this backwards (it built a fresh marker qubit off of `tmp` and phase-flipped *that*), which would have been a well-typed but physically inert no-op. The version here follows the paper's explicit worked-out semantics instead.

Everything else follows the paper's own translation notes for unrolling into qurts-core:
- `x: &mut qbit` params become owned `x: #⊥ qbit` params, mutated by shadowing (`let x = H(x) ;` for each `x.H()`, since qurts-core has no `&mut`).
- `for _ in 0..2` is manually unrolled into two copies of the loop body, since qurts-core has no loop construct.
- `let x,y,z = grover_diffusion(x,y,z)` (the paper's 3-way destructuring sugar) becomes two nested-pair destructures, since qurts-core's `let (_,_) = _` only handles 2-tuples; returning three qubits likewise needs a nested pair `(x,y),z`.

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
