-- Constructs the paper's Definition 5.1 circuit graph (V = V_init ⊔ V_gate ⊔
-- V_merge ⊔ V_linear, plus loc: V -> Loc_q) for an already type-checked
-- qurts-core program. This is deliberately *only* the graph -- Section 5.1's
-- actual pebble game (deciding which vertex can share a physical qubit with
-- which other, i.e. an uncomputation/scheduling strategy) is not built here;
-- see pebbling/README.md for the full scope note and what this is (and is
-- not) a foundation for.
--
-- Construction mirrors Unqomp's own circuit-graph builder (Paradis et al.
-- 2021, PLDI, Section 5.2: one node per gate, wired to each operand's
-- *latest* node) extended with Qurts's own two additions: V_merge (for a
-- qif's two branches converging back into one value) and V_linear (for an
-- EU application, which the type system pins to #bot -- Definition 5.1's
-- "locations becoming linear when pebbled instead of affine"). The
-- traversal itself is structured exactly like Uncompute.hs's own
-- DefMap/recordBinding/resolveExpr fold (LocMap here plays DefMap's role) --
-- deliberately, so the two passes stay easy to compare -- but is simpler in
-- one respect: this module only needs vertex *identity*, never to
-- reconstruct valid surface syntax, so it carries none of Uncompute.hs's
-- rename/copy-planning machinery.
--
-- A `drop` has NO effect on this graph at all -- every [0]()/[1]() call
-- mints its own fresh V_init, unconditionally, with no reuse. The paper's
-- own Appendix D.1 worked example (a qif branch doing `drop y; let y =
-- |0>; y`) shows that branch's fresh |0> landing back on the *original*
-- init vertex in the final diagram -- but that reuse is a qubit-allocation
-- decision (which vertices end up sharing one physical qubit), i.e. exactly
-- what the pebble game itself decides; it is not a consequence of Definition
-- 5.1 alone. Building the *unreduced* graph here (strictly more vertices
-- than a final physical circuit might need) is the same choice Unqomp's own
-- construction makes -- reuse is a separate, later optimization over the
-- graph, not part of building it.
module CircuitGraph
  ( VertexId (..)
  , Location (..)
  , GateOp (..)
  , VertexKind (..)
  , Vertex (..)
  , VTree (..)
  , CircuitGraph (..)
  , FuncEnv
  , emptyGraph
  , vertexLoc
  , buildFunctionGraph
  , buildProgramGraph
  ) where

import Ast
import PrettyAst (flattenStmt)
import GateInverse (isTwoQubitClassical)
import qualified Data.Map.Strict as Map
import Data.Text (pack)

-- | A vertex's identity -- also doubles as its own Location when it starts
-- one (see 'Location').
newtype VertexId = VertexId Int
  deriving (Eq, Ord, Show)

-- | Loc_q, Definition 5.1's physical-qubit-slot function's codomain.
-- Identified by the vertex that *starts* this location's chain -- a V_init
-- vertex starts its own (Location = its own id), and so, in this
-- unreduced/un-optimized construction, does a V_merge (its two incoming
-- edges may come from two genuinely different prior locations; the merge
-- vertex itself is where those histories become one going forward -- see
-- the module note on why this graph doesn't try to decide qubit reuse). A
-- V_gate/V_linear vertex simply continues its target predecessor's own
-- Location unchanged.
newtype Location = Location VertexId
  deriving (Eq, Ord, Show)

-- | One gate application: the same-location predecessor it's applied to
-- (Definition 5.1's required unique same-location incoming edge) plus any
-- other-location predecessors (controls). `gateLabel` keeps which concrete
-- gate this was for rendering/inspection -- nothing here re-derives an
-- inverse or otherwise interprets it.
data GateOp = GateOp
  { gateTarget   :: VertexId
  , gateControls :: [VertexId]
  , gateLabel    :: Either Unitary Classical
  } deriving (Eq, Show)

-- | The four vertex kinds partitioning V (Definition 5.1). VMerge's three
-- fields are, in order: the qif's own control (the vertex the control
-- reference currently aliases), the then-branch's incoming edge, the
-- else-branch's incoming edge -- "two ordered incoming edges" from the
-- definition, order encoded positionally rather than via a separate
-- true/false tag. (Definition 5.2's fuller guard/pebble apparatus -- which
-- lifetime a guard needs to stay active, fragment labels, and so on -- is
-- solver-only machinery, deliberately not modelled here; see the module
-- note.)
data VertexKind
  = VInit
  | VGate   GateOp
  | VLinear GateOp
  | VMerge  { mergeCtrl :: VertexId, mergeTrue :: VertexId, mergeFalse :: VertexId }
  deriving (Eq, Show)

data Vertex = Vertex
  { vKind :: VertexKind
  , vLoc  :: Location
  } deriving (Eq, Show)

data CircuitGraph = CircuitGraph
  { cgVertices :: Map.Map VertexId Vertex
  , cgNext     :: Int
  } deriving Show

emptyGraph :: CircuitGraph
emptyGraph = CircuitGraph Map.empty 0

vertexLoc :: CircuitGraph -> VertexId -> Location
vertexLoc g vid = case Map.lookup vid (cgVertices g) of
  Just v  -> vLoc v
  Nothing -> error ("CircuitGraph: internal invariant broken -- unknown vertex " ++ show vid)

-- | Insert a fresh V_init vertex, starting a brand-new Location at itself.
freshInit :: CircuitGraph -> (VertexId, CircuitGraph)
freshInit g =
  let vid = VertexId (cgNext g)
      v   = Vertex VInit (Location vid)
  in (vid, g { cgVertices = Map.insert vid v (cgVertices g), cgNext = cgNext g + 1 })

-- | Insert a fresh V_gate/V_linear vertex, continuing an existing Location.
freshGated :: VertexKind -> Location -> CircuitGraph -> (VertexId, CircuitGraph)
freshGated kind loc g =
  let vid = VertexId (cgNext g)
      v   = Vertex kind loc
  in (vid, g { cgVertices = Map.insert vid v (cgVertices g), cgNext = cgNext g + 1 })

-- | Insert a fresh V_merge vertex, starting a brand-new Location at itself
-- (see 'Location' on why a merge is treated the same way a V_init is here).
freshMerge :: VertexId -> VertexId -> VertexId -> CircuitGraph -> (VertexId, CircuitGraph)
freshMerge ctrl t f g =
  let vid = VertexId (cgNext g)
      v   = Vertex (VMerge ctrl t f) (Location vid)
  in (vid, g { cgVertices = Map.insert vid v (cgVertices g), cgNext = cgNext g + 1 })

-- | Where a variable's qubit(s) currently sit in the graph, keeping pair
-- structure intact -- the graph-construction analogue of Circuit.hs's own
-- LocTree, and of Uncompute.hs's Origin, playing the same "what is this
-- name bound to, right now" role as both. VNone is for anything that isn't
-- part of the qubit graph at all (bool/unit/a measured bit).
data VTree
  = VLeaf VertexId
  | VNode VTree VTree
  | VNone
  deriving (Eq, Show)

type LocMap = Map.Map Var VTree
type FuncEnv = Map.Map FuncName Function

newtype BuildCtx = BuildCtx { bcFuncs :: FuncEnv }

lookupLoc :: LocMap -> Var -> Either String VTree
lookupLoc lm x = case Map.lookup x lm of
  Just t  -> Right t
  Nothing -> Left ("circuit graph: unbound variable " ++ show x)

-- | `lookupLoc`, further requiring the result to be a single qubit (used
-- for EU's argument, a 1-qubit EC's argument, and a qif's own control).
singleVertex :: LocMap -> Var -> Either String VertexId
singleVertex lm x = lookupLoc lm x >>= \t -> case t of
  VLeaf v -> Right v
  _       -> Left ("circuit graph: expected a single qubit for " ++ show x ++ ", got " ++ show t)

-- | Allocate fresh V_init vertices matching a type's shape -- mirrors
-- Circuit.hs's own allocForType exactly (a qubit is one leaf, ownership/
-- reference wrappers pass through untouched, a pair is a node, bool/unit
-- carry no qubits at all).
allocForType :: Type -> CircuitGraph -> (VTree, CircuitGraph)
allocForType TyQBit       g = let (vid, g') = freshInit g in (VLeaf vid, g')
allocForType (TyBang _ t) g = allocForType t g
allocForType (TyRef  _ t) g = allocForType t g
allocForType (TyPair a b) g =
  let (ta, g1) = allocForType a g
      (tb, g2) = allocForType b g1
  in (VNode ta tb, g2)
allocForType TyBool       g = (VNone, g)
allocForType TyUnit       g = (VNone, g)

-- | Structurally pair up two qif branches' return VTrees, creating a
-- V_merge wherever they disagree and reusing the shared vertex untouched
-- wherever they don't (the common case: a sibling location neither branch's
-- own statements touched at all). Both sides are guaranteed the same shape
-- by the type checker's own EQIf rule (Fig. 15's premise that both branches
-- produce the identical type, up to the outermost lifetime tag which never
-- affects this module) -- the mismatched-shape case below is therefore
-- unreachable for any program that already passed checkProgram.
mergeTrees :: VertexId -> CircuitGraph -> VTree -> VTree -> Either String (VTree, CircuitGraph)
mergeTrees _ g (VLeaf t) (VLeaf f)
  | t == f    = Right (VLeaf t, g)
