{-# LANGUAGE PackageImports #-}
module ModelChecking.AstToKripke
  (AstToKripke(..)
  ,Label(Ident,Constr)
  ,fromLabel
  ,termToTree
  )
where
import Data.Tree (Tree(..))
import Data.Data (Data,gmapQ,showConstr,toConstr)
import Data.Generics.Text(gshow)
import ModelChecking.Kripke (Kripke(..)
                            ,KripkeDyn(..)
                            ,KripkeState
                            ,KripkeGr
                            ,KripkeIntMap
                            ,AdjList(AdjList)
                            ,addLabel'
                            ,addInitState'
                            ,addRel'
                            ,addStateWithLabel'
                            )
import "mtl" Control.Monad.State
import Data.Typeable(cast)
import Data.Array(array)

-- |'AstToKripke' offers an interface to create kripke structures containing 
-- labels of type @l@ out ofsyntax trees.
--  The outcoming kripke structure
-- should represent the given abstract syntax tree, i.e.
-- the structure of the syntax tree should be preserved substantially. 
class Kripke k => AstToKripke k where
  -- |kripke structure construction function
  astToKripke :: Data ast => ast -> k Label 
  astToKripke = astToKripkeIgSubtr []

  -- |ignores all subtrees constructed by constructors whose
  -- names are an element of string list
  astToKripkeIgSubtr :: Data ast => [String] -> ast -> k Label

-- |distinguish constructor names and identifiers in the syntax tree, i.e.
-- constructors are represented by its name using 'Constr' and strings are
-- identified by 'Ident'.
data Label = Constr String -- ^ a constructors name
           | Ident  String -- ^ a identifier in syntax tree
           deriving (Eq,Ord)

instance Show Label where
  show (Constr c) ="c_"++c
  show (Ident i)  ="i_"++i

-- |returns the underlying string
fromLabel :: Label -> String
fromLabel (Constr l) = l
fromLabel (Ident  l) = l

instance AstToKripke KripkeGr where
  astToKripkeIgSubtr cs = treeToKripke . termToTree cs

instance AstToKripke KripkeIntMap where
  astToKripkeIgSubtr cs = treeToKripke . termToTree cs

-- |transforms a tree into a kripke structure where every former tree leafs @l@
-- lies on a infinite path @(l,l,l,l)@. This is needed for the property
-- of a kripke structure that every state has a successor.
treeToKripke :: KripkeDyn k => Tree l -> k l
treeToKripke t = 
  let s = 1 in toKS s t $ addLabel' s (rootLabel t) $ addInitState' s empty

instance AstToKripke AdjList where
  astToKripkeIgSubtr cs = treeToAdj . termToTree cs 

treeToAdj :: Tree Label -> AdjList Label
treeToAdj t@(Node lab _) = 
  let 
      iState    = AdjState [] [] [(z,lab)] [z+1,z+2..]
      (AdjState ps ss ls ms) = execState (toAdj z t) iState
      z         = 1
      s         = array (z,head ms-1) ss
      p         = array (z,head ms-1) $ (z,[]):ps
      l         = array (z,head ms-1) ls
  in AdjList p s l [z]

toAdj :: KripkeState -> Tree Label -> State AdjState ()
toAdj parent (Node _ cs) = do
  ns <- getNewNodes $ length cs
  addRelM parent ns
  foldM 
    (\_ (c,n)->do 
      addStateWithLabelM n (rootLabel c)
      toAdj n c
    )
    () 
    (zip cs ns)
  

data AdjState = AdjState 
  [(KripkeState,[KripkeState])] -- ^ predecessor
  [(KripkeState,[KripkeState])] -- ^ successor
  [(KripkeState, Label)]        -- ^ labeling relation
  [KripkeState]                 -- ^ new states

addStateWithLabelM :: KripkeState -> Label -> State AdjState ()
addStateWithLabelM s l = do
  (AdjState ps ss ls ns) <- get 
  put $ AdjState ps ss ((s,l):ls) ns

addRelM :: KripkeState -> [KripkeState] -> State AdjState ()
addRelM i xs = do
  (AdjState ps ss ls ns) <- get 
  put $ AdjState ((map (\x->(x,return i)) xs)++ps) ((i,xs):ss) ls ns

getNewNodes :: Int -> State AdjState [KripkeState]
getNewNodes i = do
  (AdjState ps ss lbl ns) <- get
  let (xs,ys) = splitAt i ns
  put $ AdjState ps ss lbl ys
  return xs


-- |transforms a tree into a kripke structure representing the tree
toKS :: KripkeDyn k => Int -> Tree l -> k l -> k l
toKS j (Node _ cs) k =
  foldr (\(c,i) -> toKS i c . addRel' j i . 
                   addStateWithLabel'  i (rootLabel c)) 
        k $
        zip cs $ newNodes (length cs) k

termToTree :: Data a => [String] -> a -> Tree Label
termToTree cs t = case cast t::Maybe String of
  Nothing -> Node (Constr $ removeEsc $ showConstr $ toConstr t) 
                  (gmapQ (termToTree cs) t)
  Just _  -> Node (Ident (removeEsc $ gshow t)) [] 

removeEsc :: String -> String
removeEsc = filter (/='\"')

