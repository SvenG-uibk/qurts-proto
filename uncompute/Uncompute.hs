-- The actual uncomputation pass: naive strategy only (compute forward, then
-- reverse everything in reverse order right before the drop), qif and
-- function calls set aside.
--
-- Scope for this version: a `drop x` can be reversed when x's definition
-- chain, walked backward, consists of `let`-bound EU applications, bare
-- renames, &borrow bindings, and pair-destructures of a literal pair
-- construction, terminating in [0]()/[1](). [1]() needs an inserted [not]
-- flip (via EC, not EU -- see the FromInit1 case below for why) to actually
-- reach |0> before the point where the `drop` used to be. The `drop`
-- statement itself is then simply omitted, not replaced by another drop:
-- the reconstructed variable ends up with the same droppable type x always
-- had, and TypeChecker.hs's checkBlock implicitly drops any droppable
-- variable still active at the end of a block, so an explicit trailing
-- `drop` would be redundant (see uncomputeStmts below for the empirical
-- confirmation). Every other construct a chain might pass through (EC
-- applied to anything other than fixing up [1](), ECall, qif/if, dropping a
-- pair directly instead of destructuring it first) fails loudly with a
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
import GateInverse (unitaryInverse)
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
  | FromPair Origin Origin       -- (x0,x1), components already resolved
  | FromUnbound Var              -- referenced a name with no known local definition
  | FromUnhandled Expr           -- a construct this pass doesn't chain through
                                  -- (qif/if/call/EC-as-a-source); kept raw
                                  -- only so describeExpr can explain why
  deriving (Show)

-- | Map from a variable name to what it's currently known to have come
-- from, fully resolved as of the point its binding was recorded (see
-- 'Origin').
type DefMap = Map.Map Var Origin

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
-- (renames, gates, literal pairs) using the *current* defs -- i.e. exactly
-- the bindings in effect at this statement, not whatever they become later.
resolveExpr :: DefMap -> Expr -> Origin
resolveExpr _    EInit0        = FromInit0
resolveExpr _    EInit1        = FromInit1
resolveExpr _    ETrue         = FromTrivial
resolveExpr _    EFalse        = FromTrivial
resolveExpr _    EUnit         = FromTrivial
resolveExpr _    (ECopy _)     = FromTrivial
-- meas(x) always has type #TOP bool (expr_measure), unconditionally
-- droppable (drop_bool has no lifetime-activity condition at all) same as
-- a literal true/false -- regardless of what qubit was measured or what
-- happened to it beforehand. Measurement genuinely can't be reversed to
-- recover the pre-measurement qubit state (see describeExpr's EMeas case,
-- still used for the qubit itself, e.g. reversing through the *argument*
-- of a later EU/EC that consumed it), but that's a different question from
-- whether the resulting classical bool needs any reversal before it can be
-- dropped -- it doesn't, ever, same reasoning as ECopy just above.
resolveExpr _    (EMeas _)     = FromTrivial
resolveExpr defs (EVar x)      = resolveVar defs x
resolveExpr defs (EU u x)      = FromGate u (resolveVar defs x)
resolveExpr defs (EPair x0 x1) = FromPair (resolveVar defs x0) (resolveVar defs x1)
resolveExpr _    e             = FromUnhandled e

-- | Update a DefMap with the binding (if any) a single statement
-- introduces. Used both by 'buildDefMap' (fold over a whole list) and by
-- 'uncomputeStmts' (incremental scan, since later drops must see only the
-- definitions in effect at that point in the source).
recordBinding :: Stmt -> DefMap -> DefMap
recordBinding (SLetExpr y e)  m = Map.insert y (resolveExpr m e) m
recordBinding (SLetRef y _ _) m = Map.insert y FromBorrow m
recordBinding (SLetPair y0 y1 x) m = case resolveVar m x of
  FromPair o0 o1 -> Map.insert y1 o1 (Map.insert y0 o0 m)
  _              -> m
recordBinding _ m = m

