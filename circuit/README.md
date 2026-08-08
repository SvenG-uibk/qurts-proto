# circuit

Compiles a qurts-core program to a runnable quantum circuit — the step after parse/check/uncompute.
circuit/Circuit.hs (+ CircuitMain.hs) turns the *uncomputed* program into a flat text IR;
circuit/build_circuit.py turns that IR into a Qiskit QuantumCircuit. The IR is just the
interchange format between the two — Qiskit's own diagram is what represents "the circuit".

Compiling the uncomputed program (not the original) is what makes it physically realisable: every
drop has already become a reversal-to-|0⟩ or a classical no-op. Each variable maps to a set of
physical qubit locations (a LocTree, following the paper's Fig. 10 model, keeping pair shape);
qif compiles to controlled operations.

## The easy way: qurts.exe

qurts.exe (root Main.hs) runs the whole pipeline and pipes the compiled IR into circuit/build_circuit.py - --draw over stdin, letting Python's stdout/stderr inherit qurts.exe's own rather than capturing and re-printing them — Python's native Windows-console writing handles Unicode correctly there regardless of codepage, which forwarding bytes through a pipe didn't. Requires python on PATH with qiskit installed; otherwise it prints why and falls
back to the raw IR. `qurts.exe -simulate <file>` additionally passes `--simulate --shots=1000`, so
it also prints the Aer outcome distribution (needs qiskit-aer too) — for a different shot count,
run `python circuit/build_circuit.py <ir-file> --simulate --shots=N` directly instead.

## Building and running by hand

    ghc -i. -ibnfc -ibnfc/bnfc-output -iuncompute -icircuit -itypeChecker circuit/CircuitMain.hs circuit/Circuit.hs uncompute/Uncompute.hs uncompute/GateInverse.hs uncompute/PrettyAst.hs typeChecker/AbsQurtsToAst.hs typeChecker/Ast.hs typeChecker/TypeChecker.hs -o circuit/circuit-main

    ./circuit/circuit-main.exe examples/example_section6_f.qurts-core            # IR to stdout
    ./circuit/circuit-main.exe examples/example_section6_f.qurts-core out.ir     # IR to a file

    python circuit/build_circuit.py out.ir --simulate      # build + run on Aer, print outcome counts
    python circuit/build_circuit.py out.ir --draw          # ASCII circuit diagram
    python circuit/build_circuit.py - --draw < out.ir      # same, reading IR from stdin

Requires qiskit and qiskit-aer. The entry point is the program's last function; parameters get
fresh |0⟩ qubits. The compiled circuit is an exact translation of the source program — it never
adds a measurement the source didn't ask for. A returned value already classical (from the
source's own `meas(...)`) contributes its existing classical bit as an `output`; a returned *live*
qubit contributes nothing and stays unmeasured, exactly as the source left it. `--simulate` reports
"no measurable output" for a program whose return value isn't already classical — add an explicit
`meas()` in the qurts-core source if you want an observable result (see the "Fixed: circuits used
to gain a measurement..." section below).

## IR format

One instruction per line. <ctrls>/<cctrls> are each - or q0=1,q1=0,...
(qubit/classical-bit index = required polarity).

    qubits <n>
    cbits  <m>
    alloc  <q> <0|1>                            # fresh qubit; 1 => X applied to make |1>
    gate   <name> <t0,t1,...> <ctrls> <cctrls>  # named gate on target qubits, under controls
    meas   <q> <c>                              # measure qubit q into classical bit c
    output <c0,c1,...>                          # classical bits holding the entry's return value

Gate names map to Qiskit gates; a quantum-controlled gate becomes .control(n, ctrl_state=...).
<cctrls> comes from a classical if on a *dynamic* (measured) condition, where only one
branch's gates ever actually run: each becomes a Qiskit if_test (nested, one per classical bit)
rather than an extra qubit control.

## Coverage

18 of 23 non-_error examples compile — every one the uncomputation pass can handle. Beyond
single gates/pairs/renames/borrows/meas:

- **qif → controlled gates.** Each branch is classified by its return shape (RFresh from
  [0]()/[1](), or RInput x threading a value through) and both branches unify onto one
  shared result location. Every gate a branch emits carries the qif's control appended to any
  already active, so nested qif compiles straight to a multi-controlled (Toffoli-shaped) gate.
- **Function call inlining.** A callee's body compiles into the caller's own instruction stream,
  with its parameters bound to the caller's argument locations.
- **Classical if**, when the condition resolves to a compile-time-known bool (a literal, or a
  bool parameter's default false): picks a branch outright, no gate emitted.
- **Classical if on a dynamic (measured) condition** (example_if_dynamic): the same
  RFresh/RInput branch classification as qif, but instead of a qubit control, every gate a
  branch emits is wrapped in a Qiskit if_test conditioned on the measured classical bit
  (positive for the then-branch, negative for the else) — since only one branch's gates actually
  execute, decided at run time rather than by superposition. Getting a program that reaches this
  path through the type checker at all needed two companion fixes: expr_classical_if was
  matching condition variables against literal TyBool, but meas/true/false all produce
  #⊤bool per the paper's own typing rules (Figure 15) — nothing but a bare bool *parameter*
  could ever satisfy it before; and the condition variable wasn't restored to context afterward,
  unlike qif's control variable, even though the paper's Γ+Δ split for expr_classical_if is
  identical to expr_quantum_if's (Figure 15) and the existing qif code already did this. Both
  were implementation gaps relative to the paper, not deliberate restrictions — see the comments
  on checkExpr (EIf ...) in typeChecker/TypeChecker.hs.

Verified by simulation for the examples whose own source already calls `meas(...)` on what they
return (example_final/example_qif_reversal give a clean ~50/50 split; example_if_dynamic's
measured condition and its classically-corrected qubit always agree, only 00/11 outcomes;
example_grover peaks at |111⟩, ~93-94% over 1000-2000 shots, matching the paper's own numbers).
Examples that intentionally return a live, unmeasured qubit matching the paper's own signature
(example_and, example_call, example_section6_f) are checked by inspecting the compiled gate
structure directly instead (a genuine Toffoli/CCX for AND, a single `not` for the call example,
...) — `--simulate` on those reports "no measurable output" now, correctly, since the compiled
circuit is an exact translation of a source that never measures anything (see below).

## Fixed: example_grover.qurts-core used to give the wrong answer

Used to compile fine but simulate to a uniform distribution instead of a peak at |111⟩. Cause: the
compiled IR applied Z to the same qubit twice in a row (Z·Z = I), cancelling Grover's phase
kickback. example_grover.qurts-core applies the phase via `let tmp1 = phase<alpha1>(tmp1)`, a
rebind — that put `[Z]` into tmp1's own reversible history, so `Uncompute.hs` reversed it right
along with everything else when `drop tmp1` got reversed, giving `oracle; Z; Z; oracle⁻¹` instead
of the intended `oracle; Z; oracle⁻¹`.

The paper's own idiom (Section 3.1) applies the phase as a *borrowed* read of `tmp`
(`qif &tmp { phase(π) } else { noop }`), never rebinding it — so the phase never enters `tmp`'s
own tracked history at all, and `drop tmp`'s reversal only ever sees the oracle qif, not the
phase. That idiom isn't expressible in actual qurts-core, though: `phase(π)` there takes no qubit
argument (it's a targetless "flip the current branch's amplitude" primitive the paper itself
footnotes as sugar from "an implementation of Qurts in development", outside Section 3.2's formal
grammar) — every gate application in real qurts-core is a `let`-rebind by construction, so there's
no way to apply `[Z]` to a value without it entering that value's own reversible history.

Fixed in `Uncompute.hs`/`GateInverse.hs` instead: a diagonal gate (`Z`, `S`, `Sdg`, `T`, `Tdg`, `I`
— never moves a qubit to a different computational-basis branch, only phases it) never needs to be
undone to return a value to `|0⟩`, so `reverseOrigin`'s `FromGate`/`FromClassicalGate` cases now
skip straight through to reversing whatever produced that branch membership (the entangling qif),
leaving the diagonal gate exactly where it was applied. This matches the paper's own drop
semantics directly: the simulation semantics for `drop` zeroes only the dropped register and
otherwise leaves the survivors' amplitudes untouched — which is exactly what a kicked-back phase
is. See the `reverseOrigin` comments in `uncompute/Uncompute.hs` for the full argument, including
why it's sound even when the value being dropped isn't entangled with anything (skipping just
leaves an unobservable global phase in that case).

Validated against the automatic-uncomputation literature, not just this one example: Unqomp
(Paradis et al. 2021 — the paper this project's own approach is modelled on, and one the Qurts
paper itself cites) only ever auto-reverses a gate that is "qfree" (expressible as a purely
classical function, no phase at all), and justifies excluding `H` specifically because it "mixes
basis states." It states plainly that "the Deutsch-Jozsa and Grover implementations do not include
any uncomputation as they leverage phase kickback for the oracle evaluation" — i.e. built by hand,
entirely outside automatic uncomputation, since `Z` fails their qfree test too. This fix is a step
more precise than that conservative split: the real criterion for whether a gate's reversal is
*necessary* is "does it mix basis states" (Unqomp's own stated reason for excluding `H`), not "is
it qfree" — a diagonal gate fails qfree for an unrelated reason (phase, not superposition) and
never mixes basis states, so skipping it is sound, while `H` fails for the real reason and is
correctly still never skipped (`isDiagonalUnitary`/`isDiagonalClassical` in `GateInverse.hs` is
exactly that distinction).

## Fixed: the compiler used to add a measurement the source never asked for

`compileProgram` used to unconditionally measure a returned *live* qubit into a fresh classical
bit, purely so `--simulate` would have something to report. That's a real correctness bug, not a
convenience: compiling a circuit is supposed to produce an exact translation of the source
program, and a measurement is a genuine physical operation — adding one the source never wrote
means the "compiled circuit" and the actual program have silently diverged. It also wasn't obvious
from the outside: nothing about `qurts.exe <file>`'s plain diagram output flagged that an extra
`meas` box on the end wasn't really part of your program.

Fixed in `Circuit.hs`'s `collectOutputs`: a returned live qubit (`LLeaf`) now contributes nothing
at all — no gate, no output bit — left exactly as the source left it. An already-classical return
value (from the source's own `meas(...)`) is unaffected, still reported via `output` exactly as
before. The consequence: several examples that used to show a shot distribution under `--simulate`
purely because of the removed synthetic measurement (`example_grover`, `example_if_dynamic`) now
report "no measurable output" *unless* their own source measures what they return — so both were
updated to call `meas()` explicitly on their final result, matching the pattern
`example_grover_amplified`/`example_final` already used. This is not a workaround for the fix: it
makes those examples' own qurts-core source say what they actually mean ("this program's answer is
the measured bits"), rather than relying on the compiler to invent that meaning after the fact.
`example_and`/`example_call`/`example_section6_f` intentionally return a live qubit matching the
paper's own function signatures and were deliberately left alone — see "Coverage" above.

## Fixed: two aliased references controlling the same qif could crash the Qiskit renderer

`example_copy_alias.qurts-core` (`toffoli(y, z, w)`, called with `y = copy x` and `z = copy y` —
both aliasing the same borrowed qubit as `x`) used to crash with Qiskit's `CircuitError: duplicate
qubit arguments`. Nesting `qif x { qif y { [X](z) } ... }` accumulates controls via
`compileQifCore`'s `ctrls ++ [(ctrlLoc, polarity)]`, which has no way to notice that `x` and `y`
resolve to the identical physical qubit once the call is inlined — so the innermost gate ended up
with `ctrls = [(0,True),(0,True)]`, the same qubit index listed twice, which `.control()`/
`.append()` rejects outright.

Fixed with a single normalization pass before any gate is emitted (`Circuit.hs`'s `emitGate`/
`normalizeCtrls`, routed through from every call site that used to call `emit (IGate ...)`
directly): two control entries for the same index and polarity are redundant (`q=1 ∧ q=1 ≡ q=1`)
and collapse to one; two for the same index with *opposite* polarities are a contradiction
(`q=1 ∧ q=0`) that can never be satisfied, so the gate they'd guard is simply never emitted rather
than rendered as an impossible instruction. The source program was already well-typed and
legitimate (aliasing via `copy` on a reference is exactly what Fig. 14 describes); this was purely
a circuit-rendering gap, not a type-system one.
