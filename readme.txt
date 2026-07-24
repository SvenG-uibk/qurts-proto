Lexer and parser: see bnfc/readme.txt (shouldn't normally need changes).

Build:

ghc -ibnfc -ibnfc/bnfc-output bnfc/Main.hs AbsQurtsToAst.hs Ast.hs TypeChecker.hs -o qurts

bnfc generates its own Ident-wrapped/split types and constructor names; AbsQurtsToAst.hs converts those into Ast.hs's own syntax, which follows the paper closely.

Usage:

.\qurts parse examples\example_final.qurts-core
.\qurts check examples\example_final.qurts-core
.\qurts test examples

Files with _error in their name are expected to fail type-checking; all others must succeed. `test` prints PASS/FAIL per file and exits non-zero on any unexpected result.
