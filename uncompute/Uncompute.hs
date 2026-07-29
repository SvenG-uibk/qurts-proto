-- The actual uncomputation pass: naive strategy only (compute forward, then
-- reverse everything in reverse order right before the drop). qif and
-- function calls each have a first, deliberately partial version (see
-- FromQIf and resolveExpr's ECall case below).
--
-- Scope for this version: a `drop x` can be reversed when x's definition
-- chain, walked backward, consists of `let`-bound EU/EC applications, bare
-- renames, &borrow bindings, pair-destructures of a literal pair
-- construction, qif expressions whose *result* is what's being dropped
-- (see FromQIf), and calls to functions whose own bodies are themselves
-- built out of exactly this same list (see resolveExpr's ECall case) --
-- terminating in [0]()/[1](). [1]() needs an inserted [not] flip (via EC,
-- not EU -- see the FromInit1 case below for why) to actually reach |0>
-- before the point where the `drop` used to be. EC (classical injections
-- like [not]/[cnot]/[swap]/[Z]) is only reversible for names in
-- GateInverse.hs's classicalInverseTable, and only when what it's chained
-- through is a single already-tracked value, not a pair whose two halves
-- have been separately destructured (that needs the paper's split/merge
-- pebble-game machinery, same as the harder qif case -- see
-- FromPair/FromClassicalGate below for exactly where that line is drawn).
-- The `drop` statement itself is then simply omitted, not replaced by
-- another drop, UNLESS a later `endlft` intervenes before the end of the
-- block -- see hasLaterEndlft for why that case needs an explicit one after
-- all. Every other construct a chain might pass through (a classical `if`,
-- a pair destructured from an EC/ECall result rather than a literal pair
-- construction, a qif whose *branch* contains its own nested drop, a call
-- whose own argument is itself a reference some *nested* call created
-- internally rather than one of its own parameters) fails loudly with a
-- specific reason rather than silently doing nothing or guessing wrong.
module Uncompute
  ( uncomputeProgram
  , uncomputeFunction
  , uncomputeBlock
  , DefMap
  , Origin (..)
  , buildDefMap
  ) where

import Ast
import GateInverse (unitaryInverse, classicalInverse)
import PrettyAst (flattenStmt)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (pack)

-- | What a variable is, as of the point its binding was recorded, fully and
-- eagerly resolved back through any renames/gates -- never a raw name to be
-- looked up again later.
--
-- This is eager on purpose, not just for simplicity: qurts-core frees a
-- variable's name for reuse the moment it's consumed (EVar/EU/EC all call
-- removeVar on their argument -- see TypeChecker.hs), so a name that meant
-- one thing when first referenced can legally mean something completely
-- different by the time some *later* `drop` gets around to asking about it.
-- An earlier version of this map stored the raw Expr and re-resolved
-- variable names lazily, at reversal time, against whatever the *latest*
-- binding for that name happened to be -- which silently produced wrong
-- output on programs that rebind a name after using it, e.g.:
--
--   let x = [1]() ; let y = x ; let x = [0]() ; drop x ; drop y ;
--
-- Here `y` truly holds the old (never-flipped) |1> qubit, but the lazy
-- version resolved y's chain through *whichever* binding of "x" was live at
-- drop-time -- the fresh |0> one -- and concluded (wrongly) that `drop y`
-- needed no reversal at all, silently discarding a never-flipped qubit
-- while still reporting success. Resolving eagerly, at record time, closes
-- that hole: each Origin is a self-contained value, immune to whatever
-- happens to variable names afterward.
data Origin
  = FromInit0                    -- [0](): already |0>, nothing to undo
  | FromInit1                    -- [1](): needs a [not] flip before it's safe to drop
  | FromTrivial                  -- true/false/()/copy/meas(_): Drop-trait, always droppable regardless of history
  | FromBorrow                   -- &a x: always droppable, no gate produced it
  | FromGate Unitary Origin      -- EU u prev, prev already resolved
  | FromClassicalGate Classical Origin -- EC c prev, prev already resolved
  | FromPair Origin Origin       -- (x0,x1), components already resolved
  | FromQIf Var Origin Origin    -- qif ctrl {..ret} else {..ret}, both
                                  -- branch return values already resolved
                                  -- (see resolveBranchReturn) -- ctrl kept
                                  -- as a raw Var, not resolved further,
                                  -- since it's reused as-is (typ_qif never
                                  -- consumes a qif's control reference)
  | FromUnbound Var              -- referenced a name with no known local definition
  | FromUnhandled Expr           -- a construct this pass doesn't chain through
                                  -- (if/call/pair-producing EC, or a qif with
                                  -- a drop nested inside one of its own
                                  -- branches); kept raw only so describeExpr
                                  -- can explain why
  deriving (Show)

-- | Map from a variable name to what it's currently known to have come
-- from, fully resolved as of the point its binding was recorded (see
-- 'Origin').
type DefMap = Map.Map Var Origin

-- | Every function in the program currently being uncomputed, by name --
-- needed to resolve a call's own body (see resolveExpr's ECall case) since
-- uncomputeFunction otherwise only ever sees one function at a time.
type FuncEnv = Map.Map FuncName Function

-- | The two pieces of context that stay constant while resolving a single
-- top-level function -- as opposed to the DefMap and the renames map just
-- below, both of which change as resolution descends into a qif branch or
-- an inlined call's own body.
--
--   rcFuncs:  every function in the program, for ECall's own lookup.
--   rcCopies: original-name -> preserved-copy-name, for reference
--     arguments a call consumes that some later drop's reversal will need
--     again (see planCallCopies). Empty while merely *discovering* what's
--     needed (collectDeferredBorrows's own first, trial pass); populated
--     for the real pass that actually generates output.
data ResolveCtx = ResolveCtx
  { rcFuncs  :: FuncEnv
  , rcCopies :: Map.Map Var Var
  }

-- | Translate a single raw variable reference through the two substitutions
-- that matter when a construct's *name* (not just its Origin) ends up
-- embedded directly into reconstructed code -- currently just FromQIf's
-- ctrl field, and ECall's own argument list when inlining a *further*
-- nested call. `renames` first (a callee's own parameter name -> whatever
-- the caller passed for it, composing correctly across nested calls since
-- it's threaded through every level), then `copies` (a call-consumed
-- top-level variable -> the preserved copy standing in for it, see
-- planCallCopies) -- always in that order, since `copies` is only ever
-- keyed by names as they appear at the *current function's own* top level,
-- which `renames` is exactly what produces.
translateVar :: Map.Map Var Var -> Map.Map Var Var -> Var -> Var
translateVar renames copies v =
  let v' = Map.findWithDefault v v renames
  in Map.findWithDefault v' v' copies

-- | True for an Origin that needs no gates at all to become safe to drop --
-- Fig. 6's Drop trait: [0](), bool/unit/copy, &borrow, and (recursively,
-- via drop_tuple) a pair of such. Used to let a whole (non-destructured)
-- pair be dropped directly when it doesn't actually need any reversal work.
isTriviallyDroppable :: Origin -> Bool
isTriviallyDroppable FromInit0        = True
isTriviallyDroppable FromTrivial      = True
isTriviallyDroppable FromBorrow       = True
isTriviallyDroppable (FromPair o0 o1) = isTriviallyDroppable o0 && isTriviallyDroppable o1
isTriviallyDroppable _                = False

-- | Resolve a variable reference against what's known so far. An unbound
-- name (a function parameter, or anything this pass doesn't track) becomes
-- 'FromUnbound' rather than failing outright here -- resolution never
-- fails; only actually trying to reverse an unresolved/unbound chain does,
-- and only if that chain turns out to matter (i.e. some `drop` actually
-- needs it). Most bindings in a real program are never dropped at all.
resolveVar :: DefMap -> Var -> Origin
resolveVar defs x = Map.findWithDefault (FromUnbound x) x defs

-- | Eagerly resolve an expression into a self-contained Origin, chasing
-- through every construct 'reverseOrigin' below knows how to reverse
-- (renames, gates, literal pairs, calls) using the *current* defs -- i.e.
-- exactly the bindings in effect at this statement, not whatever they
-- become later. `renames` is the active parameter-name -> caller-name
-- substitution while resolving *inside* an inlined call's own body (empty
-- at ordinary top level); see the ECall case and 'translateVar'.
resolveExpr :: ResolveCtx -> Map.Map Var Var -> DefMap -> Expr -> Origin
resolveExpr _   _       _    EInit0        = FromInit0
resolveExpr _   _       _    EInit1        = FromInit1
resolveExpr _   _       _    ETrue         = FromTrivial
resolveExpr _   _       _    EFalse        = FromTrivial
resolveExpr _   _       _    EUnit         = FromTrivial
resolveExpr _   _       _    (ECopy _)     = FromTrivial
-- meas(x) always has type #TOP bool (expr_measure), unconditionally
-- droppable (drop_bool has no lifetime-activity condition at all) same as
-- a literal true/false -- regardless of what qubit was measured or what
-- happened to it beforehand. Measurement genuinely can't be reversed to
-- recover the pre-measurement qubit state (see describeExpr's EMeas case,
-- still used for the qubit itself, e.g. reversing through the *argument*
-- of a later EU/EC that consumed it), but that's a different question from
-- whether the resulting classical bool needs any reversal before it can be
-- dropped -- it doesn't, ever, same reasoning as ECopy just above.
resolveExpr _   _       _    (EMeas _)     = FromTrivial
resolveExpr _   _       defs (EVar x)      = resolveVar defs x
resolveExpr _   _       defs (EU u x)      = FromGate u (resolveVar defs x)
-- EC c x: chased through unconditionally, same as EU, regardless of what x
-- resolves to -- including when x is itself a FromPair (e.g. [cnot](p)).
-- That's deliberately harmless, not a scope creep into the pair-producing
-- case still marked "not handled" below: reverseOrigin's FromPair case is
-- unchanged, so a *destructured* half of an EC-on-a-pair result (the
-- example_cnot_reinit shape) still resolves to FromUnbound at the
-- SLetPair site exactly as before (recordBinding's SLetPair case only
-- unwraps a bare FromPair, not one wrapped in FromClassicalGate) and still
-- reports "no local definition found", unchanged. What this newly enables
-- is only the case where the EC result itself -- not a destructured half
-- of it -- is what eventually gets dropped or chained through further.
resolveExpr _   _       defs (EC c x)      = FromClassicalGate c (resolveVar defs x)
resolveExpr _   _       defs (EPair x0 x1) = FromPair (resolveVar defs x0) (resolveVar defs x1)
-- qif ctrl Bt Bf: resolve *each branch's own return value* against defs
-- seeded with the outer bindings in effect right here, folded forward
-- through that branch's own statements -- exactly what that branch can see
-- (see resolveBranchReturn). This only ever traces a self-contained
-- branch: whatever a branch's own `let`s build up out of its own local
-- state, same as any other Origin chain. It deliberately does not attempt
-- to notice when a branch's computation is entangled with something the
-- *other* branch (or the control reference itself) also depends on --
-- that harder case is exactly what reverseOrigin's FromQIf comment below
-- explains is out of scope for this first version.
--
-- ctrl itself is translated through `renames` before being embedded --
-- when this qif sits inside an inlined callee's own body (see the ECall
-- case below), ctrl as written is that callee's own parameter name, not a
-- name valid anywhere in the caller; translateVar maps it back to
-- whatever the caller actually knows it by. At ordinary top level
-- `renames` is empty, so this is a no-op and ctrl is used exactly as
-- written, same as before.
resolveExpr ctx renames defs (EQIf ctrl bt bf) =
  FromQIf (translateVar renames (rcCopies ctx) ctrl)
          (resolveBranchReturn ctx renames defs bt)
          (resolveBranchReturn ctx renames defs bf)
