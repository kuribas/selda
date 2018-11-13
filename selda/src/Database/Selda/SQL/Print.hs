{-# LANGUAGE GADTs, OverloadedStrings, CPP #-}
-- | Pretty-printing for SQL queries. For some values of pretty.
module Database.Selda.SQL.Print where
import Database.Selda.Column
import Database.Selda.SQL
import Database.Selda.SQL.Print.Config (PPConfig)
import qualified Database.Selda.SQL.Print.Config as Cfg
import Database.Selda.SqlType
import Database.Selda.Types
import Control.Monad.State
import Data.List
#if !MIN_VERSION_base(4, 11, 0)
import Data.Monoid hiding (Product)
#endif
import Data.Text (Text)
import qualified Data.Text as Text

-- | O(n log n) equivalent of @nub . sort@
snub :: (Ord a, Eq a) => [a] -> [a]
snub = map head . group . sort

-- | SQL pretty-printer. The state is the list of SQL parameters to the
--   prepared statement.
type PP = State PPState

data PPState = PPState
  { ppParams  :: ![Param]
  , ppTables  :: ![TableName]
  , ppParamNS :: !Int
  , ppQueryNS :: !Int
  , ppConfig  :: !PPConfig
  }

-- | Run a pretty-printer.
runPP :: PPConfig
      -> PP Text
      -> ([TableName], (Text, [Param]))
runPP cfg pp =
  case runState pp (PPState [] [] 1 0 cfg) of
    (q, st) -> (snub $ ppTables st, (q, reverse (ppParams st)))

-- | Compile an SQL AST into a parameterized SQL query.
compSql :: PPConfig
        -> SQL
        -> ([TableName], (Text, [Param]))
compSql cfg = runPP cfg . ppSql cfg

-- | Compile a single column expression.
compExp :: PPConfig -> Exp SQL a -> (Text, [Param])
compExp cfg = snd . runPP cfg . ppCol cfg

-- | Compile an @UPATE@ statement.
compUpdate :: PPConfig
           -> TableName
           -> Exp SQL Bool
           -> [(ColName, SomeCol SQL)]
           -> (Text, [Param])
compUpdate cfg tbl p cs = snd $ runPP cfg ppUpd
  where
    ppUpd = do
      updates <- mapM ppUpdate cs
      check <- ppCol cfg p
      pure $ Text.unwords
        [ "UPDATE", fromTableName tbl
        , "SET", set updates
        , "WHERE", check
        ]
    ppUpdate (n, c) = do
      let n' = fromColName n
      c' <- ppSomeCol cfg c
      let upd = Text.unwords [n', "=", c']
      if n' == c'
        then pure $ Left upd
        else pure $ Right upd
    -- if the update doesn't change anything, pick an arbitrary column to
    -- set to itself just to satisfy SQL's syntactic rules
    set us =
      case [u | Right u <- us] of
        []  -> set (take 1 [Right u | Left u <- us])
        us' -> Text.intercalate ", " us'

-- | Compile a @DELETE@ statement.
compDelete :: PPConfig -> TableName -> Exp SQL Bool -> (Text, [Param])
compDelete cfg tbl p = snd $ runPP cfg ppDelete
  where
    ppDelete = do
      c' <- ppCol cfg p
      pure $ Text.unwords ["DELETE FROM", fromTableName tbl, "WHERE", c']

-- | Pretty-print a literal as a named parameter and save the
--   name-value binding in the environment.
ppLit :: PPConfig -> Lit a -> PP Text
ppLit _cfg LNull     = pure "NULL"
ppLit cfg (LJust l) = ppLit cfg l
ppLit cfg l         = do
  PPState ps ts ns qns tr <- get
  put $ PPState (Param l : ps) ts (succ ns) qns tr
  return $ Cfg.ppPlaceholder cfg ns

dependOn :: TableName -> PP ()
dependOn t = do
  PPState ps ts ns qns tr <- get
  put $ PPState ps (t:ts) ns qns tr

-- | Generate a unique name for a subquery.
freshQueryName :: PP Text
freshQueryName = do
  PPState ps ts ns qns tr <- get
  put $ PPState ps ts ns (succ qns) tr
  return $ Text.pack ('q':show qns)

-- | Pretty-print an SQL AST.
ppSql :: PPConfig -> SQL -> PP Text
ppSql cfg (SQL cs src r gs ord lim dist) = do
  cs' <- mapM (ppSomeCol cfg) cs
  src' <- ppSrc src
  r' <- ppRestricts r
  gs' <- ppGroups gs
  ord' <- ppOrder ord
  lim' <- ppLimit lim
  pure $ mconcat
    [ "SELECT ", if dist then "DISTINCT " else "", result cs'
    , src'
    , r'
    , gs'
    , ord'
    , lim'
    ]
  where
    result []  = "1"
    result cs' = Text.intercalate ", " cs'

    ppSrc EmptyTable = do
      qn <- freshQueryName
      pure $ " FROM (SELECT NULL LIMIT 0) AS " <> qn
    ppSrc (TableName n)  = do
      dependOn n
      pure $ " FROM " <> fromTableName n
    ppSrc (Product [])   = do
      pure ""
    ppSrc (Product sqls) = do
      srcs <- mapM (ppSql cfg) (reverse sqls)
      qs <- flip mapM ["(" <> s <> ")" | s <- srcs] $ \q -> do
        qn <- freshQueryName
        pure (q <> " AS " <> qn)
      pure $ " FROM " <> Text.intercalate ", " qs
    ppSrc (Values row rows) = do
      row' <- Text.intercalate ", " <$> mapM (ppSomeCol cfg) row
      rows' <- mapM ppRow rows
      qn <- freshQueryName
      pure $ mconcat
        [ " FROM (SELECT "
        , Text.intercalate " UNION ALL SELECT " (row':rows')
        , ") AS "
        , qn
        ]
    ppSrc (Join jointype on left right) = do
      l' <- ppSql cfg left
      r' <- ppSql cfg right
      on' <- ppCol cfg on
      lqn <- freshQueryName
      rqn <- freshQueryName
      pure $ mconcat
        [ " FROM (", l', ") AS ", lqn
        , " ",  ppJoinType jointype, " (", r', ") AS ", rqn
        , " ON ", on'
        ]

    ppJoinType LeftJoin  = "LEFT JOIN"
    ppJoinType InnerJoin = "JOIN"

    ppRow xs = do
      ls <- sequence [ppLit cfg  l | Param l <- xs]
      pure $ Text.intercalate ", " ls

    ppRestricts [] = pure ""
    ppRestricts rs = ppCols cfg rs >>= \rs' -> pure $ " WHERE " <> rs'

    ppGroups [] = pure ""
    ppGroups grps = do
      cls <- sequence [ppCol cfg c | Some c <- grps]
      pure $ " GROUP BY " <> Text.intercalate ", " cls

    ppOrder [] = pure ""
    ppOrder os = do
      os' <- sequence [ (<> (" " <> ppOrd o)) <$> ppCol cfg c
                      | (o, Some c) <- os]
      pure $ " ORDER BY " <> Text.intercalate ", " os'

    ppOrd Asc = "ASC"
    ppOrd Desc = "DESC"

    ppLimit Nothing =
      pure ""
    ppLimit (Just (off, limit)) =
      pure $ " LIMIT " <> ppInt limit <> " OFFSET " <> ppInt off

    ppInt = Text.pack . show

ppSomeCol :: PPConfig -> SomeCol SQL -> PP Text
ppSomeCol cfg (Some c)    = ppCol cfg c
ppSomeCol cfg (Named n c) = do
  c' <- ppCol cfg c
  pure $ c' <> " AS " <> fromColName n

ppCols :: PPConfig -> [Exp SQL Bool] -> PP Text
ppCols cfg cs = do
  cs' <- mapM (ppCol cfg) (reverse cs)
  pure $ "(" <> Text.intercalate ") AND (" cs' <> ")"

ppType :: SqlTypeRep -> PP Text
ppType t = do
  c <- ppConfig <$> get
  pure $ Cfg.ppType c t

ppTypePK :: SqlTypeRep -> PP Text
ppTypePK t = do
  c <- ppConfig <$> get
  pure $ Cfg.ppTypePK c t

ppCol :: PPConfig -> Exp SQL a -> PP Text
ppCol _ (Col name)     = pure (fromColName name)
ppCol cfg (Lit l)        = ppLit cfg l
ppCol cfg (BinOp op a b) = ppBinOp cfg op a b
ppCol cfg (UnOp op a)    = ppUnOp cfg op a
ppCol _ (NulOp a)      = ppNulOp a
ppCol cfg (Fun2 f a b)   = do
  a' <- ppCol cfg a
  b' <- ppCol cfg b
  pure $ mconcat [f, "(", a', ", ", b', ")"]
ppCol cfg (If a b c)     = do
  a' <- ppCol cfg a
  b' <- ppCol cfg b
  c' <- ppCol cfg c
  pure $ mconcat ["CASE WHEN ", a', " THEN ", b', " ELSE ", c', " END"]
ppCol cfg (AggrEx f x)   = ppUnOp cfg (Fun f) x
ppCol cfg (Cast t x)     = do
  x' <- ppCol cfg x
  t' <- ppType t
  pure $ mconcat ["CAST(", x', " AS ", t', ")"]
ppCol cfg (InList x xs) = do
  x' <- ppCol cfg x
  xs' <- mapM (ppCol cfg) xs
  pure $ mconcat [x', " IN (", Text.intercalate ", " xs', ")"]
ppCol cfg (InQuery x q) = do
  x' <- ppCol cfg x
  q' <- ppSql cfg q
  pure $ mconcat [x', " IN (", q', ")"]

ppNulOp :: NulOp a -> PP Text
ppNulOp (Fun0 f) = pure $ f <> "()"

ppUnOp :: PPConfig -> UnOp a b -> Exp SQL a -> PP Text
ppUnOp cfg op c = do
  c' <- ppCol cfg c
  pure $ case op of
    Abs    -> "ABS(" <> c' <> ")"
    Sgn    -> "SIGN(" <> c' <> ")"
    Neg    -> "-(" <> c' <> ")"
    Not    -> "NOT(" <> c' <> ")"
    IsNull -> "(" <> c' <> ") IS NULL"
    Fun f  -> f <> "(" <> c' <> ")"

ppBinOp :: PPConfig -> BinOp a b -> Exp SQL a -> Exp SQL a -> PP Text
ppBinOp cfg op a b = do
    a' <- ppCol cfg a
    b' <- ppCol cfg b
    pure $ paren a a' <> " " <> ppOp op <> " " <> paren b b'
  where
    paren :: Exp SQL a -> Text -> Text
    paren (Col{}) c = c
    paren (Lit{}) c = c
    paren _ c       = "(" <> c <> ")"

    ppOp :: BinOp a b -> Text
    ppOp Gt    = ">"
    ppOp Lt    = "<"
    ppOp Gte   = ">="
    ppOp Lte   = "<="
    ppOp Eq    = "="
    ppOp Neq   = "!="
    ppOp And   = "AND"
    ppOp Or    = "OR"
    ppOp Add   = "+"
    ppOp Sub   = "-"
    ppOp Mul   = "*"
    ppOp Div   = "/"
    ppOp Like  = "LIKE"
