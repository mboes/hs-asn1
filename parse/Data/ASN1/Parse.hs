-- |
-- Module      : Data.ASN1.Parse
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : experimental
-- Portability : unknown
--
-- A parser combinator for ASN1 Stream.
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE CPP #-}
module Data.ASN1.Parse
    ( ParseASN1
    -- * run
    , runParseASN1State
    , runParseASN1
    -- * combinators
    , onNextContainer
    , onNextContainerMaybe
    , getNextContainer
    , getNextContainerMaybe
    , getNext
    , getNextMaybe
    , hasNext
    , getObject
    , getMany
    ) where

import Data.ASN1.Types
import Data.ASN1.Stream
import Control.Monad.State
import Control.Applicative (Applicative, (<$>))

#if MIN_VERSION_mtl(2,2,1)
import Control.Monad.Except
runErrT :: ExceptT e m a -> m (Either e a)
runErrT = runExceptT
type ErrT = ExceptT
#else
import Control.Monad.Error
runErrT = runErrorT
type ErrT = ErrorT
#endif

-- | Parse ASN1 Monad
newtype ParseASN1 a = P { runP :: ErrT String (State [ASN1]) a }
    deriving (Functor, Applicative, Monad, MonadError String, MonadState [ASN1])

-- | run the parse monad over a stream and returns the result and the remaining ASN1 Stream.
runParseASN1State :: ParseASN1 a -> [ASN1] -> Either String (a,[ASN1])
runParseASN1State f s =
    case runState (runErrT (runP f)) s of
        (Left err, _) -> Left err
        (Right r, l)  -> Right (r,l)

-- | run the parse monad over a stream and returns the result.
--
-- If there's still some asn1 object in the state after calling f,
-- an error will be raised.
runParseASN1 :: ParseASN1 a -> [ASN1] -> Either String a
runParseASN1 f s =
    case runParseASN1State f s of
        Left err      -> Left err
        Right (o, []) -> Right o
        Right (_, er) -> throwError ("runParseASN1: remaining state " ++ show er)

-- | get next object
getObject :: ASN1Object a => ParseASN1 a
getObject = do
    l <- get
    case fromASN1 l of
        Left err     -> throwError err
        Right (a,l2) -> put l2 >> return a

-- | get next element from the stream
getNext :: ParseASN1 ASN1
getNext = do
    list <- get
    case list of
        []    -> throwError "empty"
        (h:l) -> put l >> return h

-- | get many elements until there's nothing left
getMany :: ParseASN1 a -> ParseASN1 [a]
getMany getOne = do
    next <- hasNext
    if next
        then liftM2 (:) getOne (getMany getOne)
        else return []

-- | get next element from the stream maybe
getNextMaybe :: (ASN1 -> Maybe a) -> ParseASN1 (Maybe a)
getNextMaybe f = do
    list <- get
    case list of
        []    -> return Nothing
        (h:l) -> let r = f h
                  in do case r of
                            Nothing -> put list
                            Just _  -> put l
                        return r

-- | get next container of specified type and return all its elements
getNextContainer :: ASN1ConstructionType -> ParseASN1 [ASN1]
getNextContainer ty = do
    list <- get
    case list of
        []                    -> throwError "empty"
        (h:l) | h == Start ty -> do let (l1, l2) = getConstructedEnd 0 l
                                    put l2 >> return l1
              | otherwise     -> throwError "not an expected container"


-- | run a function of the next elements of a container of specified type
onNextContainer :: ASN1ConstructionType -> ParseASN1 a -> ParseASN1 a
onNextContainer ty f = getNextContainer ty >>= either throwError return . runParseASN1 f

-- | just like getNextContainer, except it doesn't throw an error if the container doesn't exists.
getNextContainerMaybe :: ASN1ConstructionType -> ParseASN1 (Maybe [ASN1])
getNextContainerMaybe ty = do
    list <- get
    case list of
        []                    -> return Nothing
        (h:l) | h == Start ty -> do let (l1, l2) = getConstructedEnd 0 l
                                    put l2 >> return (Just l1)
              | otherwise     -> return Nothing

-- | just like onNextContainer, except it doesn't throw an error if the container doesn't exists.
onNextContainerMaybe :: ASN1ConstructionType -> ParseASN1 a -> ParseASN1 (Maybe a)
onNextContainerMaybe ty f = do
    n <- getNextContainerMaybe ty
    case n of
        Just l  -> either throwError (return . Just) $ runParseASN1 f l
        Nothing -> return Nothing

-- | returns if there's more elements in the stream.
hasNext :: ParseASN1 Bool
hasNext = not . null <$> get
