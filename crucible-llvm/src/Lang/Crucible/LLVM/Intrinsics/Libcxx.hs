-- |
-- Module           : Lang.Crucible.LLVM.Intrinsics.Libcxx
-- Description      : Override definitions for C++ standard library functions
-- Copyright        : (c) Galois, Inc 2015-2019
-- License          : BSD3
-- Maintainer       : Rob Dockins <rdockins@galois.com>
-- Stability        : provisional
------------------------------------------------------------------------

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}

module Lang.Crucible.LLVM.Intrinsics.Libcxx
  ( register_cpp_override
    -- ** iostream
  , putToOverride12
  , endlOverride
  , sentryOverride
  ) where

import qualified ABI.Itanium as ABI
import           Control.Applicative (empty)
import           Control.Lens ((^.))
import           Control.Monad.Reader
import           Control.Monad.State
import qualified Data.Map.Strict as Map
import           Data.List (isInfixOf)
import           Data.Type.Equality ((:~:)(Refl), testEquality)
import qualified Text.LLVM.AST as L

import qualified Data.Parameterized.Context as Ctx

import           Lang.Crucible.Backend
import           Lang.Crucible.FunctionHandle (handleArgTypes, handleReturnType)
import           Lang.Crucible.Simulator.RegMap (regValue)
import           Lang.Crucible.Panic (panic)
import           Lang.Crucible.Types (TypeRepr(UnitRepr))

import           Lang.Crucible.LLVM.Extension
import           Lang.Crucible.LLVM.MemModel

import           Lang.Crucible.LLVM.Intrinsics.Common

------------------------------------------------------------------------
-- ** General

-- | C++ overrides generally have a bit more work to do: their types are more
-- complex, their names are mangled in the LLVM module, it's a big mess.
register_cpp_override ::
  (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch) =>
  SomeCPPOverride p sym arch ->
  RegOverrideM p sym arch rtp l a ()
register_cpp_override someCPPOverride = do
  requestedDecl <- ask
  llvmctx       <- get
  case someCPPOverride requestedDecl llvmctx of
    Just (SomeLLVMOverride override) ->
      register_llvm_override override
    Nothing                          -> empty

-- type CPPOverride p sym arch args ret =
--   L.Declare -> LLVMContext arch -> Maybe (LLVMOverride p sym arch args ret)

type SomeCPPOverride p sym arch =
  L.Declare -> LLVMContext arch -> Maybe (SomeLLVMOverride p sym arch)

------------------------------------------------------------------------
-- ** No-ops

------------------------------------------------------------------------
-- *** Utilities

matchSymbolName :: (L.Symbol -> Bool)
                -> L.Declare
                -> Maybe a
                -> Maybe a
matchSymbolName match decl =
  if not (match $ L.decName decl)
  then const Nothing
  else id

panic_ :: (Show a, Show b)
       => String
       -> L.Declare
       -> a
       -> b
       -> c
panic_ from decl args ret =
  panic from [ "Ill-typed override"
             , "Name: " ++ nm
             , "Args: " ++ show args
             , "Ret:  " ++ show ret
             ]
  where L.Symbol nm = L.decName decl

------------------------------------------------------------------------
-- *** No-op override builders

