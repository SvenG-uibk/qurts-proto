-- This module classifies some gates as "diagonal" (isDiagonalUnitary /
-- isDiagonalClassical) so Uncompute.hs's reverseOrigin can skip reversing
-- them entirely when unwinding a value's construction history, on the
-- reasoning that a diagonal gate never moves a computational-basis ket to a
-- different one, only multiplies it by a phase -- so undoing it is never
-- *necessary* to reach |0>.
--
-- History: this shortcut existed once, was found unsound as a blanket rule
-- and removed (2026-08-08) -- confirmed by direct construction: H then Z,
-- both bare EU, inside one branch of a qif whose other branch is untouched,
-- then dropped. typ_qif (TypeChecker.hs) retags that branch's return value
-- #alpha (droppable) regardless of what bang-tag it actually carries,
-- including #bot from the EU-dispatched H -- so the qubit reaching the drop
-- was never actually confined to a single basis ket the way the shortcut's
-- own argument assumes, and skipping Z's reversal there left it entangled
-- with the qif's control instead of reaching |0>.
--
-- Reinstated (2026-08-12) per direct confirmation from Kengo, the qurts-core
-- paper's author: any value that type-checks its way to a `drop` is qfree by
-- the type system's own guarantee, and a diagonal gate applied to a value
-- that's genuinely confined to a basis ket is exactly the case where
-- skipping its reversal is sound -- unconditionally, no gate-name exception
-- needed beyond "is this gate diagonal at all". This is a stronger claim
-- than Unqomp's own qfree criterion licenses on its own (Paradis et al.
-- 2021, PLDI: qfree requires coefficient exactly 1, which Z itself fails,
-- and Unqomp's own paper treats phase kickback as "built by hand, entirely
-- outside" its automatic machinery) -- the extra step is Kengo's claim that
-- Qurts's own type system, correctly enforced, already rules out the
-- "genuinely superposed at the point of the diagonal gate" case that would
-- make skipping unsound.
--
-- "Correctly enforced" is the load-bearing phrase: the H;Z-in-qif-branch
-- counterexample above still type-checks today (kept as
-- examples/example_diagonal_skip_counterexample.qurts-core) and reinstating
-- this skip reproducibly mis-uncomputes it -- verified by an actual
-- build+simulate run, not just re-argued: deterministic (1000/1000) under
-- full reversal, ~50/50 (entangled) under this skip. See grover.txt point 7
-- for the full reproduction. The gap is understood to be in TypeChecker.hs's
-- own qif rule (checkExpr (EQIf ...), `return (TyBang alpha (stripBang t))`)
-- silently retagging a branch built from a non-diagonal bare-EU gate (H) as
-- if its result were droppable/basis-confined -- fixing that is the next
-- step, tracked separately from this module. Until it lands, this skip is
-- only actually sound for values whose *entire* tracked history really is
-- qfree, same as before reinstatement, just no longer enforced by the type
-- checker for every program this skip now applies to.
module GateInverse (unitaryInverse, classicalInverse, isKnownClassicalInjection, isTwoQubitClassical, isDiagonalUnitary, isDiagonalClassical) where

import Ast (Unitary (..), Classical (..))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
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
-- Section 3.1's "Lifted functions") and their inverses. The paper names
-- not/cnot/swap explicitly here -- Section 3.1: "[not] is a 1-qubit lifted
-- function which represents the X-gate, [cnot] is a 2-qubit lifted function
-- which represents the controlled-X gate, and [swap] is a 2-qubit lifted
-- function which represents the swap gate" -- but the table also includes
-- the rest of the diagonal family (I, Z, S, Sdg, T, Tdg), none of which are
-- "classical Boolean injective functions" in that literal sense (they're
-- phase gates: Z|1> = -|1>, not a bit permutation at all).
--
-- The diagonal gates were briefly removed from here on the reasoning that
-- admission to EC should be restricted to Unqomp's qfree criterion
-- (coefficient exactly 1, no phase). That conflated two different
-- questions: "is dropping a value built from this gate sound" and "does
-- the gate happen to look like a classical function". The former is what
-- the type checker actually needs to guarantee, and it's answered entirely
-- by two things this module already does regardless of what's diagonal or
-- classical: (a) Uncompute.hs now reverses every gate fully and faithfully,
-- which is sound for *any* gate with a correctly recorded inverse, diagonal
-- or not (see the module-level note); and (b) a name with no entry in this
-- table fails loudly at uncompute time ("no known inverse for..."), never
-- silently -- see classicalInverse's own Nothing-means-unknown policy just
-- below. Given both of those, restricting *which* correctly-invertible gate
-- names are admissible is not a soundness question any more, and enforcing
-- it in the type checker rejects well-typed, faithfully-uncomputable
-- programs for a reason that no longer applies -- Qurts's type system is
-- not in the business of judging whether a program's phase games add up to
-- something useful, only whether dropping a value is safe. The whole
-- diagonal family is back for that reason (see the module-level note for
-- what a real fix -- one that actually distinguishes "safe to leave
-- un-reversed" from "would destroy an intended effect" -- would need, and
-- why it doesn't belong here).
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
-- Each entry carries its own arity (1 or 2 qubits) alongside its inverse
-- name, rather than arity living in a second, separately-maintained list
-- -- that used to be exactly this table's own shape (Map Text Text, no
-- arity at all), with a *different* list (isTwoQubitClassical, added
-- later to fix the arity-mismatch bug below) tracking which names were
-- 2-qubit. Two lists that both have to be updated in step for every gate
-- is precisely the kind of thing that silently goes stale the next time
-- someone adds a gate here and forgets the other one -- which is exactly
-- how [c](x)'s own arity went unchecked in the first place (see
-- isTwoQubitClassical's own history). One table, one place to update.
classicalInverseTable :: Map.Map Text (Text, Int)
classicalInverseTable = Map.fromList $ map (\(a, b, n) -> (pack a, (pack b, n)))
  [ ("X",    "X",    1)
  , ("cnot", "cnot", 2)
  , ("swap", "swap", 2)
  , ("I",    "I",    1)
  , ("Z",    "Z",    1)
  , ("S",    "Sdg",  1)
  , ("Sdg",  "S",    1)
  , ("T",    "Tdg",  1)
  , ("Tdg",  "T",    1)
  ]

