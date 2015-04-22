
module Agda.TypeChecking.Rules.Display (checkDisplayPragma) where

import Control.Applicative
import Data.Maybe

import qualified Agda.Syntax.Abstract as A
import Agda.Syntax.Abstract.Views
import Agda.Syntax.Internal as I
import Agda.Syntax.Position
import Agda.Syntax.Common

import Agda.TypeChecking.Monad
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Telescope
import Agda.TypeChecking.Pretty

checkDisplayPragma :: QName -> [A.NamedArg A.Pattern] -> A.Expr -> TCM ()
checkDisplayPragma f ps e = inTopContext $ do
  pappToTerm f id ps $ \n args -> do
    let lhs = map unArg args
    v <- exprToTerm e
    let df = Display n lhs (DTerm v)
    reportSLn "tc.display.pragma" 20 $ "Adding display form for " ++ show f ++ "\n  " ++ show df
    escapeContext n $ addDisplayForm f df

-- Compute a left-hand side for a display form. Inserts implicits, but no type
-- checking so does the wrong thing if implicitness is computed. Binds variables.
displayLHS :: Telescope -> [A.NamedArg A.Pattern] -> (Int -> [Term] -> TCM a) -> TCM a
displayLHS tel ps ret = patternsToTerms tel ps $ \n vs -> ret n (map unArg vs)

patternsToTerms :: Telescope -> [A.NamedArg A.Pattern] -> (Int -> Args -> TCM a) -> TCM a
patternsToTerms _ [] ret = ret 0 []
patternsToTerms EmptyTel (p : ps) ret =
  patternToTerm (namedArg p) $ \n v ->
  patternsToTerms EmptyTel ps     $ \m vs -> ret (n + m) (inheritHiding p v : vs)
patternsToTerms (ExtendTel a tel) (p : ps) ret = do
  let isMatch = getHiding p == getHiding a &&
                (notHidden p || isNothing (nameOf (unArg p)) ||
                 Just (absName tel) == (rangedThing <$> nameOf (unArg p)))
  case isMatch of
    True ->
      patternToTerm (namedArg p) $ \n v ->
      patternsToTerms (unAbs tel) ps  $ \m vs -> ret (n + m) (inheritHiding p v : vs)
    False ->
      bindWild $ patternsToTerms (unAbs tel) (p : ps) $ \n vs -> ret (1 + n) (inheritHiding a (Var 0 []) : vs)

inheritHiding :: LensHiding a => a -> b -> I.Arg b
inheritHiding a b = setHiding (getHiding a) (defaultArg b)

pappToTerm :: QName -> (Args -> b) -> [A.NamedArg A.Pattern] -> (Int -> b -> TCM a) -> TCM a
pappToTerm x f ps ret = do
  def <- getConstInfo x
  TelV tel _ <- telView $ defType def
  let dropTel n = telFromList . drop n . telToList
      pars =
        case theDef def of
          Constructor { conPars = p } -> p
          Function { funProjection = Just Projection{projIndex = i} }
            | i > 0 -> i - 1
          _ -> 0

  patternsToTerms (dropTel pars tel) ps $ \n vs -> ret n (f vs)

patternToTerm :: A.Pattern -> (Nat -> Term -> TCM a) -> TCM a
patternToTerm p ret =
  case p of
    A.VarP x               -> bindVar x $ ret 1 (Var 0 [])
    A.ConP _ (AmbQ [c]) ps -> pappToTerm c (Con (ConHead c Inductive [])) ps ret
    A.DefP _ f ps          -> pappToTerm f (Def f . map Apply) ps ret
    A.LitP l               -> ret 0 (Lit l)
    A.WildP _              -> bindWild $ ret 1 (Var 0 [])
    _ -> do
      doc <- prettyA p
      typeError $ GenericError $ "Pattern not allowed in DISPLAY pragma:\n" ++ show doc

bindWild :: TCM a -> TCM a
bindWild ret = do
  x <- freshNoName_
  bindVar x ret

bindVar :: Name -> TCM a -> TCM a
bindVar x ret = do
  addCtx x (defaultDom typeDontCare) ret

exprToTerm :: A.Expr -> TCM Term
exprToTerm e =
  case unScope e of
    A.Var x  -> fst <$> getVarInfo x
    A.Def f  -> pure $ Def f []
    A.Proj f -> pure $ Def f []  -- TODO: is this right?
    A.Con (AmbQ (c:_)) -> pure $ Con (ConHead c Inductive []) [] -- Don't care too much about ambiguity here
    A.Lit l -> pure $ Lit l
    A.App _ e arg -> apply <$> exprToTerm e <*> ((:[]) . inheritHiding arg <$> exprToTerm (namedArg arg))

    A.PatternSyn f   -> notAllowed $ "pattern synonym " ++ show f   -- TODO: allow
    A.Macro f        -> notAllowed $ "macro " ++ show f
    A.WithApp{}      -> notAllowed "with application"
    A.QuestionMark{} -> notAllowed "holes"
    A.Underscore{}   -> notAllowed "metavariables"
    A.Lam{}          -> notAllowed "lambdas"
    A.AbsurdLam{}    -> notAllowed "lambdas"
    A.ExtendedLam{}  -> notAllowed "lambdas"
    _                -> typeError $ GenericError $ "TODO: exprToTerm " ++ show e
  where
    notAllowed s = typeError $ GenericError $ "Not allowed in DISPLAY pragma right-hand side: " ++ s
