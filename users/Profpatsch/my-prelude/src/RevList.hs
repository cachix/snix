module RevList where

import Data.Semigroup qualified as Semigroup
import PossehlAnalyticsPrelude

-- | A reversed list; `:` adds to the end of the list, and '(<>)' is reversed (i.e. @longList <> [oneElement]@ will be O(1) instead of O(n))
--
-- Invariant: the inner list is already reversed.
newtype RevList a = RevList [a]
  deriving stock (Eq)
  deriving (Semigroup, Monoid) via (Semigroup.Dual [a])

empty :: RevList a
{-# INLINE empty #-}
empty = RevList []

singleton :: a -> RevList a
{-# INLINE singleton #-}
singleton a = RevList [a]

-- | (@O(n)@) Turn the list into a reversed list (by reversing)
revList :: [a] -> RevList a
{-# INLINE revList #-}
revList xs = RevList $ reverse xs

-- | (@O(n)@) Turn the reversed list into a list (by reversing)
revListToList :: RevList a -> [a]
{-# INLINE revListToList #-}
revListToList (RevList rev) = reverse rev

instance (Show a) => Show (RevList a) where
  {-# INLINE show #-}
  show (RevList rev) = rev & show
