-- Compile an (already parse/check/uncomputed) qurts-core Program into a flat,
-- textual circuit IR that circuit/build_circuit.py turns into a Qiskit
-- QuantumCircuit. See circuit/README.md for the whole pipeline.
--
-- Handles [0]()/[1]() allocation, EU/EC gate applications on single qubits
-- or literal pairs, renames, &borrows, meas, pairs and their destructure,
-- the no-op statements (drop/as/newlft/endlft/noop), entry parameters, qif
-- (-> controlled gates), classical if on a statically-known condition
-- (-> static branch selection), and function call inlining. What's left
-- (classical if on a dynamic/measured condition, and anything the
-- uncomputation pass itself can't handle) is left to fail loudly (Left)
-- rather than silently miscompile -- a wrong circuit has no type checker to
-- catch it downstream, so every unhandled construct must announce itself.
-- See circuit/README.md's "Current coverage" for the exact boundary.
--
-- Locations. Following the paper's own model (Fig. 10), every variable maps
-- to a set of physical qubit *locations*, structured as a LocTree so a pair
-- keeps its shape (EPair builds a node, SLetPair destructures it) without
-- needing any separate type information. A single qubit is a leaf, a
-- reference or rename aliases the very same tree (no new qubits), a
-- dynamic classical bit (from meas) is an LBit, a statically-known bool
-- (a literal, or -- see allocForType -- a bool parameter's default input)
-- is an LBool, and unit carries no locations at all (LUnit).
module Circuit
  ( CInstr (..)
  , Circuit (..)
  , compileProgram
  , renderCircuit
  ) where

import Ast
import PrettyAst (flattenStmt)
import qualified Data.Map.Strict as Map
import Data.Text (Text, unpack, pack)
import Data.List (intercalate)

-- | Where a variable's qubits live, keeping pair structure intact.
data LocTree
  = LLeaf Int          -- one physical qubit, at this index
  | LNode LocTree LocTree
  | LBit Int           -- a measurement result: a *dynamic* classical bit,
                        -- known only once the circuit actually runs
  | LBool Bool         -- a bool known *statically*, at Haskell-compile
                        -- time (a literal, or -- see allocForType -- a
                        -- bool parameter's default input value): distinct
                        -- from LBit precisely so a classical `if` on one
                        -- can be resolved by picking a branch outright,
                        -- with no circuit-level control needed at all
  | LUnit              -- no qubits and no bit: unit ()
  deriving (Show)

-- | Qubit indices this tree occupies, left to right (a classical-bit or
-- statically-known-bool leaf contributes none -- neither is a qubit).
leaves :: LocTree -> [Int]
leaves (LLeaf i)   = [i]
leaves (LNode a b) = leaves a ++ leaves b
leaves (LBit _)    = []
leaves (LBool _)   = []
leaves LUnit       = []

-- | One flat circuit instruction. Controls (from enclosing qifs) ride on
-- each gate directly, as (qubit, polarity) pairs -- polarity True = the
-- ordinary positive control (|1>), False = negative control (|0>, the else
-- branch). Allocation and measurement are never controlled (an init inside
-- a qif is hoisted out; meas can't occur under qif at all, per the Purely
-- Quantum restriction), so they carry no control list.
data CInstr
  = IAlloc Int Bool                 -- qubit index, init to |1>?
  | IGate Text [Int] [(Int, Bool)]  -- gate name, target qubits, controls
  | IMeas Int Int                   -- qubit index, classical-bit index
  deriving (Show)

-- | A whole compiled circuit: how many qubits/cbits it needs, the
-- instruction stream, and which qubit locations hold the entry function's
-- returned value (measured by the Python side to read the result out).
data Circuit = Circuit
  { circQubits  :: Int
  , circCbits   :: Int
  , circInstrs  :: [CInstr]
  , circOutputs :: [Int]
  }
  deriving (Show)

-- | Mutable-ish compilation state, threaded explicitly through Either.
-- csFuncs is constant (every function in the program, for inlining calls);
-- the rest evolves as compilation proceeds.
data CState = CState
  { csFuncs  :: Map.Map FuncName Function
  , csNextQ  :: Int
  , csNextC  :: Int
  , csEnv    :: Map.Map Var LocTree
  , csInstrs :: [CInstr]   -- accumulated in reverse, flipped at the end
  }

initState :: Map.Map FuncName Function -> CState
initState funcs = CState funcs 0 0 Map.empty []

allocQubit :: Bool -> CState -> (Int, CState)
allocQubit isOne st =
  let q = csNextQ st
  in (q, st { csNextQ = q + 1, csInstrs = IAlloc q isOne : csInstrs st })

allocCbit :: CState -> (Int, CState)
allocCbit st =
  let c = csNextC st
  in (c, st { csNextC = c + 1 })

emit :: CInstr -> CState -> CState
emit i st = st { csInstrs = i : csInstrs st }

bind :: Var -> LocTree -> CState -> CState
bind v t st = st { csEnv = Map.insert v t (csEnv st) }

lookupTree :: CState -> Var -> Either String LocTree
lookupTree st v = case Map.lookup v (csEnv st) of
  Just t  -> Right t
  Nothing -> Left ("circuit: unbound variable " ++ show v)

-- | Resolve a variable to the qubit indices it currently occupies.
lookupLeaves :: CState -> Var -> Either String [Int]
lookupLeaves st v = leaves <$> lookupTree st v

-- | Compile a flat list of statements in order, threading state.
compileStmts :: [(Int, Bool)] -> CState -> [Stmt] -> Either String CState
compileStmts _     st []       = Right st
compileStmts ctrls st (s : ss) = compileStmt ctrls st s >>= \st' -> compileStmts ctrls st' ss

-- | Compile one statement under the given active controls (empty at top
-- level; the enclosing qif's controls once qif compilation exists).
compileStmt :: [(Int, Bool)] -> CState -> Stmt -> Either String CState
compileStmt ctrls st stmt = case stmt of
  SNoop        -> Right st
  SSeq s1 s2   -> compileStmt ctrls st s1 >>= \st' -> compileStmt ctrls st' s2
  SNewLft _    -> Right st
  SEndLft _    -> Right st
  SLeq _ _     -> Right st
  SAs _ _      -> Right st          -- coercion: no runtime effect
  SDrop _      -> Right st          -- see module note: reversed-to-|0> or classical, nothing to emit
  SLetRef y _ x -> do               -- reference aliases the same locations
    t <- lookupTree st x
    Right (bind y t st)
  SLetPair y0 y1 x -> do
    t <- lookupTree st x
    case t of
      LNode t0 t1 -> Right (bind y1 t1 (bind y0 t0 st))
      _ -> Left ("circuit: cannot destructure non-pair " ++ show x)
  SLetExpr y e -> compileExpr ctrls st y e

compileExpr :: [(Int, Bool)] -> CState -> Var -> Expr -> Either String CState
compileExpr ctrls st y e = case e of
  EInit0 -> let (q, st') = allocQubit False st in Right (bind y (LLeaf q) st')
  EInit1 -> let (q, st') = allocQubit True  st in Right (bind y (LLeaf q) st')
  ETrue  -> Right (bind y (LBool True) st)
  EFalse -> Right (bind y (LBool False) st)
  EUnit  -> Right (bind y LUnit st)
  ECopy x -> do                    -- copy of a reference: same locations; of a bool: none
    t <- lookupTree st x
    Right (bind y t st)
  EMeas x -> do
    qs <- lookupLeaves st x
    case qs of
      [q] -> let (c, st') = allocCbit st
             in Right (bind y (LBit c) (emit (IMeas q c) st'))
      _   -> Left ("circuit: meas expects a single qubit, got " ++ show (length qs))
  EVar x -> do                     -- rename: same tree, y takes over x's locations
    t <- lookupTree st x
    Right (bind y t st)
  EU (Unitary name) x -> do
    qs <- lookupLeaves st x
    case qs of
      [q] -> Right (bind y (LLeaf q) (emit (IGate name [q] ctrls) st))
      _   -> Left ("circuit: unitary " ++ unpack name ++ " expects a single qubit")
  EC (Classical name) x -> do      -- lifted injection: 1- or 2-qubit, on the arg's leaves
    t  <- lookupTree st x
    let qs = leaves t
    Right (bind y t (emit (IGate name qs ctrls) st))
  EPair a b -> do
    ta <- lookupTree st a
    tb <- lookupTree st b
    Right (bind y (LNode ta tb) st)
  EQIf ctrl bt bf -> compileQif ctrls st y ctrl bt bf
  EIf x bt bf -> do
    t <- lookupTree st x
    case t of
      LBool True  -> compileIfBranch ctrls st y bt
      LBool False -> compileIfBranch ctrls st y bf
      LBit _      -> Left "circuit: classical if on a dynamic (measured) condition not handled yet"
      _           -> Left ("circuit: classical if expects a bool, got " ++ show t)
  ECall fname _ args -> compileCall ctrls st y fname args

-- | Classical `if`: unlike `qif`, only one branch ever actually happens, so
-- (once the condition is a statically-known LBool -- see above) there is no
-- controlled gate to emit and no shared-result-location unification needed:
-- just compile the chosen branch's statements in place and bind `y` to
-- whatever location its own return variable ends up at.
compileIfBranch :: [(Int, Bool)] -> CState -> Var -> Block -> Either String CState
compileIfBranch ctrls st y (Block stmt ret) = do
  st' <- compileStmts ctrls st (flattenStmt stmt)
  t   <- lookupTree st' ret
  Right (bind y t st')

-- | Inline a function call. The callee's body is compiled straight into
-- the same circuit (same qubit/cbit counters, same instruction stream),
-- with its parameters bound to the *caller's* argument locations -- so a
-- reference argument shares the very qubit it points at, exactly as the
-- semantics require. The callee sees only its own parameters (no closures),
-- so its environment is its params alone; afterwards the caller's
-- environment is restored, with `y` bound to the callee's returned
-- locations. `ctrls` flows in unchanged, so a call made under a qif's
-- control has its callee's gates controlled too. Recursion terminates
-- because the call graph is a DAG (a function may only call ones defined
-- before it -- see TypeChecker.hs's checkProgram).
compileCall :: [(Int, Bool)] -> CState -> Var -> FuncName -> [Var]
            -> Either String CState
compileCall ctrls st y fname args =
  case Map.lookup fname (csFuncs st) of
    Nothing -> Left ("circuit: call to unknown function " ++ show fname)
    Just fn -> do
      argTrees <- mapM (lookupTree st) args
      let params    = map fst (sigParams (funSig fn))
          callerEnv = csEnv st
          calleeSt  = st { csEnv = Map.fromList (zip params argTrees) }
          body      = funBody fn
      stBody  <- compileStmts ctrls calleeSt (flattenStmt (blockStmt body))
      retTree <- lookupTree stBody (blockRet body)
      Right (stBody { csEnv = Map.insert y retTree callerEnv })

-- | How a qif branch produces its (single-qubit) return value: either by
-- threading a pre-existing outer variable through in place (RInput,
-- possibly gated -- the my_cnot `[not](q)` / `noop; q` shape), or by
-- building a brand-new qubit (RFresh -- the `let z=[1](); z` shape). Both
-- branches of one qif must agree on which; a mismatch (or anything more
-- structured -- a nested qif, pair, call, or meas in the branch) is left
-- for a later increment and fails loudly.
data RKind = RFresh | RInput Var | ROther
  deriving (Eq, Show)

-- | Classify a branch by tracing its return variable back through the
-- branch's own statements. A name never bound in the branch is an outer
-- input (RInput); one bound by [0]/[1] is fresh; one bound by a gate/rename
-- inherits its source's kind (a gate is in-place, so it keeps the
-- location); one bound by a nested qif recursively unifies that qif's two
-- branches (a nested qif building fresh qubits is itself fresh -- this is
-- how a Toffoli-shaped `qif x { qif y {...} } else {...}` classifies);
-- anything else is ROther.
classifyReturn :: Block -> RKind
classifyReturn (Block stmt ret) =
  let m = foldl step Map.empty (flattenStmt stmt)
  in Map.findWithDefault (RInput ret) ret m
  where
    kindOf m w = Map.findWithDefault (RInput w) w m
    step m s = case s of
      SLetExpr v EInit0        -> Map.insert v RFresh m
      SLetExpr v EInit1        -> Map.insert v RFresh m
      SLetExpr v (EU _ w)      -> Map.insert v (kindOf m w) m
      SLetExpr v (EC _ w)      -> Map.insert v (kindOf m w) m
      SLetExpr v (EVar w)      -> Map.insert v (kindOf m w) m
      SLetExpr v (ECopy w)     -> Map.insert v (kindOf m w) m
      SLetExpr v (EQIf _ b1 b2) -> Map.insert v (unifyKind (classifyReturn b1)
                                                           (classifyReturn b2)) m
      SLetExpr v _             -> Map.insert v ROther m
      SLetRef  v _ w           -> Map.insert v (kindOf m w) m
      SLetPair v0 v1 _         -> Map.insert v0 ROther (Map.insert v1 ROther m)
      _                        -> m

-- | Combine the two branch kinds of a nested qif into the kind of its own
-- result: both-fresh is fresh, both-threading-the-same-input is that input,
-- anything else is unhandled.
unifyKind :: RKind -> RKind -> RKind
unifyKind RFresh RFresh = RFresh
unifyKind (RInput a) (RInput b)
  | a == b    = RInput a
unifyKind _ _ = ROther

-- | Compile `let y = qif ctrl { Bt } else { Bf }`. Both branches are
-- unified onto a single result location R -- the shared input's location
-- when both thread the same one (in-place, e.g. controlled-NOT), or one
-- fresh |0> qubit when both build fresh (controlled-init). Every gate a
-- branch emits carries the qif's control appended to the enclosing
-- controls: positive polarity (|1>) for the then-branch, negative (|0>)
-- for the else-branch -- so a nested qif would naturally accumulate
-- multiple controls (nested qif in a branch is not compiled yet, though;
-- see compileBranchStmt). The two branches are compiled from the *same*
-- pre-qif environment (neither sees the other's local bindings), and only
-- `y` is added to the environment afterward.
compileQif :: [(Int, Bool)] -> CState -> Var -> Var -> Block -> Block
           -> Either String CState
compileQif ctrls st y ctrl bt bf = do
  (st', rTree) <- compileQifCore ctrls Nothing st ctrl bt bf
  Right (bind y rTree st')

-- | The shared core: compile a qif, producing its result on a target
-- location. When `mTarget` is Nothing (an ordinary top-level qif) the
-- target is chosen by classifying the branches -- the shared input's
-- location if both thread the same one, else one fresh |0> qubit. When
-- Just t (a qif nested as the return of an enclosing branch -- see
-- compileBranchStmt) the enclosing result location t is threaded straight
-- in, so the inner qif builds onto the very same qubit rather than
-- allocating its own. Either way both branches are compiled onto that
-- location under the qif's control appended to the enclosing controls; the
-- final environment is restored to the pre-qif one (only the caller adds a
-- binding for the qif's own result).
compileQifCore :: [(Int, Bool)] -> Maybe LocTree -> CState -> Var -> Block -> Block
               -> Either String (CState, LocTree)
compileQifCore ctrls mTarget st ctrl bt bf = do
  ctrlLoc <- singleLeaf st ctrl
  let env0 = csEnv st
  (rTree, st1) <- case mTarget of
    Just t  -> Right (t, st)
    Nothing -> case (classifyReturn bt, classifyReturn bf) of
      (RInput a, RInput b) -> do
        la <- singleLeaf st a
        lb <- singleLeaf st b
        if la == lb
          then Right (LLeaf la, st)
          else Left "circuit: qif branches thread different locations, not handled yet"
      (RFresh, RFresh) ->
        let (q, st') = allocQubit False st in Right (LLeaf q, st')
      (kt, kf) -> Left ("circuit: qif branches with return kinds "
                         ++ show kt ++ "/" ++ show kf ++ " not handled yet")
  st2 <- compileBranchOnto (ctrls ++ [(ctrlLoc, True)])  rTree st1 bt
  let st2' = st2 { csEnv = env0 }
  st3 <- compileBranchOnto (ctrls ++ [(ctrlLoc, False)]) rTree st2' bf
  Right (st3 { csEnv = env0 }, rTree)

singleLeaf :: CState -> Var -> Either String Int
singleLeaf st v = do
  t <- lookupTree st v
  case leaves t of
    [q] -> Right q
    _   -> Left ("circuit: expected a single qubit for " ++ show v)

-- | Compile a branch's statements so its return lands on the shared result
-- location rTree, emitting every gate under `ctrls`. A fresh-init return is
-- redirected onto rTree (which is pre-allocated |0>, so [0] is a no-op and
-- [1] is a controlled X); an in-place gate applies to its argument's
-- existing location. Fails loudly on anything not in the small shape this
-- first version handles.
compileBranchOnto :: [(Int, Bool)] -> LocTree -> CState -> Block
                  -> Either String CState
compileBranchOnto ctrls rTree st (Block stmt ret) = do
  st' <- go st (flattenStmt stmt)
  tret <- lookupTree st' ret
  if leaves tret == leaves rTree
    then Right st'
    else Left "circuit: qif branch return did not land on the shared result location"
  where
    go s []       = Right s
    go s (x : xs) = compileBranchStmt ctrls rTree s x >>= \s' -> go s' xs

compileBranchStmt :: [(Int, Bool)] -> LocTree -> CState -> Stmt
                  -> Either String CState
compileBranchStmt ctrls rTree st stmt = case stmt of
  SNoop        -> Right st
  SSeq s1 s2   -> compileBranchStmt ctrls rTree st s1
                    >>= \st' -> compileBranchStmt ctrls rTree st' s2
  SNewLft _    -> Right st
  SEndLft _    -> Right st
  SLeq _ _     -> Right st
  SAs _ _      -> Right st
  SDrop _      -> Right st
  SLetRef y _ x -> do t <- lookupTree st x; Right (bind y t st)
  SLetExpr y EInit0 -> Right (bind y rTree st)               -- redirect fresh init to shared |0>
  SLetExpr y EInit1 ->                                        -- ... and a [1] is a controlled X onto it
    Right (bind y rTree (emit (IGate (packX) (leaves rTree) ctrls) st))
  SLetExpr y (EU (Unitary name) x) -> do
    q <- singleLeaf st x
    Right (bind y (LLeaf q) (emit (IGate name [q] ctrls) st))
  SLetExpr y (EC (Classical name) x) -> do
    t <- lookupTree st x
    Right (bind y t (emit (IGate name (leaves t) ctrls) st))
  SLetExpr y (EVar x)  -> do t <- lookupTree st x; Right (bind y t st)
  SLetExpr y (ECopy x) -> do t <- lookupTree st x; Right (bind y t st)
  -- A nested qif whose result is this branch's own contribution: build it
  -- onto the same shared result (rTree), threading the accumulated controls
  -- down so its gates end up multiply-controlled (the Toffoli shape -- see
  -- example_and). The nested qif's control adds to `ctrls` inside
  -- compileQifCore, so `qif x { qif y { [1] } .. } ..` emits X on rTree
  -- under both x and y.
  SLetExpr y (EQIf ctrl bt bf) -> do
    (st', rt) <- compileQifCore ctrls (Just rTree) st ctrl bt bf
    Right (bind y rt st')
  _ -> Left "circuit: unsupported statement inside a qif branch (pair/call/meas not compiled yet)"

-- | The X gate name, for turning a fresh [1]() inside a qif branch into a
-- controlled bit-flip on the shared result location.
packX :: Text
packX = pack "X"

-- | Allocate fresh qubits for a type, mirroring its structure into a
-- LocTree: a qubit is one leaf, a pair is a node, ownership (#a) and
-- reference (&a) wrappers pass straight through to the type they wrap (a
-- reference param, for a standalone entry circuit, just points at a real
-- underlying qubit we allocate here), and bool/unit carry no qubits. All
-- allocated qubits start at |0> -- the standard "run the circuit on the
-- all-zero input" convention, since a standalone circuit has no caller to
-- supply input states.
allocForType :: Type -> CState -> (LocTree, CState)
allocForType TyQBit        st = let (q, st') = allocQubit False st in (LLeaf q, st')
allocForType (TyBang _ t)  st = allocForType t st
allocForType (TyRef _ t)   st = allocForType t st
allocForType (TyPair a b)  st = let (ta, st1) = allocForType a st
                                    (tb, st2) = allocForType b st1
                                in (LNode ta tb, st2)
allocForType TyBool        st = (LBool False, st)  -- entry runs on the default input: same convention as TyQBit's |0>, so an unconditional-true bool param would need a literal ETrue in the body, not a param default
allocForType TyUnit        st = (LUnit, st)

-- | Compile a whole program to a circuit, using its LAST function as the
-- entry point (grover, example_ec_reversal, ... are all written last in
-- their files). Each of the entry's parameters gets fresh |0> qubits
-- matching its type (see allocForType). The entry's returned qubits are
-- measured into fresh classical bits so the Python side can read the
-- result.
compileProgram :: Program -> Either String Circuit
compileProgram (Program []) = Left "circuit: empty program"
compileProgram (Program fs) = do
  let entry  = last fs
      funcs  = Map.fromList [ (funName f, f) | f <- fs ]
      params = sigParams (funSig entry)
      st0    = foldl bindParam (initState funcs) params
      bindParam st (v, ty) = let (t, st') = allocForType ty st in bind v t st'
      body   = funBody entry
  st <- compileStmts [] st0 (flattenStmt (blockStmt body))
  retTree <- lookupTree st (blockRet body)
  let (st', cs) = collectOutputs retTree st
  Right (Circuit
    { circQubits  = csNextQ st'
    , circCbits   = csNextC st'
    , circInstrs  = reverse (csInstrs st')
    , circOutputs = cs
    })

-- | Classical bits that carry the entry function's return value: an
-- already-measured bool contributes its bit directly, a returned qubit is
-- measured into a fresh one, and a returned pair contributes both halves in
-- order. (true/false/unit contribute nothing -- a compile-time-known
-- classical value the simulator has no bit to read.)
collectOutputs :: LocTree -> CState -> (CState, [Int])
collectOutputs (LBit c)   st = (st, [c])
collectOutputs (LBool _)  st = (st, [])  -- compile-time-known constant: nothing for the simulator to read
collectOutputs LUnit      st = (st, [])
collectOutputs (LLeaf q)  st =
  let (c, st1) = allocCbit st in (emit (IMeas q c) st1, [c])
collectOutputs (LNode a b) st =
  let (st1, ca) = collectOutputs a st
      (st2, cb) = collectOutputs b st1
  in (st2, ca ++ cb)

-- | Render a Circuit as the line-based text IR build_circuit.py reads.
renderCircuit :: Circuit -> String
renderCircuit c = unlines $
  [ "qubits " ++ show (circQubits c)
  , "cbits "  ++ show (circCbits c)
  ] ++ map renderInstr (circInstrs c)
    ++ [ "output " ++ commaInts (circOutputs c) ]

renderInstr :: CInstr -> String
renderInstr (IAlloc q isOne) = "alloc " ++ show q ++ " " ++ (if isOne then "1" else "0")
renderInstr (IGate name ts ctrls) =
  "gate " ++ unpack name ++ " " ++ commaInts ts ++ " " ++ renderCtrls ctrls
renderInstr (IMeas q c) = "meas " ++ show q ++ " " ++ show c

renderCtrls :: [(Int, Bool)] -> String
renderCtrls [] = "-"
renderCtrls cs = intercalate "," [ show q ++ "=" ++ (if p then "1" else "0") | (q, p) <- cs ]

commaInts :: [Int] -> String
commaInts [] = "-"
commaInts xs = intercalate "," (map show xs)
