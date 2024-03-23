{-# LANGUAGE TemplateHaskell, UndecidableInstances #-}

module Internal.Utils.BiMap ( tests ) where

import Prelude hiding (null, lookup)
import qualified Prelude

import Data.Foldable (foldrM)
import qualified Data.List as List
import qualified Data.Map as Map
import Data.Maybe
import Data.Ord

import Agda.Utils.BiMap
import Agda.Utils.List
import Agda.Utils.Null

import Internal.Helpers

------------------------------------------------------------------------
-- * Types used for the tests below
------------------------------------------------------------------------

-- | A key type.

type K = Integer

-- | A value type.

data V = V Integer Integer
  deriving (Eq, Ord, Show)

instance HasTag V where
  type Tag V = Integer
  tag (V n _) = if n < 0 then Nothing else Just n

-- | An instance of the map type.

type BM = BiMap K V

------------------------------------------------------------------------
-- * Generators
------------------------------------------------------------------------

-- | If several keys map to the same value (with a defined tag), then
-- all but the first one are removed. The order of the remaining list
-- elements is unspecified.

dropDuplicates ::
  (Ord v, HasTag v) =>
  [(k, v)] -> [(k, v)]
dropDuplicates =
  concat .
  map (\(v, ks) -> map (,v) $ Map.elems ks) .
  Map.toList .
  Map.mapWithKey
    (\v ks -> if isNothing (tag v)
              then ks
              else uncurry Map.singleton (Map.findMin ks)) .
  Map.fromListWith Map.union .
  map (\(n, (k, v)) -> (v, Map.singleton n k)) .
  zip [1..]

-- | The generator 'validFromListList' returns lists for which the
-- precondition 'fromListPrecondition' is satisfied, assuming that
-- 'tag' is injective for values generated by the 'Arbitrary'
-- instance.

validFromListList ::
  (Arbitrary k, Arbitrary v, Ord v, HasTag v) => Gen [(k, v)]
validFromListList = dropDuplicates <$> arbitrary

prop_validFromListList :: Property
prop_validFromListList =
  forAll validFromListList $ \(kvs :: [(K, V)]) ->
  fromListPrecondition kvs

instance
  (Ord k, HasTag v, Ord v, Ord (Tag v), Arbitrary k, Arbitrary v) =>
  Arbitrary (BiMap k v) where
  arbitrary = fromList <$> validFromListList

  shrink (BiMap t b) =
    [ BiMap
        (Map.delete k t)
        (maybe b (flip Map.delete b) (tag =<< Map.lookup k t))
    | k <- Map.keys t
    ]

-- | Generates values with undefined tags.

valueWithUndefinedTag :: Gen V
valueWithUndefinedTag = do
  n <- chooseInteger (-3, -1)
  i <- arbitrary
  return (V n i)

prop_valueWithUndefinedTag :: Property
prop_valueWithUndefinedTag =
  forAll valueWithUndefinedTag $ \v ->
  isNothing (tag v)

instance Arbitrary V where
  arbitrary = oneof [g, valueWithUndefinedTag]
    where
    g = do
      i <- chooseInteger (-3, 3)
      return (V i (i + 7))

instance CoArbitrary V where
  coarbitrary (V i j) = coarbitrary (i, j)

-- | A key that is likely to be in the map (unless the map is empty).

keyLikelyInMap :: BM -> Gen K
keyLikelyInMap m
  | null ks   = arbitrary
  | otherwise = frequency [(9, elements ks), (1, arbitrary)]
  where
  ks = keys m

-- | A value that is perhaps in the map (unless the map is empty).

valueMaybeInMap :: BM -> Gen V
valueMaybeInMap m
  | null vs   = arbitrary
  | otherwise = frequency [(1, elements vs), (1, arbitrary)]
  where
  vs = elems m

-- | A pair that satisfies 'insertPrecondition' for the given map.

validInsertPair :: BM -> Gen (K, V)
validInsertPair m = do
  k <- arbitrary
  v <- V <$> arbitrary <*> arbitrary
  oneof $
    (if insertPrecondition k v m then [return (k, v)] else []) ++
    [(k,) <$> valueWithUndefinedTag]

prop_validInsertPair :: BM -> Property
prop_validInsertPair m =
  forAll (validInsertPair m) $ \(k, v) ->
  insertPrecondition k v m

-- | A function that satisfies 'mapWithKeyPrecondition' for the given
-- map.

validMapWithKeyFunction :: BM -> Gen (K -> V -> V)
validMapWithKeyFunction m = do
  f <- foldrM
    (\kv f -> do
        let add v' = return (insert kv v' f)
        v' <- arbitrary
        case flip invLookup f =<< tag v' of
          Just _ ->
            -- The tag of v' is defined, and v' has been seen
            -- before. Use a value with an undefined tag.
            add =<< valueWithUndefinedTag
          Nothing ->
            -- Use the mapping kv ↦ v'.
            add v')
    empty
    (toList m)
  fallback <- valueWithUndefinedTag
  return (\k v -> fromMaybe fallback (lookup (k, v) f))

prop_validMapWithKeyFunction :: BM -> Property
prop_validMapWithKeyFunction m =
  forAll (validMapWithKeyFunction m) $ \f ->
  mapWithKeyPrecondition f m

-- | A function that satisfies 'mapWithKeyFixedTagsPrecondition' for
-- the given map.

validMapWithKeyFixedTagsFunction :: BM -> Gen (K -> V -> V)
validMapWithKeyFixedTagsFunction _ = do
  f <- arbitrary
  return (\k v@(V i j) -> V i (f k i j))

prop_validMapWithKeyFixedTagsFunction :: BM -> Property
prop_validMapWithKeyFixedTagsFunction m =
  forAll (validMapWithKeyFixedTagsFunction m) $ \f ->
  mapWithKeyFixedTagsPrecondition f m

-- | The generator @'validUnionMap' m₁@ returns maps @m₂@ for which
-- the precondition of @'union' m₁ m₂@ is satisfied.

validUnionMap :: BM -> Gen BM
validUnionMap m1 =
  fromList . dropDuplicates . filter ok . map tweak <$> arbitrary
  where
  -- Change the key if tag v2 is defined and m1 maps a different key
  -- to v2.
  tweak (k2, v2) =
    case flip invLookup m1 =<< tag v2 of
      Just k1 | k1 /= k2 -> (k1, v2)
      _                  -> (k2, v2)

  -- Remove the pair if tag v2 is defined and m1 maps k2 to a value v1
  -- distinct from v2.
  ok (k2, v2) =
    case (tag v2, lookup k2 m1) of
      (Just _, Just v1) | v1 /= v2 -> False
      _                            -> True

prop_validUnionMap :: BM -> Property
prop_validUnionMap m1 =
  forAll (validUnionMap m1) $ \m2 ->
  let overlappingKeys = or
        [ k1 == k2
        | (k1, v1) <- toList m1
        , (k2, v2) <- toList m2
        ]

      overlappingValues = or
        [ v1 == v2
        | (k1, v1) <- toList m1
        , (k2, v2) <- toList m2
        ]

      sameKey = or
        [ k1 == k2
        | (k1, v1) <- toList m1
        , (k2, v2) <- toList m2
        , v1 /= v2
        ]

      sameValue = or
        [ v1 == v2
        | (k1, v1) <- toList m1
        , (k2, v2) <- toList m2
        , k1 /= k2
        ]
  in
  classify overlappingKeys   "overlapping keys"   $
  classify overlappingValues "overlapping values" $
  classify sameKey           "same key, different values" $
  classify sameValue         "same value, different keys" $
  biMapInvariant m2
    &&
  unionPrecondition m1 m2

------------------------------------------------------------------------
-- * Properties
------------------------------------------------------------------------

-- | \"Normalises\" lists.

normalise :: [(K, V)] -> [(K, V)]
normalise = nubOn fst . List.sortBy (comparing fst)

prop_arbitrary :: BM -> Bool
prop_arbitrary = biMapInvariant

prop_shrink :: BM -> Bool
prop_shrink = all biMapInvariant . take 5 . shrink

prop_empty :: Bool
prop_empty =
  biMapInvariant (empty :: BM)
    &&
  toList (empty :: BM) == []

prop_null :: BM -> Bool
prop_null m =
  null m == (toList m == [])

prop_lookup :: K -> BM -> Bool
prop_lookup k m =
  lookup k m == Prelude.lookup k (toList m)

prop_invLookup :: Integer -> BM -> Bool
prop_invLookup k' m =
  maybeToList (invLookup k' m) ==
  [ k
  | (k, v) <- toList m
  , tag v == Just k'
  ]

prop_singleton :: K -> V -> Bool
prop_singleton k v =
  biMapInvariant (singleton k v)
    &&
  toList (singleton k v) == [(k, v)]

prop_insert :: BM -> Property
prop_insert m =
  forAll (validInsertPair m) $ \(k, v) ->
  biMapInvariant (insert k v m)
    &&
  toList (insert k v m) == normalise ((k, v) : toList m)

prop_alter :: (Maybe V -> Maybe V) -> BM -> Property
prop_alter f m =
  forAll (keyLikelyInMap m) $ \k ->
  alterPrecondition f k m ==>
  biMapInvariant (alter f k m)
    &&
  toList (alter f k m) ==
  normalise
    ((case f (lookup k m) of
        Nothing -> []
        Just v  -> [(k, v)]) ++
     [ (k', v)
     | (k', v) <- toList m
     , k' /= k
     ])

prop_update :: (V -> Maybe V) -> BM -> Property
prop_update f m =
  forAll (keyLikelyInMap m) $ \k ->
  updatePrecondition f k m ==>
  biMapInvariant (update f k m)
    &&
  toList (update f k m) ==
  normalise
    ((case f =<< lookup k m of
        Nothing -> []
        Just v  -> [(k, v)]) ++
     [ (k', v)
     | (k', v) <- toList m
     , k' /= k
     ])

prop_adjust :: (V -> V) -> BM -> Property
prop_adjust f m =
  forAll (keyLikelyInMap m) $ \k ->
  adjustPrecondition f k m ==>
  biMapInvariant (adjust f k m)
    &&
  toList (adjust f k m) ==
  normalise
    ((case f <$> lookup k m of
        Nothing -> []
        Just v  -> [(k, v)]) ++
     [ (k', v)
     | (k', v) <- toList m
     , k' /= k
     ])

prop_insertLookupWithKey ::
  (K -> V -> V -> V) -> BM -> Property
prop_insertLookupWithKey f m =
  forAll (keyLikelyInMap m) $ \k ->
  forAll (valueMaybeInMap m) $ \v ->
  insertLookupWithKeyPrecondition f k v m ==>
  let (v', m') = insertLookupWithKey f k v m in
  biMapInvariant m'
    &&
  v' == lookup k m
    &&
  toList m' ==
  normalise
    ((k, maybe v (f k v) (lookup k m)) :
     [ (k', v)
     | (k', v) <- toList m
     , k' /= k
     ])

prop_mapWithKey :: BM -> Property
prop_mapWithKey m =
  forAll (validMapWithKeyFunction m) $ \f ->
  biMapInvariant (mapWithKey f m)
    &&
  toList (mapWithKey f m) ==
  map (\(k, v) -> (k, f k v)) (toList m)

prop_mapWithKeyFixedTags :: BM -> Property
prop_mapWithKeyFixedTags m =
  forAll (validMapWithKeyFixedTagsFunction m) $ \f ->
  biMapInvariant (mapWithKeyFixedTags f m)
    &&
  toList (mapWithKeyFixedTags f m) ==
  map (\(k, v) -> (k, f k v)) (toList m)

prop_union :: BM -> Property
prop_union m1 =
  forAll (validUnionMap m1) $ \m2 ->
  biMapInvariant (m1 `union` m2)
    &&
  toList (m1 `union` m2) == normalise (toList m1 ++ toList m2)

prop_fromList :: Property
prop_fromList =
  forAll validFromListList $ \kvs ->
  biMapInvariant (fromList kvs)
    &&
  toList (fromList kvs) == normalise kvs

prop_keys :: BM -> Bool
prop_keys m =
  keys m == map fst (toList m)

prop_elems :: BM -> Bool
prop_elems m =
  elems m == map snd (toList m)

prop_fromDistinctAscendingLists_toDistinctAscendingLists :: BM -> Bool
prop_fromDistinctAscendingLists_toDistinctAscendingLists m =
  let p = toDistinctAscendingLists m in
  fromDistinctAscendingListsPrecondition p &&
  fromDistinctAscendingLists p == m

prop_equal :: BM -> BM -> Bool
prop_equal m1 m2 =
  (m1 == m2) == (toList m1 == toList m2)

prop_compare :: BM -> BM -> Bool
prop_compare m1 m2 =
  compare m1 m2 == compare (toList m1) (toList m2)

------------------------------------------------------------------------
-- * All tests
------------------------------------------------------------------------

-- Template Haskell hack to make the following $allProperties work
-- under ghc-7.8.
return [] -- KEEP!

-- | All tests as collected by 'allProperties'.
--
-- Using 'allProperties' is convenient and superior to the manual
-- enumeration of tests, since the name of the property is added
-- automatically.

tests :: TestTree
tests = testProperties "Internal.Utils.BiMap" $allProperties
