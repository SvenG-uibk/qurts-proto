module GateInverse (unitaryInverse) where

import Ast (Unitary (..))
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
