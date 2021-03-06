{-# LANGUAGE ScopedTypeVariables, OverloadedStrings #-}

-- | Library for creating Websocket servers.  Some parts cribbed from
-- Jeff Foster's blog post at
-- <http://www.fatvat.co.uk/2010/01/web-sockets-and-haskell.html>
module Network.Websocket( Config(..), ConfigRestriction(..), WS(..),
                          startServer, send ) where

    import Char (chr)
    import Control.Concurrent
    import Control.Exception hiding (catch)
    import Control.Monad
    import Data.Char (isSpace)
    import Data.Maybe
    import Data.ByteString (ByteString)
    import qualified Data.ByteString as B
    import qualified Network as N
    import qualified Network.Socket as NS
    import Network.Web.HTTP
    import Network.Web.URI
    import Network.Web.Server
    import System.IO


    data ConfigRestriction  = Any | Only [ByteString]
    restrictionValid x Any = True
    restrictionValid x (Only xs) = elem x xs
                                   
    instance Eq Status


    -- | Server configuration structure
    data Config = Config {
          -- | The port to bind to
          configPort :: Int,

          -- | The origin URL used in the handshake
          configOrigins :: ConfigRestriction,

          -- |The location URL used in the handshake. This must match
          -- the Websocket url that the browsers connect to.
          configDomains  :: ConfigRestriction,

          -- | The onopen callback, called when a socket is opened
          configOnOpen    :: WS -> IO (),

          -- | The onmessage callback, called when a message is received
          configOnMessage :: WS -> ByteString -> IO (),

          -- | The onclose callback, called when the connection is closed.
          configOnClose   :: WS -> IO ()
        }

    -- | Connection state structure
    data WS = WS {
          -- | The server's configuration
          wsConfig :: Config,

          -- | The handle of the connected socket
          wsHandle :: Handle
        }

    readFrame :: Handle -> IO ByteString
    readFrame h = readUntil h ""
        where readUntil h str =
                  do new <- B.hGet h 1
                     let newChr = B.head new
                     if newChr == 0
                        then readUntil h ""
                        else if newChr == 255
                                then return str
                                else readUntil h (B.append str new)

    sendFrame :: Handle -> ByteString -> IO ()
    sendFrame h s = do
      hPutChar h (chr 0)
      B.hPut h s
      hPutChar h (chr 255)
      hFlush h

    -- | Send a message to the connected browser.
    send ws = sendFrame (wsHandle ws)

    parseRequest req = do
      upgrade  <- lookupField (FkOther "Upgrade") req
      origin   <- lookupField (FkOther "Origin") req
      host     <- lookupField FkHost req
      hostURI  <- parseURI (B.concat ["ws://", host, "/"])
      hostAuth <- uriAuthority hostURI
      let domain = uriRegName hostAuth

      return (upgrade, origin, domain)

    doWebSocket socket f = do 
        (h :: Handle, _, _) <- N.accept socket
        forkIO $ bracket 
            (do maybeReq <- receive h
                return (h, maybeReq))

            (\(h,_) -> hClose h)

            (\(h, maybeReq) ->
                case maybeReq of
                    Nothing -> putStrLn "Got bad request"
                    Just req -> f h req)

    sendHandshake h origin location = B.hPut h handshake >> hFlush h
        where handshake = B.concat ["HTTP/1.1 101 Web Socket Protocol Handshake\r\n\
                                    \Upgrade: WebSocket\r\n\
                                    \Connection: Upgrade\r\n\
                                    \WebSocket-Origin: ", origin, "\r\n\
                                    \WebSocket-Location: ", toURL location, "\r\n\
                                    \WebSocket-Protocol: sample\r\n\r\n"]


    accept config socket =
        forever $ doWebSocket socket $ \h req -> 
            do let (upgrade, origin, hostDomain) = case parseRequest req of
                                                     Nothing -> throw (userError "Invalid request")
                                                     Just a -> a
                   location = (reqURI req) { uriScheme = "ws:" }
                   ws = WS { wsConfig = config, wsHandle = h }

               return $ assert (upgrade == "WebSocket") ()
               return $ assert (restrictionValid origin (configOrigins config)) ()
               return $ assert (restrictionValid hostDomain (configDomains config)) ()

               sendHandshake h origin location

               onOpen ws
               (forever $ do msg <- readFrame h
                             onMessage ws msg) `catch` (\e -> onClose ws)

        where onOpen    = configOnOpen config
              onMessage = configOnMessage config
              onClose   = configOnClose config


    -- | Start a websocket server
    startServer config =
        do let port = N.PortNumber $ fromIntegral (configPort config)
           bracket (N.listenOn port)
                   NS.sClose
                   (accept config)
           return ()
