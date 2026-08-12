module TypeChecker where

import Ast
import GateInverse                (isKnownClassicalInjection, isTwoQubitClassical)
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import Data.Text                  (pack, unpack)
import Control.Monad             (unless, when, forM_)
import Control.Monad.State
import Control.Monad.Except

-- ============================================================
-- Errors
-- ============================================================

data TypeError
  = UnboundVariable Var
  | VariableFrozen  Var Lifetime           -- tried to use a frozen variable
  | TypeMismatch    Type Type              -- expected, actual
  | LifetimeNotActive Lifetime             -- lifetime not in A
  | LifetimeNotMinimal Lifetime            -- endlft: not minimal in A
  | ReferenceStillInContext Lifetime       -- endlft: &α still in Γ
  | CannotDrop Type                        -- Drop trait violation
  | NotPurelyQuantum String                -- PQ violation
  | LinearityViolation String              -- variable not consumed
  | DuplicateVariable Var                  -- bound twice
  | NotAReference Type                     -- expected &α T
  | NotAnOwned Type                        -- expected #𝔞 T
  | ReturnTypeMismatch Type Type           -- block return type mismatch
  | UnknownFunction FuncName
  | OtherError String
  deriving (Eq, Show)

-- ============================================================
-- TC Monad
-- ============================================================

-- The typing environment carries:
--   tcCtx  : current type context Γ
--   tcLfts : current lifetime preorder A (vars + relation)
--   tcFuncs: signatures of all previously defined functions (for ECall)
--   tcFunc : name of the current function (for external lifetime set A_ex)
--   tcExternalLfts, tcUsedLfts: see their own comments below
data TCState = TCState
  { tcCtx     :: Context
  , tcLfts    :: LifetimePreorder
  , tcFuncs   :: Map.Map FuncName Signature
  , tcFunc    :: FuncName
  , tcPQFuncs :: Set.Set FuncName    -- functions verified to be purely quantum
  , tcExternalLfts :: Set.Set Lifetime
  , tcUsedLfts     :: Set.Set Lifetime
  }
  deriving (Eq, Show)

-- tcExternalLfts: this function's own generic lifetime parameters (the
-- paper's A_ex,Π,f, e.g. Fig 16's stmt_borrow/stmt_end_lifetime premise
-- "α ∉ A_ex,Π,f") -- fixed for the whole function, set once from its
-- signature and never added to or removed from afterward. These are owned
-- by the *caller* (who decides when they actually start/end, via its own
-- newlft/endlft around the call), so this function may use them (they're
-- already in tcLfts/A from function entry) but must never borrow *with*
-- one directly, nor end one itself -- see requireLocalLft below.
--
-- tcUsedLfts: every lifetime variable that has ever been active along the
-- *current branch* of this function -- starts equal to tcExternalLfts,
-- grows by one on every newlft, and is restored (not left to keep growing)
-- between a qif/if's two branches the same way tcLfts already is (see
-- checkExpr's EIf/EQIf), since each branch gets its own fresh chance to
-- introduce a same-named *local* lifetime the other branch also uses,
-- exactly as if they were two entirely separate functions. Used by
-- SNewLft to enforce Section 3.2.1's own explicit assumption, page 12-13:
-- "we... impose that every lifetime variable only lives once. That is, a
-- lifetime variable cannot be restarted after it has ended" (their own
-- example: "endlft 'a; newlft 'a;" is prohibited) -- nothing enforced this
-- before; Set.insert in the old addLifetime just silently re-added
-- whatever name was given, ended or not, parameter or not.

type TC a = StateT TCState (Except TypeError) a

runTC :: TCState -> TC a -> Either TypeError a
runTC st m = runExcept (evalStateT m st)

-- ============================================================
-- Context helpers
-- ============================================================

getCtx :: TC Context
getCtx = gets tcCtx

putCtx :: Context -> TC ()
putCtx ctx = modify (\st -> st { tcCtx = ctx })

modifyCtx :: (Context -> Context) -> TC ()
modifyCtx f = modify (\st -> st { tcCtx = f (tcCtx st) })

-- Look up a variable — must be active
lookupVar :: Var -> TC (Aliveness, Type)
lookupVar x = do
  Context m <- getCtx
  case Map.lookup x m of
    Nothing                    -> throwError (UnboundVariable x)
    Just (Binding alive ty)    -> return (alive, ty)

-- Look up a variable that must be Active (not frozen)
lookupActiveVar :: Var -> TC Type
lookupActiveVar x = do
  (alive, ty) <- lookupVar x
  case alive of
    Frozen α -> throwError (VariableFrozen x α)
    Active   -> return ty

