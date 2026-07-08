module TypeChecker where

import Ast
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
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
data TCState = TCState
  { tcCtx     :: Context
  , tcLfts    :: LifetimePreorder
  , tcFuncs   :: Map.Map FuncName Signature
  , tcFunc    :: FuncName
  , tcPQFuncs :: Set.Set FuncName    -- functions verified to be purely quantum
  }
  deriving (Eq, Show)

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

-- Insert a new active variable into Γ
insertVar :: Var -> Type -> TC ()
insertVar x ty = modifyCtx (\(Context m) ->
  Context (Map.insert x (Binding Active ty) m))

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
isActive :: LifetimeAtom -> TC Bool
isActive LBottom    = return False   -- ⊥ is never in A as a variable
isActive LTop       = return True    -- ⊤ is always available
isActive (LVar α)   = do
  lp <- getLfts
  return (Set.member α (ltVars lp))

requireActive :: LifetimeAtom -> TC ()
requireActive lft = do
  ok <- isActive lft
  unless ok $ case lft of
    LVar α -> throwError (LifetimeNotActive α)
    _      -> throwError (OtherError "Invalid lifetime atom")

-- Check α ≤ β in A  (paper: α ≤ β ∈ A)
leq :: LifetimeAtom -> LifetimeAtom -> TC Bool
leq a b
  | a == b         = return True
  | a == LBottom   = return True    -- ⊥ ≤ everything
  | b == LTop      = return True    -- everything ≤ ⊤
  | otherwise      = do
      lp <- getLfts
      return (Set.member (a, b) (ltRel lp))

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

