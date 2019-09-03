module Vere.NounServ
    ( Conn(..)
    , Server(..)
    , Client(..)
    , wsServer
    , wsClient
    , testIt
    ) where

import UrbitPrelude

import qualified Network.Wai.Handler.Warp as W
import qualified Network.WebSockets       as WS

--------------------------------------------------------------------------------

data Conn i o = Conn
    { cRecv  :: STM (Maybe i)
    , cSend :: o -> STM ()
    }

mkConn :: TBMChan i -> TBMChan o -> Conn i o
mkConn inp out = Conn (readTBMChan inp) (writeTBMChan out)

--------------------------------------------------------------------------------

data Client i o = Client
    { cConn  :: Conn i o
    , cAsync :: Async ()
    }

data Server i o a = Server
    { sAccept :: STM (Maybe (Conn i o))
    , sAsync  :: Async ()
    , sData   :: a
    }

--------------------------------------------------------------------------------

wsConn :: (FromNoun i, ToNoun o, Show o, HasLogFunc e)
       => Utf8Builder
       -> TBMChan i -> TBMChan o
       -> WS.Connection
       -> RIO e ()
wsConn pre inp out wsc = do
    env <- ask
    writer <- io $ async $ runRIO env $ forever $ do
        logWarn (pre <> "(wsConn) Waiting for data.")
        byt <- io $ toStrict <$> WS.receiveData wsc
        logWarn (pre <> "Got data")
        dat <- cueBSExn byt >>= fromNounExn
        logWarn (pre <> "(wsConn) Decoded data, writing to chan")
        atomically $ writeTBMChan inp dat

    reader <- io $ async $ runRIO env $ forever $ do
        logWarn (pre <> "Waiting for data from chan")
        atomically (readTBMChan out) >>= \case
            Nothing  -> do
                logWarn (pre <> "(wsConn) Connection closed")
                error "dead-conn"
            Just msg -> do
                logWarn (pre <> "(wsConn) Got message! " <> displayShow msg)
                io $ WS.sendBinaryData wsc $ fromStrict $ jamBS $ toNoun msg

    res <- atomically (waitCatchSTM writer <|> waitCatchSTM reader)

    logWarn $ displayShow (res :: Either SomeException ())

    atomically (closeTBMChan inp >> closeTBMChan out)

    cancel writer
    cancel reader

--------------------------------------------------------------------------------

wsClient :: ∀i o e. (Show o, Show i, ToNoun o, FromNoun i, HasLogFunc e)
         => W.Port -> RIO e (Client i o)
wsClient por = do
    env <- ask
    inp <- io $ newTBMChanIO 5
    out <- io $ newTBMChanIO 5
    con <- pure (mkConn inp out)

    logDebug "(wsClie) Trying to connect"

    tid <- io $ async
              $ WS.runClient "127.0.0.1" por "/"
              $ runRIO env . wsConn "(wsClie) " inp out

    pure $ Client con tid

--------------------------------------------------------------------------------

wsServer :: ∀i o e. (Show o, Show i, ToNoun o, FromNoun i, HasLogFunc e)
         => RIO e (Server i o W.Port)
wsServer = do
    con <- io $ newTBMChanIO 5

    let app pen = do
            logError "(wsServer) Got connection! Accepting"
            wsc <- io $ WS.acceptRequest pen
            inp <- io $ newTBMChanIO 5
            out <- io $ newTBMChanIO 5
            atomically $ writeTBMChan con (mkConn inp out)
            wsConn "(wsServ) " inp out wsc

    tid <- async $ do
        env <- ask
        logError "(wsServer) Starting server"
        io $ WS.runServer "127.0.0.1" 9999 (runRIO env . app)
        logError "(wsServer) Server died"
        atomically $ closeTBMChan con

    pure $ Server (readTBMChan con) tid 9999


-- Hacky Integration Test ------------------------------------------------------

fromJust :: MonadIO m => Text -> Maybe a -> m a
fromJust err Nothing  = error (unpack err)
fromJust _   (Just x) = pure x

type Example = Maybe (Word, (), Word)

example :: Example
example = Just (99, (), 44)

testIt :: HasLogFunc e => RIO e ()
testIt = do
    logTrace "(testIt) Starting Server"
    Server{..} <- wsServer @Example @Example
    logTrace "(testIt) Connecting"
    Client{..} <- wsClient @Example @Example sData

    logTrace "(testIt) Accepting connection"
    sConn <- fromJust "accept" =<< atomically sAccept

    let
        clientSend = do
            logTrace "(testIt) Sending from client"
            atomically (cSend cConn example)
            logTrace "(testIt) Waiting for response"
            res <- atomically (cRecv sConn)
            print ("clientSend", res, example)
            unless (res == Just example) $ do
                error "Bad data"
            logInfo "(testIt) Success"

        serverSend = do
            logTrace "(testIt) Sending from server"
            atomically (cSend sConn example)
            logTrace "(testIt) Waiting for response"
            res <- atomically (cRecv cConn)
            print ("serverSend", res, example)
            unless (res == Just example) $ do
                error "Bad data"
            logInfo "(testIt) Success"

    clientSend
    clientSend
    clientSend
    serverSend
    serverSend

    cancel sAsync
    cancel cAsync
