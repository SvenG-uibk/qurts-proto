BNFC is a tool to generate a lexer and a parser, the Main.hs and .cf file in this folder are handwritten, the ones in the output are generated

run BNFC like this:

bnfc --haskell -d -o bnfc/bnfc-output/ bnfc/qurts_grammar.cf

then run alex and happy:

alex bnfc/bnfc-output/QurtsGrammar/Lex.x
happy --ghc bnfc/bnfc-output/QurtsGrammar/Par.y
