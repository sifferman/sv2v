module Language.SystemVerilog.Parser.Preprocess
  ( uncomment
  , preprocess
  ) where

-- | Remove comments from code.
uncomment :: FilePath -> String -> String
uncomment file str = uncomment' str
  where
  uncomment' a = case a of
    ""               -> ""
    '/' : '/' : rest -> "  " ++ removeEOL rest
    '/' : '*' : rest -> "  " ++ remove rest
    '"'       : rest -> '"' : ignoreString rest
    ch        : rest -> ch  : uncomment' rest

  removeEOL a = case a of
    ""          -> ""
    '\n' : rest -> '\n' : uncomment' rest
    '\t' : rest -> '\t' : removeEOL rest
    _    : rest -> ' '  : removeEOL rest

  remove a = case a of
    ""               -> error $ "File ended without closing comment (*/): " ++ file
    '"' : rest       -> removeString rest
    '\n' : rest      -> '\n' : remove rest
    '\t' : rest      -> '\t' : remove rest
    '*' : '/' : rest -> "  " ++ uncomment' rest
    _ : rest         -> " "  ++ remove rest

  removeString a = case a of
    ""                -> error $ "File ended without closing string: " ++ file
    '"' : rest        -> " "  ++ remove       rest
    '\\' : '"' : rest -> "  " ++ removeString rest
    '\n' : rest       -> '\n' :  removeString rest
    '\t' : rest       -> '\t' :  removeString rest
    _    : rest       -> ' '  :  removeString rest

  ignoreString a = case a of
    ""                -> error $ "File ended without closing string: " ++ file
    '"' : rest        -> '"' : uncomment' rest
    '\\' : '"' : rest -> "\\\"" ++ ignoreString rest
    ch : rest         -> ch : ignoreString rest

-- | A simple `define preprocessor.
preprocess :: [(String, String)] -> FilePath -> String -> String
preprocess _env file content = unlines $ pp True [] _env $ lines $ uncomment file content
  where
  pp :: Bool -> [Bool] -> [(String, String)] -> [String] -> [String]
  pp _ _ _ [] = []
  pp on stack env (a : rest) =
    -- handle macros with escaped newlines
    if a /= "" && last a == '\\' && head a == '`'
    then "" : (pp on stack env $ ((init a) ++ " " ++ (head rest)) : (tail rest))
    else case words a of
      "`define" : name : value -> "" : pp on stack (if on then (name, ppLine env $ unwords value) : env else env) rest
      "`ifdef"  : name : _     -> "" : pp (on && (elem    name $ fst $ unzip env)) (on : stack) env rest
      "`ifndef" : name : _     -> "" : pp (on && (notElem name $ fst $ unzip env)) (on : stack) env rest
      "`else" : _
        | not $ null stack     -> "" : pp (head stack && not on) stack env rest
        | otherwise            -> error $ "`else  without associated `ifdef/`ifndef: " ++ file
      "`endif" : _
        | not $ null stack     -> "" : pp (head stack) (tail stack) env rest
        | otherwise            -> error $ "`endif  without associated `ifdef/`ifndef: " ++ file
      "`default_nettype" : _   -> "" : pp on stack env rest
      _                        -> (if on then ppLine env a else "") : pp on stack env rest

ppLine :: [(String, String)] -> String -> String
ppLine _ "" = ""
ppLine env ('`' : a) = case lookup name env of
  Just value -> value ++ ppLine env rest
  Nothing    -> error $ "Undefined macro: `" ++ name ++ "  Env: " ++ show env
  where
  name = takeWhile (flip elem $ ['A' .. 'Z'] ++ ['a' .. 'z'] ++ ['0' .. '9'] ++ ['_']) a
  rest = drop (length name) a
ppLine env (a : b) = a : ppLine env b