-- f<lts>(args): resolve *into* the callee's own body, exactly the way a
-- qif branch resolves into its own statements just above -- fold the
-- callee's statements (recordBinding) into a DefMap seeded with its own
-- parameters, then resolve its own return var. The seed is Origin
-- substitution (each parameter -> the already-resolved Origin of the
-- matching actual argument, via resolveVar on *this* call's own defs) --
-- not the caller's ambient bindings the way a qif branch's seed is,
-- since a function body has no access to the caller's other locals at
-- all (no closures in this language) -- only to what's actually passed.
--
-- lts (the call's lifetime arguments) are never consulted: this pass
-- tracks no lifetimes at all (see staticallyDroppableOrigin's own note),
-- and nothing it ever reconstructs writes out a lifetime annotation of
-- its own -- a reused control variable already carries whatever lifetime
-- its own binding gave it.
--
-- calleeRenames -- translating each actual argument through the *current*
-- renames (so a call nested inside an already-inlined body composes
-- correctly back to the outermost caller) and then through rcCopies (an
-- argument this call itself consumes gets swapped for its preserved copy,
-- if planCallCopies decided one was needed -- see uncomputeStmts) -- is
-- what lets a callee's *own* qif, controlled by its *own* parameter (e.g.
-- oracle/non_zero's x/y/z), reconstruct correctly at the call site: ctrl
-- ends up being the caller's actual variable (or its copy), never the
-- callee's internal parameter name, which wouldn't mean anything outside
-- the callee's own (never re-executed) body.
--
-- Recursion here (a callee calling a further callee) is always
-- well-founded: TypeChecker.hs's checkProgram comment notes each function
-- may only call ones already defined above it, so the call graph is a DAG,
-- never a cycle.
--
-- No separate purely-quantum pre-check is needed to gate this: whatever
-- the callee's body does that this pass can't chain through (EMeas is
-- already fine -- FromTrivial, same as at top level; a classical EIf, or
-- a call to something not found in funcs) still resolves to
-- FromUnhandled/FromUnbound and fails loudly the same way it would have
-- at top level, just discovered one level down.
--
-- A further gap this doesn't cover, found via example_grover_amplified's
-- own `oracle` (not example_grover's simpler one): calleeRenames only
-- ever translates a callee's own *parameters* -- a reference the callee
-- creates *itself*, via its own SLetRef, and then passes into a *further*
-- nested call (oracle's `let rc1 = &alpha c1 ; ... ;
-- all_satisfied3<alpha>(rc1, rc2, rc3)`, where all_satisfied3's own qifs
-- are controlled by its own c1/c2/c3 params) has no caller-visible name to
-- translate to at all -- rc1 only ever exists within oracle's own body,
-- the same way a branch-locally-bound control has no caller-visible name
-- (see reverseOrigin's FromQIf comment on that case -- this is its
-- function-call-shaped sibling, one function-call boundary removed
-- instead of one qif-branch boundary). planCallCopies can't rescue this
-- either: it only ever looks at the *current* function's own top-level
-- call arguments, and rc1 never appears as one (it's oracle's own local
-- call to all_satisfied3, never visible to grover_diffusion/grover at
-- all). Confirmed empirically: example_grover.qurts-core's own oracle
-- (whose qifs are controlled directly by its own x/y/z parameters, no
-- further nested call in between) uncomputes successfully;
-- example_grover_amplified.qurts-core's oracle (which routes through
-- clause_or2/clause_nand2/clause_unit and a further all_satisfied3 call
-- first) fails with "no local definition found for Var \"rc1\"" reaching
-- into that inner reference. Left for later, alongside the branch-local
-- case it mirrors.
resolveExpr ctx renames defs (ECall fname _lts args) =
  case Map.lookup fname (rcFuncs ctx) of
    Nothing -> FromUnhandled (ECall fname [] args)
    Just calleeFn ->
      let paramNames    = map fst (sigParams (funSig calleeFn))
          translatedArgs = map (translateVar renames (rcCopies ctx)) args
          calleeRenames = Map.fromList (zip paramNames translatedArgs)
          calleeDefsSeed = Map.fromList (zip paramNames (map (resolveVar defs) args))
          calleeStmts   = flattenStmt (blockStmt (funBody calleeFn))
          calleeDefs    = foldl (flip (recordBinding ctx calleeRenames)) calleeDefsSeed calleeStmts
      in resolveVar calleeDefs (blockRet (funBody calleeFn))
resolveExpr _   _       _    e             = FromUnhandled e

-- | Resolve a qif branch's own return variable against defs seeded with
-- the outer bindings in effect at the qif itself, folded forward through
-- that branch's own local statements (recordBinding, same fold buildDefMap
-- uses). A branch is free to shadow an outer name (e.g. rebind `q` to a
-- gate applied to the outer `q`, as example_valid.qurts-core does) --
-- that's safe here because this fold happens in its own local copy of the
-- map, discarded once the branch is resolved; the outer defs used for the
-- rest of the function, and for the *other* branch, are never touched.
resolveBranchReturn :: ResolveCtx -> Map.Map Var Var -> DefMap -> Block -> Origin
resolveBranchReturn ctx renames defs (Block stmt ret) =
  resolveVar (foldl (flip (recordBinding ctx renames)) defs (flattenStmt stmt)) ret

-- | Update a DefMap with the binding (if any) a single statement
-- introduces. Used both by 'buildDefMap' (fold over a whole list) and by
-- 'uncomputeStmts' (incremental scan, since later drops must see only the
-- definitions in effect at that point in the source).
recordBinding :: ResolveCtx -> Map.Map Var Var -> Stmt -> DefMap -> DefMap
recordBinding ctx renames (SLetExpr y e)  m = Map.insert y (resolveExpr ctx renames m e) m
recordBinding _   _       (SLetRef y _ _) m = Map.insert y FromBorrow m
recordBinding _   _       (SLetPair y0 y1 x) m = case resolveVar m x of
  FromPair o0 o1 -> Map.insert y1 o1 (Map.insert y0 o0 m)
  _              -> m
recordBinding _   _       _ m = m

buildDefMap :: FuncEnv -> [Stmt] -> DefMap
buildDefMap funcs = foldl (flip (recordBinding (ResolveCtx funcs Map.empty) Map.empty)) Map.empty

note :: String -> Maybe a -> Either String a
note msg = maybe (Left msg) Right

-- Note: no EQIf case here -- resolveExpr now always turns an EQIf into a
-- FromQIf (never FromUnhandled), so describeExpr would never actually see
-- one; a drop nested inside a qif branch is reported separately, by
-- nestedDropReason below, before a chain through it is ever attempted.
-- Similarly, resolveExpr's ECall case now always resolves *through* a call
-- (transparently, into whatever the callee's own body's Origin chain is)
-- rather than wrapping it in FromUnhandled -- so the case below only ever
-- fires for a call to a function missing from funcs, which shouldn't
-- happen for a program that already passed checkProgram (UnknownFunction
-- would have caught it there first). If the callee's *own* body contains
-- something this pass can't chain through, resolution fails with that
-- inner construct's own description directly (e.g. "a classical if
-- expression"), not this one -- a small loss of "which function" context,
-- accepted for this first version rather than threading a call-site trail
-- through every failure path.
describeExpr :: Expr -> String
describeExpr (ECall (FuncName f) _ _) = "a call to " ++ show f ++ ", which isn't a known function in this program (unexpected for a program that already type-checked)"
describeExpr (EIf _ _ _)              = "a classical if expression: not handled yet"
describeExpr other                    = show other

-- | Pick a fresh variable name not already used anywhere in the function
-- (see 'boundVarsStmt'), and the counter to resume from afterward.
--
-- Just incrementing a counter forever ("rev0", "rev1", ...) isn't enough:
-- if the *source* program happens to already declare a variable called
-- "rev0" anywhere in the same function, TypeChecker.hs's insertVar has no
-- protection against the collision -- it unconditionally overwrites
-- whatever was bound to that name (see its definition), silently
-- discarding either the user's binding or this pass's own reversal
-- variable depending on which one ends up written second. Confirmed
-- empirically: a hand-written function returning `rev0` (a bool it had
-- bound earlier) with an unrelated `drop` elsewhere in the same function
-- that happens to need exactly one reversal step gets that generated
-- `rev0` silently colliding with the user's, corrupting the return value
-- (caught here only because UncomputeMain.hs/TestUncompute.hs re-type-check
-- the output and it then fails with a ReturnTypeMismatch -- a program that
-- happened to still type-check after the collision would have passed
-- through wrong and undetected). Skipping any candidate already in
-- `reserved` closes that hole outright, rather than relying on a
-- downstream check to catch it after the fact.
--
-- Parameterised over the name prefix so planCallCopies (below) can mint
-- its own "argcopyN"-shaped names out of the same collision-avoiding
-- machinery, textually distinct from this pass's "revN" reversal names --
-- distinct prefixes also mean the two counters can never collide with
-- each other, whatever order their names end up minted in.
freshNamed :: String -> Set.Set Var -> Int -> (Var, Int)
freshNamed prefix reserved n
  | candidate `Set.member` reserved = freshNamed prefix reserved (n + 1)
  | otherwise                       = (candidate, n + 1)
  where candidate = Var (pack (prefix ++ show n))

freshVar :: Set.Set Var -> Int -> (Var, Int)
freshVar = freshNamed "rev"

-- | Given an already-resolved Origin, produce the statements that undo it
-- and the name of the variable holding the fully reconstructed origin once
-- done. No DefMap needed here anymore: everything reverseOrigin might need
-- is already embedded in the Origin value itself (see 'Origin' and
-- 'resolveExpr'), so there is no name lookup left that could go stale.
reverseOrigin :: Set.Set Var -> Int -> Origin -> Var -> Either String ([Stmt], Var, Int)
-- Base case: a fresh |0> qubit origin, nothing to undo.
reverseOrigin _ n FromInit0 currentVar = Right ([], currentVar, n)
-- A fresh |1> qubit origin still needs a bit-flip before it's safe to drop
-- -- treating this as a no-op (as an earlier version of this pass did) was a
-- real bug: dropping a never-flipped |1> qubit is exactly the physically
-- invalid discard this whole pass exists to prevent. The flip must be
-- inserted via EC's `[not]`, not EU's bare gate syntax: EU is pinned to
-- operating on/producing exactly #bot qbit (see expr_unitary in
-- TypeChecker.hs), and #bot can never be widened back to a droppable type --
-- confirmed empirically, `x as #bot qbit ; let y = H(x) ; y as #top qbit`
-- fails to type check (isSubtype's subty_shorten needs top <= bot, which
-- `leq` never grants) -- so a gate inserted here must be EC, which preserves
-- whatever (already-droppable) lifetime currentVar already has.
reverseOrigin reserved n FromInit1 currentVar =
  let (fresh, n') = freshVar reserved n
      step        = SLetExpr fresh (EC (Classical (pack "not")) currentVar)
  in Right ([step], fresh, n')
-- Always-droppable results (Fig. 6's Drop trait: bool, unit, and anything
-- Copy -- which in this system means references, since only Copy-eligible
-- values can be validly copied in the first place): no gate produced these,
-- so there is nothing to reverse, currentVar is already fine to drop as-is.
reverseOrigin _ n FromTrivial currentVar = Right ([], currentVar, n)
reverseOrigin _ n FromBorrow  currentVar = Right ([], currentVar, n)
-- EU u prev: insert the inverse gate applied to currentVar, producing a
-- fresh name, then keep unwinding prev's own origin under that fresh name.
-- (prev being FromBorrow here can't actually happen in a type-checked
-- program -- a borrow is &-typed, never #-typed, so it could never have
-- been EU's argument in the first place -- so it's fine that this just
-- falls through to FromBorrow's own no-op case rather than asserting.)
reverseOrigin reserved n (FromGate u prev) currentVar = do
  invU <- note ("no known inverse for unitary gate " ++ show u) (unitaryInverse u)
  let (fresh, n') = freshVar reserved n
      step        = SLetExpr fresh (EU invU currentVar)
  (restStmts, finalVar, n'') <- reverseOrigin reserved n' prev fresh
  Right (step : restStmts, finalVar, n'')
-- EC c prev: same shape as the EU case just above, using GateInverse.hs's
-- classicalInverse table instead. Note this never gets applied to a value
-- still bundled as a pair from the *caller's* point of view in a way that
-- would be unsound: prev being FromPair here just means the EC's argument
-- was itself a literal pair construction (e.g. `[cnot]((x0,x1))` written
-- directly, no intermediate variable) -- currentVar is still a single named
-- value at this point, so `[c^-1](currentVar)` is exactly as valid as any
-- other EC application. The genuinely unhandled case -- reversing one
-- already-destructured half of a jointly-computed EC pair result while its
-- sibling is still live -- never reaches here: recordBinding's SLetPair
-- case only unwraps a bare FromPair, not a FromClassicalGate-wrapped one,
-- so a destructured half stays FromUnbound and fails at the lookup instead.
reverseOrigin reserved n (FromClassicalGate c prev) currentVar = do
  invC <- note ("no known inverse for classical injection " ++ show c) (classicalInverse c)
  let (fresh, n') = freshVar reserved n
      step        = SLetExpr fresh (EC invC currentVar)
  (restStmts, finalVar, n'') <- reverseOrigin reserved n' prev fresh
  Right (step : restStmts, finalVar, n'')
-- qif ctrl {..trueOrigin} else {..falseOrigin}, whose *result* -- not
-- something nested inside a branch -- is what's being dropped:
-- reconstructed by re-running a qif on the exact same ctrl, with each
-- branch independently reversing its own already-resolved return Origin,
-- starting from currentVar (the value actually being dropped) rather than
-- that branch's own original local variable, which doesn't exist in the
-- rewritten program at all -- the branch is rebuilt from scratch out of
-- pure reversal steps, so any of its original forward-computation
-- statements that go unreferenced are simply never emitted (nothing to
-- clean up, unlike a genuinely unused *source* binding, which would rely
-- on checkBlock's implicit per-block cleanup -- confirmed empirically that
-- qif branches get that same implicit cleanup, so either way this is
-- sound). Reusing ctrl here is exactly what typ_qif's own rule allows: a
-- qif's control reference is never consumed by using it in a qif (kept in
-- the output context, free to be used again) -- which is also exactly why
-- ctrl must never be swept up by the ordinary trailing-drop-safety fix
-- below (hasLaterEndlft): see collectDeferredBorrows for the reuse-vs-drop
-- ordering hazard that would otherwise cause (confirmed empirically against
-- example_final.qurts-core, where source-level `drop r` sits textually
-- *before* `drop y` even though reversing y needs r again).
--
-- This only reverses a *self-contained* qif result: each branch's own
-- return value, produced independently within that branch (as
-- resolveBranchReturn already requires to reach a FromQIf at all, and as
-- nestedDropReason's qif case separately guards against a drop occurring
-- *inside* a branch, which stays unhandled regardless of what happens to
-- the qif's own result). It deliberately does NOT handle the harder case
-- the paper's author (Kengo) raised: a value used *as the qif control
-- itself* (or otherwise shared across both branches) that some *other*
-- operation, outside the qif, has since further modified -- e.g.
-- `let (x,y) = [cnot](x,y) ; let y2 = qif &b x { y } else { drop y ; [0]()
-- }`. There, gate-inverting each branch in isolation the way this case
-- does is unsound: [cnot] jointly produced x and y from a shared history,
-- so reversing y alone -- without also touching x, which the control
-- reference here only *reads* -- can't "put back" a value that only makes
-- sense reversed together with its sibling. That needs the paper's full
-- split/merge pebble-game machinery (Section 5.1): a shared circuit graph
-- tracked across both branches and the control's own history, not the
-- per-branch-in-isolation Origin chains this whole pass is built from.
-- Left for later -- see example_self_controlled_uncomp.qurts-core.
--
-- A second, narrower gap (also left for later): a branch whose own return
-- value was itself produced by a *further* qif, controlled by a reference
-- created *inside that same branch* (not something from outer scope) --
-- e.g. `qif r { let s0 = [0]() ; let s = &beta s0 ; qif s {..} else {..} }
-- else {..}`. trueOrigin there resolves to a nested FromQIf whose own ctrl
-- is `s` -- but `s` was never bound anywhere outside that one branch's own
-- statements (checkExpr's own EQIf handling, TypeChecker.hs, discards a
-- branch's local bindings once that branch is done being checked; nothing
-- carries `s` to the top level). This case's own recursive call into
-- trueOrigin still faithfully reverses the *gates*, but the reconstructed
-- inner `qif s {..}` this produces is embedded as an all-new statement,
-- disconnected from wherever `s` was originally set up -- so it references
-- a name with no binding at all in the rewritten program, rather than the
-- branch-local setup (`let s0 = [0]() ; let s = &beta s0 ; ...`) that
-- would need to be regenerated alongside it for this to actually work.
-- Confirmed empirically: re-type-checking such a reversal fails with
-- UnboundVariable "s". Fixing this needs reverseOrigin to reconstruct a
-- branch's *entire* local setup, not just chase gates on currentVar --
-- out of scope for this first version, which only handles a ctrl that's
-- already available in outer scope (see qifControlsIn's own note on
-- exactly this distinction).
reverseOrigin reserved n (FromQIf ctrl trueOrigin falseOrigin) currentVar = do
  (trueStmts,  trueVar,  n1) <- reverseOrigin reserved n  trueOrigin  currentVar
  (falseStmts, falseVar, n2) <- reverseOrigin reserved n1 falseOrigin currentVar
  let trueBlk     = Block (rebuildSeq trueStmts)  trueVar
      falseBlk    = Block (rebuildSeq falseStmts) falseVar
      (fresh, n3) = freshVar reserved n2
      step        = SLetExpr fresh (EQIf ctrl trueBlk falseBlk)
  Right ([step], fresh, n3)
-- A pair dropped whole (never destructured): Fig. 6's drop_tuple rule makes
-- a tuple droppable whenever *both* components are, with no gate history
-- required at all -- so if both halves are already trivially droppable
-- (nothing to reverse), the whole pair is too, same as dropping either half
-- on its own would be. Only fail when some component would actually need
-- real reversal work, since that requires destructuring the pair first
-- (EU/EC apply to a named qubit, not "half of variable p"), which this
-- pass doesn't rewrite the surrounding statements to do.
reverseOrigin _ n (FromPair o0 o1) currentVar
  | isTriviallyDroppable o0 && isTriviallyDroppable o1 = Right ([], currentVar, n)
  | otherwise = Left "cannot reverse through a pair construction: needs its own split-back-apart treatment, not handled yet"
reverseOrigin _ _ (FromUnbound v) _ =
  Left ("no local definition found for " ++ show v
         ++ " (parameter, or bound via pair-destructure of something other than "
         ++ "a literal pair; not traced by this pass)")
reverseOrigin _ _ (FromUnhandled e) _ = Left ("cannot reverse through " ++ describeExpr e)

-- | Reverse the chain that produced `v`, looking up its own definition first.
reverseVar :: Set.Set Var -> DefMap -> Int -> Var -> Either String ([Stmt], Var, Int)
reverseVar reserved defs n v = reverseOrigin reserved n (resolveVar defs v) v

-- | Every qif control variable an Origin chain reuses -- the ctrl of every
-- FromQIf reachable by walking through gates/pairs/nested qifs, including
-- ones nested inside a branch's own origin (o0/o1). Used by
-- 'collectDeferredBorrows' to find, ahead of time, every control variable
-- some *later* drop's reversal (FromQIf, above) is going to need to reuse.
--
-- This recurses fully into nested FromQIf's, deliberately -- a ctrl used
-- *inside* a branch (e.g. non_zero's own y/z, each nested one level
-- deeper inside x's own branches -- see resolveExpr's ECall case) can
-- still be a perfectly ordinary outer-scope variable, exactly like
-- example_valid.qurts-core's `q` being read from inside a branch: typ_qif
-- only ever removes its *own* direct control while checking a branch's
-- body, nothing else, so any other in-scope variable -- including one
-- another qif nested inside that branch happens to use as *its* control --
-- remains perfectly valid to reference from there. An earlier version of
-- this function stopped recursing into a FromQIf's own branch-origins
-- specifically to avoid collecting a ctrl that was bound *inside* that
-- same branch (not outer scope at all -- see reverseOrigin's FromQIf
-- comment on that narrower, still-unhandled case) -- but that also,
-- wrongly, stopped collecting legitimate outer-scope ctrls nested this
-- way, which is exactly the shape oracle/non_zero's own bodies need
-- (their inner qifs' controls are their own further parameters, always
-- outer-scope relative to the branch they sit in). Recursing fully again
-- restores that; the narrower, branch-locally-bound case simply isn't
-- distinguishable from Origin alone (both look like "a FromQIf nested in
-- a branch"), so it's no longer specially detected here -- it now
-- surfaces the same way most of this pass's unhandled edges do, as a
-- round-trip re-type-check failure (UnboundVariable) rather than a
-- dedicated error message, which UncomputeMain.hs already reports as a
-- SKIP rather than a false success.
qifControlsIn :: Origin -> [Var]
qifControlsIn (FromQIf ctrl o0 o1)       = ctrl : qifControlsIn o0 ++ qifControlsIn o1
qifControlsIn (FromGate _ prev)          = qifControlsIn prev
qifControlsIn (FromClassicalGate _ prev) = qifControlsIn prev
qifControlsIn (FromPair o0 o1)           = qifControlsIn o0 ++ qifControlsIn o1
qifControlsIn _                          = []

-- | Only the ctrl of the *outermost* FromQIf an Origin chain reaches
-- (through gates/pairs, same as qifControlsIn -- but, unlike it, NOT
-- recursing into that FromQIf's own branch-origins). Used by
-- uncomputeStmts's SDrop case for a completely different question than
-- qifControlsIn answers: not "which controls does this reversal
-- reference at all" (deep -- everything nested needs to be *available*),
-- but "which of those controls is still actually there, needing an
-- *explicit* drop, once the reconstruction is done" (shallow -- only one).
--
-- These differ because of how typ_qif's own per-branch cleanup cascades:
-- checkExpr(EQIf x bt bf) restores only its own direct control x after
-- checking both branches, but each branch's own checkBlock (TypeChecker.hs)
-- implicitly drops *any* other still-active variable it doesn't itself
-- consume -- including a *deeper* qif's own control, already restored by
-- that inner qif's own checkExpr, if the branch containing it doesn't use
-- it for anything else afterward. In a chain of N nested reconstructed
-- qifs (see reverseOrigin's FromQIf case), each inner ctrl (e.g.
-- non_zero's own y, z once translated to argcopy1/argcopy2 -- see
-- resolveExpr's ECall case) is restored by its own qif and then
-- *immediately* swallowed by the very next enclosing branch's own
-- cleanup, one level at a time, all the way out -- only the outermost
-- ctrl (argcopy0) survives that cascade to still be present, and
-- therefore droppable, once the whole reconstructed expression is done.
-- Confirmed empirically: emitting an explicit trailing drop for every
-- level (an earlier version of this code did, via qifControlsIn's deep
-- collection) failed re-type-checking example_grover.qurts-core's
-- reversed output with UnboundVariable -- the inner ones were already
-- gone by the time their own explicit `drop` statement ran.
--
-- An earlier version of this comment worried an *inner* ctrl, being
-- cascade-consumed the first time its own enclosing reconstruction runs,
-- could be needed again by some *second*, separate later drop's own
-- reconstruction with no `consumed`-style tracking to protect it (the way
-- an outermost one gets -- see uncomputeStmts). Turns out that can't
-- happen: checkExpr(EQIf x bt bf)'s per-branch checkBlock cleanup drops
-- *every* other active variable that isn't x itself -- not just ones a
-- branch actually references, but unconditionally, whether touched or
-- not. Confirmed empirically with the simplest possible case: two
-- completely separate, sequential `qif r1 {..} else {..} ; qif r2 {..}
-- else {..}` on two *unrelated* controls, r2 never touched by the first
-- qif at all, still fails forward type-checking with UnboundVariable
-- "r2" -- the first qif's own branch cleanup drops it regardless. So no
-- reference can ever survive a `qif` it isn't the direct control of,
-- structurally separate qif or not, inner-ctrl-specific or not -- meaning
-- the same named control can never legitimately be needed by two
-- *separate* reconstructions in the first place (only by nested ones
-- sharing the same enclosing qif, which is exactly what already works).
-- The gap this comment used to describe isn't reachable by any valid
-- qurts-core program; nothing to fix here after all.
outermostQifCtrl :: Origin -> [Var]
outermostQifCtrl (FromQIf ctrl _ _)         = [ctrl]
outermostQifCtrl (FromGate _ prev)          = outermostQifCtrl prev
outermostQifCtrl (FromClassicalGate _ prev) = outermostQifCtrl prev
outermostQifCtrl _                          = []

-- | The set of variables that must NOT be touched by an ordinary `drop`
-- (in particular, must never get an explicit trailing drop from
-- hasLaterEndlft below), because some *later* `drop` in this same
-- statement list is going to reverse a qif that reuses them as its
-- control. Threads a DefMap forward exactly the way uncomputeStmts's own
-- `go` does (recordBinding per statement) so each `drop` here is resolved
-- against the definitions actually in effect at that point -- reusing the
-- final, fully-folded map instead would risk resolving a name against
-- whatever it was rebound to *later* in the function, the same staleness
-- hazard 'Origin' as a whole exists to avoid.
--
-- It is always sound to leave a deferred control variable alone: ctrl is
-- always &-typed (typ_qif requires a borrowed reference as the control),
-- and a &-typed binding is unconditionally droppable regardless of
-- lifetime activity -- so however long it sits around unconsumed, nothing
-- is lost by not dropping it here; it either gets reused by the later
-- qif-reversal (typ_qif never consumes a control reference by using it,
-- so it is still available), or is swept up by the implicit end-of-block
-- cleanup same as any other never-explicitly-dropped droppable value.
--
-- Called twice per function by uncomputeStmts: once with rcCopies empty,
-- purely to discover which top-level names are needed at all (feeding
-- planCallCopies), and once for real, with rcCopies populated, so that a
-- name a call has since consumed shows up here as its *copy* instead --
-- see uncomputeStmts for why a plain deferred-and-reused borrow isn't
-- enough once a function call is involved.
collectDeferredBorrows :: ResolveCtx -> DefMap -> [Stmt] -> Set.Set Var
collectDeferredBorrows ctx initDefs = go initDefs
  where
    go _ [] = Set.empty
    go defs (s : rest) = case s of
      SDrop y -> Set.fromList (qifControlsIn (resolveVar defs y)) <> go defs rest
      _       -> go (recordBinding ctx Map.empty s defs) rest

rebuildSeq :: [Stmt] -> Stmt
rebuildSeq []     = SNoop
rebuildSeq [s]    = s
rebuildSeq (s:ss) = SSeq s (rebuildSeq ss)

-- | Every variable name bound anywhere in a statement, including inside
-- nested qif/if branches. Used (together with a function's own parameter
-- names) to build the `reserved` set 'freshVar' must avoid -- see its
-- docstring for why generating an already-used name is a real, silent
-- correctness hazard rather than a hypothetical one.
boundVarsStmt :: Stmt -> Set.Set Var
boundVarsStmt (SSeq s1 s2)       = boundVarsStmt s1 <> boundVarsStmt s2
boundVarsStmt (SLetRef y _ _)    = Set.singleton y
boundVarsStmt (SLetExpr y e)     = Set.insert y (boundVarsExpr e)
boundVarsStmt (SLetPair y0 y1 _) = Set.fromList [y0, y1]
boundVarsStmt _                  = Set.empty

boundVarsExpr :: Expr -> Set.Set Var
boundVarsExpr (EQIf _ bt bf) = boundVarsBlock bt <> boundVarsBlock bf
boundVarsExpr (EIf  _ bt bf) = boundVarsBlock bt <> boundVarsBlock bf
boundVarsExpr _               = Set.empty

boundVarsBlock :: Block -> Set.Set Var
boundVarsBlock (Block stmt _) = boundVarsStmt stmt

-- | True if a `drop` occurs anywhere inside a statement, including nested
-- inside a qif/if branch's own block. uncomputeStmts's main scan only walks
-- the top-level statement list, so without this check a `drop` sitting
-- inside a qif/if branch would simply never be looked at -- silently passed
-- through unreversed while the file still gets reported as a successful
-- uncomputation. This makes that case fail loudly instead.
stmtContainsDrop :: Stmt -> Bool
stmtContainsDrop (SDrop _)      = True
stmtContainsDrop (SSeq s1 s2)   = stmtContainsDrop s1 || stmtContainsDrop s2
stmtContainsDrop (SLetExpr _ e) = exprContainsDrop e
stmtContainsDrop _              = False

exprContainsDrop :: Expr -> Bool
exprContainsDrop (EQIf _ bt bf) = blockContainsDrop bt || blockContainsDrop bf
exprContainsDrop (EIf  _ bt bf) = blockContainsDrop bt || blockContainsDrop bf
exprContainsDrop _              = False

blockContainsDrop :: Block -> Bool
blockContainsDrop (Block stmt _) = stmtContainsDrop stmt

-- | True if `endlft` occurs anywhere in a statement list (including nested
-- inside a qif/if branch). Used to decide whether a reversed `drop`'s
-- reconstructed value needs an *explicit* trailing drop rather than being
-- left for checkBlock's implicit end-of-block cleanup, which is the normal
-- (no-trailing-drop) behaviour everywhere else in this pass.
--
-- The implicit-cleanup assumption breaks specifically when an `endlft`
-- sits between the reversed value and the true end of its block: for a
-- #alpha-typed reversed qubit, droppability depends on alpha still being
-- active (isActive/canDrop, TypeChecker.hs), and `endlft alpha` is exactly
-- what removes alpha from the active set. Leaving such a value dangling
-- for the *block's* end-of-scope cleanup would mean justifying its drop
-- after its own lifetime has already ended -- unsound. Emitting the drop
-- explicitly, right where the pass would otherwise have left it implicit
-- but strictly before any later `endlft`, keeps it inside the window where
-- the lifetime is still active. (A plain bool/unit/&T reversed value would
-- have been fine either way -- Fig 6's drop_bool/drop_unit/drop_borrow
-- have no lifetime-activity condition at all -- but this pass doesn't
-- track static types, so it applies the same explicit-drop treatment
-- uniformly rather than trying to tell the two cases apart.)
hasLaterEndlft :: [Stmt] -> Bool
hasLaterEndlft = any stmtHasEndlft

stmtHasEndlft :: Stmt -> Bool
stmtHasEndlft (SEndLft _)    = True
stmtHasEndlft (SSeq s1 s2)   = stmtHasEndlft s1 || stmtHasEndlft s2
stmtHasEndlft (SLetExpr _ e) = exprHasEndlft e
stmtHasEndlft _              = False

exprHasEndlft :: Expr -> Bool
exprHasEndlft (EQIf _ bt bf) = blockHasEndlft bt || blockHasEndlft bf
exprHasEndlft (EIf  _ bt bf) = blockHasEndlft bt || blockHasEndlft bf
exprHasEndlft _               = False

blockHasEndlft :: Block -> Bool
blockHasEndlft (Block stmt _) = stmtHasEndlft stmt

-- | Reason a nested drop can't be handled, specific to what it's nested in.
nestedDropReason :: Stmt -> String
nestedDropReason (SLetExpr _ (EQIf {})) =
  "a drop occurs inside a qif branch: reversing through qif needs the paper's split/merge pebble-game rule, not handled yet"
nestedDropReason (SLetExpr _ (EIf {})) =
  "a drop occurs inside a classical if branch, not handled yet"
nestedDropReason _ =
  "a drop occurs inside a nested block this pass doesn't look inside"

-- | Replace every top-level `drop x` in a flat statement list with just the
-- reversed statement sequence for x -- normally no trailing `drop` of the
-- reconstructed origin. That's deliberate, not an oversight: once the chain
-- bottoms out, the final variable has the same (droppable) type x always
-- had, and checkBlock (TypeChecker.hs) implicitly drops any droppable
-- variable still active at the end of a block (see its "Droppable active
-- variables ... are implicitly dropped at end of scope" comment) -- so an
-- explicit trailing SDrop here would usually be redundant, not required.
-- Confirmed empirically: a hand-edited version of example_pair.qurts-core
-- with the trailing `drop` removed after the inserted `[not]` still
-- type-checks. The one exception is when a later `endlft` intervenes
-- before the block actually ends -- see hasLaterEndlft -- in which case an
-- explicit drop *is* emitted, right away, rather than relying on
-- end-of-block cleanup that would happen too late.
--
-- A deferred qif control variable (collectDeferredBorrows) is a second,
-- narrower exception: its own `drop` is skipped entirely at its original
-- position, not even given the usual (non-)trailing-drop treatment, so it
-- survives untouched for a later FromQIf reversal to reuse -- seeing
-- hasLaterEndlft's trailing-drop logic here would otherwise drop it too
-- early, before that reuse. It does still need dropping *somewhere*,
-- though, and unconditionally so, regardless of hasLaterEndlft: confirmed
-- empirically (a first attempt at this that just left deferred control
-- variables dangling forever, relying on implicit end-of-block cleanup,
-- failed to re-type-check example_final.qurts-core's reversed output with
-- ReferenceStillInContext) -- SEndLft's own rule (TypeChecker.hs's
-- noRefInCtx check) requires *zero* live `&α` references in context at
-- all, droppable or not, stricter than the general droppability-vs-activity
-- reasoning hasLaterEndlft is built on. So each deferred control variable
-- is dropped explicitly right after the *last* reversal that reuses it
-- (see the used-up bookkeeping below), which -- since a reversed drop is
-- only ever inserted at or before the reversed drop's original source
-- position -- always lands strictly before whatever `endlft` the original
-- program itself needed the un-reversed `drop` to precede.
--
-- `deferred` itself (which control variables are ever reused later) is
-- computed once, up front, and never shrinks -- x's own original `drop x`
-- statement must be suppressed for the rest of the scan once x is
-- deferred, full stop, regardless of whether its one real drop has already
-- been emitted early or not yet. What *does* evolve as the scan proceeds
-- is `consumed`: which deferred control variables have already had that
-- real drop emitted. Conflating the two was an earlier, broken version of
-- this function -- removing a used-up variable from `deferred` itself
-- caused its own original (now-redundant) `drop` statement, reached later
-- in the scan, to fall through to ordinary processing instead of being
-- suppressed, producing a second, invalid drop of an already-consumed
-- variable. Confirmed empirically: example_valid.qurts-core (`drop q ;
-- drop r ;`, in that order -- q's reversal uses r before r's own original
-- `drop r` statement is even reached) failed re-type-checking with
-- UnboundVariable "r" under that earlier version.
--
-- Processes statements in order so each drop sees the definitions in effect
-- at that point, since qurts-core allows rebinding a name -- and since
-- recordBinding resolves eagerly (see 'Origin'), that rebinding is safe:
-- whatever a name was already resolved to stays correct even after the
-- name itself is reused for something else. A `drop` nested inside a
-- qif/if branch is reported as a failure (see stmtContainsDrop) rather
-- than silently left untouched -- regardless of whether the enclosing
-- qif's own result is itself later reversed; these are independent
-- concerns (see reverseOrigin's FromQIf case).
--
-- Function calls are the one place this pass writes a *new* statement
-- into the ordinary forward-computation flow, rather than only ever
-- rewriting a `drop` in place -- and only when actually needed. The
-- problem: a call consumes *every* argument outright, including reference
-- ones (TypeChecker.hs's checkExpr(ECall ...) calls removeVar on each one
-- unconditionally -- unlike qif, which explicitly restores its own control
-- afterward). So if some later drop's reversal needs to reuse a reference
-- that was passed into a qif-using callee (e.g. non_zero<alpha>(rx,ry,rz)
-- in example_grover.qurts-core's grover_diffusion, whose own internal
-- qifs are controlled by its own x/y/z parameters), that reference is
-- simply gone by the time the reversal needs it again -- confirmed
-- empirically (calling a function twice with the same reference fails
-- with UnboundVariable on the second call; re-borrowing the underlying
-- qubit doesn't work either, since it's still Frozen until endlft). The
-- one thing that *does* work, also confirmed empirically: `copy`ing the
-- reference *before* the consuming call preserves an independent, still
-- valid reference to reuse later -- copying doesn't consume the original,
-- and a reference is Copy (Fig. 14).
--
-- Figuring out *which* call arguments actually need this can't be done in
-- a single left-to-right pass: whether argument `rx` of an *earlier* call
-- needs preserving depends on whether some *later* drop's reversal will
-- need it -- the same fundamental look-ahead collectDeferredBorrows itself
-- already needs, just one step earlier (before the consuming call, not
-- after a redundant drop). So this runs collectDeferredBorrows *twice*:
--
--  1. A trial run, with rcCopies empty, just to see which top-level names
--     get pulled into some later reversal via an *already fully-resolved*
--     Origin chain (resolveExpr's ECall case inlines transparently
--     regardless of whether any copy exists yet -- an Origin's meaning
--     doesn't depend on what name will eventually hold it).
--  2. planCallCopies below walks the statement list once more and, for
--     each call whose own argument list contains a name from that trial
--     result, mints a fresh "argcopyN" name for it.
--  3. uncomputeStmts's own collectDeferredBorrows call, and everything
--     else in `go`, then run for real with rcCopies populated -- so
--     `deferred` (and reverseDeferredCtrls's own eventual explicit drop)
--     end up correctly keyed by "argcopy0" rather than "rx", since
--     resolveExpr's ECall case substitutes the copy in wherever it
--     translates that argument (see translateVar).
--
-- A copy is minted only when the trial run shows it's actually needed --
-- not unconditionally for every reference argument of every qif-using
-- callee -- because an unused, never-explicitly-dropped copy would be
-- exactly as unsound as an un-reversed value left dangling across an
-- `endlft` (hasLaterEndlft's own reasoning): SEndLft's noRefInCtx check
-- requires *zero* live references in context, so a spare copy nobody ever
-- consumes would need dropping too, and without knowing in advance
-- whether it's needed, there'd be no principled place to put that drop.
uncomputeStmts :: FuncEnv -> Set.Set Var -> DefMap -> [Stmt] -> Either String [Stmt]
uncomputeStmts funcs reserved initDefs stmts = go initDefs Set.empty n0 stmts
  where
    copies    = planCallCopies funcs reserved initDefs stmts
    reserved' = reserved <> Set.fromList (Map.elems copies)
    ctx       = ResolveCtx funcs copies
    deferred  = collectDeferredBorrows ctx initDefs stmts
    n0        = 0
    go _ _ _ [] = Right []
    go defs consumed n (s : rest) = case s of
      -- Insert a `copy` for each of this call's own arguments that
      -- planCallCopies decided is needed, right before the call itself
      -- (which is otherwise left completely untouched -- it still
      -- consumes the *original* argument names exactly as the source
      -- did; the copies are purely additional, parallel bindings).
      SLetExpr _ (ECall _ _ args) ->
        let copyStmts = [ SLetExpr cpy (ECopy arg) | arg <- args, Just cpy <- [Map.lookup arg copies] ]
            defs'     = foldl (flip (recordBinding ctx Map.empty)) defs (copyStmts ++ [s])
        in ((copyStmts ++ [s]) ++) <$> go defs' consumed n rest
      SDrop x | x `Set.member` deferred -> go defs consumed n rest
      SDrop x -> do
        (revStmts, finalVar, n') <- reverseVar reserved' defs n x
        -- Any deferred control variable this particular reversal just
        -- reused (via a FromQIf inside it) that hasn't already been
        -- dropped by some *earlier* reversal's own use of it: drop it for
        -- real here, its last use. Only the *outermost* one needs (or
        -- can validly receive) an explicit drop here -- see
        -- outermostQifCtrl for why a deeper-nested one is already gone by
        -- this point, automatically.
        let usedCtrls = filter (\v -> v `Set.member` deferred && not (v `Set.member` consumed))
                               (outermostQifCtrl (resolveVar defs x))
        (ctrlStmts, n'') <- reverseDeferredCtrls reserved' defs n' usedCtrls
        let consumed' = consumed <> Set.fromList usedCtrls
            trailing   = [SDrop finalVar | hasLaterEndlft rest]
        restOut <- go defs consumed' n'' rest
        Right (revStmts ++ ctrlStmts ++ trailing ++ restOut)
      _ | stmtContainsDrop s -> Left (nestedDropReason s)
        | otherwise          -> (s :) <$> go (recordBinding ctx Map.empty s defs) consumed n rest

-- | See uncomputeStmts's own comment for the full picture. Runs a trial,
-- copies-free collectDeferredBorrows to see which top-level names are
-- needed by some later reversal, then walks the statement list once more,
-- minting a fresh, collision-checked copy name for each call argument
-- that trial run flagged.
planCallCopies :: FuncEnv -> Set.Set Var -> DefMap -> [Stmt] -> Map.Map Var Var
planCallCopies funcs reserved initDefs stmts = go initDefs 0 stmts
  where
    trialCtx  = ResolveCtx funcs Map.empty
    deferred0 = collectDeferredBorrows trialCtx initDefs stmts
    go _ _ [] = Map.empty
    go defs n (s : rest) = case s of
      SLetExpr _ (ECall _ _ args) ->
        let needy         = filter (`Set.member` deferred0) args
            (mine, n')    = mintCopies n needy
        in mine <> go (recordBinding trialCtx Map.empty s defs) n' rest
      _ -> go (recordBinding trialCtx Map.empty s defs) n rest
    mintCopies n []       = (Map.empty, n)
    mintCopies n (v : vs) =
      let (fresh, n')   = freshNamed "argcopy" reserved n
          (rest', n'')  = mintCopies n' vs
      in (Map.insert v fresh rest', n'')

-- | Reverse-and-drop each control variable in turn (see uncomputeStmts's
-- SDrop case): each is expected to be FromBorrow, or (for a call-consumed
-- reference now standing in as a preserved copy -- see planCallCopies)
-- FromTrivial, same no-op reversal either way -- so in practice this just
-- produces a bare trailing SDrop with no gates -- routed through
-- reverseOrigin rather than assumed, for the same reason nothing else in
-- this pass special-cases FromBorrow/FromTrivial: if that assumption is
-- ever wrong, this fails loudly instead of silently dropping something it
-- shouldn't.
reverseDeferredCtrls :: Set.Set Var -> DefMap -> Int -> [Var] -> Either String ([Stmt], Int)
reverseDeferredCtrls _ _ n [] = Right ([], n)
reverseDeferredCtrls reserved defs n (v : vs) = do
  (revStmts, finalVar, n')  <- reverseOrigin reserved n (resolveVar defs v) v
  (restStmts, n'')          <- reverseDeferredCtrls reserved defs n' vs
  Right (revStmts ++ [SDrop finalVar] ++ restStmts, n'')

uncomputeBlock :: FuncEnv -> Set.Set Var -> DefMap -> Block -> Either String Block
uncomputeBlock funcs reserved initDefs (Block stmt ret) = do
  newStmts <- uncomputeStmts funcs reserved initDefs (flattenStmt stmt)
  Right (Block (rebuildSeq newStmts) ret)

-- | The Origin of a function parameter whose type is droppable no matter
-- what lifetime/activity state holds at the point of a `drop` -- Fig. 6's
-- drop_bool, drop_unit, drop_borrow, and (recursively) drop_tuple built
-- from these. Nothing for anything else, in particular #a T: droppability
-- there depends on whether `a` is still active at the drop site, which this
-- pass has no lifetime tracking to determine, so such a parameter is left
-- untracked (reported plainly as "no local definition", same as before)
-- rather than guessed at.
--
-- Without this, a `drop` of a bare classical/reference parameter -- e.g.
-- the paper's own `fn forget<'a!='0>(x: #'a qbit) { drop x; }` pattern,
-- just with a bool/unit/&T parameter instead of a qbit one -- was reported
-- as an unresolvable chain, even though it needs zero reversal: nothing
-- but SLetExpr/SLetRef/SLetPair targets were ever recorded in DefMap, so a
-- parameter was always absent regardless of how trivially droppable its
-- static type is. Confirmed empirically: `fn f(b: bool) -> #top qbit {
-- drop b; [0]() }` type-checks, but this pass rejected the `drop b`
-- outright before this fix.
staticallyDroppableOrigin :: Type -> Maybe Origin
staticallyDroppableOrigin TyBool         = Just FromTrivial
staticallyDroppableOrigin TyUnit         = Just FromTrivial
staticallyDroppableOrigin (TyRef _ _)    = Just FromBorrow
staticallyDroppableOrigin (TyPair t1 t2) =
  FromPair <$> staticallyDroppableOrigin t1 <*> staticallyDroppableOrigin t2
staticallyDroppableOrigin _              = Nothing

uncomputeFunction :: FuncEnv -> Function -> Either String Function
uncomputeFunction funcs f = do
  let params   = sigParams (funSig f)
      reserved = Set.fromList (map fst params) <> boundVarsStmt (blockStmt (funBody f))
      initDefs = Map.fromList [ (x, o) | (x, ty) <- params, Just o <- [staticallyDroppableOrigin ty] ]
  newBody <- uncomputeBlock funcs reserved initDefs (funBody f)
  Right (f { funBody = newBody })

uncomputeProgram :: Program -> Either String Program
uncomputeProgram (Program fs) =
  let funcs = Map.fromList [ (funName f, f) | f <- fs ]
  in Program <$> mapM (uncomputeFunction funcs) fs