-- Check α is minimal in A − {⊥}
-- i.e. no β ∈ A such that β < α (β ≤ α but not α ≤ β)
isMinimal :: Lifetime -> TC Bool
isMinimal α = do
  lp <- getLfts
  let others = Set.delete α (ltVars lp)
  let smallerExists = any (\β ->
        Set.member (LVar β, LVar α) (ltRel lp) &&
        not (Set.member (LVar α, LVar β) (ltRel lp))
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

    initState env pqEnv f = TCState
      { tcCtx     = buildInitialContext (funSig f)
      , tcLfts    = buildInitialPreorder (funSig f)
      , tcFuncs   = env
      , tcFunc    = funName f
      , tcPQFuncs = pqEnv
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
checkFunction :: Function -> TC ()
checkFunction (Function _name sig body) = do
  ty <- checkBlock body
  unless (ty == sigReturn sig) $
    throwError (ReturnTypeMismatch (sigReturn sig) ty)

-- typing_block: run statement, exactly one variable left, return its type
-- { S ; x } : T  when S : (Γ,A) → (x:T, A)
-- Droppable active variables (references, booleans) are implicitly dropped at end of scope.
-- Non-droppable active variables (e.g. #⊥ qbit) remaining after the block are a linearity error.
checkBlock :: Block -> TC Type
checkBlock (Block stmt retVar) = do
  lftsBefore <- getLfts
  checkStmt stmt
  lftsAfter <- getLfts
  -- typing_block: A must not gain new lifetime variables across the block.
  -- Lifetimes introduced by newlft inside the block must all be ended by endlft.
  -- (Pre-existing lifetimes ended by endlft are allowed — no internal/external distinction.)
  let leaked = Set.difference (ltVars lftsAfter) (ltVars lftsBefore)
  unless (Set.null leaked) $
    throwError (OtherError ("Lifetime introduced in block was not ended: "
      ++ show (Set.toList leaked)))
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
    lp <- getLfts
    let externalLfts = Set.delete α (ltVars lp)
    addLifetime α
    forM_ (Set.toList externalLfts) $ \γ ->
      addConstraint (LVar α) (LVar γ)

  -- stmt_end_lifetime: α minimal in A−{⊥}, &α not in Γ, defrost
  -- endlft α : (Γ, A) → (defrost_α(Γ), A − α)
  SEndLft α -> do
    ok <- isMinimal α
    unless ok $ throwError (LifetimeNotMinimal α)
    noRef <- noRefInCtx α
    unless noRef $ throwError (ReferenceStillInContext α)
    defrostLifetime α
    removeLifetime α

  -- stmt_lft_ineq: add α ≤ β to A
  -- α ≤ β : (Γ, A) → (Γ, A')
  SLeq α β -> addConstraint (LVar α) (LVar β)

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
  SLetRef y α x -> do
    ty <- lookupActiveVar x
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
checkExpr (EPair x0 x1) = do
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
-- consumes x : #⊥ qbit
checkExpr (EMeas x) = do
  ty <- lookupActiveVar x
  case ty of
    TyBang LBottom TyQBit -> do
      removeVar x
      return (TyBang LTop TyBool)
    _ -> throwError (TypeMismatch (TyBang LBottom TyQBit) ty)

-- expr_unitary: U(x) : #⊥ qbit  (Figure 15, expr_unitary)
-- consumes x : #⊥ qbit, returns #⊥ qbit
-- Input must already be committed to linear use (#⊥); result is not uncomputable.
-- Use `x as #⊥ qbit` before calling if x has an affine lifetime.
-- (Unlike [c], a general unitary is not a classical injection, so it cannot be inverted.)
checkExpr (EU _u x) = do
  ty <- lookupActiveVar x
  case ty of
    TyBang LBottom TyQBit -> do
      removeVar x
      return (TyBang LBottom TyQBit)
    _ -> throwError (TypeMismatch (TyBang LBottom TyQBit) ty)

-- expr_lifted: [c](x) : #𝔞 qbit^n  (Figure 15, expr_lifted)
-- single qubit: consumes x : #𝔞 qbit, returns #𝔞 qbit
-- pair of qubits: consumes x : (#𝔞 qbit × #𝔞 qbit), returns (#𝔞 qbit × #𝔞 qbit)
--   (both qubits must share the same lifetime 𝔞, matching the paper's #𝔞 qbit²)
checkExpr (EC _c x) = do
  ty <- lookupActiveVar x
  case ty of
    TyBang a TyQBit -> do
      removeVar x
      return (TyBang a TyQBit)
    TyPair (TyBang a TyQBit) (TyBang b TyQBit) | a == b -> do
      removeVar x
      return (TyPair (TyBang a TyQBit) (TyBang b TyQBit))
    _ -> throwError (TypeMismatch (TyBang LBottom TyQBit) ty)

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
checkExpr (EIf x bt bf) = do
  ty <- lookupActiveVar x
  case ty of
    TyBool -> do
      removeVar x
      ctxBefore  <- getCtx
      lftsBefore <- getLfts
      t1 <- checkBlock bt
      putCtx  ctxBefore
      putLfts lftsBefore
      t2 <- checkBlock bf
      unless (t1 == t2) $ throwError (TypeMismatch t1 t2)
      return t1
    _ -> throwError (TypeMismatch TyBool ty)



-- expr_quantum_if: qif x B|0⟩ B|1⟩
-- x : &^α qbit stays in Δ (not consumed); branches typed under Γ (without x)
-- Both branches must be PQ and return a PQ type T; result type is #^α T
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
          t1 <- checkBlock bt
          putCtx  ctxBefore
          putLfts lftsBefore
          t2 <- checkBlock bf
          -- restore x: &^α qbit back into context (stays in Δ after expression)
          insertVar x ty
          compatible <- isSubtype t1 t2 `orM` isSubtype t2 t1
          unless compatible $ throwError (TypeMismatch t1 t2)
          unless (isPurelyQuantumType t1) $
            throwError (NotPurelyQuantum ("qif then-branch return type is not PQ: " ++ show t1))
          unless (isPurelyQuantumType t2) $
            throwError (NotPurelyQuantum ("qif else-branch return type is not PQ: " ++ show t2))
          isT1Sub <- isSubtype t1 t2
          let t = if isT1Sub then t2 else t1
          return (TyBang α (stripBang t))
        _ -> throwError (NotAReference ty)
    _ -> throwError (NotAReference ty)


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
-- subty_borrow_affine: &𝔠 #𝔞 T ≤ &𝔟 T  when 𝔟 ≤ 𝔠 and 𝔟 ≤ 𝔞
isSubtype (TyRef c t1) (TyRef b t2) = tryShorten `orM` tryCollapse
  where
    tryShorten  = do ok1 <- leq b c; ok2 <- isSubtype t1 t2; return (ok1 && ok2)
    tryCollapse = case t1 of
      TyRef  a inner -> do ok1 <- leq b c; ok2 <- leq b a; ok3 <- isSubtype inner t2; return (ok1 && ok2 && ok3)
      TyBang a inner -> do ok1 <- leq b c; ok2 <- leq b a; ok3 <- isSubtype inner t2; return (ok1 && ok2 && ok3)
      _              -> return False
-- subty_shorten: #𝔞 T ≤ #𝔟 T  when 𝔟 ≤ 𝔞
-- subty_double_affine: #𝔠 #𝔞 T ≤ #𝔟 T  when 𝔟 ≤ 𝔠 and 𝔟 ≤ 𝔞
isSubtype (TyBang c t1) (TyBang b t2) = tryShorten `orM` tryCollapse
  where
    tryShorten  = do ok1 <- leq b c; ok2 <- isSubtype t1 t2; return (ok1 && ok2)
    tryCollapse = case t1 of
      TyBang a inner -> do ok1 <- leq b c; ok2 <- leq b a; ok3 <- isSubtype inner t2; return (ok1 && ok2 && ok3)
      _              -> return False
-- subty_affine_borrow: #𝔠 &𝔞 T ≤ &𝔟 T  when 𝔟 ≤ 𝔠 and 𝔟 ≤ 𝔞
isSubtype (TyBang c (TyRef a t1)) (TyRef b t2) = do
  ok1 <- leq b c; ok2 <- leq b a; ok3 <- isSubtype t1 t2
  return (ok1 && ok2 && ok3)
-- subty_unit: P𝔞() ≤ ()
isSubtype (TyRef _ TyUnit) TyUnit  = return True
isSubtype (TyBang _ TyUnit) TyUnit = return True
-- subty_ptr_tuple: P𝔞(T₀×T₁) ≤ (P𝔞 T₀ × P𝔞 T₁)
isSubtype (TyRef  a (TyPair t1 t2)) (TyPair (TyRef  b t1') (TyRef  c t2')) = do
  ok1 <- isSubtype (TyRef  a t1) (TyRef  b t1')
  ok2 <- isSubtype (TyRef  a t2) (TyRef  c t2')
  return (ok1 && ok2)
isSubtype (TyBang a (TyPair t1 t2)) (TyPair (TyBang b t1') (TyBang c t2')) = do
  ok1 <- isSubtype (TyBang a t1) (TyBang b t1')
  ok2 <- isSubtype (TyBang a t2) (TyBang c t2')
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