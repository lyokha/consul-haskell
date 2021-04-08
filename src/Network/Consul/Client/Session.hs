{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | TODO: document module
module Network.Consul.Client.Session
  ( createSession
  , destroySession
  , getSessionInfo
  , renewSession
  , withSession
  ) where

import Control.Concurrent hiding (killThread)
import Control.Monad (forever)
import Control.Monad.IO.Class
import Control.Monad.Catch (MonadMask)
import Control.Retry
import Data.Aeson (Value(..), decode,encode)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.HashMap.Strict as H
import Data.Maybe (catMaybes, isJust, listToMaybe)
import Data.Monoid ((<>))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as TR
import Data.Word
import qualified Data.Vector as V
import qualified Network.Consul.Internal as I
import Network.Consul.Types
import Network.HTTP.Client -- (method, Manager, responseBody)
import Network.HTTP.Client.TLS (newTlsManager, newTlsManagerWith, tlsManagerSettings)
import Network.HTTP.Types
import Network.Socket (PortNumber)
import UnliftIO (MonadUnliftIO, async, cancel, finally, wait, waitAnyCancel, withAsync)

import Network.Consul.Internal

-- | TODO: Document
createSession :: MonadIO m => ConsulClient -> SessionRequest -> m (Maybe Session)
createSession client@ConsulClient{..} request = do
  let hostnameWithScheme = hostWithScheme client
  initReq <- createRequest hostnameWithScheme
                           ccPort
                           "/v1/session/create"
                           noQuery
                           (Just $ BL.toStrict $ encode request)
                           waitFalse
                           ccDatacenter
  liftIO $ withResponse initReq ccManager $ \ response -> do
    case responseStatus response of
      x | x == status200 -> do
        bodyParts <- brConsume $ responseBody response
        return $ decode $ BL.fromStrict $ B.concat bodyParts
      _ -> return Nothing


-- | TODO: Document
destroySession :: MonadIO m => ConsulClient -> Session ->  m ()
destroySession client@ConsulClient{..} (Session session _) = do
  let hostnameWithScheme = hostWithScheme client
  initReq <- createRequest hostnameWithScheme
                           ccPort
                           (T.concat ["/v1/session/destroy/", session])
                           Nothing
                           Nothing
                           False
                           ccDatacenter
  let req = initReq{method = "PUT"}
  liftIO $ withResponse req ccManager $ \ _response -> return ()


-- | TODO: Document
renewSession :: MonadIO m => ConsulClient -> Session ->  m Bool
renewSession client@ConsulClient{..} (Session session _) =  do
  let hostnameWithScheme = hostWithScheme client
  initReq <- createRequest hostnameWithScheme
                           ccPort
                           (T.concat ["/v1/session/renew/", session])
                           Nothing
                           Nothing
                           False
                           ccDatacenter
  let req = initReq{method = "PUT"}
  liftIO $ withResponse req ccManager $ \ response -> do
    case responseStatus response of
      x | x == status200 -> return True
      _ -> return False


-- | TODO: Document
getSessionInfo :: MonadIO m => ConsulClient -> Session ->  m (Maybe [SessionInfo])
getSessionInfo client@ConsulClient{..} (Session sessionId _) = do
  let hostnameWithScheme = hostWithScheme client
  req <- createRequest hostnameWithScheme
                       ccPort
                       (T.concat ["/v1/session/info/",sessionId])
                       noQuery
                       noRequestBody
                       waitFalse
                       ccDatacenter
  liftIO $ withResponse req ccManager $ \ response -> do
    case responseStatus response of
      x | x == status200 -> do
        bodyParts <- brConsume $ responseBody response
        return $ decode $ BL.fromStrict $ B.concat bodyParts
      _ -> return Nothing


-- | TODO: Document
-- TODO: use `name` in function?
withSession :: forall m a. (MonadMask m, MonadUnliftIO m) => ConsulClient -> Maybe Text -> Int -> Session -> (Session -> m a) -> m a -> m a
withSession client@ConsulClient{..} name delay session action lostAction = (do
  withAsync (action session) $ \ mainAsync -> withAsync extendSession $ \ extendAsync -> do
    result :: a <- return . snd =<< waitAnyCancel [mainAsync,extendAsync]
    return result) `finally` (destroySession client session)
  where
    extendSession :: m a
    extendSession = do
      liftIO $ threadDelay $ (delay * 1000000)
      x <- renewSession client session
      case x of
        True -> extendSession
        False -> lostAction