buildDefMap :: [Stmt] -> DefMap
buildDefMap = foldl (flip recordBinding) Map.empty

note :: String -> Maybe a -> Either String a
note msg = maybe (Left msg) Right

describeExpr :: Expr -> String
describeExpr (ECall (FuncName f) _ _) = "a function call (" ++ show f ++ "): reversing a call means the callee's own body must be reversible too, not handled yet"
describeExpr (EQIf _ _ _)             = "a qif expression: set aside for now (needs the paper's split/merge pebble-game rule)"
describeExpr (EIf _ _ _)              = "a classical if expression: not handled yet"
describeExpr (EC (Classical c) _)     = "a classical injection ([" ++ show c ++ "](...)): EC has no inverse table yet, only EU does"
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
freshVar :: Set.Set Var -> Int -> (Var, Int)
freshVar reserved n
  | candidate `Set.member` reserved = freshVar reserved (n + 1)
  | otherwise                       = (candidate, n + 1)
  where candidate = Var (pack ("rev" ++ show n))

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

-- | Reason a nested drop can't be handled, specific to what it's nested in.
nestedDropReason :: Stmt -> String
nestedDropReason (SLetExpr _ (EQIf {})) =
  "a drop occurs inside a qif branch: reversing through qif needs the paper's split/merge pebble-game rule, not handled yet"
nestedDropReason (SLetExpr _ (EIf {})) =
  "a drop occurs inside a classical if branch, not handled yet"
nestedDropReason _ =
  "a drop occurs inside a nested block this pass doesn't look inside"

-- | Replace every top-level `drop x` in a flat statement list with just the
-- reversed statement sequence for x -- no trailing `drop` of the
-- reconstructed origin. That's deliberate, not an oversight: once the chain
-- bottoms out, the final variable has the same (droppable) type x always
-- had, and checkBlock (TypeChecker.hs) implicitly drops any droppable
-- variable still active at the end of a block (see its "Droppable active
-- variables ... are implicitly dropped at end of scope" comment) -- so an
-- explicit trailing SDrop here would be redundant, not required. Confirmed
-- empirically: a hand-edited version of example_pair.qurts-core with the
-- trailing `drop` removed after the inserted `[not]` still type-checks.
-- Processes statements in order so each drop sees the definitions in effect
-- at that point, since qurts-core allows rebinding a name -- and since
-- recordBinding resolves eagerly (see 'Origin'), that rebinding is safe:
-- whatever a name was already resolved to stays correct even after the
-- name itself is reused for something else. A `drop` nested inside a
-- qif/if branch is reported as a failure (see stmtContainsDrop) rather
-- than silently left untouched.
uncomputeStmts :: Set.Set Var -> DefMap -> [Stmt] -> Either String [Stmt]
uncomputeStmts reserved initDefs = go initDefs 0
  where
    go _ _ [] = Right []
    go defs n (s : rest) = case s of
      SDrop x -> do
        (revStmts, _finalVar, n') <- reverseVar reserved defs n x
        restOut <- go defs n' rest
        Right (revStmts ++ restOut)
      _ | stmtContainsDrop s -> Left (nestedDropReason s)
        | otherwise          -> (s :) <$> go (recordBinding s defs) n rest

uncomputeBlock :: Set.Set Var -> DefMap -> Block -> Either String Block
uncomputeBlock reserved initDefs (Block stmt ret) = do
  newStmts <- uncomputeStmts reserved initDefs (flattenStmt stmt)
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

uncomputeFunction :: Function -> Either String Function
uncomputeFunction f = do
  let params   = sigParams (funSig f)
      reserved = Set.fromList (map fst params) <> boundVarsStmt (blockStmt (funBody f))
      initDefs = Map.fromList [ (x, o) | (x, ty) <- params, Just o <- [staticallyDroppableOrigin ty] ]
  newBody <- uncomputeBlock reserved initDefs (funBody f)
  Right (f { funBody = newBody })

uncomputeProgram :: Program -> Either String Program
uncomputeProgram (Program fs) = Program <$> mapM uncomputeFunction fs
