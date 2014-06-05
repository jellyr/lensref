{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE CPP #-}
-- {-# OPTIONS_HADDOCK hide #-}
{- |
Reference implementation for the @MonadRefCreator@ interface.

The implementation uses @unsafeCoerce@ internally, but its effect cannot escape.
-}
module Data.LensRef.Pure
    ( Register
    , runRegister
    , runTests
    ) where

import Data.Monoid
import Control.Applicative
import Control.Arrow
import Control.Monad.State
import Control.Monad.Writer
import Control.Monad.Reader
import Control.Monad.Identity
import Control.Lens.Simple

import Unsafe.Coerce

import Data.LensRef.Class
import Data.LensRef.Common
#ifdef __TESTS__
import Data.LensRef.TestEnv
import Data.LensRef.Test
#endif

----------------------

newtype instance RefWriterOf (RefReaderT m) a
    = RefWriterOfReaderT { runRefWriterOfReaderT :: RefWriterT m a }
        deriving (Monad, Applicative, Functor)

newtype Reference (m :: * -> *) b
    = Reference {unwrapLens :: Lens' AllReferenceState b}

joinLens :: RefReaderT m (Reference m b) -> Lens' AllReferenceState b
joinLens (RefReaderT r) f a = unwrapLens (runReader r a) f a

type AllReferenceState = [ReferenceState]

data ReferenceState where
    ReferenceState :: (AllReferenceState -> a -> a) -> a -> ReferenceState

type RefWriterT = StateT AllReferenceState
newtype RefReaderT (m :: * -> *) a
    = RefReaderT { runRefReaderT :: Reader AllReferenceState a }
        deriving (Monad, Applicative, Functor)

initAllReferenceState :: AllReferenceState
initAllReferenceState = []

instance (Monad m, Applicative m) => MonadRefReader (RefReaderT m) where
    type BaseRef (RefReaderT m) = Reference m
    liftRefReader = id

instance (Monad m, Applicative m) => MonadRefReader (RefWriterOf (RefReaderT m)) where
    type BaseRef (RefWriterOf (RefReaderT m)) = Reference m
    liftRefReader = RefWriterOfReaderT . gets . runReader . runRefReaderT

instance (Monad m, Applicative m) => MonadRefWriter (RefWriterOf (RefReaderT m)) where
    liftRefWriter = id

instance (Monad m, Applicative m) => RefClass (Reference m) where
    type RefReaderSimple (Reference m) = RefReaderT m

    readRefSimple r = RefReaderT $ view $ joinLens r
    writeRefSimple r a = RefWriterOfReaderT $ joinLens r .= a
    lensMap l r = pure $ Reference $ joinLens r . l
    unitRef = pure $ Reference united

instance (Monad m, Applicative m) => MonadRefReader (RefWriterT m) where
    type BaseRef (RefWriterT m) = Reference m

    liftRefReader = gets . runReader . runRefReaderT

instance (Monad m, Applicative m) => MonadRefCreator (RefWriterT m) where
    extRef r r2 a0 = state extend
      where
        rk = set (joinLens r) . (^. r2)
        kr = set r2 . (^. joinLens r)

        extend x0 = (pure $ Reference $ lens get set, x0 ++ [ReferenceState kr (kr x0 a0)])
          where
            limit = splitAt (length x0)

            get = unsafeData . head . snd . limit

            set x a = foldl (\x -> (x++) . (:[]) . ap_ x) (rk a zs ++ [ReferenceState kr a]) ys where
                (zs, _ : ys) = limit x

        ap_ :: AllReferenceState -> ReferenceState -> ReferenceState
        ap_ x (ReferenceState f a) = ReferenceState f (f x a)

        unsafeData :: ReferenceState -> a
        unsafeData (ReferenceState _ a) = unsafeCoerce a


instance (Monad m, Applicative m) => MonadMemo (RefWriterT m) where
    memoRead = memoRead_

instance (Monad m, Applicative m) => MonadRefWriter (RefWriterT m) where
    liftRefWriter = runRefWriterOfReaderT

----------------------

newtype Time = Time Integer
    deriving (Eq, Ord)

instance Monoid Time where
    mempty = Time 0
    Time a `mappend` Time b = Time $ a `max` b

incTime (Time i) = Time $ i + 1

newtype TimeReference m b
    = TimeReference { runTimeReference :: Reference m (Writer Time b) }
{-
joinTimeRef :: (Monad m, Applicative m) => TimeRefReaderT m (TimeReference m a) -> TimeReference m a
joinTimeRef (TimeRefReaderT m) = TimeReference $ undefined -- _ $ Reference $ joinLens m
-}
instance (Monad m, Applicative m) => RefClass (TimeReference m) where
    type RefReaderSimple (TimeReference m) = TimeRefReaderT m
    unitRef = TimeRefReaderT $ lift $ fmap TimeReference $ lens pure const `lensMap` unitRef
    lensMap k m = do
        TimeReference r <- m
        TimeRefReaderT $ lift $ fmap TimeReference $ lensMap (lens (fmap (^. k)) (liftA2 $ flip $ set k)) $ pure r
    readRefSimple m = do
        TimeReference r <- m
        TimeRefReaderT $ join $ lift $ fmap (mapWriterT (pure . runIdentity)) $ readRefSimple $ pure r
    writeRefSimple m a = do
        TimeReference r <- liftRefReader m
        RefWriterOfTimeReaderT $ TimeRefWriterT $ do
            modify incTime
            t <- get
            lift $ runRefWriterOfReaderT $ writeRefSimple (pure r) $ do
                tell t
                pure a

newtype TimeRefReaderT m a
    = TimeRefReaderT { runTimeRefReaderT :: WriterT Time (RefReaderT m) a }
        deriving (Monad, Applicative, Functor)

instance (Monad m, Applicative m) => MonadRefReader (TimeRefReaderT m) where
    type BaseRef (TimeRefReaderT m) = TimeReference m
    liftRefReader = id

newtype TimeRefWriterT m a
    = TimeRefWriterT { runTimeRefWriterT :: StateT Time (RefWriterT m) a }
        deriving (Monad, Applicative, Functor, MonadFix)

instance MonadTrans TimeRefWriterT where
    lift = TimeRefWriterT . lift . lift

instance (Monad m, Applicative m) => MonadRefReader (TimeRefWriterT m) where
    type BaseRef (TimeRefWriterT m) = TimeReference m
    liftRefReader (TimeRefReaderT m) = TimeRefWriterT $ do
        (a, t) <- lift $ liftRefReader $ runWriterT m
        modify $ max t
        return a

instance (Monad m, Applicative m) => MonadRefWriter (TimeRefWriterT m) where
    liftRefWriter = runRefWriterOfTimeReaderT

instance (Monad m, Applicative m) => MonadMemo (TimeRefWriterT m) where
    memoRead = memoRead_

instance (Monad m, Applicative m) => MonadRefCreator (TimeRefWriterT m) where
    extRef r k a = TimeRefWriterT $ do
        t <- get
        let tr :: Lens' a b -> Lens' (Writer Time a) (Writer Time b)
            tr k = lens (fmap (^. k)) (liftA2 $ flip $ set k)
            r' = do
                (TimeReference r_, t) <- runWriterT $ runTimeRefReaderT r
                let set x b 
                        | tb > tx = b
                        | otherwise = x
                      where
                        (x', tx) = runWriter x
                        (b', tb) = runWriter b
                lensMap (lens id set) $ pure r_
        lift $ fmap (TimeRefReaderT . lift . fmap TimeReference) $ extRef r' (tr k) $ do
            tell t
            pure a
{-
    newRef a = TimeRefWriterT $ do
        t <- get
        let united' = lens (const ()) (const)
        lift $ fmap (TimeRefReaderT . lift . fmap TimeReference) $ extRef unitRef united' $ do
            tell t
            pure a
-}
newtype instance RefWriterOf (TimeRefReaderT m) a
    = RefWriterOfTimeReaderT { runRefWriterOfTimeReaderT :: TimeRefWriterT m a }
        deriving (Monad, Applicative, Functor)

instance (Monad m, Applicative m) => MonadRefReader (RefWriterOf (TimeRefReaderT m)) where
    type BaseRef (RefWriterOf (TimeRefReaderT m)) = TimeReference m
    liftRefReader = RefWriterOfTimeReaderT . liftRefReader

instance (Monad m, Applicative m) => MonadRefWriter (RefWriterOf (TimeRefReaderT m)) where
    liftRefWriter = id

instance (Monad m, Applicative m) => MonadEffect (RefWriterOf (TimeRefReaderT m)) where
    type EffectM (RefWriterOf (TimeRefReaderT m)) = m
    liftEffectM = RefWriterOfTimeReaderT . lift


---------------------------------

type Register_ m
    = WriterT (MonadMonoid m (), RegionStatusChange -> MonadMonoid m ()) m

newtype Register m a
    = Register { _unRegister :: ReaderT (TimeRefWriterT m () -> m ()) (Register_ (TimeRefWriterT m)) a }
        deriving (Monad, Applicative, Functor, MonadFix)

instance (Monad m, Applicative m) => MonadRefReader (Register m) where
    type BaseRef (Register m) = TimeReference m
    liftRefReader = Register . lift . lift . liftRefReader

instance (Monad m, Applicative m) => MonadRefCreator (Register m) where
    extRef r l = Register . lift . lift . extRef r l
    newRef = Register . lift . lift . newRef

instance (Monad m, Applicative m) => MonadMemo (Register m) where
    memoRead = memoRead_

instance (Monad m, Applicative m) => MonadRefWriter (Register m) where
    liftRefWriter = Register . lift . lift . liftRefWriter

instance (Monad m, Applicative m) => MonadEffect (RefWriterOf (RefReaderT m)) where
    type EffectM (RefWriterOf (RefReaderT m)) = m
    liftEffectM = RefWriterOfReaderT . lift

instance (Monad m, Applicative m) => MonadEffect (Register m) where
    type EffectM (Register m) = m
    liftEffectM = Register . lift . lift . lift

instance (Monad m, Applicative m) => MonadEffect (RefWriterT m) where
    type EffectM (RefWriterT m) = m
    liftEffectM = lift

instance (Monad m, Applicative m) => MonadRegister (Register m) where
{-
    type UpdateM (Register m) = Register m

    onUpdate r b f = Register $ ReaderT $ \ff -> 
        toSend_ r b $ \a b -> mapWriterT (evalRegister' ff) $ f a b

    onChangeEq r f = do
        a0 <- liftRefReader r
        b0 <- runWriterT $ f a0
        fmap (fmap fst) $ onUpdate r (b0, (m0, a0)) $ \a (b', (kill', rep', a')) ->
            if a == a'
              then do
                rep'
                return (b', (kill', rep', a'))
              else do
                liftEffectM m'
                (b, kill) <- runWriterT $ f a
                return (b, (kill, a))
-}
    onChangeMemo r f = onChangeAcc r undefined undefined $ \b _ _ -> fmap const $ f b

    askPostpone = fmap (\f -> f . runRefWriterOfTimeReaderT) $ Register ask

    onRegionStatusChange g = Register $ tell (mempty, MonadMonoid . lift . g)

runRegister :: (Monad m, Applicative m) => (forall a . m (m a, a -> m ())) -> Register m a -> m (a, m ())
runRegister newChan m = do
    (read, write) <- newChan
    runRegister_ read write m


runRegister_ :: (Monad m, Applicative m) => m (TimeRefWriterT m ()) -> (TimeRefWriterT m () -> m ()) -> Register m a -> m (a, m ())
runRegister_ read write (Register m) = do
    (((a, tick), t), s) <- flip runStateT initAllReferenceState $ flip runStateT mempty $ runTimeRefWriterT $ do
        (a, (w, _)) <- runWriterT $ runReaderT m write
        pure (a, runMonadMonoid w)
    let eval s = flip evalStateT s $ flip evalStateT t $ runTimeRefWriterT $ forever $ do
            join $ lift read
            tick
    pure $ (,) a $ eval s

------------------------------------

onChangeAcc r b0 c0 f = Register $ ReaderT $ \ff -> 
    toSend r b0 c0 $ \b b' c' -> fmap (\x -> evalRegister' ff . x) $ evalRegister' ff $ f b b' c'

evalRegister' ff (Register m) = runReaderT m ff

toSend_
    :: (MonadRefCreator m, MonadRefWriter m, MonadEffect m)
    => RefReader m a
    -> b
    -> (a -> b -> WriterT [EffectM m ()] (Register_ m) b)
    -> Register_ m (RefReader m b)
toSend_ rb b0 fb = do
    undefined
{-
    let doit = runMonadMonoid . fst
        reg (_, st) = runMonadMonoid . st

    memoref <- lift $ do
        b <- liftRefReader rb
        (c, st1) <- runWriterT $ fb b b0 $ c0 b0
        (val, st2) <- runWriterT $ c $ c0 b0
        doit st1
        doit st2
        newRef ((b, (c, val, st1, st2)), [])      -- memo table

    let act = MonadMonoid $ do
            b <- liftRefReader rb
            (last@(b', cc@(_, oldval, st1, st2)), memo) <- readRef memoref
            (_, _, st1, st2) <- if b' == b
              then
                pure cc
              else do
                reg st1 Block
                reg st2 Kill
                (c, oldval', st1, _) <- case lookup b memo of
                  Nothing -> do
                    (c, st1) <- runWriterT $ fb b b' oldval
                    pure (c, c0 b, st1, undefined)
                  Just cc'@(_, _, st1, _) -> do
                    reg st1 Unblock
                    pure cc'
                (val, st2) <- runWriterT $ c oldval'
                let cc = (c, val, st1, st2)
                writeRef memoref ((b, cc), filter ((/= b) . fst) (last:memo))
                pure cc
            doit st1
            doit st2

    tell (act, mempty)
    pure $ readRef $ (_1 . _2 . _2) `lensMap` memoref
-}
toSend
    :: (Eq b, MonadRefCreator m, MonadRefWriter m)
    => RefReader m b
    -> b -> (b -> c)
    -> (b -> b -> c -> {-Either (Register m c)-} Register_ m (c -> Register_ m c))
    -> Register_ m (RefReader m c)
toSend rb b0 c0 fb = do
    let doit = runMonadMonoid . fst
        reg (_, st) = runMonadMonoid . st

    memoref <- lift $ do
        b <- liftRefReader rb
        (c, st1) <- runWriterT $ fb b b0 $ c0 b0
        (val, st2) <- runWriterT $ c $ c0 b0
        doit st1
        doit st2
        newRef ((b, (c, val, st1, st2)), [])      -- memo table

    let act = MonadMonoid $ do
            b <- liftRefReader rb
            (last@(b', cc@(_, oldval, st1, st2)), memo) <- readRef memoref
            (_, _, st1, st2) <- if b' == b
              then
                pure cc
              else do
                reg st1 Block
                reg st2 Kill
                (c, oldval', st1, _) <- case lookup b memo of
                  Nothing -> do
                    (c, st1) <- runWriterT $ fb b b' oldval
                    pure (c, c0 b, st1, undefined)
                  Just cc'@(_, _, st1, _) -> do
                    reg st1 Unblock
                    pure cc'
                (val, st2) <- runWriterT $ c oldval'
                let cc = (c, val, st1, st2)
                writeRef memoref ((b, cc), filter ((/= b) . fst) (last:memo))
                pure cc
            doit st1
            doit st2

    tell (act, mempty)
    pure $ readRef $ (_1 . _2 . _2) `lensMap` memoref

------------------------

runTests :: IO ()
#ifdef __TESTS__
runTests = tests runTest

runTest :: (Eq a, Show a) => String -> Register (Prog TP) a -> Prog' (a, Prog' ()) -> IO ()
runTest name = runTest_ name (TP . lift) $ \r w -> runRegister_ (fmap unTP r) (w . TP)

newtype TP = TP { unTP :: TimeRefWriterT (Prog TP) () }
#else
runTests = fail "enable the tests flag like \'cabal configure --enable-tests -ftests; cabal build; cabal test\'"
#endif
