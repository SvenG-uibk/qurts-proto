-- This module used to also classify some gates as "diagonal" and let
-- Uncompute.hs skip reversing them (isDiagonalUnitary/isDiagonalClassical,
-- backing a shortcut in reverseOrigin's FromGate/FromClassicalGate cases).
-- That shortcut is gone -- it was unsound, not just an optimisation.
--
-- The argument for it was: "a diagonal gate never moves a qubit to a
-- different computational-basis branch, only multiplies that branch's own
-- amplitude by a phase, so reversing it is never *necessary* to reach |0>".
-- True in isolation, but it silently assumed the qubit was already confined
-- to a single basis ket at the point the diagonal gate was applied --
-- nothing in Qurts's type system guarantees that. A qif's own typing rule
-- (typ_qif, TypeChecker.hs) retypes a branch's return value to #alpha T
-- regardless of what bang-tag that branch actually produced, including
-- #bot from an EU-dispatched *non*-diagonal gate (e.g. H) earlier in that
-- same branch's own local history -- so a later diagonal gate in the same
-- chain can end up applied to a value that is genuinely, locally superposed,
-- not just phase-tagged per branch. Skipping its reversal there silently
-- entangles the dropped value with whatever it was branching on, instead of
-- returning it to |0> -- confirmed by direct construction (H then Z, both
-- bare EU, inside one branch of a qif whose other branch is untouched: the
-- compiled circuit's two branches disagree on the qubit's final value under
-- the old skip-based reversal).
--
-- Full, faithful reversal -- apply each gate's own exact inverse, in exact
-- reverse order, every time, never skipping any step regardless of what the
-- gate is -- is what Qurts's uncomputation-semantics theorem (Thm 5.4, the
-- proof that uncomputation semantics and simulation semantics agree)
-- actually establishes as correct. There is no theorem, in Qurts or in
-- Unqomp (Paradis et al. 2021, PLDI -- the paper this project's own
-- uncomputation approach is modelled on), licensing a shortcut keyed on a
-- gate's name being diagonal. Unqomp's own qfree criterion is in fact
-- stricter than "diagonal": qfree requires |i>|k> -> |i>|f(k)> with
-- coefficient exactly 1, which a phase gate like Z fails outright (Z|1> =
-- -|1>) -- Unqomp's own algorithm would refuse to auto-reverse Z at all,
-- the same way it refuses H, and its own paper states plainly that Grover's
-- phase kickback is "built by hand, entirely outside" their automatic
-- machinery. Consequently example_grover.qurts-core no longer computes its
-- oracle's phase via a temporary ancilla that gets dropped through a
-- tracked Z; it applies Z directly to one search-register qubit, controlled
-- by the others via qif (a direct phase oracle, no ancilla, nothing to
-- reverse at all) -- see that file for the restructuring.
module GateInverse (unitaryInverse, classicalInverse, isKnownClassicalInjection) where

import Ast (Unitary (..), Classical (..))
import qualified Data.Map.Strict as Map
import Data.Text (Text, pack)

