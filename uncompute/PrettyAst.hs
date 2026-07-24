-- Pretty-printer from Ast.hs back to qurts-core concrete syntax.
--
-- This is the reverse direction of AbsQurtsToAst.hs (which goes BNFC concrete
-- syntax -> Ast.hs). 
--
-- Purpose is debugging/understanding, not a polished formatter: given an
-- Ast.Program (e.g. one produced by the uncomputation pass), render it back
-- to text that a human can read and that the existing parser can re-check,
-- so the transform's output can be fed straight back through
-- TypeChecker.checkProgram as a sanity check.
module PrettyAst
  ( prettyProgram
  , prettyFunction
  , prettyBlock
  , prettyStmt
  , prettyExpr
  , prettyType
  , flattenStmt
  ) where

import Ast
import qualified Data.Set as Set
import Data.List (intercalate)
import Data.Text (Text, unpack)

t :: Text -> String
t = unpack

var :: Var -> String
var (Var x) = t x

funcName :: FuncName -> String
funcName (FuncName x) = t x

lifetime :: Lifetime -> String
lifetime (Lifetime x) = t x

atom :: LifetimeAtom -> String
atom (LVar l) = lifetime l
atom LBottom  = "bot"
atom LTop     = "top"

-- Types are printed following the grammar precisely: T ::= T * PrefixType
-- (left-associative, no parentheses exist in the grammar for types), and
-- PrefixType ::= &a PrefixType | #a PrefixType | bool | qbit | ().
prettyType :: Type -> String
prettyType (TyPair t1 t2)   = prettyType t1 ++ " * " ++ prettyPrefixType t2
prettyType ty                = prettyPrefixType ty

prettyPrefixType :: Type -> String
prettyPrefixType (TyRef a ty)  = "& " ++ atom a ++ " " ++ prettyPrefixType ty
prettyPrefixType (TyBang a ty) = "# " ++ atom a ++ " " ++ prettyPrefixType ty
prettyPrefixType TyBool        = "bool"
prettyPrefixType TyQBit        = "qbit"
prettyPrefixType TyUnit        = "()"
prettyPrefixType (TyPair t1 t2) = error $
  "prettyPrefixType: & or # of a pair type has no valid qurts-core syntax (grammar has no "
    ++ "parenthesized-type production), got &/# (" ++ prettyType (TyPair t1 t2) ++ ")"

prettyExpr :: Expr -> String
prettyExpr (EVar x)          = var x
prettyExpr EFalse             = "false"
prettyExpr ETrue               = "true"
prettyExpr EUnit                = "()"
prettyExpr (EPair x0 x1)     = "(" ++ var x0 ++ ", " ++ var x1 ++ ")"
prettyExpr (ECopy x)          = "copy " ++ var x
prettyExpr (EMeas x)          = "meas(" ++ var x ++ ")"
prettyExpr (EU (Unitary u) x)   = t u ++ "(" ++ var x ++ ")"
prettyExpr (EC (Classical c) x) = "[" ++ t c ++ "](" ++ var x ++ ")"
prettyExpr EInit0                = "[0]()"
prettyExpr EInit1                = "[1]()"
prettyExpr (ECall f lts xs)  =
  funcName f ++ "<" ++ intercalate ", " (map atom lts) ++ ">(" ++ intercalate ", " (map var xs) ++ ")"
prettyExpr (EIf x bt bf)  = "if " ++ var x ++ " " ++ prettyBlock bt ++ " else " ++ prettyBlock bf
prettyExpr (EQIf x bt bf) = "qif " ++ var x ++ " " ++ prettyBlock bt ++ " else " ++ prettyBlock bf

-- Flatten a right- or left-nested SSeq chain into a list of simple
-- statements, in source order, so printing doesn't have to care which
-- associativity AbsQurtsToAst.hs happened to build.
flattenStmt :: Stmt -> [Stmt]
flattenStmt (SSeq s1 s2) = flattenStmt s1 ++ flattenStmt s2
flattenStmt s             = [s]

prettySimpleStmt :: Stmt -> String
prettySimpleStmt SNoop            = "noop"
prettySimpleStmt (SSeq _ _)       = error "prettySimpleStmt: SSeq should have been flattened"
prettySimpleStmt (SNewLft a)      = "newlft " ++ lifetime a
prettySimpleStmt (SEndLft a)      = "endlft " ++ lifetime a
prettySimpleStmt (SLeq a b)       = lifetime a ++ " <= " ++ lifetime b
prettySimpleStmt (SAs x ty)       = var x ++ " as " ++ prettyType ty
prettySimpleStmt (SLetRef y a x)  = "let " ++ var y ++ " = &" ++ lifetime a ++ " " ++ var x
prettySimpleStmt (SLetExpr y e)   = "let " ++ var y ++ " = " ++ prettyExpr e
prettySimpleStmt (SLetPair y0 y1 x) = "let (" ++ var y0 ++ ", " ++ var y1 ++ ") = " ++ var x
prettySimpleStmt (SDrop x)        = "drop " ++ var x

-- | Renders a statement sequence as one " ; "-separated line. For a
-- multi-statement Block, prettyBlock below adds line breaks per statement.
prettyStmt :: Stmt -> String
prettyStmt s = intercalate " ; " (map prettySimpleStmt (flattenStmt s))

indent :: String -> String
indent = unlines . map ("    " ++) . lines

prettyBlock :: Block -> String
prettyBlock (Block stmt ret) =
  "{\n" ++ indent (intercalate " ;\n" (map prettySimpleStmt (flattenStmt stmt)) ++ " ;\n" ++ var ret) ++ "}"

prettyLifetimeContext :: LifetimePreorder -> String
prettyLifetimeContext lp =
  "< " ++ intercalate ", " (map lifetime (ltParams lp))
    ++ " | " ++ intercalate ", " (map prettyConstraint (Set.toList (ltRel lp))) ++ " >"
  where
    prettyConstraint (a, b) = atom a ++ " <= " ++ atom b

prettySignature :: Signature -> String
prettySignature sig =
  prettyLifetimeContext (sigLifetime sig)
    ++ " (" ++ intercalate ", " (map prettyParam (sigParams sig)) ++ ")"
    ++ " -> " ++ prettyType (sigReturn sig)
  where
    prettyParam (x, ty) = var x ++ " : " ++ prettyType ty

prettyFunction :: Function -> String
prettyFunction f =
  "fn " ++ funcName (funName f) ++ " " ++ prettySignature (funSig f) ++ " " ++ prettyBlock (funBody f)

prettyProgram :: Program -> String
prettyProgram (Program fs) = intercalate " ;\n\n" (map prettyFunction fs) ++ "\n"
