{- sv2v
 - Author: Zachary Snow <zach@zachjs.com>
 -
 - Conversion for `edge` sensitivity
 -
 - IEEE 1800-2017 Section 9.4.2 defines `edge` as either `posedge` or `negedge`.
 - This does not convert senses in assertions as they are likely either removed
 - or fully supported downstream.
 -}

module Convert.SenseEdge (convert) where

import Convert.Traverse
import Language.SystemVerilog.AST

convert :: [AST] -> [AST]
convert =
    map $ traverseDescriptions $ traverseModuleItems $ traverseStmts $
        traverseNestedStmts convertStmt

convertStmt :: Stmt -> Stmt
convertStmt (Asgn op (Just timing) lhs expr) =
    Asgn op (Just $ convertTiming timing) lhs expr
convertStmt (Timing timing stmt) =
    Timing (convertTiming timing) stmt
convertStmt other = other

convertTiming :: Timing -> Timing
convertTiming (Event sense) = Event $ convertSense sense
convertTiming other = other

convertSense :: Sense -> Sense
convertSense (SenseOr s1 s2) =
    SenseOr (convertSense s1) (convertSense s2)
convertSense (SenseEdge lhs) =
    SenseOr (SensePosedge lhs) (SenseNegedge lhs)
convertSense other = other