-- | Look up the inverse of a named classical injection. Same Nothing-means-
-- unknown policy as 'unitaryInverse'.
classicalInverse :: Classical -> Maybe Classical
classicalInverse (Classical name) = Classical . fst <$> Map.lookup name classicalInverseTable

-- | Whether `c` is one of the gate names TypeChecker.hs's EC rule (`[c](x)`)
-- is allowed to accept at all. This is the *same* set as classicalInverseTable's
-- keys, by construction (see 'classicalInverse') -- kept as an explicit,
-- separately-named predicate (rather than just `isJust . classicalInverse`)
-- so the intent at the call site (TypeChecker.hs's checkExpr(EC c x)) reads
-- as "is c a name this module has a verified inverse for", which is now the
-- *entire* criterion (see classicalInverseTable's own note on why "is c a
-- classical Boolean function specifically" was the wrong question to be
-- asking). This still means an arbitrary typo or an unrecognised gate name
-- (e.g. "H", which has no entry here -- only in unitaryInverseTable, EU's
-- own table) is rejected at type-check time rather than surfacing later as
-- an uncompute-time failure; the difference from before is only that
-- membership in classicalInverseTable is no longer curated down to "true"
-- classical injections; it's curated down to "gates we've actually verified
-- the inverse of". Tying admission to the type checker itself, off the same
-- source of truth this module already maintains, makes "coincidentally not
-- typo'd into the table" no longer the
-- thing standing between a well-typed program and a miscompiled one.
isKnownClassicalInjection :: Classical -> Bool
isKnownClassicalInjection (Classical name) = name `Map.member` classicalInverseTable

-- | Whether `c` names a genuinely 2-qubit classical injection (cnot, swap)
-- rather than a 1-qubit one (X, I, Z, S, Sdg, T, Tdg) -- read directly off
-- classicalInverseTable's own arity field (see its note on why that's a
-- single table now, not this plus a second list). TypeChecker.hs's
-- checkExpr(EC c x) uses this to require the *matching* argument shape (a
-- single qubit for a 1-qubit name, a same-lifetime pair for a 2-qubit
-- one) -- previously unchecked at all, so `[cnot](q)` on a single qubit,
-- or `[X](p)` on a pair, both type-checked and passed uncompute, only
-- ever failing at the very last stage as a raw Python ValueError out of
-- build_circuit.py's own arity check ("gate cnot wants 2 targets, got 1"),
-- confirmed empirically -- never a clean error anywhere in the Haskell
-- pipeline that's supposed to catch exactly this kind of mistake first.
isTwoQubitClassical :: Classical -> Bool
isTwoQubitClassical (Classical name) = fmap snd (Map.lookup name classicalInverseTable) == Just 2

-- | The gate names, EU and EC alike, that are diagonal in the computational
-- basis -- phase-only (I/Z/S/Sdg/T/Tdg), as opposed to X/Y/H (which mix
-- basis states) or cnot/swap (which permute them). Same set on both sides:
-- a name means the same physical gate whichever syntax invoked it. See the
-- module-level note for what this backs and what it currently depends on.
diagonalGateNames :: Set.Set Text
diagonalGateNames = Set.fromList $ map pack ["I", "Z", "S", "Sdg", "T", "Tdg"]

-- | Whether a unitary gate named via EU (bare U(x)) is diagonal -- see
-- diagonalGateNames and the module-level note. Used by Uncompute.hs's
-- reverseOrigin to skip reversing this gate entirely.
isDiagonalUnitary :: Unitary -> Bool
isDiagonalUnitary (Unitary name) = name `Set.member` diagonalGateNames

-- | Same, for a classical injection named via EC ([c](x)). Same name set as
-- isDiagonalUnitary -- see diagonalGateNames.
isDiagonalClassical :: Classical -> Bool
isDiagonalClassical (Classical name) = name `Set.member` diagonalGateNames
