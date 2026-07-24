-- The actual uncomputation pass: naive strategy only (compute forward, then
-- reverse everything in reverse order right before the drop), qif set aside.
--
-- Scope for this first version: a `drop x` can only be reversed when x's
-- entire definition chain, walked backward, consists of `let`-bound EU
-- applications terminating in [0]()/[1](). Every other construct a chain
-- might pass through (EC, ECall, qif/if, pairs, &borrow) fails loudly with
-- a specific reason rather than silently doing nothing or guessing wrong
module Uncompute
  ( uncomputeProgram
  , uncomputeFunction
  , uncomputeBlock
  , DefMap
  , buildDefMap
  ) where

import Ast
import GateInverse (unitaryInverse)
import PrettyAst (flattenStmt)
import qualified Data.Map.Strict as Map
import Data.Text (pack)

-- | Map from a variable name to the expression that most recently defined
-- it, as of some point in a linear scan of a statement sequence. Only
-- SLetExpr bindings are recorded: those are the only chains this pass can
-- currently reverse. A variable bound via &borrow, pair-destructure, or
-- never bound at all locally (a function parameter) is simply absent --
-- reverseVar below reports that plainly instead of guessing.
type DefMap = Map.Map Var Expr

buildDefMap :: [Stmt] -> DefMap
buildDefMap = foldl step Map.empty
  where
    step m (SLetExpr y e) = Map.insert y e m
    step m _              = m

note :: String -> Maybe a -> Either String a
note msg = maybe (Left msg) Right

describeExpr :: Expr -> String
describeExpr (ECall (FuncName f) _ _) = "a function call (" ++ show f ++ "): reversing a call means the callee's own body must be reversible too, not handled yet"
describeExpr (EQIf _ _ _)             = "a qif expression: set aside for now (needs the paper's split/merge pebble-game rule)"
describeExpr (EIf _ _ _)              = "a classical if expression: not handled yet"
describeExpr (EPair _ _)              = "a pair construction: needs its own split-back-apart treatment, not handled yet"
describeExpr (EMeas _)                = "a measurement: not reversible at all, not just unsupported"
describeExpr (EC (Classical c) _)     = "a classical injection ([" ++ show c ++ "](...)): EC has no inverse table yet, only EU does"
describeExpr other                    = show other

freshVar :: Int -> Var
freshVar n = Var (pack ("rev" ++ show n))

-- | Given the Expr that (in the forward program) defined the value now held
-- by `currentVar` (in the statements generated so far), produce the
-- statements that undo it, and the name of the variable holding the fully
-- reconstructed origin once done. Recurses on the *previous* variable's own
-- definition, but always applies the actual reversing gate to the freshly
-- generated name, never to a stale name from the forward chain.
reverseFrom :: DefMap -> Int -> Expr -> Var -> Either String ([Stmt], Var, Int)
-- Base case: a fresh qubit origin, nothing to undo.
reverseFrom _    n EInit0 currentVar = Right ([], currentVar, n)
reverseFrom _    n EInit1 currentVar = Right ([], currentVar, n)
-- Always-droppable results (Fig. 6's Drop trait: bool, unit, and anything
-- Copy -- which in this system means references, since only Copy-eligible
-- values can be validly copied in the first place): no gate produced these,
-- so there is nothing to reverse, currentVar is already fine to drop as-is.
reverseFrom _    n ETrue      currentVar = Right ([], currentVar, n)
reverseFrom _    n EFalse     currentVar = Right ([], currentVar, n)
reverseFrom _    n EUnit      currentVar = Right ([], currentVar, n)
reverseFrom _    n (ECopy _)  currentVar = Right ([], currentVar, n)
-- A bare rename (`let y = x`): no gate applied, so no statement to emit and
-- no fresh name consumed -- just keep unwinding x's own definition under the
-- same currentVar name.
reverseFrom defs n (EVar prevName) currentVar = do
  prevExpr <- note ("no local definition found for " ++ show prevName
                       ++ " (parameter, or bound via &borrow/pair-destructure, not traced by this pass)")
                    (Map.lookup prevName defs)
  reverseFrom defs n prevExpr currentVar
reverseFrom defs n (EU u prevName) currentVar = do
  invU <- note ("no known inverse for unitary gate " ++ show u) (unitaryInverse u)
  prevExpr <- note ("no local definition found for " ++ show prevName
                       ++ " (parameter, or bound via &borrow/pair-destructure, not traced by this pass)")
                    (Map.lookup prevName defs)
  let fresh = freshVar n
      step  = SLetExpr fresh (EU invU currentVar)
  (restStmts, finalVar, n') <- reverseFrom defs (n + 1) prevExpr fresh
  Right (step : restStmts, finalVar, n')
reverseFrom _ _ other _ = Left ("cannot reverse through " ++ describeExpr other ++ " yet")

-- | Reverse the chain that produced `v`, looking up its own definition first.
reverseVar :: DefMap -> Int -> Var -> Either String ([Stmt], Var, Int)
reverseVar defs n v = do
  e <- note ("no local definition found for " ++ show v
               ++ " (parameter, or bound via &borrow/pair-destructure, not traced by this pass)")
            (Map.lookup v defs)
  reverseFrom defs n e v

rebuildSeq :: [Stmt] -> Stmt
rebuildSeq []     = SNoop
rebuildSeq [s]    = s
rebuildSeq (s:ss) = SSeq s (rebuildSeq ss)

-- | Replace every `drop x` in a flat (qif-free) statement list with the
-- reversed statement sequence for x, followed by a drop of the reconstructed
-- origin. Processes statements in order so each drop sees the definitions in
-- effect at that point, since qurts-core allows rebinding a name.
uncomputeStmts :: [Stmt] -> Either String [Stmt]
uncomputeStmts = go Map.empty 0
  where
    go _ _ [] = Right []
    go defs n (s : rest) = case s of
      SLetExpr y e -> (s :) <$> go (Map.insert y e defs) n rest
      SDrop x -> do
        (revStmts, finalVar, n') <- reverseVar defs n x
        restOut <- go defs n' rest
        Right (revStmts ++ [SDrop finalVar] ++ restOut)
      _ -> (s :) <$> go defs n rest

uncomputeBlock :: Block -> Either String Block
uncomputeBlock (Block stmt ret) = do
  newStmts <- uncomputeStmts (flattenStmt stmt)
  Right (Block (rebuildSeq newStmts) ret)

uncomputeFunction :: Function -> Either String Function
uncomputeFunction f = do
  newBody <- uncomputeBlock (funBody f)
  Right (f { funBody = newBody })

uncomputeProgram :: Program -> Either String Program
uncomputeProgram (Program fs) = Program <$> mapM uncomputeFunction fs
