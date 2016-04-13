-----------------------------------------------------------------------------
--
-- Module      :  Transient.Move
-- Copyright   :
-- License     :  GPL-3
--
-- Maintainer  :  agocorona@gmail.com
-- Stability   :
-- Portability :
--
-- | see <https://www.fpcomplete.com/user/agocorona/moving-haskell-processes-between-nodes-transient-effects-iv>
-----------------------------------------------------------------------------
{-# LANGUAGE DeriveDataTypeable , ExistentialQuantification, OverloadedStrings
    ,ScopedTypeVariables, StandaloneDeriving, RecordWildCards, FlexibleContexts, CPP
    ,GeneralizedNewtypeDeriving #-}
module Transient.Move(

Cloud(..),runCloudIO, runCloudIO',local,onAll, loggedc, lliftIO,
listen, connect,

wormhole, teleport, copyData,

beamTo, forkTo, streamFrom, callTo, callTo',runAt,

clustered, mclustered,

newMailBox, putMailBox,getMailBox, sendNodeEvent, waitNodeEvents,
setBuffSize, getBuffSize,

createNode, createWebNode, getMyNode, setMyNode, getNodes,
addNodes, shuffleNodes,



 getWebServerNode, Node(..), nodeList, Connection(..),MyNode(..), Service(),
 isBrowserInstance


) where
import Transient.Base
import Transient.Internals(killChildren,getCont,runCont,EventF(..),LogElem(..),Log(..),onNothing,RemoteStatus(..),getCont)
import Transient.Logged
import Transient.EVars
import Transient.Stream.Resource
import Data.Typeable
import Control.Applicative
#ifndef ghcjs_HOST_OS
import Network
import Network.Info
import qualified Network.Socket as NS
import qualified Network.BSD as BSD
import qualified Network.WebSockets as NS(sendTextData,receiveData, Connection,RequestHead(..),sendClose)
import qualified Network.WebSockets.Connection   as WS
import Network.WebSockets.Stream   hiding(parse)
import           Data.ByteString       as B             (ByteString,concat)
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import Network.Socket.ByteString as SBS(send,sendMany,sendAll,recv)
import Data.CaseInsensitive(mk)
import Data.Char(isSpace)
--import GHCJS.Perch (JSString)
#else
import  JavaScript.Web.WebSocket
import  qualified JavaScript.Web.MessageEvent as JM
import GHCJS.Prim (JSVal)
import GHCJS.Marshal(fromJSValUnchecked)
import qualified Data.JSString as JS


import           JavaScript.Web.MessageEvent.Internal
import           GHCJS.Foreign.Callback.Internal (Callback(..))
import qualified GHCJS.Foreign.Callback          as CB
import Data.JSString  (JSString(..), pack)

#endif


import Control.Monad.State
import System.IO
import Control.Exception
import Data.Maybe
import Unsafe.Coerce

--import System.Directory
import Control.Monad

import System.IO.Unsafe
import Control.Concurrent.STM as STM
import Control.Concurrent.MVar

import Data.Monoid
import qualified Data.Map as M
import Data.List (nub,(\\),find)
import Data.IORef


import qualified Data.ByteString.Lazy.Char8 as BS
import System.IO

import Control.Concurrent

import System.Random



import Data.Dynamic
import Data.String


#ifdef ghcjs_HOST_OS
type HostName  = String
newtype PortID = PortNumber Int deriving (Read, Show, Eq, Typeable)
#endif
data Node= Node{ nodeHost   :: HostName
               , nodePort   :: PortID
               , connection :: IORef Pool
               , services   :: [Service]}
         | WebNode{wconnection:: IORef Pool}
         deriving (Typeable)

instance Ord Node where
   compare node1 node2= compare (nodeHost node1,nodePort node1)(nodeHost node2,nodePort node2)

-- The cloud monad is a thin layer over Transient in order to make sure that the type system
-- forces the logging of intermediate results
newtype Cloud a= Cloud {runCloud ::TransIO a} deriving (Functor,Applicative, Alternative, Monad, MonadState EventF, Monoid)


-- | Means that this computation will be executed in the current node. the result will be logged
-- so the closure will be recovered if the computation is translated to other node by means of
-- primitives like `beamTo`, `forkTo`, `runAt`, `teleport`, `clustered`, `mclustered` etc
local :: Loggable a => TransIO a -> Cloud a
local =  Cloud . logged



-- #ifndef ghcjs_HOST_OS
-- | run the cloud computation.
runCloudIO :: Cloud a -> IO a
runCloudIO (Cloud mx)= keep mx

-- | run the cloud computation with no console input
runCloudIO' :: Cloud a -> IO a
runCloudIO' (Cloud mx)= keep' mx

-- #endif

-- | alternative to `local` It means that if the computation is translated to other node
-- this will be executed again if this has not been executed inside a `local` computation.
--
-- > onAll foo
-- > local foo'
-- > local $ do
-- >       bar
-- >       runCloud $ do
-- >               onAll baz
-- >               runAt node ....
-- > callTo node' .....
--
-- Here foo will be executed in node' but foo' bar and baz don't.
--
-- However foo bar and baz will e executed in node.
--

onAll ::  TransIO a -> Cloud a
onAll =  Cloud

-- log the result a cloud computation. like `loogged`, This eliminated all the log produced by computations
-- inside and substitute it for that single result when the computation is completed.
loggedc (Cloud mx)= Cloud $ logged mx

lliftIO :: Loggable a => IO a -> Cloud a
lliftIO= local . liftIO

--remote :: Loggable a => TransIO a -> Cloud a
--remote x= Cloud $ step' x $ \full x ->  Transient $ do
--            let add= Wormhole: full
--            setSData $ Log False add add
--
--            r <-  runTrans x
--
--            let add= WaitRemote: full
--            (setSData $ Log False add add)     -- !!> "AFTER STEP"
--            return  r

---- | stop the current computation
--stop :: Cloud a
--stop= empty

-- | continue the execution in a new node
-- all the previous actions from `listen` to this statement must have been logged
beamTo :: Node -> Cloud ()
beamTo node =  local $ do
  Log rec log _ <-  getSData <|> return (Log False [][])
  if rec
    then do
      setSData WasRemote
      return ()
    else  do
      msendToNode node $ SLast $ reverse log   -- !> "BEAMTO" -- !> ("beamto send", log)
      empty


-- | execute in the remote node a process with the same execution state
-- all the previous actions from `listen` to this statement must have been logged
forkTo  :: Node -> Cloud ()
forkTo node= local $ do
  Log rec log _<- getSData <|> return (Log False [][])
  if rec
    then do
      setSData WasRemote
      return ()
    else  do
      msendToNode node $ SLast $ reverse log

-- | executes an action in another node.
callTo :: Loggable a => Node -> Cloud a -> Cloud a
callTo node  remoteProc=
   wormhole node $ do
       teleport     -- !!> "TELEPORT to remote"
       r <-  loggedc remoteProc
       teleport     -- !!> "TELEPORT from remote"
       return r


-- | synonymous of `callTo`
-- all the previous actions from `listen` to this statement must have been logged

runAt :: Loggable a => Node -> Cloud a -> Cloud a
runAt= callTo


msendToNode node msg= do
      conn <-  mconnect  node
      liftIO $ msend conn msg


msend :: Loggable a => Connection -> StreamData a -> IO ()


#ifndef ghcjs_HOST_OS

msend (Connection _(Just (Node2Node _ h sock)) _ _ blocked _ _ ) r= liftIO $ do
  withMVar blocked $
             const $ do
                     hPutStrLn   h "LOG a b"
                     hPutStrLn   h ""
                     hPutStrLn h (show r)
                     hFlush h                         -- !>  ("msend: ", r)
--             `catch` (\(e::SomeException) -> sClose sock)


msend (Connection _(Just (Node2Web sconn)) _ _ blocked _ _) r=
  withMVar blocked $ const $ NS.sendTextData sconn $ BS.pack (show r)


#else

msend (Connection _ (Just (Web2Node sconn)) _ _ blocked _ _) r=
  withMVar blocked $ const $ JavaScript.Web.WebSocket.send  (JS.pack $ show r) sconn   -- !!> "MSEND SOCKET"



#endif

msend (Connection _ Nothing _ _  _ _ _ ) _= error "calling msend:  with no connection"

mread :: Loggable a => Connection -> TransIO (StreamData a)
#ifdef ghcjs_HOST_OS


mread (Connection _ (Just (Web2Node sconn)) _ _ _ _ _)=  wsRead sconn


--wsAsk ws tosend= do
--   liftIO $ send ws tosend
--   wsRead ws


wsRead :: Loggable a => WebSocket  -> TransIO  a
wsRead ws= do
  dat <- react (hsonmessage ws) (return ())
  case JM.getData dat of
    JM.StringData str  ->  return (read $ JS.unpack str)  --  !!> ("WSREAD RECEIVED " ++ show str)
    JM.BlobData   blob -> error " blob"
    JM.ArrayBufferData arrBuffer -> error "arrBuffer"

{-
wsRead1 :: Loggable a => WebSocket  -> TransIO (StreamData a)
wsRead1 ws= do
  reactStream (makeCallback MessageEvent) (js_onmessage ws) CB.releaseCallback (return ())
  where
  reactStream createHandler setHandler removeHandler iob= Transient $ do
        cont    <- getCont
        hand <- liftIO . createHandler $ \dat ->do
              runStateT (setSData dat >> runCont cont) cont
              iob
        mEvData <- getSessionData
        case mEvData of
          Nothing -> liftIO $ do
                        setHandler hand
                        return Nothing

          Just dat -> do
             liftIO $ print "callback called 2*****"
             delSessionData dat
             dat' <- case getData dat of
                 StringData str  -> liftIO $ putStrLn "WSREAD RECEIVED " >> print str >> return (read $ JS.unpack str)
                 BlobData   blob -> error " blob"
                 ArrayBufferData arrBuffer -> error "arrBuffer"
             liftIO $ case dat' of
               SDone -> do
                        removeHandler $ Callback hand
                        empty
               sl@(SLast x) -> do
                        removeHandler $ Callback hand     -- !!> "REMOVEHANDLER"
                        return $ Just sl
               SError e -> do
                        removeHandler $ Callback hand
                        print e
                        empty
               more -> return (Just  more)
-}


wsOpen :: JS.JSString -> TransIO WebSocket
wsOpen url= do
   ws <-  liftIO $ js_createDefault url      --  !> ("wsopen",url)
   react (hsopen ws) (return ())             -- !!> "react"
   return ws                                 -- !!> "AFTER ReACT"

foreign import javascript safe
    "window.location.hostname"
   js_hostname ::    JSVal

foreign import javascript safe
   "(function(){var res=window.location.href.split(':')[2];if (res === undefined){return 80} else return res.split('/')[0];})()"
   js_port ::   JSVal

foreign import javascript safe
    "$1.onmessage =$2;"
   js_onmessage :: WebSocket  -> JSVal  -> IO ()

getWebServerNode _=

    createNode  <$> ( fromJSValUnchecked js_hostname)
                <*> (fromIntegral <$> (fromJSValUnchecked js_port :: IO Int))

hsonmessage ::WebSocket -> (MessageEvent ->IO()) -> IO ()
hsonmessage ws hscb= do
  cb <- makeCallback MessageEvent hscb
  js_onmessage ws cb

foreign import javascript safe
             "$1.onopen =$2;"
   js_open :: WebSocket  -> JSVal  -> IO ()

newtype OpenEvent = OpenEvent JSVal deriving Typeable
hsopen ::  WebSocket -> (OpenEvent ->IO()) -> IO ()
hsopen ws hscb= do
   cb <- makeCallback OpenEvent hscb
   js_open ws cb

makeCallback :: (JSVal -> a) ->  (a -> IO ()) -> IO JSVal

makeCallback f g = do
   Callback cb <- CB.syncCallback1 CB.ContinueAsync (g . f)
   return cb


foreign import javascript safe
   "new WebSocket($1)" js_createDefault :: JS.JSString -> IO WebSocket


#else
mread (Connection _(Just (Node2Node _ h _)) _ _ blocked _ _ ) =
       parallel $ do
              hGetLine h       -- to skip LOG header
              hGetLine h
              readHandler  h


mread (Connection node  (Just (Node2Web sconn )) bufSize events blocked _ _ )=
        parallel $ do
            s <- NS.receiveData sconn
            return . read $  BS.unpack s         -- !>  ("WS MREAD RECEIVED ---->", s)

getWebServerNode port= return $ createNode "localhost" port
#endif


-- | A wormhole opens a connection with another node anywhere in a computation.
wormhole :: Loggable a => Node -> Cloud a -> Cloud a
wormhole node (Cloud comp) = local $ Transient $ do

   moldconn <- getData   -- !!> "wormhole"

   Log rec log fulLog <- getData `onNothing` return (Log False [][])
--   initState
   let lengthLog= length fulLog
   if not rec                                                     -- !> ("recovery", rec)
            then runTrans $ (do
                conn <- mconnect node                             -- !> ("connecting node ", show node)
                                                                  -- !> "wormhole local"

                liftIO $ msend conn $ SLast $ reverse fulLog      -- !> ("wh sending ", show fulLog) -- SLast will disengage  the previous wormhole/listen

                setSData $ conn{calling= True,offset= lengthLog}
                (mread conn >>= check fulLog)  <|> return ()      -- !> "MREAD local"
--                putState    !!> "PUTSTATE"
#ifdef ghcjs_HOST_OS
                addPrefix    -- for the DOM identifiers
#endif
                comp)
               <** (when (isJust moldconn) $ setSData (fromJust moldconn))
                    -- <*** is not enough

            else do

             let oldconn = fromMaybe (error "wormhole: no connection in remote node") moldconn

             if null log    -- has recovered state already

              then do
               setData $ oldconn{calling= False,offset= lengthLog}

               runTrans $ do
                  mlog <- mread oldconn
                  check  fulLog mlog           -- !> ("MREAD remote",mlog)
                  comp
                 <** do
                      setSData  oldconn
                      setSData WasRemote       -- !> " set wasremote in wormhole"

              else do   -- it is recovering a wormhole in the middle of a chain of nested wormholes
                  setData $ oldconn{calling= False,offset= lengthLog}
                  runTrans $ comp  <** setSData oldconn

  where
  -- for state recovery after a remote call.
  -- it has problems so now the state variables are forwarded to the remote host and returned back
--  initState= do
--       rstat <-liftIO $ newIORef undefined
--       setSData rstat
--       stat <- gets mfData
--       liftIO $ writeIORef rstat stat
--
--  putState = do
--        rstate <- getSData <|> error "rstate not defined" :: TransIO (IORef(M.Map TypeRep SData))
--        st <- get
--        log@(Log _ _ l) <- getSData :: TransIO Log
--        con <-getSData :: TransIO Connection
--        mfDat <- liftIO $ readIORef rstate -- !!> show ("LOG BEFORe",  l)
--        put st {mfData= mfDat}
--        setSData log
--        setSData con
--



  check fulLog mlog =
   case  mlog    of                       -- !> ("RECEIVED ", mlog ) of
             SError e -> do
                 finish $ Just e
                 empty

             SDone -> finish Nothing >> empty
             SMore log -> setSData (Log True log $ reverse log ++  fulLog ) -- !!> ("SETTING "++ show log)
             SLast log -> setSData (Log True log $ reverse log ++  fulLog ) -- !!> ("SETTING "++ show log)

#ifndef ghcjs_HOST_OS
type JSString= String
pack= id
#endif


newtype Prefix= Prefix JSString deriving(Read,Show)
newtype IdLine= IdLine JSString deriving(Read,Show)
data Repeat= Repeat | RepeatHandled JSString deriving (Eq, Read, Show)

addPrefix= Transient $ do
   r <- liftIO $ replicateM  5 (randomRIO ('a','z'))

--   n <- genId
--   Prefix s <- getData `onNothing` return ( Prefix "")
--   setSData $ Prefix (pack( 's': show n)<> s)
   setSData $ Prefix $ pack  r
   return $ Just ()




-- | teleport is a new primitive that translates computations back and forth
-- reusing an already opened connection.
teleport :: Cloud ()
teleport =  local $ Transient $ do
    conn@Connection{calling= calling,offset= n} <- getData
         `onNothing` error "teleport: No connection defined: use wormhole"
    when  (saveVars conn) $ runTrans (do
        let copyCounter= do
               r <- local $ gets mfSequence
               onAll $ modify $ \s -> s{mfSequence= r}
        runCloud $ do
            copyData $ Prefix ""
            copyData $ IdLine ""
            copyData $ Repeat
            copyCounter)  >> return ()



    Log rec log fulLog <- getData `onNothing` return (Log False [][])    -- !!> "TELEPORT"
    if not rec
      then  do
         liftIO $ msend conn $ SMore $ drop n $ reverse fulLog
                --  !!> ("TELEPORT LOCAL sending" ++ show (drop n $ reverse fulLog))
                 -- will be read by wormhole remote
         when (not calling) $ setData WasRemote  -- !> "setting WasRemote in telport"
--         getState   !!> "GETSTAT"
         return Nothing
      else do  delSData WasRemote                -- !> "deleting wasremote in teleport"

               return (Just ())                             -- !!> "TELEPORT remote"

   where
#ifndef ghcjs_HOST_OS
   saveVars Connection{connData= Just(Node2Node{})}= False
#endif
   saveVars _ = True

-- | copy session data variable from the local to the remote node.
-- The parameter is the default value if there is none set in the local node.
-- Then the default value is also set in the local node.
copyData def = do
  r <- local getSData <|> return def
  onAll $ setSData r
  return r

-- | `callTo` can stream data but can not inform the receiving process about the finalization. This call
-- does it.
streamFrom :: Loggable a => Node -> Cloud (StreamData a) -> Cloud  (StreamData a)
streamFrom = callTo



{- All the previous actions from `listen` to this statement must have been logged
streamFrom1 :: Loggable a => Node -> TransIO (StreamData a) -> TransIO  a -- (StreamData a)
streamFrom1 node remoteProc= logged $ Transient $ do
      liftIO $ print "STREAMFROM"
      Log rec log fulLog <- getData `onNothing` return (Log False [][])
      if rec
         then
          runTrans $ do
            liftIO $ print "callTo Remote executing"
            conn <- getSData  <|> error "callTo receive: no connection data"

            r <- remoteProc                  -- !> "executing remoteProc" !> "CALLTO REMOTE" -- LOg="++ show fulLog
            n <- liftIO $ msend conn  r      -- !> "sent response"
            setSData WasRemote
            stop
          <|> do
            setSData WasRemote
            stop

         else  do
            cont <- getCont
            runTrans $ process (return()) (mconnect node) (mcloseRelease cont node) $ \conn _ -> do

                liftIO $ msend conn  (SLast $ reverse fulLog)  !> "CALLTO LOCAL" -- send "++ show  log

                let log'= Wait:tail log
                setData $ Log rec log' log'
                liftIO $ print "mread in callTO"
                mread conn

      where
      mcloseRelease :: EventF -> Node -> Connection -> Maybe SomeException -> IO ()
      mcloseRelease cont node conn reason=
         case reason of
            Nothing -> release node conn
            Just r -> do
              forkIO $ mclose conn

              killChildren cont
-}
   {-
         runTrans $ do
            conn <-  mconnect  node !> "mconnect"
            onFinish $ \_ -> do
                   liftIO $ print "MCLOSE"
                   liftIO $ mclose conn
                   c <- getCont
                   liftIO $ killChildren c -- liftIO $ myThreadId >>= \th -> liftIO (print th) >> killThread th


            liftIO $ msend conn  (SLast $ reverse fulLog)  !> "CALLTO LOCAL" -- send "++ show  log

            let log'= Wait:tail log
            setData $ Log rec log' log'
            liftIO $ print "mread in callTO"
            r <- mread conn
--              adjustRecThreads h

            case r of
                 SError e -> do
                     liftIO $ do
                        release node conn
                        print e
                     stop
                 SDone ->  release node conn >> empty
                 smore@(SMore x) -> return smore
                 other ->  release node conn >> return other

-}
--      where
--      adjustRecThreads h= do
--          b <- liftIO $ hWaitForInput  h 1
--          addThreads' $ if b then 1 else 0
--          liftIO $ putStrLn $ "REC "++ show (case b of True -> "INC" ; _ -> "DEC")999999*
--
--      adjustSenderThreads n
--         | n > 2 = addThreads' (-1)  >> liftIO (putStrLn ("SEND DEC"))
--         | n==0 = addThreads' 1  >> liftIO (putStrLn ("SEND INC"))
--         | otherwise= return () >> liftIO(myThreadId >>= \th -> (putStrLn ("SEND "++ show th)))

release (Node h p rpool _) hand= liftIO $ do
--    print "RELEASED"
    atomicModifyIORef rpool $  \ hs -> (hand:hs,())
      -- !!> "RELEASED"

mclose :: Connection -> IO ()
#ifndef ghcjs_HOST_OS
mclose (Connection _  (Just (Node2Node _ h sock )) _ _ _ _ _ )= hClose h  -- !!> "Handle closed"
mclose (Connection node  (Just (Node2Web sconn )) bufSize events blocked _ _ )= NS.sendClose sconn ("closemsg" ::ByteString)
#else
mclose (Connection _ (Just (Web2Node sconn)) _ _ blocked _ _)= JavaScript.Web.WebSocket.close Nothing Nothing sconn
#endif

mconnect :: Node -> TransIO Connection
mconnect  (Node host port  pool _)=  do
    mh <- liftIO $ atomicModifyIORef pool $ \mh ->
      case mh of
       (handle:hs) -> (hs,Just handle)
       [] -> ([],Nothing)
    case mh of
      Just handle ->  return handle   -- !!>   "REUSED!"

      Nothing -> do
        Connection{comEvent= ev} <- getSData <|> error "connect: listen not set for this node"
#ifndef ghcjs_HOST_OS

        liftIO $ do
          let size=8192
          h <-  connectTo' size host port   -- !!> ("CONNECTING "++ show port)
          hSetBuffering h $ BlockBuffering $ Just size

          let conn= (defConnection 8100){comEvent= ev,connData= Just $ Node2Node u h u}
--          writeIORef pool [conn]
          return conn
#else
        do
          ws <- connectToWS host port
          let conn= (defConnection 8100){myNode=(),comEvent= ev,connData= Just $ Web2Node ws}
--          liftIO $ writeIORef pool [conn]
          return conn
#endif
  where u= undefined

mconnect _ = empty



#ifndef ghcjs_HOST_OS
connectTo' bufSize hostname (PortNumber port) =  do
        proto <- BSD.getProtocolNumber "tcp"
        bracketOnError
            (NS.socket NS.AF_INET NS.Stream proto)
            (sClose)  -- only done if there's an error
            (\sock -> do
              NS.setSocketOption sock NS.RecvBuffer bufSize
              NS.setSocketOption sock NS.SendBuffer bufSize
              he <- BSD.getHostByName hostname
              NS.connect sock (NS.SockAddrInet port (BSD.hostAddress he))

              NS.socketToHandle sock ReadWriteMode
            )
#else
connectToWS  h (PortNumber p) =
   wsOpen $ JS.pack $ "ws://"++ h++ ":"++ show p
#endif
#ifndef ghcjs_HOST_OS
-- | A connectionless version of callTo for long running remote calls
-- myNode should be set with `setMyNode`
callTo' :: (Show a, Read a,Typeable a) => Node -> Cloud a -> Cloud a
callTo' node remoteProc=  do
    mynode <-  getMyNode
    beamTo node
    r <-  remoteProc
    beamTo mynode
    return r
#endif

type Blocked= MVar ()
type BuffSize = Int
data ConnectionData=
#ifndef ghcjs_HOST_OS
                   Node2Node{port :: PortID
                              ,handle :: Handle
                              ,socket ::Socket
                                   }

                   | Node2Web{webSocket :: NS.Connection}
#else

                   Web2Node{webSocket :: WebSocket}
#endif


#ifndef ghcjs_HOST_OS
data Connection= Connection{myNode :: TVar  MyNode
#else
data Connection= Connection{myNode :: ()
#endif
                           ,connData :: (Maybe(ConnectionData))
                           ,bufferSize ::BuffSize
                           ,comEvent :: EVar Dynamic
                           ,blocked :: Blocked
                           ,calling :: Bool
                           ,offset  :: Int}
                  deriving Typeable

-- | Updates the mailbox of another node. It means that the data is transported trough the network
-- The call does not end until the mailbox entry is porcessed in the remote node.
-- Mailboxes are node-wide, for all processes that share the same connection data, that is, are under the
-- same `listen`  or `connect`
-- while EVars scope are visible for the process where they are initialized and their children.
-- Internally a mailbox is a well known EVar stored by `listen` in the `Connection` state.
sendRemoteNodeEvent :: Loggable a => Node -> a -> Cloud ()
sendRemoteNodeEvent node dat= runAt node $ local $ sendNodeEvent dat

newMailBox :: MonadIO m => m String
newMailBox= liftIO $ replicateM  10 (randomRIO ('a','z'))

putMailBox :: Typeable a => String -> a -> TransIO ()
putMailBox name dat= sendNodeEvent (name, dat)

getMailBox :: Typeable a => String -> TransIO a
getMailBox name= do
     (nam, dat) <- waitNodeEvents
     if nam /= name then empty else  return dat

-- | updates the local mailbox.
sendNodeEvent :: Typeable a => a -> TransIO ()
sendNodeEvent dat=  Transient $ do
   Connection{comEvent=comEvent}<- getData
          `onNothing` error "sendNodeEvent: accessing network events out of listen"
   (runTrans $  writeEVar comEvent $ toDyn dat)  -- !> "PUTMAILBOXX"


-- | wait until a message of the type expected appears in the mailbox. Then executes the continuation
-- When the message appears, all the waiting `waitNodeEvents` are executed from newer to the older
-- following the `readEVar` order.
waitNodeEvents :: Typeable a => TransIO a
waitNodeEvents = Transient $  do
       Connection{comEvent=comEvent} <- getData `onNothing` error "waitNodeEvents: accessing network events out of listen"
       runTrans  $ do
                     d <-  readEVar comEvent
                     case fromDynamic d of
                      Nothing -> empty
                      Just x -> do
                         writeEVar comEvent $ toDyn ()
                         return x



defConnection :: Int -> Connection

#ifndef ghcjs_HOST_OS
defConnection size=
 Connection (unsafePerformIO $  newTVarIO $ MyNode  $ createNode "invalid" 0) Nothing  size
                 (error "defConnection: accessing network events out of listen")
                 (unsafePerformIO $ newMVar ())
                 False 0
#else
defConnection size= Connection () Nothing  size
                 (error "defConnection: accessing network events out of listen")
                 (unsafePerformIO $ newMVar ())
                 False 0
#endif


#ifndef ghcjs_HOST_OS
setBuffSize :: Int -> TransIO ()
setBuffSize size= Transient $ do
   conn<- getData `onNothing` return (defConnection 8192)
   setData $ conn{bufferSize= size}
   return $ Just ()

getBuffSize=
  (do getSData >>= return . bufferSize) <|> return  8192

readHandler h= do
    line <- hGetLine h

    let [(v,left)]= readsPrec 0 line

    return  v         --  !>  line

  `catch` (\(e::SomeException) -> return $ SError   e)
--   where
--   hGetLine' h= do






--listen ::  Node ->  TransIO ()
--listen  (node@(Node _  port _ _)) = do
--   addThreads 1
--   setMyNode node
--   setSData $ Log False [] []
--
--   Connection node  _ bufSize events blocked <- getSData <|> return (defConnection 8192)
--
--   sock <- liftIO $  listenOn  port
--   liftIO $ do NS.setSocketOption sock NS.RecvBuffer bufSize
--               NS.setSocketOption sock NS.SendBuffer bufSize
--   SMore(h,host,port1) <- parallel $ (SMore <$> accept sock)
--                          `catch` (\(e::SomeException) -> do
--                               print "socket exception"
--                               sClose sock
--                               return SDone)
--
--
--   setSData $ Connection node  (Just (Node2Node port h sock )) bufSize events blocked
--
--   liftIO $  hSetBuffering h LineBuffering -- !> "LISTEN in "++ show (h,host,port1)
--
--   mlog <- parallel $ readHandler h
--
--   case  mlog  of
--         SError e -> do
--             liftIO $ do
--                hClose h
--                putStr "listen: "
--                print e
--             stop
--
--         SDone -> liftIO (hClose h) >> stop
--         SMore log -> setSData $ Log True log (reverse log)
--         SLast log -> setSData $ Log True log (reverse log)

listen ::  Node ->  Cloud ()
listen  (node@(Node _  (PortNumber port) _ _)) = onAll $ do
   addThreads 1
   setMyNode node
   setSData $ Log False [] []

   Connection node  _ bufSize events blocked _ _ <- getSData <|> return (defConnection 8192)

   sock <- liftIO . listenOn  $ PortNumber port

   liftIO $ do NS.setSocketOption sock NS.RecvBuffer bufSize
               NS.setSocketOption sock NS.SendBuffer bufSize


   (conn,_) <- waitEvents $  NS.accept sock         -- !!> "BEFORE ACCEPT"


   h <- liftIO $ NS.socketToHandle conn ReadWriteMode      -- !!> "NEW SOCKET CONNECTION"

--   let conn= Connection node  (Just (Node2Node port h sock )) bufSize events blocked
--   setSData conn
--   mlog <- mread conn

   (method,uri, headers) <- receiveHTTPHead h
--   liftIO $ print ("RECEIVED ---------->",method,uri, headers)
   mlog <- case method of
     "LOG" ->
          do
           setSData $ (Connection node  (Just (Node2Node (PortNumber port) h sock ))
                         bufSize events blocked False 0  :: Connection)
           parallel $ readHandler  h       -- !!> "read Listen"  -- :: TransIO (StreamData [LogElem])
     _ -> do
           sconn <- httpMode (method,uri, headers) conn
           setSData $ (Connection node  (Just (Node2Web sconn ))
                         bufSize events blocked False 0 :: Connection)

           parallel $ do
               msg <- WS.receiveData sconn
--               liftIO $ print ("WS RECEIVED: ", msg)
               return . read $ BC.unpack msg

   -- liftIO $ putStr "LISTEN RECEIVED " >> print mlog

   case  mlog  of
             SError e -> do
                 liftIO $ do
                    hClose h
                    putStr "listen: "
                    print e
--                 killChilds
                 c <- getCont
                 liftIO $ killChildren . fromJust $ parent c
                 empty

             SDone ->  empty -- liftIO (hClose h) >> stop
             SMore log -> setSData $ Log True log (reverse log)
             SLast log -> setSData $ Log True log (reverse log)
--   liftIO $ print "END LISTEN"



instance Read PortNumber where
  readsPrec n str= let [(n,s)]=   readsPrec n str in [(fromIntegral n,s)]


deriving instance Read PortID
deriving instance Typeable PortID
#endif


type Pool= [Connection] --  Pool{free :: [Handle], pending :: Int}
type Package= String
type Program= String
type Service= (Package, Program, Int)


-- * Level 2: connections node lists and operations with the node list


{-# NOINLINE emptyPool #-}
emptyPool :: MonadIO m => m (IORef Pool)
emptyPool= liftIO $ newIORef  []

createNode :: HostName -> Integer -> Node
createNode h p= Node h ( PortNumber $ fromInteger p) (unsafePerformIO emptyPool) []

createWebNode= WebNode  (unsafePerformIO emptyPool)

instance Eq Node where
    Node h p _ _ ==Node h' p' _ _= h==h' && p==p'
    _ == _ = False

instance Show Node where
    show (Node h p _ servs)= show (h,p,servs)
    show (WebNode _)= "webnode"

instance Read Node where
    readsPrec _ ('w':'e':'b':'n':'o':'d':'e':xs)=
          [(WebNode . unsafePerformIO $ emptyPool, xs)]
    readsPrec _ s=
          let r= readsPrec 0 s
          in case r of
            [] -> []
            [((h,p,ss),s')] ->  [(Node h p empty ss,s')]
          where
          empty= unsafePerformIO  emptyPool

newtype MyNode= MyNode Node deriving(Read,Show,Typeable)


--instance Indexable MyNode where key (MyNode Node{nodePort=port}) =  "MyNode "++ show port
--
--instance Serializable MyNode where
--    serialize= BS.pack . show
--    deserialize= read . BS.unpack

nodeList :: TVar  [Node]
nodeList = unsafePerformIO $ newTVarIO []

deriving instance Ord PortID

--myNode :: Int -> DBRef  MyNode
--myNode= getDBRef $ key $ MyNode undefined






errorMyNode f= error $ f ++ ": Node not set. Use setMynode before listen"

#ifdef ghcjs_HOST_OS
getMyNode :: Cloud ()
getMyNode= return ()

setMyNode :: Node -> TransIO ()
setMyNode node= do
        addNodes [node]
        events <- newEVar
        let conn= Connection () Nothing 8192 events (unsafePerformIO $ newMVar ()) False 0  :: Connection
        setData conn
#else

getMyNode :: Cloud Node
getMyNode = local $ do
    Connection{myNode=rnode} <- getSData <|> errorMyNode "getMyNode"
    MyNode node <- liftIO $ atomically $ readTVar rnode  -- `onNothing` errorMyNode "getMyNode"
    return node



setMyNode :: Node -> TransIO ()
setMyNode node= do
        addNodes [node]
        events <- newEVar
        rnode <- liftIO $ newTVarIO $ MyNode node
        let conn= Connection rnode Nothing 8192 events (unsafePerformIO $ newMVar ()) False 0  :: Connection
        setData conn
--        return $ Just ()
#endif

-- | return the list of nodes connected to the local node
getNodes :: MonadIO m => m [Node]
getNodes  = liftIO $ atomically $ readTVar  nodeList

addNodes :: (MonadIO m, MonadState EventF m) => [Node] -> m ()
addNodes   nodes=  do
#ifndef ghcjs_HOST_OS
  mapM_ verifyNode nodes -- if the node is a web one, add his connection
#endif
  liftIO . atomically $ do
    prevnodes <- readTVar nodeList
    writeTVar nodeList $ nub $ nodes ++ prevnodes

#ifndef ghcjs_HOST_OS
verifyNode (WebNode pool)= do
  r <- getData `onNothing` error "adding web node without connection set"
  case r of
   conn@(Connection{connData= Just( Node2Web ws)}) ->
            liftIO $ writeIORef pool [conn]
   other -> return ()

verifyNode n= return ()
#endif

shuffleNodes :: MonadIO m => m [Node]
shuffleNodes=  liftIO . atomically $ do
  nodes <- readTVar nodeList
  let nodes'= tail nodes ++ [head nodes]
  writeTVar nodeList nodes'
  return nodes'

--getInterfaces :: TransIO TransIO HostName
--getInterfaces= do
--   host <- logged $ do
--      ifs <- liftIO $ getNetworkInterfaces
--      liftIO $ mapM_ (\(i,n) ->putStrLn $ show i ++ "\t"++  show (ipv4 n) ++ "\t"++name n)$ zip [0..] ifs
--      liftIO $ putStrLn "Select one: "
--      ind <-  input ( < length ifs)
--      return $ show . ipv4 $ ifs !! ind


-- | execute a Transient action in each of the nodes connected.
--
-- The response of each node is received by the invoking node and processed by the rest of the procedure.
-- By default, each response is processed in a new thread. To restrict the number of threads
-- use the thread control primitives.
--
-- this snippet receive a message from each of the simulated nodes:
--
-- > main = keep $ do
-- >    let nodes= map createLocalNode [2000..2005]
-- >    addNodes nodes
-- >    (foldl (<|>) empty $ map listen nodes) <|> return ()
-- >
-- >    r <- clustered $ do
-- >               Connection (Just(PortNumber port, _, _, _)) _ <- getSData
-- >               return $ "hi from " ++ show port++ "\n"
-- >    liftIO $ putStrLn r
-- >    where
-- >    createLocalNode n= createNode "localhost" (PortNumber n)
clustered :: Loggable a  => Cloud a -> Cloud a
clustered proc= loggedc $ do
     nodes <-  onAll getNodes
     foldr (<|>) empty $ map (\node -> runAt node proc) nodes  -- !> ("clustered",nodes)



-- A variant of `clustered` that wait for all the responses and `mappend` them
mclustered :: (Monoid a, Loggable a)  => Cloud a -> Cloud a
mclustered proc= loggedc $ do
     nodes <-  onAll getNodes
     foldr (<>) mempty $ map (\node -> runAt node proc) nodes  -- !> ("mclustered",nodes)

-- | Initiates the transient monad, initialize it as a new node (first parameter) and connect it
-- to an existing node (second parameter).
-- The other node will notify about this connection to
-- all the nodes connected to him. this new connected node will receive the list of nodes
-- the local list of nodes then is updated with this list. it can be retrieved with `getNodes`

connect ::  Node ->  Node -> Cloud ()
connect  node  remotenode =   do
    listen node <|> return () -- listen1 node remotenode
    local $ liftIO $ putStrLn $ "connecting to: "++ show remotenode
    newnode <- local $ return node -- must pass my node to the remote node or else it will use his own

    nodes <- runAt remotenode $  do
                   mclustered $ onAll $ addNodes [newnode]
                   onAll $ do
                      liftIO $ putStrLn $ "Connected node: " ++ show node
                      getNodes

    onAll $ liftIO $ putStrLn $ "Connected to nodes: " ++ show nodes
    onAll $ addNodes nodes


--------------------------------------------


#ifndef ghcjs_HOST_OS
httpMode (method,uri, headers) conn  = do
   if isWebSocketsReq headers
     then  liftIO $ do

         stream <- makeStream                  -- !!> "WEBSOCKETS request"
            (do
                bs <- SBS.recv conn  4096
                return $ if BC.null bs then Nothing else Just bs)
            (\mbBl -> case mbBl of
                Nothing -> return ()
                Just bl ->  SBS.sendMany conn (BL.toChunks bl) >> return())   -- !!> show ("SOCK RESP",bl)

         let
             pc = WS.PendingConnection
                { WS.pendingOptions     = WS.defaultConnectionOptions
                , WS.pendingRequest     =  NS.RequestHead uri headers False -- RequestHead (BC.pack $ show uri)
                                                      -- (map parseh headers) False
                , WS.pendingOnAccept    = \_ -> return ()
                , WS.pendingStream      = stream
                }


         sconn    <- WS.acceptRequest pc               -- !!> "accept request"
         WS.forkPingThread sconn 30
         return sconn



     else do
          let uri'= BC.tail $ uriPath uri               -- !> "HTTP REQUEST"
              file= if BC.null uri' then "index.html" else uri'

          content <- liftIO $  BL.readFile ( "static/out.jsexe/"++ BC.unpack file)
                            `catch` (\(e:: SomeException) -> return "NOT FOUND")
          return ()
          n <- liftIO $ SBS.sendMany conn   $  ["HTTP/1.0 200 OK\nContent-Type: text/html\nConnection: close\nContent-Length: " <> BC.pack (show $ BL.length content) <>"\n\n"] ++
                                  (BL.toChunks content )
          return ()    -- !> "HTTP sent"
          empty

      where
      uriPath = BC.dropWhile (/= '/')



isWebSocketsReq = not  . null
    . filter ( (== mk "Sec-WebSocket-Key") . fst)



data ParseContext a = ParseContext (IO  a) a deriving Typeable


--giveData h= do
--    r <- BC.hGetLine h
--    return r !> ( "RECEIVED "++ show r)

giveData h= do

   r <- readIORef rend

   if r then return "" else do
    r<- BC.hGetLine h                    -- !!> "GETLINE"

    if r=="\r" || r == "" then do
       writeIORef rend True
       return ""
       else return r
  where
  rend= unsafePerformIO $ newIORef False


receiveHTTPHead h = do
  setSData $ ParseContext (giveData h) ""
  (method, uri, vers) <- (,,) <$> getMethod <*> getUri <*> getVers
  headers <- many $ (,) <$> (mk <$> getParam) <*> getParamValue    -- !>  (method, uri, vers)
  return (method, uri, headers)                                    -- !>  (method, uri, headers)

  where

  getMethod= getString
  getUri= getString
  getVers= getString
  getParam= do
      dropSpaces
      r <- tTakeWhile (\x -> x /= ':' && x /= '\r')
      if BC.null r || r=="\r"  then  empty  else  dropChar >> return r

  getParamValue= dropSpaces >> tTakeWhile  (/= '\r')

  dropSpaces= parse $ \str ->((),BC.dropWhile isSpace str)

  dropChar= parse  $ \r -> ((), BC.tail r)

  getString= do
    dropSpaces

    tTakeWhile (not . isSpace)

  tTakeWhile :: (Char -> Bool) -> TransIO BC.ByteString
  tTakeWhile cond= parse (BC.span cond)

  parse :: (Typeable a, Eq a, Show a, Monoid a,Monoid b) => (a -> (b,a)) -> TransIO b
  parse split= do
    ParseContext rh str <- getSData <|> error "parse: ParseContext not found"
    if  str == mempty then do
          str3 <- liftIO  rh

          setSData $ ParseContext rh str3                     -- !> str3

          if str3== mempty then empty   else  parse split

       else do

          cont <- do
             let (ret,str3) = split str
             setSData $ ParseContext rh str3
             if  str3 == mempty
                then  return $ Left ret
                else  return $ Right ret
          case cont of
            Left r  ->  (<>) <$> return r  <*> (parse split <|> return mempty)

            Right r ->   return r




#endif

#ifdef ghcjs_HOST_OS
isBrowserInstance= True

listen node = onAll $ setMyNode node
--   return () -- error "listen not implemented in browser"
#else
isBrowserInstance= False
#endif