-- | Make an override for a function which doesn't return anything.
voidOverride :: (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
              => (L.Symbol -> Bool)
              -> SomeCPPOverride p sym arch
voidOverride filt requestedDecl llvmctx =
  matchSymbolName filt requestedDecl $
    case (Map.lookup (L.decName requestedDecl) (llvmctx ^. symbolMap)) of
      Just (LLVMHandleInfo decl hand) -> Just $
        let (args, ret) = (handleArgTypes hand, handleReturnType hand)
        in 
          case (args, ret) of
            (_, UnitRepr) ->
              SomeLLVMOverride $ LLVMOverride decl args ret $ \_mem _sym _args ->
                pure ()

            _ -> panic_ "voidOverride" requestedDecl args ret
      _ -> panic "voidOverride"
                 ["No function handle for " ++ show (L.decName requestedDecl)]

-- | Make an override for a function of (LLVM) type @a -> a@, for any @a@.
--
-- The override simply returns its input.
identityOverride :: (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
                 => (L.Symbol -> Bool)
                 -> SomeCPPOverride p sym arch
identityOverride filt requestedDecl llvmctx =
  matchSymbolName filt requestedDecl $
    case (Map.lookup (L.decName requestedDecl) (llvmctx ^. symbolMap)) of
      Just (LLVMHandleInfo decl hand) -> Just $
        let (args, ret) = (handleArgTypes hand, handleReturnType hand)
        in 
          case (args, ret) of
            (Ctx.Empty Ctx.:> ty1, ty2) | Just Refl <- testEquality ty1 ty2 ->
              SomeLLVMOverride $ LLVMOverride decl args ret $ \_mem _sym args' ->
                -- Just return the input
                pure (Ctx.uncurryAssignment regValue args')

            _ -> panic_ "identityOverride" requestedDecl args ret
      _ -> panic "identityOverride"
                 ["No function handle for " ++ show (L.decName requestedDecl)]

-- | Make an override for a function of (LLVM) type @a -> b -> a@, for any @a@.
--
-- The override simply returns its first input.
constOverride :: (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
                 => (L.Symbol -> Bool)
                 -> SomeCPPOverride p sym arch
constOverride filt requestedDecl llvmctx =
  matchSymbolName filt requestedDecl $
    case (Map.lookup (L.decName requestedDecl) (llvmctx ^. symbolMap)) of
      Just (LLVMHandleInfo decl hand) -> Just $
        let (args, ret) = (handleArgTypes hand, handleReturnType hand)
        in 
          case (args, ret) of
            (Ctx.Empty Ctx.:> ty1 Ctx.:> _, ty2)
              | Just Refl <- testEquality ty1 ty2 ->
              SomeLLVMOverride $ LLVMOverride decl args ret $ \_mem _sym args' ->
                pure (Ctx.uncurryAssignment (const . regValue) args')

            _ -> panic_ "constOverride" requestedDecl args ret

      _ -> panic "constOverride"
                 ["No function handle for " ++ show (L.decName requestedDecl)]

------------------------------------------------------------------------
-- ** Declarations

------------------------------------------------------------------------
-- *** iostream

------------------------------------------------------------------------
-- **** basic_ostream

-- | The override for the \"put to\" operator, @<<@
--
-- This is the override for the 12th function signature listed here:
-- https://en.cppreference.com/w/cpp/io/basic_ostream/operator_ltlt
putToOverride12 :: (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
                => SomeCPPOverride p sym arch
putToOverride12 =
  constOverride $ \(L.Symbol nm) ->
    case ABI.demangleName nm of
      Right (ABI.Function
             (ABI.NestedName
              []
              [ ABI.SubstitutionPrefix ABI.SubStdNamespace
              , _
              , ABI.UnqualifiedPrefix (ABI.SourceName "basic_ostream")
              , ABI.TemplateArgsPrefix _
              ]
              (ABI.OperatorName ABI.OpShl))
              [ABI.PointerToType (ABI.FunctionType _)]) -> True
      _ -> False

-- | TODO: When @itanium-abi@ get support for parsing templates, make this a
-- more structured match
endlOverride :: (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
             => SomeCPPOverride p sym arch
endlOverride =
  identityOverride $ \(L.Symbol nm) ->
    and [ "endl"          `isInfixOf` nm
        , "char_traits"   `isInfixOf` nm
        , "basic_ostream" `isInfixOf` nm
        ]


sentryOverride :: (IsSymInterface sym, HasPtrWidth wptr, wptr ~ ArchWidth arch)
               => SomeCPPOverride p sym arch
sentryOverride =
  voidOverride $ \(L.Symbol nm) ->
    case ABI.demangleName nm of
      Right (ABI.Function
             (ABI.NestedName
              []
              [ ABI.SubstitutionPrefix ABI.SubStdNamespace
              , _
              , ABI.UnqualifiedPrefix (ABI.SourceName "basic_ostream")
              , _
              , ABI.UnqualifiedPrefix (ABI.SourceName "sentry")
              ]
              _)
             _) -> True
      _ -> False