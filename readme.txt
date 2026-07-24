lexer and parser is explained in the BNFC folder, but hopefully these dont need to be changed anymore for now.

compile the Main.hs file, which does the following: takes qurts-core code and runs the parser on it and also converts it to the syntax that I defined in Ast.hs, then runs the type checker (if the flag is set)

ghc -ibnfc -ibnfc/bnfc-output bnfc/Main.hs AbsQurtsToAst.hs Ast.hs TypeChecker.hs -o qurts

bnfc generation always adds Ident-wrappers and split types for parsing reasons and generates its own constructor names. I really want to work with my own Ast.hs syntax though (which follows the paper very closely), so i had to write another conversion step (AbsQurtsToAst.hs)

compile that with this

ghc -ibnfc -ibnfc/bnfc-output bnfc/Main.hs AbsQurtsToAst.hs Ast.hs -o Qurts

When everything is compiled, we can run either just the parser or parse+type-check with flags

.\qurts parse examples\example_final.qurts-core
.\qurts check examples\example_final.qurts-core

To run all examples at once and verify they all produce the expected result:

.\qurts test examples

Files with _error in their name are expected to fail type-checking; all others must succeed. The command prints PASS/FAIL for each file and exits non-zero if anything is unexpected.

normal git add . , commit -m, push
