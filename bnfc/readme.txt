BNFC generates the lexer and parser from qurts_grammar.cf (handwritten; bnfc-output/ is generated).
Main.hs lives at the repo root; Ast.hs/AbsQurtsToAst.hs/TypeChecker.hs live in typeChecker/.

Regenerate:

bnfc --haskell -d -o bnfc/bnfc-output/ bnfc/qurts_grammar.cf
alex bnfc/bnfc-output/QurtsGrammar/Lex.x
happy --ghc bnfc/bnfc-output/QurtsGrammar/Par.y
