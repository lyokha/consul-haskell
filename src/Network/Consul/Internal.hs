{-# LANGUAGE OverloadedStrings #-}

module Network.Consul.Internal (
  --Key-Value Store
    deleteKey
  , getKey
  , getKeys
  , listKeys
  , putKey
  , putKeyAcquireLock
  , putKeyReleaseLock

  --Agent
  , deregisterHealthCheck
  , deregisterService
  , failHealthCheck
  , passHealthCheck
  , registerHealthCheck
  , registerService
  , warnHealthCheck

  --Health
  , getServiceChecks
  , getServiceHealth

  -- Session
  , createSession
  , destroySession
  , renewSession

  --Catalog
  , getDatacenters
  ) where

import Control.Monad.IO.Class
import Data.Aeson (decode,encode)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word
import Network.Consul.Types
import Network.HTTP.Client
import Network.Socket (PortNumber(..))

createRequest :: MonadIO m => Text -> PortNumber -> Text -> Maybe Text -> Maybe ByteString -> Bool -> Maybe Datacenter -> m Request
createRequest hostname (PortNum portNumber) endpoint query body wait dc = do
  let baseUrl = T.concat ["http://",hostname,":",T.pack $ show portNumber,endpoint,needQueryString
                         ,maybe "" id query, prefixAnd, maybe "" (\ (Datacenter x) -> T.concat["dc=",x]) dc]
  initReq <- liftIO $ parseUrl $ T.unpack baseUrl
  case body of
    Just x -> return $ indef $ initReq{ method = "PUT", requestBody = RequestBodyBS x, checkStatus = \ _ _ _ -> Nothing}
    Nothing -> return $ indef $ initReq{checkStatus = \ _ _ _ -> Nothing}
  where
    needQueryString = if isJust dc || isJust query then "?" else ""
    prefixAnd = if isJust query && isJust dc then "&" else ""
    indef req = if wait == True then req{responseTimeout = Nothing} else req

{- Key Value Store -}
getKey :: MonadIO m => Manager -> Text -> PortNumber -> Text -> Maybe Word64 -> Maybe Consistency -> Maybe Datacenter -> m (Maybe KeyValue)
getKey manager hostname portnumber key index consistency dc = do
  request <- createRequest hostname portnumber (T.concat ["/v1/kv/",key]) fquery Nothing (isJust index) dc
  liftIO $ withResponse request manager $ \ response -> do
    case responseStatus response of
      _status200 -> do
        bodyParts <- brConsume $ responseBody response
        let body = B.concat bodyParts
        return $ listToMaybe =<< (decode $ BL.fromStrict body)
      _ -> return Nothing
  where
    cons = fmap (\ x -> T.concat["consistency=", T.pack $ show x] ) consistency
    ind = fmap (\ x -> T.concat["index=", T.pack $ show x]) index
    query = T.intercalate "&" $ catMaybes [cons,ind]
    fquery = if query /= T.empty then Just query else Nothing

getKeys :: MonadIO m => Manager -> Text -> PortNumber -> Text -> Maybe Word64 -> Maybe Consistency -> Maybe Datacenter -> m [KeyValue]
getKeys manager hostname portnumber key index consistency dc = do
  request <- createRequest hostname portnumber (T.concat ["/v1/kv/",key]) fquery Nothing (isJust index) dc
  liftIO $ withResponse request manager $ \ response -> do
    case responseStatus response of
      _status200 -> do
        bodyParts <- brConsume $ responseBody response
        let body = B.concat bodyParts
        return $ maybe [] id $ decode $ BL.fromStrict body
      _ -> return []
  where
    cons = fmap (\ x -> T.concat["consistency=", T.pack $ show x] ) consistency
    ind = fmap (\ x -> T.concat["index=", T.pack $ show x]) index
    query = T.intercalate "&" $ catMaybes [cons,ind, Just "recurse"]
    fquery = if query /= T.empty then Just query else Nothing


listKeys :: MonadIO m => Manager -> Text -> PortNumber -> Text -> Maybe Word64 -> Maybe Consistency -> Maybe Datacenter -> m [Text]
listKeys manager hostname portNumber prefix index consistency dc = do
  initReq <- createRequest hostname portNumber (T.concat ["/v1/kv/", prefix]) fquery Nothing (isJust index) dc
  liftIO $ withResponse initReq manager $ \ response ->
    case responseStatus response of
      _status200 -> do
        bodyParts <- brConsume $ responseBody response
        let body = B.concat bodyParts
        return $ maybe [] id $ decode $ BL.fromStrict body
      _ -> return []
  where
    cons = fmap (\ x -> T.concat["consistency=", T.pack $ show x] ) consistency
    ind = fmap (\ x -> T.concat["index=", T.pack $ show x]) index
    query = T.intercalate "&" $ catMaybes [cons,ind, Just "keys"]
    fquery = if query /= T.empty then Just query else Nothing

putKey :: MonadIO m => Manager -> Text -> PortNumber -> KeyValuePut -> Maybe Datacenter -> m Bool
putKey manager hostname portNumber request dc = do
  initReq <- createRequest hostname portNumber (T.concat ["/v1/kv/", kvpKey request]) fquery (Just $ kvpValue request) False dc
  liftIO $ withResponse initReq manager $ \ response -> do
    bodyParts <- brConsume $ responseBody response
    let body = B.concat bodyParts
    case TE.decodeUtf8 body of
      "true" -> return True
      "false" -> return False
      _ -> return False
  where
    flags = fmap (\ x -> T.concat["flags=", T.pack $ show x]) $ kvpFlags request
    cas = fmap (\ x -> T.concat["cas=",T.pack $ show x]) $ kvpCasIndex request
    query = T.intercalate "&" $ catMaybes [flags,cas]
    fquery = if query /= T.empty then Just query else Nothing

putKeyAcquireLock :: MonadIO m => Manager -> Text -> PortNumber -> KeyValuePut -> Session -> Maybe Datacenter -> m Bool
putKeyAcquireLock manager hostname portNumber request (Session session _) dc = do
  initReq <- createRequest hostname portNumber (T.concat ["/v1/kv/", kvpKey request]) fquery (Just $ kvpValue request) False dc
  liftIO $ withResponse initReq manager $ \ response -> do
    bodyParts <- brConsume $ responseBody response
    let body = B.concat bodyParts
    case TE.decodeUtf8 body of
      "true" -> return True
      "false" -> return False
      _ -> return False
  where
    flags = fmap (\ x -> T.concat["flags=", T.pack $ show x]) $ kvpFlags request
    cas = fmap (\ x -> T.concat["cas=",T.pack $ show x]) $ kvpCasIndex request
    acquire = T.concat["acquire=",session]
    query = T.intercalate "&" $ catMaybes [flags,cas,Just acquire]
    fquery = if query /= T.empty then Just query else Nothing

putKeyReleaseLock :: MonadIO m => Manager -> Text -> PortNumber -> KeyValuePut -> Session -> Maybe Datacenter -> m Bool
putKeyReleaseLock manager hostname portNumber request (Session session _) dc = do
  initReq <- createRequest hostname portNumber (T.concat ["/v1/kv/", kvpKey request]) fquery (Just $ kvpValue request) False dc
  liftIO $ withResponse initReq manager $ \ response -> do
    bodyParts <- brConsume $ responseBody response
    let body = B.concat bodyParts
    case TE.decodeUtf8 body of
      "true" -> return True
      "false" -> return False
      _ -> return False
  where
    flags = fmap (\ x -> T.concat["flags=", T.pack $ show x]) $ kvpFlags request
    cas = fmap (\ x -> T.concat["cas=",T.pack $ show x]) $ kvpCasIndex request
    release = T.concat["release=",session]
    query = T.intercalate "&" $ catMaybes [flags,cas,Just release]
    fquery = if query /= T.empty then Just query else Nothing

deleteKey :: MonadIO m => Manager -> Text -> PortNumber -> Text -> Bool -> Maybe Datacenter -> m ()
deleteKey manager hostname portNumber key recurse dc = do
  initReq <- createRequest hostname portNumber (T.concat ["/v1/kv/", key]) (if recurse then Just "recurse" else Nothing) Nothing False dc
  let httpReq = initReq { method = "DELETE"}
  liftIO $ withResponse httpReq manager $ \ response -> do
    _bodyParts <- brConsume $ responseBody response
    return ()

{- Agent -}
{-getHealthChecks :: MonadIO m => Manager -> Text -> PortNumber -> Maybe Datacenter -> m [Check]
getHealthChecks  manager hostname portNumber dc = do
  request <- createRequest hostname portNumber "/agent/checks" Nothing Nothing False dc
 -}

registerHealthCheck :: MonadIO m => Manager -> Text -> PortNumber -> RegisterHealthCheck -> m ()
registerHealthCheck manager hostname (PortNum portNumber) request = do
  initReq <- liftIO $ parseUrl $ T.unpack $ T.concat ["http://",hostname, ":", T.pack $ show portNumber ,"/v1/agent/check/register"]
  let httpReq = initReq { method = "PUT", requestBody = RequestBodyBS $ BL.toStrict $ encode request}
  liftIO $ withResponse httpReq manager $ \ response -> do
    _bodyParts <- brConsume $ responseBody response
    return ()

deregisterHealthCheck :: MonadIO m => Manager -> Text -> PortNumber -> Text -> m ()
deregisterHealthCheck manager hostname (PortNum portNumber) checkId = do
  initReq <- liftIO $ parseUrl $ T.unpack $ T.concat ["http://",hostname, ":", T.pack $ show portNumber ,"/v1/agent/check/deregister/", checkId]
  liftIO $ withResponse initReq manager $ \ response -> do
    _bodyParts <- brConsume $ responseBody response
    return ()


passHealthCheck :: MonadIO m => Manager -> Text -> PortNumber -> Text -> m ()
passHealthCheck manager hostname (PortNum portNumber) checkId = do
  initReq <- liftIO $ parseUrl $ T.unpack $ T.concat ["http://",hostname, ":", T.pack $ show portNumber ,"/v1/agent/check/pass/", checkId]
  liftIO $ withResponse initReq manager $ \ response -> do
    _bodyParts <- brConsume $ responseBody response
    return ()

warnHealthCheck :: MonadIO m => Manager -> Text -> PortNumber -> Text -> m ()
warnHealthCheck manager hostname (PortNum portNumber) checkId = do
  initReq <- liftIO $ parseUrl $ T.unpack $ T.concat ["http://",hostname, ":", T.pack $ show portNumber ,"/v1/agent/check/warn/", checkId]
  liftIO $ withResponse initReq manager $ \ response -> do
    _bodyParts <- brConsume $ responseBody response
    return ()

failHealthCheck :: MonadIO m => Manager -> Text -> PortNumber -> Text -> m ()
failHealthCheck manager hostname (PortNum portNumber) checkId = do
  initReq <- liftIO $ parseUrl $ T.unpack $ T.concat ["http://",hostname, ":", T.pack $ show portNumber ,"/v1/agent/check/fail/", checkId]
  liftIO $ withResponse initReq manager $ \ response -> do
    _bodyParts <- brConsume $ responseBody response
    return ()

registerService :: MonadIO m => Manager -> Text -> PortNumber -> RegisterService -> m ()
registerService manager hostname (PortNum portNumber) request = do
  initReq <- liftIO $ parseUrl $ T.unpack $ T.concat ["http://",hostname, ":", T.pack $ show portNumber ,"/v1/agent/service/register"]
  let httpReq = initReq { method = "PUT", requestBody = RequestBodyBS $ BL.toStrict $ encode request}
  liftIO $ withResponse httpReq manager $ \ response -> do
    _bodyParts <- brConsume $ responseBody response
    return ()

deregisterService :: MonadIO m => Manager -> Text -> PortNumber -> Text -> m ()
deregisterService manager hostname (PortNum portNumber) service = do
  initReq <- liftIO $ parseUrl $ T.unpack $ T.concat ["http://",hostname, ":", T.pack $ show portNumber ,"/v1/agent/service/deregister/", service]
  liftIO $ withResponse initReq manager $ \ response -> do
    _bodyParts <- brConsume $ responseBody response
    return ()


{- Health -}
getServiceChecks :: MonadIO m => Manager -> Text -> PortNumber -> Text -> m [Check]
getServiceChecks manager hostname (PortNum portNumber) name = do
  initReq <- liftIO $ parseUrl $ T.unpack $ T.concat ["http://",hostname, ":", T.pack $ show portNumber ,"/v1/health/checks/", name]
  liftIO $ withResponse initReq manager $ \ response -> do
    bodyParts <- brConsume $ responseBody response
    let body = B.concat bodyParts
    return $ maybe [] id (decode $ BL.fromStrict body)

getServiceHealth :: MonadIO m => Manager -> Text -> PortNumber -> Text -> m (Maybe Health)
getServiceHealth manager hostname (PortNum portNumber) name = do
  initReq <- liftIO $ parseUrl $ T.unpack $ T.concat ["http://",hostname, ":", T.pack $ show portNumber ,"/v1/health/service/", name]
  liftIO $ withResponse initReq manager $ \ response -> do
    bodyParts <- brConsume $ responseBody response
    let body = B.concat bodyParts
    return $ decode $ BL.fromStrict body

{- Session -}
createSession :: MonadIO m => Manager -> Text -> PortNumber -> SessionRequest -> Maybe Datacenter -> m (Maybe Session)
createSession manager hostname portNumber request dc = do
  initReq <- createRequest hostname portNumber "/v1/session/create" Nothing (Just $ BL.toStrict $ encode request) False dc
  liftIO $ withResponse initReq manager $ \ response -> do
    case responseStatus response of
      status200 -> do
        bodyParts <- brConsume $ responseBody response
        return $ decode $ BL.fromStrict $ B.concat bodyParts
      _ -> return Nothing

destroySession :: MonadIO m => Manager -> Text -> PortNumber -> Session -> Maybe Datacenter -> m ()
destroySession manager hostname portNumber (Session session _) dc = do
  initReq <- createRequest hostname portNumber (T.concat ["/v1/session/destroy/", session]) Nothing Nothing False dc
  liftIO $ withResponse initReq manager $ \ response -> do
    return ()

renewSession :: MonadIO m => Manager -> Text -> PortNumber -> Session -> Maybe Datacenter -> m Bool
renewSession manager hostname portNumber (Session session _) dc = do
  initReq <- createRequest hostname portNumber (T.concat ["/v1/session/renew/", session]) Nothing Nothing False dc
  liftIO $ withResponse initReq manager $ \ response -> do
    case responseStatus response of
      status200 -> return True
      _ -> return False

{- Catalog -}
getDatacenters :: MonadIO m => Manager -> Text -> PortNumber -> m [Datacenter]
getDatacenters manager hostname (PortNum portNumber) = liftIO $ do
  initReq <- parseUrl $ T.unpack $ T.concat ["http://",hostname, ":", T.pack $ show portNumber ,"/v1/catalog/datacenters/"]
  withResponse initReq manager $ \ response -> do
    bodyParts <- brConsume $ responseBody response
    let body = B.concat bodyParts
    let val = (decode $ BL.fromStrict body)
    case val of
      Just x -> return x
      Nothing -> return []

