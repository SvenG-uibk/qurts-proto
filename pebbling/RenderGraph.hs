-- Two ways to look at a constructed CircuitGraph: a plain indented text
-- listing (no external tools needed) and Graphviz DOT (for an actual
-- picture -- `dot -Tpng foo.dot -o foo.png`, or paste into
-- https://dreampuf.github.io/GraphvizOnline). Both are read-only views over
-- CircuitGraph.hs's own data -- neither one interprets or validates the
-- graph any further than printing what's already there.
module RenderGraph
  ( renderText
  , renderDot
  ) where

import Ast (Unitary (..), Classical (..))
import CircuitGraph
import qualified Data.Map.Strict as Map
import Data.List (intercalate)
import Data.Text (unpack)

vidStr :: VertexId -> String
vidStr (VertexId n) = "v" ++ show n

gateName :: Either Unitary Classical -> String
gateName (Left  (Unitary   n)) = unpack n
gateName (Right (Classical n)) = unpack n

-- | One line per vertex: its id, kind, and incoming edges. Ordered by
-- vertex id (i.e. construction order), so this doubles as a chronological
-- trace of the build.
renderText :: CircuitGraph -> String
renderText g = intercalate "\n"
  [ vidStr vid ++ ": " ++ describe v | (vid, v) <- Map.toAscList (cgVertices g) ]
  where
    describe (Vertex VInit _) = "init"
    describe (Vertex (VGate op) _)   = "gate "   ++ describeOp op
    describe (Vertex (VLinear op) _) = "linear " ++ describeOp op
    describe (Vertex (VMerge ctrl t f) _) =
      "merge ctrl=" ++ vidStr ctrl ++ " true=" ++ vidStr t ++ " false=" ++ vidStr f
    describeOp (GateOp target ctrls label) =
      gateName label ++ " target=" ++ vidStr target
        ++ (if null ctrls then "" else " ctrls=" ++ intercalate "," (map vidStr ctrls))

renderDot :: CircuitGraph -> String
renderDot g = intercalate "\n" $
  [ "digraph pebbling {"
  , "  rankdir=LR;"
  , "  node [fontname=\"monospace\",fontsize=10];"
  , "  edge [fontname=\"monospace\",fontsize=9];"
  ]
  ++ concatMap (uncurry renderVertex) (Map.toAscList (cgVertices g))
  ++ [ "}" ]
  where
    renderVertex vid (Vertex VInit _) =
      [ "  " ++ vidStr vid ++ " [shape=circle,style=filled,fillcolor=lightgreen,label=\"" ++ vidStr vid ++ "\\ninit\"];" ]
    renderVertex vid (Vertex (VGate op) _) =
      node vid "box" "lightblue" (gateName (gateLabel op)) : gateEdges vid op
    renderVertex vid (Vertex (VLinear op) _) =
      node vid "box" "orange" (gateName (gateLabel op) ++ "\\n(linear)") : gateEdges vid op
    renderVertex vid (Vertex (VMerge ctrl t f) _) =
      [ node vid "diamond" "khaki" "merge"
      , edge t vid "true"
      , edge f vid "false"
      , "  " ++ vidStr ctrl ++ " -> " ++ vidStr vid ++ " [style=dotted,label=\"ctrl\"];"
      ]

    node vid shape color label =
      "  " ++ vidStr vid ++ " [shape=" ++ shape ++ ",style=filled,fillcolor=" ++ color
        ++ ",label=\"" ++ vidStr vid ++ "\\n" ++ label ++ "\"];"
    edge from to label =
      "  " ++ vidStr from ++ " -> " ++ vidStr to ++ " [label=\"" ++ label ++ "\"];"
    gateEdges vid (GateOp target ctrls _) =
      edge target vid "" : [ edge c vid "ctrl" | c <- ctrls ]
