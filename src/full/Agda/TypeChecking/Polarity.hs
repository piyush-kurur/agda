{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE PatternGuards #-}

module Agda.TypeChecking.Polarity where

import Control.Applicative
import Control.Monad.State

import Data.List
import Data.Maybe
import Data.Traversable (traverse)

import Agda.Syntax.Common
import Agda.Syntax.Internal as I

import Agda.TypeChecking.Monad
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Telescope
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Free hiding (Occurrence(..))

import Agda.Interaction.Options

import Agda.Utils.List
import Agda.Utils.Monad
import Agda.Utils.Permutation
import Agda.Utils.Size

#include "undefined.h"
import Agda.Utils.Impossible

------------------------------------------------------------------------
-- * Polarity lattice.
------------------------------------------------------------------------

-- | Infimum on the information lattice.
--   'Invariant' is bottom (dominant for inf),
--   'Nonvariant' is top (neutral for inf).
(/\) :: Polarity -> Polarity -> Polarity
Nonvariant /\ b = b
a /\ Nonvariant = a
a /\ b | a == b    = a
       | otherwise = Invariant

-- | 'Polarity' negation, swapping monotone and antitone.
neg :: Polarity -> Polarity
neg Covariant     = Contravariant
neg Contravariant = Covariant
neg Invariant     = Invariant
neg Nonvariant    = Nonvariant

-- | What is the polarity of a function composition?
composePol :: Polarity -> Polarity -> Polarity
composePol Nonvariant _    = Nonvariant
composePol _ Nonvariant    = Nonvariant
composePol Invariant _     = Invariant
composePol Covariant x     = x
composePol Contravariant x = neg x

polFromOcc :: Occurrence -> Polarity
polFromOcc o = case o of
  GuardPos  -> Covariant
  StrictPos -> Covariant
  JustPos   -> Covariant
  JustNeg   -> Contravariant
  Mixed     -> Invariant
  Unused    -> Nonvariant

------------------------------------------------------------------------
-- * Auxiliary functions
------------------------------------------------------------------------

-- | Get the next polarity from a list, 'Invariant' if empty.
nextPolarity :: [Polarity] -> (Polarity, [Polarity])
nextPolarity []       = (Invariant, [])
nextPolarity (p : ps) = (p, ps)

-- | Replace 'Nonvariant' by 'Invariant'.
purgeNonvariant :: [Polarity] -> [Polarity]
purgeNonvariant = map (\ p -> if p == Nonvariant then Invariant else p)

------------------------------------------------------------------------
-- * Computing the polarity of a symbol.
------------------------------------------------------------------------

-- | Main function of this module.
computePolarity :: QName -> TCM ()
computePolarity x = do
  reportSLn "tc.polarity.set" 25 $ "Computing polarity of " ++ show x

  -- get basic polarity from positivity analysis
  def      <- getConstInfo x
  let pol0 = map polFromOcc $ defArgOccurrences def
--  let pol0 = map polFromOcc $ getArgOccurrences_ $ theDef def
  reportSLn "tc.polarity.set" 15 $ "Polarity of " ++ show x ++ " from positivity: " ++ show pol0

{-
  -- get basic polarity from shape of def (arguments matched on or not?)
  def      <- getConstInfo x
  let usagePol = usagePolarity $ theDef def
  reportSLn "tc.polarity.set" 15 $ "Polarity of " ++ show x ++ " from definition form: " ++ show usagePol
  let n = genericLength usagePol  -- n <- getArity x
  reportSLn "tc.polarity.set" 20 $ "  arity = " ++ show n

  -- refine polarity by positivity information
  pol0 <- zipWith (/\) usagePol <$> mapM getPol [0..n - 1]
  reportSLn "tc.polarity.set" 15 $ "Polarity of " ++ show x ++ " from positivity: " ++ show pol0
-}

  -- compute polarity of sized types
  pol1 <- sizePolarity x pol0

  -- refine polarity again by using type information
  let t = defType def
  -- Instantiation takes place in Rules.Decl.instantiateDefinitionType
  -- t <- instantiateFull t -- Andreas, 2014-04-11 Issue 1099: needed for
  --                        -- variable occurrence test in  dependentPolarity.
  reportSDoc "tc.polarity.set" 15 $ text "Refining polarity with type " <+> prettyTCM t
  pol <- enablePhantomTypes (theDef def) <$> dependentPolarity t pol1
  reportSLn "tc.polarity.set" 10 $ "Polarity of " ++ show x ++ ": " ++ show pol

  -- set the polarity in the signature
  setPolarity x $ pol -- purgeNonvariant pol -- temporarily disable non-variance

  -- make 'Nonvariant' args 'UnusedArg' in type and clause telescope
  -- Andreas 2012-11-18: skip this for abstract definitions (fixing issue 755).
  -- This means that the most precise type for abstract definitions
  -- is not available, even to other abstract definitions.
  -- A proper fix would be to introduce a second type for use within abstract.
  t <- if (defAbstract def == AbstractDef) then return t else
         nonvariantToUnusedArg pol t
  modifySignature $ updateDefinition x $
   updateTheDef (nonvariantToUnusedArgInDef pol) . updateDefType (const t)

-- | Data and record parameters are used as phantom arguments all over
--   the test suite (and possibly in user developments).
--   @enablePhantomTypes@ turns 'Nonvariant' parameters to 'Invariant'
--   to enable phantoms.
enablePhantomTypes :: Defn -> [Polarity] -> [Polarity]
enablePhantomTypes def pol = case def of
  Datatype{ dataPars = np } -> enable np
  Record  { recPars  = np } -> enable np
  _                         -> pol
  where enable np = let (pars, rest) = genericSplitAt np pol
                    in  purgeNonvariant pars ++ rest

{- UNUSED
-- | Extract a basic approximate polarity info from the shape of definition.
--   Arguments that are matched against get 'Invariant', others 'Nonvariant'.
--   For data types, parameters get 'Nonvariant', indices 'Invariant'.
usagePolarity :: Defn -> [Polarity]
usagePolarity def = case def of
    Axiom{}                                 -> []
    Function{ funClauses = [] }             -> []
    Function{ funClauses = cs }             -> usage $ map clausePats cs
    Datatype{ dataPars = np, dataIxs = ni } -> genericReplicate np Nonvariant
    Record{ recPars = n }                   -> genericReplicate n Nonvariant
    Constructor{}                           -> []
    Primitive{}                             -> []
  where
    usage = foldr1 (zipWith (/\)) . map (map (usagePat . unArg))
    usagePat VarP{} = Nonvariant
    usagePat DotP{} = Nonvariant
    usagePat ConP{} = Invariant
    usagePat LitP{} = Invariant
-}

-- | Make arguments 'Invariant' if the type of a not-'Nonvariant'
--   later argument depends on it.
dependentPolarity :: Type -> [Polarity] -> TCM [Polarity]
dependentPolarity t []          = return []  -- all remaining are 'Invariant'
dependentPolarity t pols@(p:ps) = do
  t <- reduce $ unEl t
  case ignoreSharing t of
    Pi a b -> do
      let c = absBody b
      ps <- dependentPolarity c ps
      p  <- case b of
              Abs{} | p /= Invariant  ->
                -- Andreas, 2014-04-11 see Issue 1099
                -- Free variable analysis is not in the monad,
                -- hence metas must have been instantiated before!
                ifM (relevantInIgnoringNonvariant 0 c ps)
                  (return Invariant)
                  (return p)
              _ -> return p
      return $ p : ps
    _ -> return pols

-- | Check whether a variable is relevant in a type expression,
--   ignoring domains of non-variant arguments.
relevantInIgnoringNonvariant :: Nat -> Type -> [Polarity] -> TCM Bool
relevantInIgnoringNonvariant i t []     = return $ i `relevantInIgnoringSortAnn` t
relevantInIgnoringNonvariant i t (p:ps) = do
  t <- reduce $ unEl t
  case ignoreSharing t of
    Pi a b -> if p /= Nonvariant && i `relevantInIgnoringSortAnn` a then return True
              else relevantInIgnoringNonvariant (i + 1) (absBody b) ps
    _ -> return $ i `relevantInIgnoringSortAnn` t

-- * Turn polarity 'Nonvariant' into relevance 'UnusedArg'

-- | Record information that an argument is unused in 'Relevance'.
mkUnused :: Relevance -> Relevance
mkUnused Relevant = UnusedArg   -- commenting out this line switches off 'UnusedArg' polarity machinery
mkUnused r        = r  -- 'Irrelevant' is more informative than 'UnusedArg'.

-- | Improve 'Relevance' information in a type by polarity information.
--   'Nonvariant' becomes 'UnusedArg'.
nonvariantToUnusedArg :: [Polarity] -> Type -> TCM Type
nonvariantToUnusedArg []     t = return t
nonvariantToUnusedArg (p:ps) t = do
  t <- reduce t
  case ignoreSharingType t of
    El s (Pi a b) -> do
      let a' = if p == Nonvariant then mapRelevance mkUnused a else a
      El s . Pi a' <$> traverse (nonvariantToUnusedArg ps) b
        -- we do not lift properly but bound variables do not matter for reduce
        -- also, we do not maintain the context
    _ -> return t

-- | Propagate 'Nonvariant' 'Polarity' to 'Relevance' information in
--   'Arg's of a defined symbol.
nonvariantToUnusedArgInDef :: [Polarity] -> Defn -> Defn
nonvariantToUnusedArgInDef pol def = case def of
  Function { funClauses = cl } ->
       def { funClauses = map (nonvariantToUnusedArgInClause pol) cl }
  _ -> def

nonvariantToUnusedArgInClause :: [Polarity] -> Clause -> Clause
nonvariantToUnusedArgInClause pol cl@Clause{clauseTel = tel, clausePerm = perm, namedClausePats = ps} =
  let adjPat p Nonvariant
        | properlyMatching (namedArg p) = __IMPOSSIBLE__ -- if we match, we cannot be Nonvariant (sanity check)
        | otherwise                     = mapRelevance mkUnused p
      adjPat p _    = p
      -- change relevance of 'Nonvariant' arguments to 'UnusedArg'
      -- note that the associated patterns cannot be 'ConP' or 'LitP'
      ps'   = zipWith adjPat ps (pol ++ repeat Invariant)
      -- get a list of 'Relevance's for the variables bound in the pattern
      rels0 = getRelevance <$> (concatMap (patternVars . fmap namedThing) ps')
      -- this is the order the variables appear in the telescope
      rels  = permute perm rels0
      -- now improve 'Relevance' in 'Telescope' by pattern relevance
      updateDom UnusedArg = mapRelevance mkUnused
      updateDom r          = id
      tel' = telFromList $ zipWith updateDom rels $ telToList tel
   in cl { namedClausePats = ps', clauseTel = tel'}

------------------------------------------------------------------------
-- * Sized types
------------------------------------------------------------------------

-- | Hack for polarity of size indices.
sizePolarity :: QName -> [Polarity] -> TCM [Polarity]
sizePolarity d pol0 = do
  let exit = return pol0
  ifM (not . optSizedTypes <$> pragmaOptions) exit $ do
  def <- getConstInfo d
  case theDef def of
    Datatype{ dataPars = np, dataCons = cons } -> do
      let TelV tel _      = telView' $ defType def
          (parTel, ixTel) = genericSplitAt np $ telToList tel
      case ixTel of
        []                 -> exit  -- No size index
        Dom _ (_, a) : _ -> ifM ((/= Just BoundedNo) <$> isSizeType a) exit $ do
          -- we assume the size index to be 'Covariant' ...
          let pol   = genericTake np pol0
              polCo = pol ++ [Covariant]
              polIn = pol ++ [Invariant]
          setPolarity d $ polCo
          -- and seek confirm it by looking at the constructor types
          let check c = do
                t <- defType <$> getConstInfo c
                addCtxTel (telFromList parTel) $ do
--OLD:                  let pars = reverse [ defaultArg $ var i | i <- [0..np - 1] ]
                  let pars = map (defaultArg . var) $ downFrom np
                  TelV conTel target <- telView =<< (t `piApplyM` pars)
                  case conTel of
                    EmptyTel  -> return False  -- no size argument
                    ExtendTel arg  tel ->
                      ifM ((/= Just BoundedNo) <$> isSizeType (unDom arg)) (return False) $ do -- also no size argument
                        -- First constructor argument has type Size

                        -- check that only positive occurences in tel
                        let isPos = underAbstraction arg tel $ \ tel -> do
                              pols <- zipWithM polarity [0..] $ map (snd . unDom) $ telToList tel
                              reportSDoc "tc.polarity.size" 25 $
                                text $ "to pass size polarity check, the following polarities need all to be covariant: " ++ show pols
                              return $ all (`elem` [Nonvariant, Covariant]) pols

                        -- check that the size argument appears in the
                        -- right spot in the target type
                        let sizeArg = size tel
                            isLin = addContext conTel $ checkSizeIndex d np sizeArg target

                        ok <- isPos `and2M` isLin
                        reportSDoc "tc.polarity.size" 15 $
                          text "constructor" <+> prettyTCM c <+>
                          text (if ok then "passes" else "fails") <+>
                          text "size polarity check"
                        return ok

          ifM (andM $ map check cons)
              (return polCo) -- yes, we have a sized type here
              (return polIn) -- no, does not conform to the rules of sized types
    _ -> exit

-- | @checkSizeIndex d np i a@ checks that constructor target type @a@
--   has form @d ps (↑ i) idxs@ where @|ps| = np@.
--
--   Precondition: @a@ is reduced and of form @d ps idxs0@.
checkSizeIndex :: QName -> Nat -> Nat -> Type -> TCM Bool
checkSizeIndex d np i a = do
  reportSDoc "tc.polarity.size" 15 $ withShowAllArguments $
    text "checking that constructor target type " <+> prettyTCM a <+>
    text "is data type " <+> prettyTCM d <+>
    text "has size index successor of " <+> prettyTCM (var i)
  case ignoreSharing $ unEl a of
    Def d0 es -> do
      unlessM (isJust <$> sameDef d d0) __IMPOSSIBLE__
      s <- sizeView $ unArg ix
      case s of
        SizeSuc v | Var j [] <- ignoreSharing v, i == j
          -> return $ not $ freeIn i (pars ++ ixs)
        _ -> return False
      where
        (pars, Apply ix : ixs) = genericSplitAt np es
    _ -> __IMPOSSIBLE__

-- | @polarities i a@ computes the list of polarities of de Bruijn index @i@
--   in syntactic entity @a@.
class HasPolarity a where
  polarities :: Nat -> a -> TCM [Polarity]

-- | @polarity i a@ computes the polarity of de Bruijn index @i@
--   in syntactic entity @a@ by taking the infimum of all 'polarities'.
polarity :: HasPolarity a => Nat -> a -> TCM Polarity
polarity i x = do
  ps <- polarities i x
  case ps of
    [] -> return Nonvariant
    ps -> return $ foldr1 (/\) ps

instance HasPolarity a => HasPolarity (I.Arg a) where
  polarities i = polarities i . unArg

instance HasPolarity a => HasPolarity (I.Dom a) where
  polarities i = polarities i . unDom

instance HasPolarity a => HasPolarity (Abs a) where
  polarities i (Abs   _ b) = polarities (i + 1) b
  polarities i (NoAbs _ v) = polarities i v

instance HasPolarity a => HasPolarity [a] where
  polarities i xs = concat <$> mapM (polarities i) xs

instance (HasPolarity a, HasPolarity b) => HasPolarity (a, b) where
  polarities i (x, y) = (++) <$> polarities i x <*> polarities i y

instance HasPolarity Type where
  polarities i (El _ v) = polarities i v

instance HasPolarity a => HasPolarity (Elim' a) where
  polarities i (Proj p)  = return []
  polarities i (Apply a) = polarities i a

instance HasPolarity Term where
  polarities i v = do
   v <- instantiate v
   case v of
    -- Andreas, 2012-09-06: taking the polarities of the arguments
    -- without taking the variance of the function into account seems wrong.
    Var n ts  | n == i -> (Covariant :) . map (const Invariant) <$> polarities i ts
              | otherwise -> map (const Invariant) <$> polarities i ts
    Lam _ t    -> polarities i t
    Lit _      -> return []
    Level l    -> polarities i l
    Def x ts   -> do
      pols <- getPolarity x
      let compose p ps = map (composePol p) ps
      concat . zipWith compose (pols ++ repeat Invariant) <$> mapM (polarities i) ts
    Con _ ts   -> polarities i ts -- constructors can be seen as monotone in all args.
    Pi a b     -> (++) <$> (map neg <$> polarities i a) <*> polarities i b
    Sort s     -> return [] -- polarities i s -- return []
    MetaV _ ts -> map (const Invariant) <$> polarities i ts
    Shared p   -> polarities i $ derefPtr p
    DontCare t -> polarities i t -- return []

instance HasPolarity Level where
  polarities i (Max as) = polarities i as

instance HasPolarity PlusLevel where
  polarities i ClosedLevel{} = return []
  polarities i (Plus _ l) = polarities i l

instance HasPolarity LevelAtom where
  polarities i l = case l of
    MetaLevel _ vs   -> map (const Invariant) <$> polarities i vs
    BlockedLevel _ v -> polarities i v
    NeutralLevel _ v -> polarities i v
    UnreducedLevel v -> polarities i v
