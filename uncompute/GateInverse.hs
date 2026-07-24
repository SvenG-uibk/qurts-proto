module GateInverse (unitaryInverse, classicalInverse) where

import Ast (Unitary (..), Classical (..))
import qualified Data.Map.Strict as Map
import Data.Text (Text, pack)

-- Table of standard single-qubit unitaries named via EU (bare U(x) syntax,
-- requiring the argument to be exactly #bot qbit) and their inverses.
--
-- Every gate actually used in the examples so far (H) is self-inverse, but
-- the table is written to hold non-self-inverse gates too (S/Sdg, T/Tdg),
-- since assuming self-inverse as a fallback for an unrecognised gate name
-- would silently generate a reversal that is not actually the inverse.
unitaryInverseTable :: Map.Map Text Text
unitaryInverseTable = Map.fromList $ map (\(a, b) -> (pack a, pack b))
  [ ("I", "I")
  , ("X", "X")
  , ("Y", "Y")
  , ("Z", "Z")
  , ("H", "H")
  , ("not", "not")      -- maybe name it X instead
  , ("S", "Sdg")
  , ("Sdg", "S")
  , ("T", "Tdg")
  , ("Tdg", "T")
  ]

-- | Look up the inverse of a named unitary gate. Returns Nothing for any
-- gate name not in the table. Callers must treat Nothing as "this gate's
-- inverse is unknown", not as licence to assume self-inverse -- gate names
-- are uninterpreted text in Ast.hs, so there is no way to derive an inverse
-- for a name this table doesn't recognise.
unitaryInverse :: Unitary -> Maybe Unitary
unitaryInverse (Unitary name) = Unitary <$> Map.lookup name unitaryInverseTable

-- Table of named classical injections used via EC ([c](x)-style syntax,
-- Section 3.1's "Lifted functions") and their inverses. Deliberately small:
-- only the ones the paper names explicitly (not/cnot/swap -- Section 3.1:
-- "[not] is a 1-qubit lifted function which represents the X-gate, [cnot]
-- is a 2-qubit lifted function which represents the controlled-X gate, and
-- [swap] is a 2-qubit lifted function which represents the swap gate") plus
-- Z (used via EC in example_grover.qurts-core's `phase` function), all of
-- which are self-inverse. Same policy as unitaryInverseTable: a classical
-- injection can be an arbitrary user-defined bijection over bits, so
-- returning Nothing (rather than guessing self-inverse) for any name not
-- in this table is deliberate, not an oversight.
classicalInverseTable :: Map.Map Text Text
classicalInverseTable = Map.fromList $ map (\(a, b) -> (pack a, pack b))
  [ ("not",  "not")
  , ("cnot", "cnot")
  , ("swap", "swap")
  , ("Z",    "Z")
  ]

-- | Look up the inverse of a named classical injection. Same Nothing-means-
-- unknown policy as 'unitaryInverse'.
classicalInverse :: Classical -> Maybe Classical
classicalInverse (Classical name) = Classical <$> Map.lookup name classicalInverseTable
