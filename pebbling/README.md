# Pebbling circuit graph

Builds the paper's Definition 5.1 circuit graph (`V = V_init ⊔ V_gate ⊔
V_merge ⊔ V_linear`, `loc: V -> Loc_q`) for an already type-checked
qurts-core program. **This is only the graph.** Section 5.1's actual pebble
game -- deciding which vertices can share one physical qubit, i.e. an actual
uncomputation/scheduling strategy -- is not implemented here. See "Scope" below.

Usage:

```
qurts -graph examples/example_my_cnot.qurts-core       # text listing to stdout
qurts -graph-dot examples/example_my_cnot.qurts-core   # Graphviz DOT to examples-graphs/
```

## Construction

Mirrors Unqomp's own circuit-graph builder (Paradis et al. 2021, PLDI,
Section 5.2): one node per gate application, wired to each operand's
*latest* node, walking the program in order. Extended with Qurts's own two
additions:

- **V_merge**, for a `qif`'s two branches converging back into one value.
  Both branches are built independently from the same starting point; where
  they leave a given (sub-)value at the same vertex, nothing new is
  created; where they disagree, a `VMerge { mergeCtrl, mergeTrue,
  mergeFalse }` vertex is created, referencing the qif's own control and
  both branches' incoming vertices.
- **V_linear**, for an `EU` application (`U(x)` syntax) -- the type checker
  pins EU's result to `#bot` unconditionally (`expr_unitary`, Fig. 15), which
  is exactly Definition 5.1's "locations becoming linear when pebbled
  instead of affine". An `EC` application (`[c](x)`) is classified `V_gate`
  instead, since it preserves whatever lifetime tag its argument already
  had.

Function calls are inlined transparently (same choice `Uncompute.hs` and
`Circuit.hs` both already make) -- there is no separate per-call graph
fragment, and no separate "graph for this function" vs "graph for the whole
program" distinction beyond which top-level function you start from
(`buildFunctionGraph` for one function in isolation, `buildProgramGraph` for
the whole file's own entry point, i.e. its last function, exactly matching
`Circuit.hs`'s own convention).

The traversal itself (`LocMap` threaded through a fold over each block's
flattened statements) is structured like `Uncompute.hs`'s own
`DefMap`/`recordBinding`/`resolveExpr` -- deliberately, to keep the two
passes easy to compare -- but is simpler in one respect: this module only
ever needs vertex *identity*, never to reconstruct valid surface syntax, so
none of `Uncompute.hs`'s rename/copy-planning machinery is needed here.

## Scope: what this does and doesn't give you

**`drop` has no effect on the graph at all.** Every `[0]()`/`[1]()` call
mints its own fresh `V_init`, unconditionally, with no reuse. The paper's
own Appendix D.1 worked example (a qif branch doing `drop y; let y = |0>;
y`) shows that branch's fresh `|0>` landing back on the *original* init
vertex in the final diagram -- but that reuse is a qubit-allocation
decision (which vertices end up sharing one physical qubit), i.e. exactly
what the pebble game itself decides; it is not a consequence of Definition
5.1 alone. This module deliberately builds the *unreduced* graph -- the
same choice Unqomp's own construction makes: build the full graph first,
decide reuse/scheduling as a separate, later step.

Consequence: **building the graph does not, by itself, make any of
`Uncompute.hs`'s three currently-unhandled example shapes compile
end-to-end** (a `drop` nested inside a qif branch; a qif branch whose
result depends on a reference created locally inside that branch; one half
of a jointly-computed pair while its sibling is still live -- see
`uncompute/README.md`). What it *does* do is remove the structural barrier
`Uncompute.hs`'s own `Origin` tree has for all three: real, shared vertex
identity instead of an unshared tree, and independent tracking of a pair's
two components. Confirmed by running `-graph` directly against all three
shapes (`example_reinitialise.qurts-core`, `example_self_controlled_uncomp.qurts-core`,
`example_cnot_reinit.qurts-core`) -- each builds a clean, well-formed graph,
where `Uncompute.hs` fails outright with "not handled yet". Actually
*resolving* any of them (deciding a real reversal/reuse strategy) is exactly
the pebble game, and is future work, not this module's job.

Classical `if` is not handled (`Left` error) -- it is never Purely Quantum
(the type checker itself refuses to nest one inside a qif branch), and
Definition 5.1's graph, like the pebble game it feeds, is only ever defined
over Purely Quantum code. Same boundary `Uncompute.hs` already draws for the
identical construct.

## Files

- `CircuitGraph.hs` -- the data types (`VertexId`, `Location`, `GateOp`,
  `VertexKind`, `Vertex`, `CircuitGraph`) and the construction pass
  (`buildFunctionGraph`, `buildProgramGraph`).
- `RenderGraph.hs` -- two read-only views over an already-built
  `CircuitGraph`: a plain indented text listing (`renderText`, no external
  tools needed) and Graphviz DOT (`renderDot` -- render with
  `dot -Tpng foo.dot -o foo.png`, or paste into
  https://dreampuf.github.io/GraphvizOnline).
