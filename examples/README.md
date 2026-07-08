# Qurts-core Examples

Each *.qurts-core file can be run with:

.\qurts check examples\<filename>.qurts-core

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
