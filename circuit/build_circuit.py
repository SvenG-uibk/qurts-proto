#!/usr/bin/env python3
"""Read the flat circuit IR emitted by uncompute/Circuit.hs and build a
Qiskit QuantumCircuit from it. With --simulate, run it on the Aer state-
vector simulator and print the measured-outcome distribution, which is how
we verify a compiled qurts-core program actually does what it should.

IR format (one instruction per line):
    qubits <n>
    cbits  <m>
    alloc  <q> <0|1>            # 0 => |0> (no-op), 1 => X to make |1>
    gate   <name> <t0,t1,..> <ctrls>   # ctrls: '-' or c0=1,c1=0,...
    meas   <q> <c>
    output <c0,c1,..>          # classical bits holding the return value

Gate names map to Qiskit gates; a controlled gate becomes the base gate's
.control(len(ctrls), ctrl_state=...), with ctrl_state built from the
per-control polarities (Qiskit reads ctrl_state right-to-least-significant).
"""
import sys

from qiskit import QuantumCircuit

# qurts-core gate name -> (qiskit method name on QuantumCircuit, arity)
# EU unitaries and EC lifted injections share this table; both are just
# named gates at the circuit level.
GATES = {
    "I":   ("id",   1),
    "X":   ("x",    1),
    "Y":   ("y",    1),
    "Z":   ("z",    1),
    "H":   ("h",    1),
    "S":   ("s",    1),
    "Sdg": ("sdg",  1),
    "T":   ("t",    1),
    "Tdg": ("tdg",  1),
    "not": ("x",    1),   # [not] is the 1-qubit lift of X
    "cnot": ("cx",  2),   # [cnot]: 2-qubit
    "swap": ("swap", 2),
}


def parse_ir(text):
    qubits = cbits = 0
    instrs = []
    outputs = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        parts = line.split()
        head = parts[0]
        if head == "qubits":
            qubits = int(parts[1])
        elif head == "cbits":
            cbits = int(parts[1])
        elif head == "alloc":
            instrs.append(("alloc", int(parts[1]), parts[2] == "1"))
        elif head == "gate":
            name = parts[1]
            targets = [] if parts[2] == "-" else [int(t) for t in parts[2].split(",")]
            ctrls = []
            if parts[3] != "-":
                for c in parts[3].split(","):
                    q, pol = c.split("=")
                    ctrls.append((int(q), pol == "1"))
            instrs.append(("gate", name, targets, ctrls))
        elif head == "meas":
            instrs.append(("meas", int(parts[1]), int(parts[2])))
        elif head == "output":
            outputs = [] if parts[1] == "-" else [int(c) for c in parts[1].split(",")]
        else:
            raise ValueError(f"unknown IR line: {line!r}")
    return qubits, cbits, instrs, outputs


def build(qubits, cbits, instrs):
    qc = QuantumCircuit(qubits, cbits)
    for ins in instrs:
        if ins[0] == "alloc":
            _, q, is_one = ins
            if is_one:
                qc.x(q)              # qubits start at |0>; X makes |1>
        elif ins[0] == "gate":
            _, name, targets, ctrls = ins
            apply_gate(qc, name, targets, ctrls)
        elif ins[0] == "meas":
            _, q, c = ins
            qc.measure(q, c)
    return qc


def apply_gate(qc, name, targets, ctrls):
    if name not in GATES:
        raise ValueError(f"unknown gate {name!r}")
    method, arity = GATES[name]
    if len(targets) != arity:
        raise ValueError(f"gate {name} wants {arity} targets, got {len(targets)}")

    if not ctrls:
        getattr(qc, method)(*targets)
        return

    # Controlled: build the base gate, wrap in .control() with a ctrl_state
    # whose bits are the control polarities. Qiskit's ctrl_state is a bit
    # string read most-significant-first over the control qubits in the
    # order we pass them, so build it to match ctrl_qubits order below.
    base = QuantumCircuit(arity, name=name)
    getattr(base, method)(*range(arity))
    gate = base.to_gate()

    ctrl_qubits = [q for q, _ in ctrls]
    # ctrl_state string: leftmost char = highest-order control. We list
    # controls in ctrl_qubits order, so reverse polarities into the string.
    ctrl_state = "".join("1" if pol else "0" for _, pol in reversed(ctrls))
    cgate = gate.control(len(ctrls), ctrl_state=ctrl_state)
    qc.append(cgate, ctrl_qubits + targets)


def main():
    # qc.draw(output="text") emits Unicode box-drawing characters. When
    # stdout is a real console, Python already talks to it natively
    # (WriteConsoleW) and gets this right regardless of the console's
    # codepage -- reconfiguring here would override that and route through
    # the codepage-dependent path instead, which is what we don't want.
    # When stdout is redirected (a file or a pipe -- e.g. piped into a
    # pager, or captured by another program), there's no console to talk
    # to natively, so force UTF-8 rather than falling back to whatever
    # locale encoding was inherited (that mismatch is what originally
    # raised UnicodeEncodeError here on Windows).
    if hasattr(sys.stdout, "reconfigure") and not sys.stdout.isatty():
        sys.stdout.reconfigure(encoding="utf-8")

    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    if not args:
        print("usage: build_circuit.py <ir-file|-> [--simulate] [--draw] [--shots N]",
              file=sys.stderr)
        sys.exit(1)

    if args[0] == "-":
        text = sys.stdin.read()
    else:
        with open(args[0]) as f:
            text = f.read()
    qubits, cbits, instrs, outputs = parse_ir(text)
    qc = build(qubits, cbits, instrs)

    if "--draw" in flags:
        print(qc.draw(output="text"))

    print(f"qubits={qubits} cbits={cbits} outputs(cbits)={outputs}")

    if "--simulate" in flags:
        shots = 1024
        for f in sys.argv[1:]:
            if f.startswith("--shots"):
                shots = int(f.split("=")[1]) if "=" in f else shots
        try:
            from qiskit_aer import AerSimulator
        except ImportError:
            print("qiskit-aer not installed; skipping simulation "
                  "(pip install qiskit-aer)", file=sys.stderr)
            return
        if cbits == 0 or not any(ins[0] == "meas" for ins in instrs):
            print("no measurable output (the entry returns a classical/unit "
                  "value; nothing to sample)")
            return
        from qiskit import transpile
        sim = AerSimulator()
        # Controlled custom gates (from .control()) aren't Aer basis
        # instructions; transpiling lowers them to gates the simulator runs.
        qc_run = transpile(qc, sim)
        result = sim.run(qc_run, shots=shots).result()
        counts = result.get_counts()
        print(f"counts (over {shots} shots):")
        for outcome, n in sorted(counts.items(), key=lambda kv: -kv[1]):
            print(f"  {outcome}: {n}")


if __name__ == "__main__":
    main()
