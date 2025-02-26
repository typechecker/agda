{-# OPTIONS --cubical-compatible --level-universe --safe #-}

module Common.String where

open import Agda.Builtin.String public
open import Common.Bool
open import Common.Char
open import Common.List
open import Common.Nat
open import Common.Integer

strEq : (x y : String) -> Bool
strEq = primStringEquality

infixr 30 _+S+_

_+S+_ : (x y : String) -> String
_+S+_ = primStringAppend

fromList : List Char -> String
fromList = primStringFromList

stringToList : String -> List Char
stringToList = primStringToList

-- Unlike primShowChar, this function
-- does not add quotes
charToStr : Char → String
charToStr c = primStringFromList (c ∷ [])

intToString : Integer → String
intToString = primShowInteger

natToString : Nat -> String
natToString = primShowNat
