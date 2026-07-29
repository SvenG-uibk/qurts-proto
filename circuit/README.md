# circuit

Compiles a qurts-core program to a runnable quantum circuit — the final step after parse/check/uncompute. Two halves: `circuit/Circuit.hs` (+ `circuit/CircuitMain.hs`) turns the *uncomputed* program into a flat text IR; `circuit/build_circuit.py` turns that IR into a Qiskit `QuantumCircuit` you can draw and simulate. The IR is only an interchange format between those two halves — it's never the thing meant to represent "the circuit" to a human; Qiskit's own diagram is.

Compiling the **uncomputed** program (not the original) is what makes it physically realisable: every `drop` has already become a reversal-to-`|0⟩` or a classical no-op, so the circuit never has to discard a non-`|0⟩` qubit. Following the paper's Fig. 10 location model, each variable maps to a set of physical qubit *locations* (a `LocTree`, so pairs keep their shape); gates apply to those locations, and `qif` compiles to controlled operations.

## The easy way: `qurts.exe`

`qurts.exe` (built from `Main.hs` at the repo root — see the root `readme.txt`) runs the whole pipeline and, as its last step, pipes the compiled IR into `circuit/build_circuit.py - --draw` over stdin (its stdout/stderr are left to inherit qurts.exe's own, rather than being captured and re-printed) — this is what `qurts <file>` and `qurts -v <file>` show as "the circuit." Requires `python` on PATH with `qiskit` installed; if that fails (missing python, missing qiskit, ...) it prints why and falls back to the raw IR so the tool still gives you something.

Earlier versions captured the child's output through a pipe and re-printed it from Haskell, which mangled the box-drawing characters into mojibake on Windows (GHC's pipe-reading and the console's codepage disagreed about the encoding, no matter what `chcp` was set to). Letting the child inherit the real console directly sidesteps that: Python's own Windows-console writing talks to the console API natively and doesn't depend on the codepage at all, so there's nothing left to get wrong.

## Building and running by hand

    ghc -i. -ibnfc -ibnfc/bnfc-output -iuncompute -icircuit -itypeChecker circuit/CircuitMain.hs circuit/Circuit.hs uncompute/Uncompute.hs uncompute/GateInverse.hs uncompute/PrettyAst.hs typeChecker/AbsQurtsToAst.hs typeChecker/Ast.hs typeChecker/TypeChecker.hs -o circuit/circuit-main

    ./circuit/circuit-main.exe examples/example_section6_f.qurts-core            # IR to stdout
    ./circuit/circuit-main.exe examples/example_section6_f.qurts-core out.ir     # IR to a file

    python circuit/build_circuit.py out.ir --simulate      # build + run on Aer, print outcome counts
    python circuit/build_circuit.py out.ir --draw          # ASCII circuit diagram
    python circuit/build_circuit.py - --draw < out.ir      # same, reading the IR from stdin

Requires `qiskit` and `qiskit-aer` (`pip install qiskit qiskit-aer`). The entry point is the program's **last** function; its parameters get fresh `|0⟩` qubits (standalone circuits run on the all-zero input), and its returned qubits are measured into classical bits so `--simulate` can read the result out. When stdout is a real console, `build_circuit.py` leaves it alone — Python's own Windows-console writing already handles `--draw`'s box-drawing characters correctly there, regardless of codepage. Only when stdout is redirected (a file, a pipe, `--draw > out.txt`) does it force UTF-8 (`sys.stdout.reconfigure`), since there's no console to talk to natively at that point and the inherited locale encoding otherwise raised `UnicodeEncodeError` on Windows.

## IR format

Line-based, one instruction per line. `<ctrls>` is `-` (none) or `q0=1,q1=0,...` (control qubit = required polarity; `1` positive/`|1⟩`-branch, `0` negative/`|0⟩`-branch).

    qubits <n>
    cbits  <m>
    alloc  <q> <0|1>                    # fresh qubit; 1 => X applied to make |1>
    gate   <name> <t0,t1,...> <ctrls>   # named gate on target qubits, under controls
    meas   <q> <c>                      # measure qubit q into classical bit c
    output <c0,c1,...>                  # classical bits holding the entry's return value

`build_circuit.py` maps gate names (`H`, `X`, `Z`, `S`/`Sdg`, `T`/`Tdg`, `not`, `cnot`, `swap`, ...) to Qiskit gates; a controlled gate becomes `.control(n, ctrl_state=...)` with the state built from the per-control polarities.

## Current coverage

17 of the 22 non-`_error` examples compile to a circuit — every one the uncomputation pass itself can handle. Handles the gate-and-structure subset — `[0]()`/`[1]()`, `EU`/`EC` gates (single-qubit and literal-pair), renames, `&borrows`, pairs and their destructure, `meas`, the no-op statements (`drop`/`as`/`newlft`/`endlft`), entry parameters (fresh `|0⟩` per qubit, `false` per bool) — plus three bigger pieces:

- **`qif` → controlled gates.** Each branch is classified by tracing its return variable back through its own statements (`classifyReturn` in `Circuit.hs`): `RFresh` (built from `[0]()`/`[1]()`) or `RInput x` (threads an existing variable through, gated or not — the `[not](q)` / `noop; q` shape). Both branches of one `qif` must classify the same way and unify onto a single shared result location — the common input's location for `RInput`/`RInput`, one fresh `|0⟩` qubit for `RFresh`/`RFresh` — since physically there's only ever one qubit in superposition across both branches, never two that get "merged" afterward (confirmed against the paper's own location model, Fig. 10, and its "controlled-swap" reading of `qif p { (y,x) } else { (x,y) }`). Every gate a branch emits carries the `qif`'s control appended to whatever controls are already active, so a **nested** `qif` naturally accumulates multiple controls — `qif x { qif y { [1]() } else { [0]() } } else { [0]() }` compiles straight to a Toffoli.
- **Function call inlining.** A callee's body compiles directly into the caller's own instruction stream (same qubit/cbit counters), with its parameters bound to the caller's argument locations — a reference argument shares the exact qubit it points at. Mirrors `Uncompute.hs`'s own `resolveExpr`/`ECall` inlining; termination is guaranteed the same way (the call graph is a DAG — `TypeChecker.hs`'s `checkProgram` only allows calling functions already defined earlier).
- **Classical `if`.** Unlike `qif`, at most one branch of a classical `if` ever actually runs, so it's compiled by picking a branch outright rather than emitting a controlled gate — but only once the condition is resolved to a compile-time-known `LBool`, which it always is in the current examples: `true`/`false` literals bind one directly, and (mirroring the existing "entry runs on the all-zero input" convention for qubit parameters) a `bool` entry parameter defaults to `LBool False`. `example_if.qurts-core`'s `if b { true } else { false }` on a `bool` parameter `b` compiles to an empty circuit (0 qubits, 0 gates) — the `false` branch is selected at Haskell-compile time and the unreached `true` branch leaves no trace, confirmed by inspecting the emitted IR. A condition that's a genuinely dynamic classical bit (from `meas`, tracked as `LBit`) is deliberately **not** handled — that needs Qiskit's classically-controlled gates (`c_if`/`if_test`), and no current example exercises it, so it fails loudly instead of being guessed at.

**Verified by simulation, not just by compiling** — a wrong circuit has no type checker to catch it, so every increment was checked against a case a broken version couldn't fake:
- `example_my_cnot`'s compiled CX, with an `H` added on the control, produces a clean **Bell state** (`00`/`11` only, `01`/`10` never) — confirms control, target, and polarity are all correct, not just "some gate got emitted."
- `example_and`'s Toffoli reproduces the exact **AND truth table** across all 4 inputs.
- `example_call`/`example_nested_call_reversal` return `|1⟩`/`|0⟩` exactly as their gate chains predict by hand.
- `example_section6_f`'s `H` gives the expected ~50/50 split, with the two physically-impossible outcomes never appearing.

Not handled yet (fails loudly rather than miscompiling): classical `if` on a dynamic (measurement-derived) condition. Anything the uncomputation pass itself can't handle (the shared-dependency/pebble-game cases — see `uncompute/README.md`) never reaches this stage at all.

## Known issue: `example_grover.qurts-core` simulates to the wrong answer (not pursuing a fix right now)

Compiling `example_grover.qurts-core` succeeds (7 qubits, 49 instructions) but **simulating it gives a uniform distribution over all 8 outcomes, not the expected peak at `|111⟩`** (Grover's marked state). This was found *by* the simulation layer — nothing upstream (type-checking, uncomputation's own round-trip check) catches it, because the output is a perfectly well-typed, physically-realisable circuit that just computes the wrong thing.

**Root cause, confirmed by isolation:** the compiled IR contains `gate Z 3` immediately followed by another `gate Z 3` on the same qubit (and the same pattern on the diffusion's other ancillas). Two consecutive `Z`s cancel (`Z·Z = I`), destroying Grover's phase kickback. Deleting just the second (reversal) `Z` from each pair — nothing else — changes the simulated result to `111: 965/1024` (94%), textbook Grover amplification. That isolates the bug to exactly this double-`Z`, and rules out the circuit compiler itself: given the *correct* circuit, it produces the *correct* physics.

**Why the double-`Z` happens:** `example_grover.qurts-core` applies the phase as `let tmp1 = phase<alpha1>(tmp1);` — a **rebind**. That makes `[Z]` part of `tmp1`'s own reversible history, so when `Uncompute.hs` later reverses `drop tmp1`, it dutifully reverses the `[Z]` right along with everything else, cancelling it. The paper's own idiom (`qif &tmp { phase() } else { noop }`, Section 3.1) instead applies the phase as a *controlled* operation with `tmp` only ever *read*, never rebound — so the phase lands on `x`/`y`/`z` (the qubits that survive) rather than on `tmp` (the qubit about to be dropped), and reversing `tmp` alone can't touch it. `examples/README.md`'s own note on `example_grover.qurts-core`, justifying the `qif { phase() } else { noop }` → `phase(tmp)` simplification as "equivalent," is exactly the claim this finding contradicts — it's equivalent for computing the phase, but not for surviving `tmp`'s own later uncomputation.

**Two ways to actually fix this, neither attempted:**
1. **Fix the example** — rewrite `example_grover.qurts-core` (and check `example_grover_amplified*` for the same shape) to apply the phase as a genuine `qif`-controlled read of `tmp`, matching the paper's own idiom, rather than a rebind. Confirmed the physics on this side (94% on `|111⟩`, isolated to the double-`Z` deletion) — this is squarely "the example was written the wrong way," not a bug in either pass.
2. **Treat it as an `Uncompute.hs` question** — should reversal recognize that a gate applied to a value only for its *phase* effect (and never rebinding it, or being immediately re-dropped) shouldn't be undone the same way a genuine computation would? This is a materially harder question than (1): distinguishing "this gate's effect must survive `tmp`'s own drop" from "this gate is part of what makes `tmp` need reversing" isn't visible from `tmp`'s own `Origin` chain alone — it edges toward the same shared/joint-dependency territory (Section 5.1's pebble game) already deferred for `example_self_controlled_uncomp.qurts-core` and friends, since it's fundamentally about a gate's effect being shared between the qubit that's dropped and the qubits that aren't.

Left alone for now, by request — this note is so the finding and both options aren't lost.