mergeTrees ctrl g (VLeaf t) (VLeaf f) =
  let (vid, g') = freshMerge ctrl t f g in Right (VLeaf vid, g')
mergeTrees ctrl g (VNode t1 t2) (VNode f1 f2) = do
  (m1, g1) <- mergeTrees ctrl g  t1 f1
  (m2, g2) <- mergeTrees ctrl g1 t2 f2
  Right (VNode m1 m2, g2)
mergeTrees _ g VNone VNone = Right (VNone, g)
mergeTrees _ _ t f = Left ("circuit graph: qif branches returned mismatched shapes ("
                            ++ show t ++ " vs " ++ show f ++ ") -- shouldn't happen for a type-checked program")

-- | Build one expression, given the LocMap in effect right before it --
-- exactly resolveExpr's role in Uncompute.hs, returning the VTree the
-- expression's result occupies plus the (possibly-extended) graph.
buildExpr :: BuildCtx -> LocMap -> CircuitGraph -> Expr -> Either String (VTree, CircuitGraph)
buildExpr _   _  g EInit0 = let (vid, g') = freshInit g in Right (VLeaf vid, g')
buildExpr _   _  g EInit1 = let (vid, g') = freshInit g in Right (VLeaf vid, g')
buildExpr _   _  g ETrue  = Right (VNone, g)
buildExpr _   _  g EFalse = Right (VNone, g)
buildExpr _   _  g EUnit  = Right (VNone, g)
buildExpr _   lm g (ECopy x) = (\t -> (t, g)) <$> lookupLoc lm x
buildExpr _   _  g (EMeas _) = Right (VNone, g)   -- a measured bit is classical, not part of this graph at all
buildExpr _   lm g (EVar x)  = (\t -> (t, g)) <$> lookupLoc lm x
buildExpr _   lm g (EU u x)  = do
  prevVid <- singleVertex lm x
  let loc = vertexLoc g prevVid
      (vid, g') = freshGated (VLinear (GateOp prevVid [] (Left u))) loc g
  Right (VLeaf vid, g')
buildExpr _   lm g (EC c x)
  | isTwoQubitClassical c = do
      t <- lookupLoc lm x
      case t of
        VNode (VLeaf a) (VLeaf b) -> Right (buildTwoQubitEC c a b g)
        _ -> Left ("circuit graph: expected a same-location qubit pair for " ++ show x)
  | otherwise = do
      prevVid <- singleVertex lm x
      let loc = vertexLoc g prevVid
          (vid, g') = freshGated (VGate (GateOp prevVid [] (Right c))) loc g
      Right (VLeaf vid, g')
buildExpr _   lm g (EPair a b) = do
  ta <- lookupLoc lm a
  tb <- lookupLoc lm b
  Right (VNode ta tb, g)
buildExpr ctx lm g (EQIf ctrl bt bf) = do
  ctrlVid    <- singleVertex lm ctrl
  (lmT, gT)  <- buildBlockLocal ctx lm g  bt
  retT       <- lookupLoc lmT (blockRet bt)
  (lmF, gF)  <- buildBlockLocal ctx lm gT bf
  retF       <- lookupLoc lmF (blockRet bf)
  mergeTrees ctrlVid gF retT retF
buildExpr ctx lm g (ECall fname _lts args) = case Map.lookup fname (bcFuncs ctx) of
  Nothing -> Left ("circuit graph: call to unknown function " ++ show fname)
  Just fn -> do
    argTrees <- mapM (lookupLoc lm) args
    let paramNames = map fst (sigParams (funSig fn))
        calleeSeed = Map.fromList (zip paramNames argTrees)
    (lm', g') <- buildBlockLocal ctx calleeSeed g (funBody fn)
    ret       <- lookupLoc lm' (blockRet (funBody fn))
    Right (ret, g')
-- Classical `if` is never Purely Quantum (the type checker itself refuses
-- to nest one inside a qif branch), and Definition 5.1's graph -- like the
-- pebble game it feeds -- is only ever defined over Purely Quantum code.
-- Left deliberately unhandled here, same boundary Uncompute.hs already
-- draws for the identical construct.
buildExpr _   _  _ (EIf {}) =
  Left "circuit graph: a classical if expression is not Purely Quantum, not handled"

-- | Two-qubit EC applications (cnot, swap -- the closed 2-qubit registry;
-- see GateInverse.hs). `a` is the control-position component, `b` the
-- target-position one (matching build_circuit.py's own `qc.cx(a, b)`/
-- `qc.swap(a, b)` argument order for these same two names).
--
-- cnot: only the target's location actually changes -- the control
-- continues completely untouched, so only one new vertex is minted, with
-- the control's vertex riding along as its one other-location edge.
--
-- swap: *both* qubits' values exchange, so this mints two new vertices,
-- one per location, each one's own-location target edge being its own
-- prior vertex and its one other-location edge being the *other* qubit's
-- prior vertex -- both perfectly valid Definition 5.1 V_gate shapes (one
-- same-location edge, one other-location edge), just two of them for one
-- source-level gate application.
buildTwoQubitEC :: Classical -> VertexId -> VertexId -> CircuitGraph -> (VTree, CircuitGraph)
buildTwoQubitEC c@(Classical name) a b g
  | name == pack "swap" =
      let locA     = vertexLoc g a
          locB     = vertexLoc g b
          (a', g1) = freshGated (VGate (GateOp a [b] (Right c))) locA g
          (b', g2) = freshGated (VGate (GateOp b [a] (Right c))) locB g1
      in (VNode (VLeaf a') (VLeaf b'), g2)
  | otherwise =  -- cnot
      let locB     = vertexLoc g b
          (b', g') = freshGated (VGate (GateOp b [a] (Right c))) locB g
      in (VNode (VLeaf a) (VLeaf b'), g')

-- | Fold 'buildStmt' over a block's own flattened statements, starting from
-- a *local copy* of the incoming LocMap -- exactly resolveBranchReturn's
-- role in Uncompute.hs. The caller (buildExpr's EQIf/ECall cases) discards
-- this local LocMap once the block's return value has been read out of it;
-- only the CircuitGraph itself (new vertices) escapes.
buildBlockLocal :: BuildCtx -> LocMap -> CircuitGraph -> Block -> Either String (LocMap, CircuitGraph)
buildBlockLocal ctx lm g (Block stmt _) = foldStmts ctx (lm, g) (flattenStmt stmt)

foldStmts :: BuildCtx -> (LocMap, CircuitGraph) -> [Stmt] -> Either String (LocMap, CircuitGraph)
foldStmts _   st []       = Right st
foldStmts ctx st (s : ss) = buildStmt ctx st s >>= \st' -> foldStmts ctx st' ss

buildStmt :: BuildCtx -> (LocMap, CircuitGraph) -> Stmt -> Either String (LocMap, CircuitGraph)
buildStmt ctx (lm, g) stmt = case stmt of
  SNoop            -> Right (lm, g)
  SSeq s1 s2       -> buildStmt ctx (lm, g) s1 >>= \st' -> buildStmt ctx st' s2
  SNewLft _        -> Right (lm, g)
  SEndLft _        -> Right (lm, g)
  SLeq _ _         -> Right (lm, g)
  SAs _ _          -> Right (lm, g)
  SDrop _          -> Right (lm, g)  -- see module note: drop has no effect on this graph
  SLetRef y _ x    -> (\t -> (Map.insert y t lm, g)) <$> lookupLoc lm x
  SLetPair y0 y1 x -> do
    t <- lookupLoc lm x
    case t of
      VNode t0 t1 -> Right (Map.insert y1 t1 (Map.insert y0 t0 lm), g)
      _           -> Left ("circuit graph: cannot destructure non-pair " ++ show x)
  SLetExpr y e -> do
    (t, g') <- buildExpr ctx lm g e
    Right (Map.insert y t lm, g')

-- | Build one function's own graph in isolation, seeding one fresh V_init
-- chain per parameter (matching Circuit.hs's own per-entry allocation) --
-- useful for inspecting a single function (e.g. `oracle`) on its own,
-- independent of buildProgramGraph's whole-program inlining.
buildFunctionGraph :: FuncEnv -> Function -> Either String (CircuitGraph, VTree)
buildFunctionGraph funcs f = do
  let ctx       = BuildCtx funcs
      params    = sigParams (funSig f)
      (lm0, g0) = foldl seed (Map.empty, emptyGraph) params
      seed (lm, g) (v, ty) = let (t, g') = allocForType ty g in (Map.insert v t lm, g')
  (lm', g') <- buildBlockLocal ctx lm0 g0 (funBody f)
  ret       <- lookupLoc lm' (blockRet (funBody f))
  Right (g', ret)

-- | Build the whole program's graph, using its last function as the entry
-- point -- same convention Circuit.hs's compileProgram already uses. Every
-- call the entry (transitively) makes is inlined by buildExpr's ECall case,
-- so this ends up covering the entire reachable program, same as the
-- existing uncompute/circuit passes.
buildProgramGraph :: Program -> Either String (CircuitGraph, VTree)
buildProgramGraph (Program []) = Left "circuit graph: empty program"
buildProgramGraph (Program fs) =
  let funcs = Map.fromList [ (funName fn, fn) | fn <- fs ]
  in buildFunctionGraph funcs (last fs)
