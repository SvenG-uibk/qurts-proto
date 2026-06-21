module AbsQurtsToAst where

import qualified QurtsGrammar.Abs as B
import Ast

import qualified Data.Set as Set
import qualified Data.Map as Map
import Data.Text (Text, pack)

-- ============================================================
-- Top level
-- ============================================================

convertProgram :: B.Program -> Program
convertProgram (B.Program fns) = Program (map convertFunction fns)

-- ============================================================
-- Function
-- ============================================================

convertFunction :: B.Function -> Function
convertFunction (B.Function ident sig block) = Function
  { funName = convertFuncName ident
  , funSig  = convertSignature sig
  , funBody = convertBlock block
  }

-- ============================================================
-- Signature
-- ============================================================

convertSignature :: B.Signature -> Signature
convertSignature (B.Signature lctx params retTy) = Signature
  { sigLifetime = convertLifetimeContext lctx
  , sigParams   = map convertParam params
  , sigReturn   = convertType retTy
  }

convertParam :: B.Param -> (Var, Type)
convertParam (B.Param ident ty) = (convertVar ident, convertType ty)

-- ============================================================
-- Lifetime Context -> LifetimePreorder
-- ============================================================

convertLifetimeContext :: B.LifetimeContext -> LifetimePreorder
convertLifetimeContext (B.LifetimeContext lifetimes constraints) = LifetimePreorder
  { ltVars = Set.fromList (map convertLifetimeToVar lifetimes)
  , ltRel  = Set.fromList (map convertConstraint constraints)
  }

-- Extract just the variable name from a lifetime for the var set
convertLifetimeToVar :: B.Lifetime -> Lifetime
convertLifetimeToVar (B.LVar (B.Ident s)) = Lifetime (pack s)
convertLifetimeToVar B.LBottom            = Lifetime (pack "bot")
convertLifetimeToVar B.LTop              = Lifetime (pack "top")

convertConstraint :: B.LifetimeConstraint -> (LifetimeAtom, LifetimeAtom)
convertConstraint (B.LifetimeConstraint a b) =
  (convertLifetimeAtom a, convertLifetimeAtom b)

-- ============================================================
-- Block
-- ============================================================

convertBlock :: B.Block -> Block
convertBlock (B.Block stmt ident) = Block
  { blockStmt = convertStmt stmt
  , blockRet  = convertVar ident
  }

-- ============================================================
-- Statements
-- ============================================================

convertStmt :: B.Stmt -> Stmt
convertStmt (B.Stmt s)       = convertSimpleStmt s
convertStmt (B.StmtSeq s ss) = SSeq (convertStmt s) (convertSimpleStmt ss)

convertSimpleStmt :: B.SimpleStmt -> Stmt
convertSimpleStmt B.SimpleStmtNoop              = SNoop
convertSimpleStmt (B.SimpleStmtNewLft lt)       = SNewLft (convertLifetimeVar lt)
convertSimpleStmt (B.SimpleStmtEndLft lt)       = SEndLft (convertLifetimeVar lt)
convertSimpleStmt (B.SimpleStmtLeq a b)         = SLeq (convertLifetimeVar a) (convertLifetimeVar b)
convertSimpleStmt (B.SimpleStmtAs ident ty)     = SAs (convertVar ident) (convertType ty)
convertSimpleStmt (B.SimpleStmtLetRef y lt x)   = SLetRef (convertVar y) (convertLifetimeVar lt) (convertVar x)
convertSimpleStmt (B.SimpleStmtLetExpr y e)     = SLetExpr (convertVar y) (convertExpr e)
convertSimpleStmt (B.SimpleStmtLetPair y0 y1 x) = SLetPair (convertVar y0) (convertVar y1) (convertVar x)
convertSimpleStmt (B.SimpleStmtDrop x)          = SDrop (convertVar x)

-- ============================================================
-- Expressions
-- ============================================================

convertExpr :: B.Expr -> Expr
convertExpr (B.EVar ident)        = EVar (convertVar ident)
convertExpr B.ETrue               = ETrue
convertExpr B.EFalse              = EFalse
convertExpr B.EUnit               = EUnit
convertExpr (B.EPair x y)         = EPair (convertVar x) (convertVar y)
convertExpr (B.ECopy x)           = ECopy (convertVar x)
convertExpr (B.EMeas x)           = EMeas (convertVar x)
convertExpr (B.EU u x)            = EU (Unitary (identToText u)) (convertVar x)
convertExpr (B.EC c x)            = EC (Classical (identToText c)) (convertVar x)
convertExpr B.EInit0              = EInit0
convertExpr B.EInit1              = EInit1
convertExpr (B.ECall f lts args)  = ECall
  (convertFuncName f)
  (map convertLifetimeAtom lts)
  (map convertVar args)
convertExpr (B.EIf x bt bf)       = EIf  (convertVar x) (convertBlock bt) (convertBlock bf)
convertExpr (B.EQIf x bt bf)      = EQIf (convertVar x) (convertBlock bt) (convertBlock bf)

-- ============================================================
-- Types
-- ============================================================

convertType :: B.Type -> Type
convertType (B.TypeMul t pt)  = TyPair (convertType t) (convertPrefixType pt)
convertType (B.TypePrefix pt) = convertPrefixType pt

convertPrefixType :: B.PrefixType -> Type
convertPrefixType (B.TypePrefixRef lt pt)  = TyRef  (convertLifetimeAtom lt) (convertPrefixType pt)
convertPrefixType (B.TypePrefixBang lt pt) = TyBang (convertLifetimeAtom lt) (convertPrefixType pt)
convertPrefixType B.TypeAtomBool           = TyBool
convertPrefixType B.TypeAtomQbit           = TyQBit
convertPrefixType B.TypeAtomUnit           = TyUnit

-- ============================================================
-- Lifetimes
-- ============================================================

convertLifetimeAtom :: B.Lifetime -> LifetimeAtom
convertLifetimeAtom (B.LVar (B.Ident s)) = LVar (Lifetime (pack s))
convertLifetimeAtom B.LBottom            = LBottom
convertLifetimeAtom B.LTop               = LTop

-- Extract just the Lifetime variable (for newlft, endlft, leq)
-- bot and top are not valid lifetime variables in these positions
-- but we handle them gracefully
convertLifetimeVar :: B.Lifetime -> Lifetime
convertLifetimeVar (B.LVar (B.Ident s)) = Lifetime (pack s)
convertLifetimeVar B.LBottom            = Lifetime (pack "bot")
convertLifetimeVar B.LTop               = Lifetime (pack "top")

-- ============================================================
-- Identifiers
-- ============================================================

convertVar :: B.Ident -> Var
convertVar (B.Ident s) = Var (pack s)

convertFuncName :: B.Ident -> FuncName
convertFuncName (B.Ident s) = FuncName (pack s)

identToText :: B.Ident -> Text
identToText (B.Ident s) = pack s