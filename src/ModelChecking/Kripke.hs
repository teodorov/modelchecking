module ModelChecking.Kripke where
import qualified Data.Graph.Inductive as G 
import qualified Data.IntMap.Strict as M
import Data.Tree (Tree(..))

import Data.Maybe (mapMaybe,fromJust)
import Control.Monad(guard)
import Data.List (nub,union)
import Data.Array (Array,indices,(!))
import qualified Data.Foldable as F

-- * Interfaces for kripke structures

-- | We use @Int@s to uniquely identify a state in a kripke structure.
type KripkeState = Int

-- |A interface for kripke structures. 
-- Minimal definition: 'states','initStates','rel','labels'
class Functor k => Kripke k where
  -- |all states
  states :: k l -> [KripkeState] 
  -- |initial states
  initStates :: k l -> [KripkeState] 
  -- |transition relation
  rel :: KripkeState -> KripkeState -> k l -> Bool 
  -- |state labeling function
  labels :: KripkeState -> k l -> [l] 

  -- |return all transitions
  rels :: k l -> [(KripkeState,KripkeState)]
  rels k = [(i,j)|i<-states k,j<-states k,rel i j k] 

  -- helper functions
  -- |returns whether given state is already in kripke structure
  elemK :: KripkeState -> k l -> Bool
  elemK s = elem s . states

  -- |returns a specified number of state which are not in kripke structure
  newNodes :: Int -> k l -> [KripkeState]
  newNodes n k = 
    let m = if null $ states k then 0  else maximum $ states k 
    in take n [m+1,m+2..]

  -- |returns all predecessors of a given state
  pre :: k l -> KripkeState -> [KripkeState] 
  pre k s = [s'|s'<-states k, rel s' s k]

  -- |returns all successors of a given state
  suc :: k l -> KripkeState -> [KripkeState] 
  suc k s = [s'|s' <- states k,rel s s' k]

  -- |transitive closure of predecessor relation for a given state
  preT :: k l -> KripkeState -> [KripkeState]
  preT k s = nub $ pre k s `union` concatMap (preT k) (pre k s)

  -- |transitive closure of successor relation for a given state
  sucT :: k l -> KripkeState -> [KripkeState]
  sucT k s | suc k s == [s] = [s] 
           | otherwise      = 
      nub $ suc k s `union` (nub $ concatMap (nub . sucT k) (suc k s))

-- |This class offers an interface to mutable kripke structure, i.e.
-- their content may change after initial creation. Minimal definition:
-- 'empty', 'addState', 'addInitState', 'addRel', 'addLabel'
class Kripke k => KripkeDyn k where
  -- building a kripke structure
  -- |a empty kripke structure
  empty :: k l 
  -- |add a new state
  addState :: KripkeState -> k l -> Maybe (k l) 
  -- |add a new state and mark is a initial
  addInitState :: KripkeState -> k l -> Maybe (k l) 
  -- | adds a relation between two already existing states
  addRel :: KripkeState -> KripkeState -> k l -> Maybe (k l) 
  -- | adds a label to a already existing state
  addLabel :: KripkeState -> l -> k l -> Maybe (k l) 

  -- |adds a new node with a given label
  addStateWithLabel :: KripkeState -> l -> k l -> Maybe (k l)
  addStateWithLabel s l k = addState s k >>= addLabel s l 


-- ** unsafe version of insert operations
addState' :: KripkeDyn k => KripkeState -> k l -> k l 
addState' s = fromJust . addState s

addInitState' :: KripkeDyn k => KripkeState -> k l -> k l 
addInitState' s = fromJust . addInitState s

addRel' :: KripkeDyn k => KripkeState -> KripkeState -> k l -> k l 
addRel' u v = fromJust . addRel u v

addLabel' :: KripkeDyn k => KripkeState -> l -> k l -> k l
addLabel' s l = fromJust . addLabel s l

addStateWithLabel' :: KripkeDyn k => KripkeState -> l -> k l -> k l
addStateWithLabel' s l = fromJust . addStateWithLabel s l

-- * Implementations of kripke structure representations

-- ** Rose trees 'Tree'

newtype KripkeTree a = KripkeTree (Tree (KripkeState,a))

instance Functor KripkeTree where
  fmap f (KripkeTree t) = KripkeTree $ g t where
     g (Node (i,l) cs) = Node (i,f l) (map g cs) 

instance Kripke KripkeTree where      
  states (KripkeTree t) = F.foldr (\(i,_) acc -> i:acc) [] t
  initStates (KripkeTree (Node (i,_) _)) = [i]
  rel x y (KripkeTree (Node (i,_) cs)) 
    | x==i      = any (\(Node (j,_) _) -> j==y) cs
    | otherwise = any (\c -> rel x y (KripkeTree c)) cs
  labels s (KripkeTree (Node (i,l) cs))
    | s==i      = [l]
    | otherwise = concatMap (\c -> labels s (KripkeTree c)) cs

-- ** Arrays

-- |a state in a kripke structure has a type and a set of labels
type KripkeLabel a = (NodeType,[a])

-- |we distinguish the following kinds of states
data NodeType 
  = Initial -- ^ see definition of kripke structures
  | Terminal -- ^ optional but useful for control flow graphs
  | Normal   -- ^ a normal node in kripke structure
  | Label    -- ^ a node which will only be processed by printer
  deriving Eq

-- |a adjacency list to represent static kripke structures
data AdjList a = AdjList 
  (Array KripkeState [KripkeState]) -- ^ predecessor relation
  (Array KripkeState [KripkeState]) -- ^ succesor relation
  (Array KripkeState a) -- ^ labeling function
  [KripkeState] -- ^ initial states
  deriving Show

instance Kripke AdjList where
  states (AdjList adj _ _ _) = indices adj
  initStates (AdjList _ _ _ is) = is 
  rel i j (AdjList _ ss _ _) = j `elem` (ss ! i)
  labels i (AdjList _ _ l _) = return $ l ! i
  suc (AdjList _ ss _ _) s = ss ! s
  pre (AdjList ps _ _ _) s = ps ! s

instance Functor AdjList where
  fmap f (AdjList ps ss ls is) = AdjList ps ss (fmap f ls) is

-- ** Integer Maps

-- |a 'Context' defines all informations about one node
data Context l = Context 
  [KripkeState] -- ^ predecessors
  [KripkeState] -- ^ successors
  [l] -- ^ labels

data KripkeIntMap a = KripkeIntMap 
  [KripkeState]           -- ^ initial states
  (M.IntMap (Context a))  -- ^ relational structure

instance Functor KripkeIntMap where
  fmap f (KripkeIntMap is m) = 
    KripkeIntMap is $ fmap (\(Context ps ss ls)-> Context ps ss (map f ls)) m

instance Kripke KripkeIntMap where
  states (KripkeIntMap _ m) = M.keys m
  initStates (KripkeIntMap is _) = is
  rel u v (KripkeIntMap _ m) =
    case M.lookup u m of
      Nothing               -> False
      Just (Context _ ps _) -> elem v ps

  labels u (KripkeIntMap _ m) =
    case M.lookup u m of
      Nothing               -> []
      Just (Context _ _ ls) -> ls

  pre (KripkeIntMap _ m) u = case M.lookup u m of
    Nothing               -> []
    Just (Context ps _ _) -> ps

  suc (KripkeIntMap _ m) u = case M.lookup u m of
    Nothing               -> []
    Just (Context _ ss _) -> ss

  rels (KripkeIntMap _ m) =
    foldr (\(u,(Context _ s _)) acc -> (zip [u..] s)++ acc) 
          [] 
          (M.assocs m)


instance KripkeDyn KripkeIntMap where
  empty = KripkeIntMap [] M.empty 

  addState s (KripkeIntMap is m) = case M.lookup s m of
    Just _  -> Nothing
    Nothing -> Just $ KripkeIntMap is (M.insert s (Context [] [] []) m)

  addInitState s k = do
    (KripkeIntMap is m) <- addState s k
    return $ KripkeIntMap (s:is) m
  
  addRel u v (KripkeIntMap is m) = do 
    guard $ M.member u m &&  M.member v m
    return $ KripkeIntMap is $ 
      M.adjust (\(Context p1 s1 l1) -> Context p1 (v:s1) l1) u $ 
      M.adjust (\(Context p2 s2 l2) -> Context (u:p2) s2 l2) v m

  addLabel s l (KripkeIntMap is m)
    | M.notMember s m = Nothing
    | otherwise =  
      Just $ KripkeIntMap is $ 
        M.adjust (\(Context ps ss ls) -> Context ps ss (l:ls)) s m

  addStateWithLabel s l (KripkeIntMap is m) 
    | M.member s m = Nothing
    | otherwise    =
      Just $ KripkeIntMap is $ M.insert s (Context [] [] [l]) m

-- ** Inductive graphs

-- |a wrapper for functional inductive graphs containing 'NodeType's
newtype KripkeGr a = KripkeGr {graph :: G.Gr (KripkeLabel a) ()}

instance Functor KripkeGr where
  fmap f (KripkeGr gr) = KripkeGr $ G.gmap g gr where 
    g (ps,n,(t,ls),ss) =(ps,n,(t,map f ls),ss) 

instance Kripke KripkeGr where
  states (KripkeGr g) = G.nodes g

  initStates (KripkeGr g) = mapMaybe (f . flip G.match g) (G.nodes g) where
    f (Just (_,n,(Initial,_),_),_) = Just n
    f _                            = Nothing

  rel u v = elem (u,v) . G.edges . graph

  labels s (KripkeGr g) = case G.match s g of
    (Just (_,_,(_,ls),_),_) -> ls
    _                       -> []
  pre (KripkeGr g) s = G.pre g s
  suc (KripkeGr g) s = G.suc g s
  rels (KripkeGr k) = G.edges k

  newNodes n (KripkeGr k) = G.newNodes n k

instance KripkeDyn KripkeGr where
  empty = KripkeGr G.empty

  addState s g
    | elemK s g = Nothing 
    | otherwise = Just $ KripkeGr $ G.insNode (s,(Normal,[])) $ graph g

  addInitState s g 
    | elemK s g = Nothing 
    | otherwise = Just $ KripkeGr $ G.insNode (s,(Initial,[])) $ graph g

  addRel u v g
    | elemK u g && elemK v g = Just $ KripkeGr $ G.insEdge (u,v,()) $ graph g
    | otherwise              = Nothing 

  addLabel s l g = case G.match s $ graph g of
    (Just (pp,n,(t,ls),ss),g') -> Just $ KripkeGr $ (pp,n,(t,l:ls),ss) G.& g'
    _                          -> Nothing 

  addStateWithLabel s l g 
    | elemK s g = Nothing 
    | otherwise = Just $ KripkeGr $ G.insNode (s,(Normal,[l])) $ graph g
