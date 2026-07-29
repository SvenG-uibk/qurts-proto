BNFC is a tool to generate a lexer and a parser, the .cf file in this folder is handwritten, the ones in the output are generated. (Main.hs -- the CLI entry point that uses this grammar -- lives at the repo root; Ast.hs/AbsQurtsToAst.hs/TypeChecker.hs live in typeChecker/. Neither is in here.)

run BNFC like this:

bnfc --haskell -d -o bnfc/bnfc-output/ bnfc/qurts_grammar.cf

then run alex and happy:

alex bnfc/bnfc-output/QurtsGrammar/Lex.x
happy --ghc bnfc/bnfc-output/QurtsGrammar/Par.y
