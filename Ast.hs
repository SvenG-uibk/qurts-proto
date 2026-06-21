{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}

module Ast where

import qualified Data.Set as Set
import qualified Data.Map as Map
import Data.Text


-- Identifiers
newtype Var      = Var Text
  deriving (Eq, Ord, Show)
newtype FuncName = FuncName Text
  deriving (Eq, Ord, Show)
newtype Lifetime = Lifetime Text       -- lifetime variable α, β, ...
  deriving (Eq, Ord, Show)


-- Lifetime atom: 𝔞 ::= α | ⊥ | ⊤  (Figure 4)
data LifetimeAtom
  = LVar Lifetime
  | LBottom                            -- ⊥ ("bot"), the empty lifetime = linear
  | LTop                               -- ⊤ ("top"), the static lifetime = always affine
  deriving (Eq, Ord, Show)


-- Lifetime Preorder: A = ⟨A, R⟩  (Figure 3)
-- A: set of currently active lifetime variables
-- R: preorder on A ∪ {⊥, ⊤}
data LifetimePreorder = LifetimePreorder
  { ltVars :: Set.Set Lifetime
  , ltRel  :: Set.Set (LifetimeAtom, LifetimeAtom)
  }
  deriving (Eq, Show)


-- Types: T ::= bool | qbit | () | T1×T2 | &𝔞 T | #𝔞 T  (Figure 4)
data Type
  = TyBool
  | TyQBit
  | TyUnit
  | TyPair Type Type                   -- T1 × T2
  | TyRef  LifetimeAtom Type           -- &𝔞 T  (immutable reference)
  | TyBang LifetimeAtom Type           -- #𝔞 T  (owned, affine during 𝔞)
  deriving (Eq, Ord, Show)


-- Aliveness: a ::= active | †α  (Figure 4)
-- A variable is frozen (†α) when immutably borrowed with lifetime α
data Aliveness
  = Active
  | Frozen Lifetime                    -- †α: frozen during lifetime α
  deriving (Eq, Show)


-- Type context entry
data Binding = Binding
  { bindAlive :: Aliveness
  , bindType  :: Type
  }
  deriving (Eq, Show)

-- Type Context: Γ ::= x0:a0 T0, ..., xn-1:an-1 Tn-1  (Figure 4)
newtype Context = Context (Map.Map Var Binding)
  deriving (Eq, Show)


-- Unitary gate name (e.g. H, X, CX)
newtype Unitary = Unitary Text
  deriving (Eq, Ord, Show)

-- Classical injection name for lifted functions (e.g. not, cnot, swap)
newtype Classical = Classical Text
  deriving (Eq, Ord, Show)


-- Expressions: e ::= ...  (Figure 3)
data Expr
  = EVar  Var                          -- x
  | EFalse                             -- false
  | ETrue                              -- true
  | EUnit                              -- ()
  | EPair Var Var                      -- (x0, x1)
  | ECopy Var                          -- copy x
  | EMeas Var                          -- meas(x)
  | EU    Unitary Var                  -- U(x)
  | EC    Classical Var                -- [c](x)
  | EInit0                             -- [0]()  introduce qubit in state |0⟩
  | EInit1                             -- [1]()  introduce qubit in state |1⟩
  | ECall FuncName [LifetimeAtom] [Var] -- f⟨α0,...⟩(x0,...)
  | EIf   Var Block Block              -- if x Bt else Bf
  | EQIf  Var Block Block              -- qif x B|1⟩ else B|0⟩
  deriving (Eq, Show)


-- Statements: S ::= ...  (Figure 3)
data Stmt
  = SNoop                              -- noop
  | SSeq    Stmt Stmt                  -- S1 ; S2
  | SNewLft Lifetime                   -- newlft α
  | SEndLft Lifetime                   -- endlft α
  | SLeq    Lifetime Lifetime          -- α ≤ β
  | SAs     Var Type                   -- x as T
  | SLetRef Var Lifetime Var           -- let y = &α x
  | SLetExpr Var Expr                  -- let y = e
  | SLetPair Var Var Var               -- let (y0,y1) = x
  | SDrop   Var                        -- drop x
  deriving (Eq, Show)


-- Block: B ::= { S; x }  (Figure 3)
data Block = Block
  { blockStmt :: Stmt
  , blockRet  :: Var
  }
  deriving (Eq, Show)


-- Function Signature: Σ ::= A (x0:T0,...) → T  (Figure 3)
data Signature = Signature
  { sigLifetime :: LifetimePreorder
  , sigParams   :: [(Var, Type)]
  , sigReturn   :: Type
  }
  deriving (Eq, Show)


-- Function: F ::= fn f Σ B  (Figure 3)
data Function = Function
  { funName :: FuncName
  , funSig  :: Signature
  , funBody :: Block
  }
  deriving (Eq, Show)


-- Program: Π ::= F0 ... Fn-1  (Figure 3)
newtype Program = Program [Function]
  deriving (Eq, Show)