-- Insert a new active variable into Γ. Requires x not already bound --
-- Appendix B's own opening assumption ("each variable is declared only
-- once in the program, and variable shadowing is not allowed") is a
-- load-bearing invariant, not a footnote: this Map is keyed by name, so a
-- second `let x = ...` while the first `x` is still Active would silently
-- overwrite (and permanently lose track of) it, with no error anywhere --
-- confirmed empirically, `let q = H(q0); let q = [0](); q` (the second `q`
-- discarding the first, never-dropped #bot qubit from H) type-checked,
-- uncomputed, and compiled to a real circuit with a dangling H'd qubit
-- before this check. This does NOT reject the extremely common "let x =
-- H(x);" rebind-after-use idiom: by the time this runs, x's own previous
-- binding has already been consumed (removeVar'd) by evaluating the RHS,
-- so it is no longer in Γ at all -- only a rebind while the old value is
-- still genuinely live and untouched is caught.
insertVar :: Var -> Type -> TC ()
insertVar x ty = do
  Context m <- getCtx
  when (Map.member x m) $ throwError (DuplicateVariable x)
  modifyCtx (\(Context m') -> Context (Map.insert x (Binding Active ty) m'))

-- Remove a variable from Γ (consume it)
removeVar :: Var -> TC ()
removeVar x = modifyCtx (\(Context m) -> Context (Map.delete x m))

-- Freeze variable x with lifetime α (for borrowing)
freezeVar :: Var -> Lifetime -> TC ()
freezeVar x α = modifyCtx (\(Context m) ->
  Context (Map.adjust (\b -> b { bindAlive = Frozen α }) x m))

-- Defrost all variables frozen by α  (paper's defrost_α)
defrostLifetime :: Lifetime -> TC ()
defrostLifetime α = modifyCtx (\(Context m) ->
  Context (Map.map restore m))
  where
    restore (Binding (Frozen β) ty)
      | β == α    = Binding Active ty
      | otherwise = Binding (Frozen β) ty
    restore b = b

-- ============================================================
-- Lifetime preorder helpers
-- ============================================================
orM :: TC Bool -> TC Bool -> TC Bool
orM a b = do { x <- a; if x then return True else b }

getLfts :: TC LifetimePreorder
getLfts = gets tcLfts

putLfts :: LifetimePreorder -> TC ()
putLfts lp = modify (\st -> st { tcLfts = lp })

-- Check α ∈ A  (i.e. α is currently active, α > ⊥)
--
-- LMeet a b (see its own note in Ast.hs) is active iff *both* a and b are
-- -- computed fresh from the current state every call, never cached, so a
-- meet automatically stops being active the moment either side does,
-- without this function (or anything else) needing to know that happened.
isActive :: LifetimeAtom -> TC Bool
isActive LBottom      = return False   -- ⊥ is never in A as a variable
isActive LTop         = return True    -- ⊤ is always available
isActive (LMeet a b)  = (&&) <$> isActive a <*> isActive b
isActive (LVar α)     = do
  lp <- getLfts
  return (Set.member α (ltVars lp))

requireActive :: LifetimeAtom -> TC ()
requireActive lft = do
  ok <- isActive lft
  unless ok $ case lft of
    LVar α -> throwError (LifetimeNotActive α)
    _      -> throwError (OtherError "Invalid lifetime atom")

-- Check α ≤ β in A  (paper: α ≤ β ∈ A, where A is a *preorder* -- Fig. 8's
-- typ_fn rule builds it as "the smallest preorder on {α_i}... including"
-- a signature's own declared constraints, i.e. their reflexive+transitive
-- closure, not the literal set as written; SNewLft similarly only ever
-- adds direct edges to its own immediate neighbours, relying on this same
-- closure for anything further away). Previously just a single
-- Set.member lookup in ltRel, missing the transitive part entirely --
-- confirmed empirically, a signature declaring `<a,b,c | a<=b, b<=c>`
-- (never `a<=c` directly) failed to derive `a<=c`, rejecting a `#c qbit
-- as #a qbit` coercion that Fig. 8's own closure requirement says should
-- hold. reachable does a plain visited-set search over ltRel treated as a
-- graph rather than pre-materialising the closure, since A changes too
-- often (every newlft/endlft/leq) to make caching it worthwhile here.
-- LMeet cases (see its own note in Ast.hs) are handled structurally, before
-- ever consulting ltRel -- an LMeet atom is never inserted into ltRel
-- itself, so `reachable` doesn't need to know about it at all:
--   LMeet a1 a2 ≤ b   iff a1 ≤ b  ∨  a2 ≤ b   (meet ≤ b if *either* side already is,
--                                               since meet ≤ a1 and meet ≤ a2 always
--                                               hold definitionally, so transitivity
--                                               through whichever side reaches b is
--                                               a sound, if not exhaustive, witness)
--   a ≤ LMeet b1 b2   iff a ≤ b1  ∧  a ≤ b2   (a is below the meet iff below both --
--                                               the defining universal property of
--                                               a greatest lower bound)
leq :: LifetimeAtom -> LifetimeAtom -> TC Bool
leq a b
  | a == b               = return True
  | a == LBottom         = return True    -- ⊥ ≤ everything
  | b == LTop            = return True    -- everything ≤ ⊤
  | LMeet a1 a2 <- a     = (||) <$> leq a1 b <*> leq a2 b
  | LMeet b1 b2 <- b     = (&&) <$> leq a b1 <*> leq a b2
  | otherwise            = do
      lp <- getLfts
      return (reachable (ltRel lp) a b)

-- | Meet (greatest lower bound) of two lifetime atoms -- ⊤ is the identity
-- (meeting with ⊤ gives back the other atom untouched, since ⊤ imposes no
-- restriction at all -- "for static and lft, we can just use the lft as
-- static is infinite"), ⊥ is absorbing (meeting with ⊥ is always ⊥, since ⊥
-- is already the global minimum of the preorder -- nothing can be *more*
-- restrictive than the empty lifetime). Two genuinely different lifetime
-- variables produce a structural LMeet term rather than a freshly minted
-- variable -- see LMeet's own note in Ast.hs for why that needs no new
-- newlft/endlft bookkeeping at all. Idempotent (a `meetLft` a = a) so
-- repeated/nested merges (e.g. a chain of nested qifs) don't grow an
-- ever-deeper LMeet tree when the same lifetime keeps recurring.
meetLft :: LifetimeAtom -> LifetimeAtom -> LifetimeAtom
meetLft a b
  | a == b                        = a
  | a == LTop                     = b
  | b == LTop                     = a
  | a == LBottom || b == LBottom  = LBottom
  | otherwise                     = LMeet a b

reachable :: Set.Set (LifetimeAtom, LifetimeAtom) -> LifetimeAtom -> LifetimeAtom -> Bool
reachable rel start target = go Set.empty start
  where
    go visited x
      | x == target             = True
      | x `Set.member` visited  = False
      | otherwise               =
          let visited' = Set.insert x visited
              nexts    = [ y | (x', y) <- Set.toList rel, x' == x ]
          in any (go visited') nexts

-- Add a new lifetime variable to A
addLifetime :: Lifetime -> TC ()
addLifetime α = modify (\st ->
  st { tcLfts = (tcLfts st)
    { ltVars = Set.insert α (ltVars (tcLfts st)) } })

-- Remove a lifetime variable from A
removeLifetime :: Lifetime -> TC ()
removeLifetime α = modify (\st ->
  st { tcLfts = (tcLfts st)
    { ltVars = Set.delete α (ltVars (tcLfts st))
    , ltRel  = Set.filter (notMentions α) (ltRel (tcLfts st)) } })
  where
    notMentions a (x, y) = x /= LVar a && y /= LVar a

-- Add a lifetime ordering constraint α ≤ β
addConstraint :: LifetimeAtom -> LifetimeAtom -> TC ()
addConstraint a b = modify (\st ->
  st { tcLfts = (tcLfts st)
    { ltRel = Set.insert (a, b) (ltRel (tcLfts st)) } })

-- ============================================================
-- Lifetime-variable well-formedness (Section 3.2.1's own assumptions,
-- previously entirely unchecked -- see tcExternalLfts/tcUsedLfts's comment)
-- ============================================================

getUsedLfts :: TC (Set.Set Lifetime)
getUsedLfts = gets tcUsedLfts

putUsedLfts :: Set.Set Lifetime -> TC ()
putUsedLfts s = modify (\st -> st { tcUsedLfts = s })

-- newlft α: reject if α has ever been active on this branch before,
-- whether as this function's own external parameter (never valid to
-- "newlft" -- it's already active from function entry) or as a
-- previously-newlft'd-and-ended local (Section 3.2.1: "a lifetime variable
-- cannot be restarted after it has ended" -- their own prohibited example,
-- page 13, is exactly "endlft 'a; newlft 'a;").
requireFreshLft :: Lifetime -> TC ()
requireFreshLft α = do
  used <- getUsedLfts
  when (α `Set.member` used) $
    throwError (OtherError ("lifetime variable " ++ show α
      ++ " cannot be introduced with newlft: either it's already this "
      ++ "function's own generic parameter (only the caller may "
      ++ "start/end it), or it was already newlft'd and ended earlier in "
      ++ "this function -- a lifetime variable may only ever be used "
      ++ "once (Qurts-core, Sec. 3.2.1)"))

-- stmt_end_lifetime's own "α ∉ A_ex,Π,f" premise (Fig. 16): a function may
-- end only a lifetime it introduced itself via its own newlft -- never one
-- of its own signature's generic parameters, whose actual start/end
-- belongs to the *caller*; ending one here would desync this function's
-- own bookkeeping from what the caller still believes is true. (Fig. 16's
-- stmt_borrow carries the identical premise for *borrowing* with an
-- external α, but enforcing that one turned out to reject a genuinely
-- necessary pattern -- see the note where it used to be called, in
-- SLetRef, below -- so only stmt_end_lifetime's copy is enforced here.)
requireLocalLft :: Lifetime -> String -> TC ()
requireLocalLft α verb = do
  ext <- gets tcExternalLfts
  when (α `Set.member` ext) $
    throwError (OtherError ("cannot " ++ verb ++ " " ++ show α
      ++ ": it is one of this function's own generic lifetime parameters "
      ++ "-- only the caller controls when an external lifetime starts or "
      ++ "ends (Fig. 16's stmt_borrow/stmt_end_lifetime both require "
      ++ "\x3b1 \x2209 A_ex,\x3a0,f); introduce a fresh local lifetime "
      ++ "with newlft instead"))

-- newlft/endlft/α≤β/a borrow's own &α all take a lifetime *variable*
-- specifically (Fig. 3's own footnote: "α, β are lifetime variables") --
-- never the special ⊥/⊤ atoms, which exist only at the *type* level
-- (Fig. 4's 𝔞 ::= α | ⊥ | ⊤) and are never introduced, ended, or borrowed
-- *with*. Since "bot"/"top" are lexer-reserved keywords (Lex.hs's
-- resWords), no ordinary Ident-named variable can ever collide with this
-- check -- a Lifetime whose own text is literally "bot"/"top" can only
-- ever have come from one of those two keywords written in one of these
-- four statement positions (AbsQurtsToAst.hs's convertLifetimeVar, unlike
-- convertLifetimeAtom used for *types*, has no way to tell them apart from
-- an ordinary variable, so was silently accepting them as one -- confirmed
-- empirically, `let r = &top x;` with no `newlft top;` failed with
-- LifetimeNotActive "top", proving "top" there was never treated as the
-- real, always-on ⊤ at all, just a variable that happened to be spelled
-- that way).
requireLftVariable :: Lifetime -> TC ()
requireLftVariable (Lifetime t)
  | t == pack "bot" || t == pack "top" =
      throwError (OtherError ("'" ++ unpack t ++ "' is the special always-"
        ++ (if t == pack "bot" then "empty (\x22a5)" else "available (\x22a4)")
        ++ " lifetime, not a variable -- newlft/endlft/<=/a borrow's own "
        ++ "&-lifetime all require an actual lifetime *variable* here "
        ++ "(a `#" ++ unpack t ++ " T` or `&" ++ unpack t
        ++ " T` *type* is unaffected by this -- this is only about these "
        ++ "four statement positions)"))
  | otherwise = return ()

-- Check α is minimal in A − {⊥}
-- i.e. no β ∈ A such that β < α (β ≤ α but not α ≤ β)
--
-- Uses the same transitive `reachable` search leq does, not a direct
-- Set.member lookup on ltRel -- checking the identical relation two
-- different ways in the same file was itself the inconsistency worth
-- fixing here, independent of whether it's separately exploitable. (It
-- isn't, currently: endlft's own requireLocalLft already restricts α to a
-- locally-newlft'd lifetime, and SNewLft directly links every lifetime it
-- introduces to *everything* already active at that moment -- external or
-- local -- so any β that could ever be smaller than such an α already has
-- a direct edge, not just a transitive one. But that's a fragile,
-- cross-function argument to depend on -- if SNewLft's own exhaustive
-- linking ever changed, this would silently go back to being wrong with
-- nothing likely to catch it -- whereas computing it correctly here
-- doesn't depend on any other function's behaviour at all.)
isMinimal :: Lifetime -> TC Bool
isMinimal α = do
  lp <- getLfts
  let others = Set.delete α (ltVars lp)
  let smallerExists = any (\β ->
        reachable (ltRel lp) (LVar β) (LVar α) &&
        not (reachable (ltRel lp) (LVar α) (LVar β))
        ) (Set.toList others)
  return (not smallerExists)

-- Check &α does not appear in Γ
noRefInCtx :: Lifetime -> TC Bool
noRefInCtx α = do
  Context m <- getCtx
  return $ not $ any (mentionsRef α . bindType) (Map.elems m)
  where
    mentionsRef a (TyRef (LVar b) t) = a == b || mentionsRef a t
    mentionsRef a (TyRef _ t)        = mentionsRef a t
    mentionsRef a (TyBang _ t)       = mentionsRef a t
    mentionsRef a (TyPair t1 t2)     = mentionsRef a t1 || mentionsRef a t2
    mentionsRef _ _                  = False

-- ============================================================
-- Drop trait  (Figure 6)
-- A ⊢ T : Drop
-- ============================================================

canDrop :: Type -> TC Bool
canDrop TyBool         = return True          -- drop_bool
canDrop TyUnit         = return True          -- drop_unit
canDrop TyQBit         = return False         -- qubits cannot be dropped (no-cloning)
canDrop (TyRef _ _)    = return True          -- drop_borrow: &𝔞 T always droppable
canDrop (TyPair t1 t2) = do                  -- drop_tuple
  d1 <- canDrop t1
  d2 <- canDrop t2
  return (d1 && d2)
canDrop (TyBang a _)   = isActive a          -- drop_own: #𝔞 T droppable iff 𝔞 ∈ A

-- ============================================================
-- Purely Quantum  (Figure 7)
-- ============================================================

isPurelyQuantumType :: Type -> Bool
isPurelyQuantumType TyQBit          = True    -- pq_ty_base
isPurelyQuantumType (TyBang _ t)    = isPurelyQuantumType t  -- pq_ty_own
isPurelyQuantumType (TyPair t1 t2)  = isPurelyQuantumType t1 && isPurelyQuantumType t2
isPurelyQuantumType _               = False   -- bool, unit, &α T are not PQ

isPurelyQuantumExpr :: Set.Set FuncName -> Expr -> Bool
isPurelyQuantumExpr _ (EMeas _)       = False   -- measurement is not PQ
isPurelyQuantumExpr _ (EIf _ _ _)     = False   -- classical if is not PQ
isPurelyQuantumExpr pq (ECall f _ _)  = Set.member f pq  -- PQ only if called fn is PQ
isPurelyQuantumExpr _ _               = True

isPurelyQuantumStmt :: Set.Set FuncName -> Stmt -> Bool
isPurelyQuantumStmt pq (SSeq s1 s2)   = isPurelyQuantumStmt pq s1 && isPurelyQuantumStmt pq s2
isPurelyQuantumStmt pq (SLetExpr _ e) = isPurelyQuantumExpr pq e
isPurelyQuantumStmt _ SNoop            = True
isPurelyQuantumStmt _ (SDrop _)        = True
isPurelyQuantumStmt _ _                = True

isPurelyQuantumBlock :: Set.Set FuncName -> Block -> Bool
isPurelyQuantumBlock pq (Block s _) = isPurelyQuantumStmt pq s

-- ============================================================
-- Program / Function / Block  (Figure 17, 8)
-- ============================================================

-- typing_program: each function can only use previously defined ones
checkProgram :: Program -> Either TypeError ()
checkProgram (Program funs) = go Map.empty Set.empty funs
  where
    go _ _ []     = Right ()
    go env pqEnv (f:fs) = do
      case runTC (initState env pqEnv f) (checkFunction f) of
        Left err -> Left err
        Right () ->
          let newPQ = if isPurelyQuantumBlock pqEnv (funBody f)
                      then Set.insert (funName f) pqEnv
                      else pqEnv
          in go (Map.insert (funName f) (funSig f) env) newPQ fs

    initState env pqEnv f =
      let initial = ltVars (buildInitialPreorder (funSig f))
      in TCState
      { tcCtx     = buildInitialContext (funSig f)
      , tcLfts    = buildInitialPreorder (funSig f)
      , tcFuncs   = env
      , tcFunc    = funName f
      , tcPQFuncs = pqEnv
      , tcExternalLfts = initial
      , tcUsedLfts     = initial
      }

-- Build Γ from signature parameters, all Active
buildInitialContext :: Signature -> Context
buildInitialContext sig =
  Context $ Map.fromList
    [ (x, Binding Active t) | (x, t) <- sigParams sig ]

-- Build A from signature lifetime preorder
buildInitialPreorder :: Signature -> LifetimePreorder
buildInitialPreorder = sigLifetime

-- typing_fn: check body has return type matching signature
-- Also enforces the same "declared once" invariant insertVar enforces for
-- let-bindings (see its own comment) on a signature's own parameter list --
-- buildInitialContext's Map.fromList would otherwise silently keep only the
-- last of two same-named parameters, dropping the other without a trace.
-- Same check, separately, for the signature's own *lifetime* parameter
-- list (`<alpha, alpha|>`): ltVars (a Set) would silently collapse the
-- duplicate, but ltParams (a List, since expr_function's substitution
-- needs positional order) would not, so a call's own lts/args zip
-- (checkExpr's ECall case) would end up mapping the *same* generic name to
-- two different caller-supplied lifetimes, with `lookup`'s own
-- first-match behaviour silently discarding the second everywhere it's
-- substituted in -- not unsound (the discarded one is still separately
-- required to be active), just a silent, confusing near-miss for a
-- vanishingly unlikely signature to begin with.
checkFunction :: Function -> TC ()
checkFunction (Function _name sig body) = do
  case firstDuplicate (map fst (sigParams sig)) of
    Just x  -> throwError (DuplicateVariable x)
    Nothing -> return ()
  case firstDuplicate (ltParams (sigLifetime sig)) of
    Just α  -> throwError (OtherError ("Duplicate lifetime parameter in signature: " ++ show α))
    Nothing -> return ()
  ty <- checkBlock body
  unless (ty == sigReturn sig) $
    throwError (ReturnTypeMismatch (sigReturn sig) ty)

firstDuplicate :: Ord a => [a] -> Maybe a
firstDuplicate = go Set.empty
  where
    go _    []       = Nothing
    go seen (x : xs)
      | x `Set.member` seen = Just x
      | otherwise            = go (Set.insert x seen) xs

-- typing_block: run statement, exactly one variable left, return its type
-- { S ; x } : T  when S : (Γ,A) → (x:T, A)
-- Droppable active variables (references, booleans) are implicitly dropped at end of scope.
-- Non-droppable active variables (e.g. #⊥ qbit) remaining after the block are a linearity error.
checkBlock :: Block -> TC Type
checkBlock (Block stmt retVar) = do
  lftsBefore <- getLfts
  checkStmt stmt
  lftsAfter <- getLfts
  -- typing_block (page 32): "the lifetime preorder A has to be the same
  -- before and after the block" -- both directions, not just "no new
  -- leaks": a newlft'd-but-never-ended lifetime (added, not removed) is
  -- exactly as much a violation as an external lifetime the block
  -- illegitimately endlft'd and never restored (removed, not added back).
  -- The latter direction went unchecked before -- confirmed empirically,
  -- `fn f<alpha|>(r: &alpha #bot qbit) -> #top bool { drop r; endlft
  -- alpha; let b = true; b }` (ending a signature's own external lifetime,
  -- never valid per Fig. 16's stmt_end_lifetime -- see requireLocalLft)
  -- type-checked under the old one-directional check.
  unless (ltVars lftsAfter == ltVars lftsBefore) $
    throwError (OtherError ("Lifetime preorder must be unchanged across a block: had "
      ++ show (Set.toList (ltVars lftsBefore)) ++ " before, "
      ++ show (Set.toList (ltVars lftsAfter)) ++ " after"))
  ty <- lookupActiveVar retVar
  Context m <- getCtx
  let activeOthers = [(v, bindType b) | (v, b) <- Map.toList m
                                       , v /= retVar
                                       , bindAlive b == Active]
  forM_ activeOthers $ \(v, t) -> do
    ok <- canDrop t
    unless ok $ throwError (LinearityViolation ("Variable not consumed after block: " ++ show v))
    removeVar v
  removeVar retVar
  return ty

-- ============================================================
-- Statements  (Figure 16)
-- ============================================================

checkStmt :: Stmt -> TC ()
checkStmt stmt = case stmt of

  -- stmt_noop
  SNoop -> return ()

  -- stmt_composition
  SSeq s1 s2 -> do
    checkStmt s1
    checkStmt s2

  -- stmt_new_lifetime: add α to A, constrained below all existing lifetimes
  -- newlft α : (Γ, A) → (Γ, A' where A' includes {α ≤ γ | γ ∈ A_ex})
  -- A_ex = lifetimes already in A (excluding α itself, in case it's already present)
  SNewLft α -> do
    requireLftVariable α
    requireFreshLft α
    lp <- getLfts
    let externalLfts = Set.delete α (ltVars lp)
    addLifetime α
    used <- getUsedLfts
    putUsedLfts (Set.insert α used)
    forM_ (Set.toList externalLfts) $ \γ ->
      addConstraint (LVar α) (LVar γ)

  -- stmt_end_lifetime: α minimal in A−{⊥}, &α not in Γ, defrost
  -- endlft α : (Γ, A) → (defrost_α(Γ), A − α)
  SEndLft α -> do
    requireLftVariable α
    requireLocalLft α "endlft"
    ok <- isMinimal α
    unless ok $ throwError (LifetimeNotMinimal α)
    noRef <- noRefInCtx α
    unless noRef $ throwError (ReferenceStillInContext α)
    defrostLifetime α
    removeLifetime α

  -- stmt_lft_ineq: add α ≤ β to A
  -- α ≤ β : (Γ, A) → (Γ, A')
  --
  -- Fig. 16's own premise is "α, β ∉ A_ex,Π,f" -- BOTH sides must be
  -- lifetimes this function introduced itself, never its own external
  -- generic parameters. Unlike stmt_borrow's identical premise (not
  -- enforced -- see SLetRef's own note on why), this one is enforced,
  -- because leaving it unchecked is a genuine soundness hole, not just an
  -- over-strict rule: a function can declare `<a,b|>` with *no* signature
  -- constraint between them, then assert `a <= b;` in its own body and
  -- coerce accordingly -- but expr_function's own caller-side check only
  -- ever verifies a callee's *signature*-declared constraints (ltRel of
  -- sigLifetime), never anything a callee's body separately asserts about
  -- its own external parameters. So the caller can never see, and never
  -- has to satisfy, that invented "a <= b" -- confirmed by construction:
  -- a function exactly this shape type-checked, and a caller instantiating
  -- it with two lifetimes actually related the *other* way (the callee's
  -- own claimed a <= b substituting to the caller's real beta <= alpha)
  -- was accepted too, only caught later by Uncompute's own defensive
  -- re-type-check (ReferenceStillInContext) rather than rejected outright
  -- here, where the actual mistake is. No existing example uses an
  -- explicit body-level `α <= β;` statement at all (every current use of
  -- "<=" is in a signature's own `< | >` clause, a completely separate
  -- code path from this one), so there's nothing to regress.
  SLeq α β -> do
    requireLftVariable α
    requireLftVariable β
    requireLocalLft α "relate (<=)"
    requireLocalLft β "relate (<=)"
    addConstraint (LVar α) (LVar β)

  -- stmt_coercion: x as T  (subtyping / coercion)
  -- x as T : (Γ + {x:U}, A) → (Γ + {x:T}, A)  when A ⊢ U ≤ T
  SAs x ty -> do
    oldTy <- lookupActiveVar x
    ok <- isSubtype oldTy ty
    unless ok $ throwError (TypeMismatch ty oldTy)
    removeVar x
    insertVar x ty

  -- stmt_borrow: let y = &α x
  -- freezes x with lifetime α, introduces y : &α T
  -- Paper (Figure 16 stmt_borrow): requires ∀γ ∈ {γ | &^γ appears in T}, α ≤ γ ∈ A
  --
  -- Fig. 16's stmt_borrow also carries an "α ∉ A_ex,Π,f" premise (this
  -- function may only borrow with a lifetime it introduced itself, never
  -- one of its own external generic parameters) -- NOT enforced here,
  -- deliberately, after trying it and finding it rejects a genuinely
  -- necessary pattern: example_grover_amplified.qurts-core's `oracle<alpha>`
  -- does `let rc1 = &alpha c1;` -- borrowing a *locally computed* c1 with
  -- oracle's own external alpha, so that the further call
  -- all_satisfied3<alpha>(rc1,..) comes back #alpha qbit, matching
  -- oracle's own declared return type exactly. This isn't avoidable by
  -- borrowing with a fresh local beta instead: newlft's own rule ties beta
  -- to be *shorter* than every already-active lifetime including alpha
  -- (beta ≤ alpha), so a #beta qbit result could never be coerced back up
  -- to #alpha qbit afterward (subty_shorten only ever narrows). So
  -- borrowing with an external lifetime, specifically, appears
  -- structurally required for a function to hand a *locally built* value
  -- into a further call while keeping the result tagged with its own
  -- return lifetime -- worth confirming with Kengo whether Fig. 16's own
  -- premise here is another case (like typ_qif's branch-equality, see
  -- kengo.txt) where the fully-formal rule is stricter than the paper's
  -- own Grover example actually needs. Ending an external lifetime
  -- (stmt_end_lifetime's identical premise) is a different question --
  -- that one *is* enforced, see requireLocalLft's own call in SEndLft --
  -- because nothing here ever needed to do that.
  SLetRef y α x -> do
    ty <- lookupActiveVar x
    requireLftVariable α
    requireActive (LVar α)
    forM_ (refLifetimes ty) $ \γ -> do
      ok <- leq (LVar α) γ
      unless ok $ throwError (OtherError
        ("Borrow lifetime ordering violated: " ++ show α ++ " must be ≤ " ++ show γ))
    freezeVar x α
    insertVar y (TyRef (LVar α) ty)

  -- stmt_expr: let y = e
  SLetExpr y e -> do
    ty <- checkExpr e
    insertVar y ty

  -- stmt_proj: let (y0,y1) = x
  SLetPair y0 y1 x -> do
    ty <- lookupActiveVar x
    case ty of
      TyPair t0 t1 -> do
        removeVar x
        insertVar y0 t0
        insertVar y1 t1
      _ -> throwError (TypeMismatch (TyPair TyUnit TyUnit) ty)

  -- stmt_drop: drop x  (requires A ⊢ T : Drop)
  SDrop x -> do
    ty <- lookupActiveVar x
    ok <- canDrop ty
    unless ok $ throwError (CannotDrop ty)
    removeVar x

-- ============================================================
-- Expressions  (Figure 15)
-- ============================================================

-- Returns the type of the expression and updates Γ
-- (variables are consumed from context as needed)
checkExpr :: Expr -> TC Type

-- expr_var: x : T consumes x from Γ
checkExpr (EVar x) = do
  ty <- lookupActiveVar x
  removeVar x
  return ty

-- expr_const_bool: true/false : #⊤ bool
checkExpr ETrue  = return (TyBang LTop TyBool)
checkExpr EFalse = return (TyBang LTop TyBool)

-- expr_unit: () : ()
checkExpr EUnit = return TyUnit

-- expr_tuple: (x0,x1) : T0 × T1, consumes x0 and x1
-- x0 and x1 must be *different* variables -- Γ + {x0:T0, x1:T1} (Fig. 15's
-- own premise) isn't a meaningful context extension otherwise, and this
-- rule's own implementation looks both up *before* removing either, so
-- without this check (x0,x0) would look x0 up twice while it's still
-- Active both times, silently pairing a single qubit with itself: a
-- genuine no-cloning violation, not just a linearity bookkeeping slip --
-- confirmed empirically end to end, `let p = (x,x); let (a,b) = p; ...`
-- compiled to a circuit with *one* physical qubit measured *twice*,
-- reported as if they were two independent qubits (perfectly correlated
-- 00/11 results, never 01/10, over 1000 shots). ECall's own repeated-
-- argument case doesn't have this gap: it looks up and removes each
-- argument in strict sequence, so a repeated name is already caught by
-- the second lookup finding it gone (UnboundVariable) -- confirmed
-- empirically too. EPair is the only construct that reads-then-removes
-- in two separate passes.
checkExpr (EPair x0 x1) = do
  when (x0 == x1) $ throwError (OtherError
    ("(x0, x1) requires two different variables, got the same one twice: "
      ++ show x0 ++ " -- pairing a value with itself would duplicate "
      ++ "ownership of whatever it refers to (no-cloning)"))
  t0 <- lookupActiveVar x0
  t1 <- lookupActiveVar x1
  removeVar x0
  removeVar x1
  return (TyPair t0 t1)

-- expr_copy: copy x : T  (T must be Copy)
-- does NOT consume x
checkExpr (ECopy x) = do
  ty <- lookupActiveVar x
  ok <- isCopy ty
  unless ok $ throwError (OtherError ("Type is not Copy: " ++ show ty))
  return ty

-- expr_measure: meas(x) : #⊤ bool  (Figure 15, expr_measure)
-- consumes x : #𝔞 qbit for *any* lifetime 𝔞 -- Fig. 5/15's own typ_meas
-- premise is "Γ + {x : #𝔞 qbit}", not "#⊥ qbit" specifically; measuring
-- destroys superposition regardless of what lifetime tag x carried, and
-- the result is unconditionally droppable (drop_bool has no activity
-- condition) either way, so there was never a soundness reason to require
-- exactly #⊥ here. Confirmed this was over-restrictive in practice:
-- `meas(q)` on a `q : #⊤ qbit` (e.g. straight off `[0]()`) used to be
-- rejected with a TypeMismatch, forcible only by first inserting a
-- pointless `q as #bot qbit;`.
checkExpr (EMeas x) = do
  ty <- lookupActiveVar x
  case ty of
    TyBang _a TyQBit -> do
      removeVar x
      return (TyBang LTop TyBool)
    -- NotAnOwned ty, not TypeMismatch (TyBang LBottom TyQBit) ty: since the
    -- fix above, the actual requirement is "#𝔞 qbit for *any* 𝔞", so
    -- claiming "expected #⊥ qbit" specifically would itself be a wrong
    -- error message now -- this was a real, if harmless, inconsistency
    -- left over from that fix (the error text never got updated to match
    -- the relaxed rule). NotAnOwned was also dead code until this fix --
    -- defined in the TypeError enum but never actually thrown anywhere.
    _ -> throwError (NotAnOwned ty)

-- expr_unitary: U(x) : #⊥ qbit  (Figure 15, expr_unitary)
-- consumes x : #𝔞 qbit for *any* lifetime 𝔞, returns #⊥ qbit -- same fix as
-- expr_measure just above and for the same reason: Fig. 5/15's own
-- typ_unitary premise is "Γ + {x : #𝔞 qbit^n}"; only the *output* is
-- pinned to #⊥ (a general unitary isn't a classical injection, so its
-- result can't be inverted and is therefore never uncomputable, no matter
-- what the input's own lifetime was). Previously required the input to
-- already be #⊥ specifically, which was always workable around with a
-- prior `x as #bot qbit;` (subty_shorten always permits #𝔞 T -> #⊥ T) but
-- had no basis in the rule itself.
checkExpr (EU _u x) = do
  ty <- lookupActiveVar x
  case ty of
    TyBang _a TyQBit -> do
      removeVar x
      return (TyBang LBottom TyQBit)
    -- NotAnOwned, not a TypeMismatch claiming #⊥ specifically -- same
    -- reasoning as expr_measure's identical fix just above.
    _ -> throwError (NotAnOwned ty)

-- expr_lifted: [c](x) : #𝔞 qbit^n  (Figure 15, expr_lifted)
-- single qubit: consumes x : #𝔞 qbit, returns #𝔞 qbit
-- pair of qubits: consumes x : (#𝔞 qbit × #𝔞 qbit), returns (#𝔞 qbit × #𝔞 qbit)
--   (both qubits must share the same lifetime 𝔞, matching the paper's #𝔞 qbit²)
--
-- [c] keeps its argument's lifetime tag (preserving droppability) where EU
-- pins to #bot instead, so admitting a name here is a promise that dropping
-- a value built from it is sound. That promise is backed entirely by
-- GateInverse.hs's classicalInverseTable actually having a verified inverse
-- for `c` -- not by `c` being a "classical Boolean function" in some
-- stricter sense (see that table's own note: a phase gate like Z is
-- admitted too, since full/faithful reversal makes it just as safe to drop
-- as a true permutation once a correct inverse is on record). So this check
-- has to happen here, tied to the same table, rather than being left
-- unchecked: without it, `[H](x)` (no entry in classicalInverseTable at
-- all) still type-checked, preserving droppability for a gate this module
-- has no recorded inverse for, and was only ever caught by accident,
-- downstream, when Uncompute.hs's own lookup failed to recognise the name.
checkExpr (EC c x) = do
  unless (isKnownClassicalInjection c) $
    throwError (OtherError ("not a known classical injection for [c](x): " ++ show c
      ++ " -- only names with a verified inverse in GateInverse.hs's "
      ++ "classicalInverseTable are valid here; use U(x) (EU) for a general "
      ++ "unitary, which forfeits the argument's droppability instead of "
      ++ "falsely promising it"))
  ty <- lookupActiveVar x
  -- The argument's own shape must match c's own arity -- cnot/swap are
  -- genuinely 2-qubit gates, everything else here is 1-qubit -- not just
  -- "single qubit or same-lifetime pair, whichever c happens to get
  -- applied to". Previously unchecked: confirmed empirically, `[cnot](q)`
  -- for a single qubit q type-checked and passed uncompute, only ever
  -- failing at the very end as a raw Python ValueError out of
  -- build_circuit.py's own arity check -- never caught here, where a
  -- clean, immediate error belongs. See isTwoQubitClassical's own note.
  let twoQubit = isTwoQubitClassical c
  case ty of
    TyBang a TyQBit | not twoQubit -> do
      removeVar x
      return (TyBang a TyQBit)
    TyPair (TyBang a TyQBit) (TyBang b TyQBit) | a == b, twoQubit -> do
      removeVar x
      return (TyPair (TyBang a TyQBit) (TyBang b TyQBit))
    TyBang _ TyQBit | twoQubit ->
      throwError (OtherError ("[c](x) for " ++ show c ++ " needs a same-lifetime "
        ++ "pair of qubits (it's a 2-qubit gate), got a single qubit: " ++ show ty))
    TyPair (TyBang _ TyQBit) (TyBang _ TyQBit) ->
      throwError (OtherError ("[c](x) for " ++ show c ++ " needs a single qubit "
        ++ "(it's a 1-qubit gate), got a pair: " ++ show ty))
    -- Same stale-error-message issue as expr_measure/expr_unitary above,
    -- pre-existing here rather than introduced by this session's fixes:
    -- this accepts #𝔞 qbit for any 𝔞 (or a same-𝔞 pair) and always has,
    -- but the failure case claimed "expected #⊥ qbit" regardless. Not
    -- NotAnOwned here, since the accepted shape isn't just "an owned
    -- qubit" -- it's that or a matching pair -- so a plain description is
    -- clearer than reusing a constructor that doesn't cover the pair case.
    _ -> throwError (OtherError ("expected #𝔞 qbit or a same-lifetime pair "
      ++ "of #𝔞 qbit for [c](x), got " ++ show ty))

-- EInit0 / EInit1: [0]() / [1]() : #⊤ qbit
-- introduces a new qubit in state |0⟩ or |1⟩
-- return type is #⊤ qbit (affine for whole program)
checkExpr EInit0 = return (TyBang LTop TyQBit)
checkExpr EInit1 = return (TyBang LTop TyQBit)

-- expr_function: f⟨α0,...⟩(x0,...)
-- Paper (Figure 15 expr_function): substitutes generic lifetimes α'_i with provided α_i
checkExpr (ECall fname lts args) = do
  env <- gets tcFuncs
  case Map.lookup fname env of
    Nothing  -> throwError (UnknownFunction fname)
    Just sig -> do
      let genericLfts = ltParams (sigLifetime sig)
      unless (length lts == length genericLfts) $
        throwError (OtherError ("Wrong number of lifetime arguments: expected "
          ++ show (length genericLfts) ++ ", got " ++ show (length lts)))
      -- expr_function: ∀i, α_i ∈ A (each provided lifetime must be active)
      forM_ lts requireActive
      let subst    = zip genericLfts lts
      -- expr_function: ∀(α'_i ≤ α'_j) ∈ sig constraints, subst(α'_i) ≤ subst(α'_j) ∈ A
      forM_ (Set.toList (ltRel (sigLifetime sig))) $ \(a, b) -> do
        ok <- leq (substAtom subst a) (substAtom subst b)
        unless ok $ throwError (OtherError
          ("Lifetime constraint not satisfied in call to " ++ show fname))
      let paramTys = map (substType subst . snd) (sigParams sig)
      let retTy    = substType subst (sigReturn sig)
      unless (length args == length paramTys) $
        throwError (OtherError "Wrong number of arguments")
      forM_ (zip args paramTys) $ \(arg, expectedTy) -> do
        actualTy <- lookupActiveVar arg
        unless (actualTy == expectedTy) $
          throwError (TypeMismatch expectedTy actualTy)
        removeVar arg
      return retTy

-- expr_classical_if: if x Bt else Bf
-- x : bool, both branches return same type T
-- Context consistency is enforced by checkBlock: each branch must consume all of Γ.
-- The paper's own expr_measure/expr_const_bool rules type every bool-producing
-- expression (meas(x), true, false) as #⊤bool, never bare bool, and Figure 13's
-- subtyping has no rule collapsing #𝔞bool to bool -- so a literal-TyBool match
-- here would make expr_classical_if only ever satisfiable by a bare `bool`
-- function parameter, never by a measured or literal condition. Since bool is
-- unconditionally Copy (cpy_bool) regardless of its ownership wrapper (cpy_own
-- adds no restriction #𝔞bool doesn't already have), stripping the wrapper here
-- is a conservative reading of the intended rule, not a soundness-affecting
-- extension: no linear resource is hidden inside a bool's #𝔞 annotation.
checkExpr (EIf x bt bf) = do
  ty <- lookupActiveVar x
  case stripBang ty of
    TyBool -> do
      -- x ∈ Δ: remove x so branches are typed under Γ alone (mirrors
      -- expr_quantum_if's identical Γ+Δ split -- see checkExpr EQIf above)
      removeVar x
      ctxBefore  <- getCtx
      lftsBefore <- getLfts
      usedBefore <- getUsedLfts
      t1 <- checkBlock bt
      putCtx  ctxBefore
      putLfts lftsBefore
      putUsedLfts usedBefore
      t2 <- checkBlock bf
      -- restore x: bool back into context (stays in Δ after the
      -- expression, same as qif restores its own control variable)
      insertVar x ty
      unless (t1 == t2) $ throwError (TypeMismatch t1 t2)
      return t1
    _ -> throwError (TypeMismatch TyBool ty)



-- expr_quantum_if (Fig. 15): qif x B|1⟩ else B|0⟩
-- x : &^α qbit stays in Δ (not consumed); branches typed under Γ (without x)
-- Both branches must be PQ and return the literal same T, per the rule's
-- own premise "(Γ,A) ⊢ B_i : T" for both i -- exactly like expr_classical_if
-- right next to it in Fig. 15. Result type is #^α T.
--
-- This used to require t1/t2 literally identical, full stop -- correct per
-- the rule above, but stricter than necessary: it rejected any qif whose
-- two branches were "morally the same value" but happened to carry
-- different lifetime tags (typically because one branch nests a further
-- qif, whose own conclusion is unconditionally retagged #^beta by this same
-- rule, while its sibling is a bare [0]()/[1]() sitting at #top, or an
-- untouched parameter at some other lifetime), forcing the programmer to
-- insert an explicit `as` coercion by hand every time. Confirmed with Kengo
-- this is exactly the kind of gap Fig. 15's literal rule leaves for a
-- reason: the proof is easier against the strict version, but the intended
-- implementation-level relaxation is the same one Rust itself uses across
-- if/else branches -- automatically unify to the *shortest common*
-- lifetime (a greatest-lower-bound/meet), not require the programmer to
-- name it. See meetLft/unifyBranchTypes and LMeet's own note in Ast.hs for
-- how that's implemented: never a freshly `newlft`'d variable (which would
-- need its own cascading endlft bookkeeping to track when it stops being
-- valid), but a purely structural term whose own activity is *defined* as
-- "both original lifetimes still active" -- ends together with whichever
-- of the two ends first, for free, exactly as intended.
--
-- The critical difference from the *old*, pre-Fig.-15-audit version of this
-- rule (see grover.txt points 7-8) is where the merged lifetime ends up:
-- that old version discarded whichever branch lifetime "won" a subtyping
-- comparison and *replaced* it outright with a fresh, unrelated α, with no
-- check that α was even reachable from it -- unsound (confirmed by
-- build+simulate: examples/example_diagonal_skip_counterexample_error.qurts-core).
-- meetLft never discards information: meeting with #top (the identity) can
-- recover the old "just use α" behaviour when a branch's own tag was #top,
-- but meeting with #bot (absorbing) or another genuine lifetime always
-- narrows *into* the more restrictive one instead of silently overwriting
-- it -- so a branch built from a non-diagonal bare-EU gate (#bot, a
-- one-way door) can never again be laundered into something droppable just
-- by passing it through a qif.
checkExpr (EQIf x bt bf) = do
  ty <- lookupActiveVar x
  case ty of
    TyRef α innerTy -> do
      let baseInner = stripBang innerTy
      case baseInner of
        TyQBit -> do
          requireActive α
          pqFuncs <- gets tcPQFuncs
          unless (isPurelyQuantumBlock pqFuncs bt) $
            throwError (NotPurelyQuantum "qif then-branch contains measurement or classical if")
          unless (isPurelyQuantumBlock pqFuncs bf) $
            throwError (NotPurelyQuantum "qif else-branch contains measurement or classical if")
          -- x ∈ Δ: remove x so branches are typed under Γ (paper Figure 15 expr_quantum_if)
          removeVar x
          ctxBefore  <- getCtx
          lftsBefore <- getLfts
          usedBefore <- getUsedLfts
          t1 <- checkBlock bt
          putCtx  ctxBefore
          putLfts lftsBefore
          putUsedLfts usedBefore
          t2 <- checkBlock bf
          -- restore x: &^α qbit back into context (stays in Δ after expression)
          insertVar x ty
          t <- case unifyBranchTypes t1 t2 of
            Just unified -> return unified
            Nothing      -> throwError (TypeMismatch t1 t2)
          unless (isPurelyQuantumType t) $
            throwError (NotPurelyQuantum ("qif branch return type is not PQ: " ++ show t))
          return (retagQifResult α t)
        _ -> throwError (NotAReference ty)
    _ -> throwError (NotAReference ty)

-- | Unify two branch types that may differ only in their lifetime
-- annotations, meeting the lifetime at each corresponding #^𝔞-position
-- (see checkExpr's EQIf case for why, and meetLft for the meet itself).
-- Nothing if the two types differ in anything other than a lifetime
-- annotation under a # -- a genuinely different type shape (e.g. bool vs
-- qbit, or a & at one position vs a # at the same position in the other)
-- is still a hard TypeMismatch, same as before; this only ever widens
-- what's accepted at a #^𝔞 position specifically.
unifyBranchTypes :: Type -> Type -> Maybe Type
unifyBranchTypes t1 t2 | t1 == t2 = Just t1
unifyBranchTypes (TyBang a1 t1) (TyBang a2 t2) =
  TyBang (meetLft a1 a2) <$> unifyBranchTypes t1 t2
unifyBranchTypes (TyPair a1 b1) (TyPair a2 b2) =
  TyPair <$> unifyBranchTypes a1 a2 <*> unifyBranchTypes b1 b2
unifyBranchTypes _ _ = Nothing

-- | Combine a qif's own control lifetime α with its (already-unified)
-- branch return type's own outer lifetime tag, by meeting them -- not by
-- discarding the branch's own tag and substituting α outright, which was
-- the unsound behaviour this replaces (see checkExpr's EQIf case). When the
-- branch type isn't itself #-wrapped (shouldn't arise for a PQ-valid qbit
-- branch in practice, since every quantum value here is always #-tagged,
-- but kept total rather than partial), falls back to wrapping with α alone
-- -- the only sound choice when there's no existing tag to meet against.
retagQifResult :: LifetimeAtom -> Type -> Type
retagQifResult alpha (TyBang l inner) = TyBang (meetLft alpha l) inner
retagQifResult alpha t                = TyBang alpha t


--stripBang helper function to remove the outermost TyBang from a type
-- Collapse nested #𝔞 (#𝔟 T) to #𝔠 T  (subty_double_affine, Figure 13)
stripBang :: Type -> Type
stripBang (TyBang _ t) = t
stripBang t            = t
-- ============================================================
-- Subtyping  (Figure 13)
-- A ⊢ T1 ≤ T2
-- ============================================================

isSubtype :: Type -> Type -> TC Bool
-- subty_shorten: &𝔞 T ≤ &𝔟 T  when 𝔟 ≤ 𝔞
-- subty_reborrow: &𝔠 &𝔞 T ≤ &𝔟 T  when 𝔟 ≤ 𝔠 and 𝔟 ≤ 𝔞
-- subty_borrow_affine: &^α #^𝔞 T ≤ &^α T (Fig. 13's own axiom -- no
-- condition on 𝔞 at all, and *literally* the same α on both sides; composed
-- here with subty_shorten's own 𝔟 ≤ 𝔠 to get the more generally useful
-- &^𝔠 #^𝔞 T ≤ &^𝔟 T whenever 𝔟 ≤ 𝔠, for *any* 𝔞). Previously required
-- `leq b a` too (as if this were a second subty_reborrow), which has no
-- basis in the axiom -- confirmed over-restrictive in practice: `&⊤(#⊥
-- qbit) as &⊤ qbit` needs only ⊤ ≤ ⊤ (trivial), not the ⊤ ≤ ⊥ the old code
-- also demanded (never true), so it was rejected outright before this fix.
isSubtype (TyRef c t1) (TyRef b t2) = tryShorten `orM` tryCollapse
  where
    tryShorten  = do ok1 <- leq b c; ok2 <- isSubtype t1 t2; return (ok1 && ok2)
    tryCollapse = case t1 of
      TyRef  a inner -> do ok1 <- leq b c; ok2 <- leq b a; ok3 <- isSubtype inner t2; return (ok1 && ok2 && ok3)
      TyBang _a inner -> do ok1 <- leq b c; ok2 <- isSubtype inner t2; return (ok1 && ok2)
      _              -> return False
-- subty_shorten: #𝔞 T ≤ #𝔟 T  when 𝔟 ≤ 𝔞
-- subty_double_affine: #𝔠 #𝔞 T ≤ #𝔟 T  when 𝔟 ≤ 𝔠 and 𝔟 ≤ 𝔞
isSubtype (TyBang c t1) (TyBang b t2) = tryShorten `orM` tryCollapse
  where
    tryShorten  = do ok1 <- leq b c; ok2 <- isSubtype t1 t2; return (ok1 && ok2)
    tryCollapse = case t1 of
      TyBang a inner -> do ok1 <- leq b c; ok2 <- leq b a; ok3 <- isSubtype inner t2; return (ok1 && ok2 && ok3)
      _              -> return False
-- subty_affine_borrow: #^𝔞 &^α T ≤ &^α T (Fig. 13's own axiom -- mirror
-- image of subty_borrow_affine above, same bug, same fix: no condition on
-- the *outer* bang's own lifetime 𝔞 at all, literally the same α on both
-- sides of the reference; composed with subty_shorten to get
-- #^𝔠 &^𝔞 T ≤ &^𝔟 T whenever 𝔟 ≤ 𝔞, for *any* 𝔠. Previously also required
-- `leq b c` (the discarded outer bang's own lifetime), which has no basis
-- in the axiom either -- confirmed over-restrictive the same way: a
-- function parameter typed `#bot &gamma qbit` couldn't be coerced down to
-- `&gamma qbit` (needed gamma ≤ bot, never true) even though gamma ≤ gamma
-- is all the axiom actually asks for.
isSubtype (TyBang _c (TyRef a t1)) (TyRef b t2) = do
  ok1 <- leq b a; ok2 <- isSubtype t1 t2
  return (ok1 && ok2)
-- subty_unit: P𝔞() ≤ ()
isSubtype (TyRef _ TyUnit) TyUnit  = return True
isSubtype (TyBang _ TyUnit) TyUnit = return True
-- subty_ptr_tuple: P𝔞(T₀×T₁) ≅ (P𝔞 T₀ × P𝔞 T₁) -- an isomorphism (Fig. 13
-- states it with "≅", not "≤"), so both directions must hold; only the
-- wrapper-outside ≤ wrapper-distributed direction was implemented. Added
-- the reverse (wrapper-distributed ≤ wrapper-outside) too, mirroring the
-- forward rule exactly: the two source halves need not already share one
-- lifetime, they just each need to independently subtype down to the
-- target's single combined one (the same per-component narrowing the
-- forward rule already allows via subty_shorten, just run in the other
-- direction) -- references/owned values carry no memory of their own (Fig.
-- 10's location model; Circuit.hs's own LocTree only ever aliases, never
-- allocates, for a reference), so which side of the isomorphism a value's
-- *type* happens to be written in has no runtime consequence to preserve.
-- Nothing currently in examples/ needs this direction (checkExpr's own
-- EC/EQIf handling reaches the "distributed" shape directly, never via
-- this rule), but its absence was a genuine asymmetry against the paper's
-- own stated axiom, not a deliberate restriction.
isSubtype (TyRef  a (TyPair t1 t2)) (TyPair (TyRef  b t1') (TyRef  c t2')) = do
  ok1 <- isSubtype (TyRef  a t1) (TyRef  b t1')
  ok2 <- isSubtype (TyRef  a t2) (TyRef  c t2')
  return (ok1 && ok2)
isSubtype (TyBang a (TyPair t1 t2)) (TyPair (TyBang b t1') (TyBang c t2')) = do
  ok1 <- isSubtype (TyBang a t1) (TyBang b t1')
  ok2 <- isSubtype (TyBang a t2) (TyBang c t2')
  return (ok1 && ok2)
isSubtype (TyPair (TyRef b t1') (TyRef c t2')) (TyRef a (TyPair t1 t2)) = do
  ok1 <- isSubtype (TyRef b t1') (TyRef a t1)
  ok2 <- isSubtype (TyRef c t2') (TyRef a t2)
  return (ok1 && ok2)
isSubtype (TyPair (TyBang b t1') (TyBang c t2')) (TyBang a (TyPair t1 t2)) = do
  ok1 <- isSubtype (TyBang b t1') (TyBang a t1)
  ok2 <- isSubtype (TyBang c t2') (TyBang a t2)
  return (ok1 && ok2)
-- subty_tuple
isSubtype (TyPair t1 t2) (TyPair t1' t2') = do
  ok1 <- isSubtype t1 t1'
  ok2 <- isSubtype t2 t2'
  return (ok1 && ok2)
isSubtype t1 t2 = return (t1 == t2)

-- ============================================================
-- Copy trait  (Figure 14)
-- ============================================================

isCopy :: Type -> TC Bool
isCopy TyBool         = return True   -- cpy_bool
isCopy (TyRef _ _)    = return True   -- cpy_borrow
isCopy TyUnit         = return True   -- cpy_unit
isCopy (TyPair t1 t2) = do           -- cpy_tuple
  ok1 <- isCopy t1
  ok2 <- isCopy t2
  return (ok1 && ok2)
isCopy (TyBang _ t)   = isCopy t     -- cpy_own: #𝔞 T copyable iff T copyable
isCopy TyQBit         = return False  -- qubits are not copyable (no-cloning)

-- ============================================================
-- Lifetime substitution helpers  (for expr_function, Figure 15)
-- ============================================================

-- Substitute a single LifetimeAtom given a mapping from generic Lifetime vars
substAtom :: [(Lifetime, LifetimeAtom)] -> LifetimeAtom -> LifetimeAtom
substAtom subst (LVar α) = case lookup α subst of
  Just atom -> atom
  Nothing   -> LVar α
substAtom _ atom = atom

-- Apply lifetime substitution throughout a Type
substType :: [(Lifetime, LifetimeAtom)] -> Type -> Type
substType _     TyBool           = TyBool
substType _     TyQBit           = TyQBit
substType _     TyUnit           = TyUnit
substType subst (TyPair t1 t2)   = TyPair (substType subst t1) (substType subst t2)
substType subst (TyRef a t)      = TyRef  (substAtom subst a)  (substType subst t)
substType subst (TyBang a t)     = TyBang (substAtom subst a)  (substType subst t)

-- Collect all &^γ lifetime atoms that appear directly as reference heads in a type
-- Used to verify the lifetime ordering constraint in stmt_borrow (Figure 16)
refLifetimes :: Type -> [LifetimeAtom]
refLifetimes TyBool           = []
refLifetimes TyQBit           = []
refLifetimes TyUnit           = []
refLifetimes (TyPair t1 t2)   = refLifetimes t1 ++ refLifetimes t2
refLifetimes (TyRef γ t)      = γ : refLifetimes t
refLifetimes (TyBang _ t)     = refLifetimes t