-- Table of standard single-qubit unitaries named via EU (bare U(x) syntax,
-- requiring the argument to be exactly #bot qbit) and their inverses.
--
-- Every gate actually used in the examples so far (H) is self-inverse, but
-- the table is written to hold non-self-inverse gates too (S/Sdg, T/Tdg),
-- since assuming self-inverse as a fallback for an unrecognised gate name
-- would silently generate a reversal that is not actually the inverse.
unitaryInverseTable :: Map.Map Text Text
unitaryInverseTable = Map.fromList $ map (\(a, b) -> (pack a, pack b))
  [ ("I", "I")
  , ("X", "X")
  , ("Y", "Y")
  , ("Z", "Z")
  , ("H", "H")
  , ("S", "Sdg")
  , ("Sdg", "S")
  , ("T", "Tdg")
  , ("Tdg", "T")
  ]

-- | Look up the inverse of a named unitary gate. Returns Nothing for any
-- gate name not in the table. Callers must treat Nothing as "this gate's
-- inverse is unknown", not as licence to assume self-inverse -- gate names
-- are uninterpreted text in Ast.hs, so there is no way to derive an inverse
-- for a name this table doesn't recognise.
unitaryInverse :: Unitary -> Maybe Unitary
unitaryInverse (Unitary name) = Unitary <$> Map.lookup name unitaryInverseTable

-- Table of named classical injections used via EC ([c](x)-style syntax,
-- Section 3.1's "Lifted functions") and their inverses. Restricted to
-- exactly the ones the paper names explicitly -- Section 3.1: "[not] is a
-- 1-qubit lifted function which represents the X-gate, [cnot] is a 2-qubit
-- lifted function which represents the controlled-X gate, and [swap] is a
-- 2-qubit lifted function which represents the swap gate" -- i.e. genuine
-- lifts of a classical Boolean injective function: |i>|k> -> |i>|f(k)>
-- with coefficient exactly 1, no phase at all (Unqomp's own qfree
-- definition, cited in the module note below). A phase gate like Z does
-- NOT satisfy that definition (Z|1> = -|1>, not |1>) even though it has a
-- perfectly well known inverse -- see the module-level note for why it was
-- removed from here rather than kept as a "known-inverse" convenience.
-- Same Nothing-means-unknown policy as unitaryInverseTable: a classical
-- injection can be an arbitrary user-defined bijection over bits, so
-- returning Nothing (rather than guessing self-inverse) for any name not
-- in this table is deliberate, not an oversight.
--
-- The paper calls this lifted X-gate "not"; this implementation calls it
-- "X" instead, on both the EU and EC sides, so there is exactly one name
-- for the gate rather than two. Keeping "not" (EC) alongside "X" (EU) for
-- the identical physical gate turned out to be a real, user-visible wart,
-- not just a naming quirk: build_circuit.py's compiled-circuit rendering
-- distinguishes an uncontrolled gate (which always draws as Qiskit's own
-- "X" box, regardless of which of our own names invoked it) from a
-- *controlled* one (which keeps our own name as an explicit label) -- so
-- the identical gate rendered as "X" in one circuit and "not" in another
-- depending only on whether it happened to sit under a qif in that
-- particular program, with no semantic difference at all. One name removes
-- that inconsistency at the source instead of explaining it away.
classicalInverseTable :: Map.Map Text Text
classicalInverseTable = Map.fromList $ map (\(a, b) -> (pack a, pack b))
  [ ("X",    "X")
  , ("cnot", "cnot")
  , ("swap", "swap")
  ]

-- | Look up the inverse of a named classical injection. Same Nothing-means-
-- unknown policy as 'unitaryInverse'.
classicalInverse :: Classical -> Maybe Classical
classicalInverse (Classical name) = Classical <$> Map.lookup name classicalInverseTable

-- | Whether `c` is one of the gate names TypeChecker.hs's EC rule (`[c](x)`)
-- is allowed to accept at all. This is the *same* set as classicalInverseTable's
-- keys, by construction (see 'classicalInverse') -- kept as an explicit,
-- separately-named predicate (rather than just `isJust . classicalInverse`)
-- so the intent at the call site (TypeChecker.hs's checkExpr(EC c x)) reads
-- as "is c a legitimate classical injection", not "do we happen to have an
-- inverse for it". Closes a real gap: without this check, `[c](x)` type-checked
-- for *any* identifier c, including a genuinely basis-mixing gate name like
-- "H" -- accepted by the type rule (preserving droppability, exactly like
-- [X]), and only ever caught downstream, by accident, when Uncompute.hs's
-- classicalInverse lookup failed to find an entry for it. That protection
-- depended entirely on this table happening to be small; any future
-- addition of a non-injective gate name to classicalInverseTable (e.g.
-- someone adding a phase gate because "it's self-inverse, that's enough")
-- would have silently reintroduced exactly that hole. Tying admission to
-- the type checker itself, off the same source of truth this module already
-- maintains, makes "coincidentally not typo'd into the table" no longer the
-- thing standing between a well-typed program and a miscompiled one.
isKnownClassicalInjection :: Classical -> Bool
isKnownClassicalInjection (Classical name) = name `Map.member` classicalInverseTable
