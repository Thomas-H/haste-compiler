{-# LANGUAGE GADTs, TypeFamilies, FlexibleInstances, FlexibleContexts, CPP #-}
-- | Implements concurrency for Haste based on "A Poor Man's Concurrency Monad".
module Haste.Concurrent.Monad (
    MVar, CIO, ToConcurrent (..), MonadConc (..),
    forkIO, forkMany, newMVar, newEmptyMVar, takeMVar, putMVar, withMVarIO,
    peekMVar, modifyMVarIO, readMVar, concurrent, liftIO,
    tryTakeMVar, tryPutMVar
  ) where
import Control.Monad.IO.Class
import Control.Monad.Cont.Class
import Control.Monad
import Data.IORef
import Haste.Events.Core (MonadEvent (..))

-- | Any monad which supports concurrency.
class MonadIO m => MonadConc m where
  liftCIO :: CIO a -> m a
  fork    :: m () -> m ()

-- | Old name for 'liftCIO'.
{-# DEPRECATED liftConc "liftConc is deprecated; use liftCIO instead" #-}
liftConc :: MonadConc m => CIO a -> m a
liftConc = liftCIO

instance MonadConc CIO where
  liftCIO = id
  fork = forkIO

instance MonadEvent CIO where
  mkHandler = return . fmap concurrent

-- | Embed concurrent computations into non-concurrent ones.
class ToConcurrent a where
  type Async a
  async :: Async a -> a

instance ToConcurrent (IO ()) where
  type Async (IO ()) = CIO ()
  async = concurrent

instance ToConcurrent (CIO ()) where
  type Async (CIO ()) = CIO ()
  async = id

instance ToConcurrent b => ToConcurrent (a -> b) where
  type Async (a -> b) = a -> Async b
  async f = \x -> async (f x)

data MV a
  = Full a [(a, CIO ())] -- A full MVar: a queue of writers
  | Empty  [a -> CIO ()] -- An empty MVar: a queue of readers
newtype MVar a = MVar (IORef (MV a))

data Action where
  Atom :: IO Action -> Action
  Fork :: [Action] -> Action
  Stop :: Action

-- | Concurrent IO monad. The normal IO monad does not have concurrency
--   capabilities with Haste. This monad is basically IO plus concurrency.
newtype CIO a = C {unC :: (a -> Action) -> Action}

instance Monad CIO where
  return x    = C $ \next -> next x
  (C m) >>= f = C $ \b -> m (\a -> unC (f a) b)

instance Functor CIO where
  fmap f m = do
    x <- m
    return $ f x

instance Applicative CIO where
  (<*>) = ap
  pure  = return

instance MonadIO CIO where
  liftIO m = C $ \next -> Atom (fmap next m)

instance MonadCont CIO where
  callCC f = C $ \next -> unC (f (\a -> C $ \_ -> next a)) next

-- | Spawn a new thread.
forkIO :: CIO () -> CIO ()
forkIO (C m) = C $ \next -> Fork [next (), m (const Stop)]

-- | Spawn several threads at once.
forkMany :: [CIO ()] -> CIO ()
forkMany ms = C $ \next -> Fork (next () : [act (const Stop) | C act <- ms])

-- | Create a new MVar with an initial value.
newMVar :: MonadIO m => a -> m (MVar a)
newMVar a = liftIO $ MVar `fmap` newIORef (Full a [])

-- | Create a new empty MVar.
newEmptyMVar :: MonadIO m => m (MVar a)
newEmptyMVar = liftIO $ MVar `fmap` newIORef (Empty [])

-- | Read an MVar. Blocks if the MVar is empty.
--   Only the first writer in the write queue, if any, is woken.
takeMVar :: MonadConc m => MVar a -> m a
takeMVar (MVar ref) = liftCIO $ do
  callCC $ \next -> join $ liftIO $ do
    v <- readIORef ref
    case v of
      Full x ((x',w):ws) -> do
        writeIORef ref (Full x' ws)
        return $ forkIO w >> return x
      Full x _ -> do
        writeIORef ref (Empty [])
        return $ return x
      Empty rs -> do
        writeIORef ref (Empty (rs ++ [next]))
        return $ C (const Stop)

-- | Try to take a value from an MVar, but return @Nothing@ if it is empty.
tryTakeMVar :: MonadConc m => MVar a -> m (Maybe a)
tryTakeMVar (MVar ref) = liftCIO $ do
  join $ liftIO $ do
    v <- readIORef ref
    case v of
      Full x ((x',w):ws) -> do
        writeIORef ref (Full x' ws)
        return $ forkIO w >> return (Just x)
      Full x _ -> do
        writeIORef ref (Empty [])
        return $ return (Just x)
      Empty rs -> do
        return $ return Nothing

-- | Peek at the value inside a given MVar, if any, without removing it.
peekMVar :: MonadIO m => MVar a -> m (Maybe a)
peekMVar (MVar ref) = liftIO $ do
  v <- readIORef ref
  case v of
    Full x _ -> return (Just x)
    _        -> return Nothing

-- | Read an MVar then put it back. As Javascript is single threaded, this
--   function is atomic. If this ever changes, this function will only be
--   atomic as long as no other thread attempts to write to the MVar.
readMVar :: MonadConc m => MVar a -> m a
readMVar m = do
  x <- takeMVar m
  putMVar m x
  return x

-- | Write an MVar. Blocks if the MVar is already full.
--   Only the first reader in the read queue, if any, is woken.
putMVar :: MonadConc m => MVar a -> a -> m ()
putMVar (MVar ref) x = liftCIO $ do
  callCC $ \next -> join $ liftIO $ do
    v <- readIORef ref
    case v of
      Full oldx ws -> do
        writeIORef ref (Full oldx (ws ++ [(x, next ())]))
        return $ C (const Stop)
      Empty (r:rs) -> do
        writeIORef ref (Empty rs)
        return $ forkIO (r x)
      Empty _ -> do
        writeIORef ref (Full x [])
        return $ return ()

-- | Try to put a value into an MVar, returning @False@ if the MVar is already
--   full.
tryPutMVar :: MonadConc m => MVar a -> a -> m Bool
tryPutMVar (MVar ref) x = liftCIO $ do
  join $ liftIO $ do
    v <- readIORef ref
    case v of
      Full oldx ws -> do
        return $ return False
      Empty (r:rs) -> do
        writeIORef ref (Empty rs)
        return $ forkIO (r x) >> return True
      Empty _ -> do
        writeIORef ref (Full x [])
        return $ return True

-- | Perform an IO action over an MVar.
withMVarIO :: MonadConc m => MVar a -> (a -> IO b) -> m b
withMVarIO v m = takeMVar v >>= liftIO . m

-- | Perform an IO action over an MVar, then write the MVar back.
modifyMVarIO :: MonadConc m => MVar a -> (a -> IO (a, b)) -> m b
modifyMVarIO v m = do
  (x, res) <- withMVarIO v m
  putMVar v x
  return res

-- | Run a concurrent computation. Two different concurrent computations may
--   share MVars; if this is the case, then a call to `concurrent` may return
--   before all the threads it spawned finish executing.
concurrent :: CIO () -> IO ()
concurrent (C m) = scheduler [m (const Stop)]
  where
    scheduler (p:ps) =
      case p of
        Atom io -> do
          next <- io
          scheduler (ps ++ [next])
        Fork ps' -> do
          scheduler (ps ++ ps')
        Stop -> do
          scheduler ps
    scheduler _ =
      return ()
