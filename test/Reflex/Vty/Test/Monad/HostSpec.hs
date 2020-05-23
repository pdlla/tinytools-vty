{-# LANGUAGE RankNTypes           #-}
{-# LANGUAGE RecordWildCards      #-}
{-# LANGUAGE UndecidableInstances #-}

module Reflex.Vty.Test.Monad.HostSpec
  ( spec
  )
where

import           Prelude

import           Test.Hspec
import           Test.Hspec.Contrib.HUnit   (fromHUnitTest)
import           Test.HUnit

import           Control.Monad.IO.Class     (liftIO)
import           Data.Kind

import qualified Graphics.Vty               as V
import           Reflex
import           Reflex.Host.Class
import           Reflex.Vty
import           Reflex.Vty.Test.Monad.Host

data BasicNetworkTest1 t (m :: Type -> Type)

instance (MonadVtyApp t (TestGuestT t m), TestGuestConstraints t m) => ReflexVtyTestApp (BasicNetworkTest1 t m) t m where
  data VtyAppInputTriggerRefs (BasicNetworkTest1 t m) = BasicNetworkTest1_InputTriggerRefs
  data VtyAppInputEvents (BasicNetworkTest1 t m) = BasicNetworkTest1_InputEvents
  data VtyAppOutput (BasicNetworkTest1 t m) =
    BasicNetworkTest1_Output {
        _basicNetworkTest1_Output_vtyEv :: Event t VtyEvent 
        , _basicNetworkTest1_Output_displayWidth :: Dynamic t Int
        , _basicNetworkTest1_Output_displayHeight :: Dynamic t Int
      }
  getApp _ = do
    inp <- input
    dw <- displayWidth
    dh <- displayHeight
    return $ BasicNetworkTest1_Output inp dw dh
  makeInputs = do
    -- return dummy inputs since they are both empty
    return (BasicNetworkTest1_InputEvents, BasicNetworkTest1_InputTriggerRefs)

test_basic :: Test
test_basic = TestLabel "basic" $ TestCase $ runSpiderHost $
  runReflexVtyTestApp @ (BasicNetworkTest1 (SpiderTimeline Global) (SpiderHost Global)) (100,100) $ do
    -- get our app's output events and subscribe to them
    BasicNetworkTest1_Output {..} <- userOutputs
    vtyH                            <- subscribeEvent _basicNetworkTest1_Output_vtyEv
    dwH <- subscribeEvent $ updated _basicNetworkTest1_Output_displayWidth

    -- fire an empty event and ensure there is no output
    a1 <- fireQueuedEventsAndRead $ sequence =<< readEvent vtyH
    liftIO $ a1 @?= [Nothing]

    -- fire a vty event and ensure the output is the same as the input
    let someEvent = V.EvKey V.KEsc []
    queueVtyEvent someEvent
    a2 <- fireQueuedEventsAndRead $ sequence =<< readEvent vtyH
    liftIO $ a2 @?= [Just someEvent]

    -- resize the screen and check that the changes are reflected
    queueVtyEvent $ V.EvResize 10 10
    a3 <- fireQueuedEventsAndRead $ sequence =<< readEvent dwH
    liftIO $ a3 @?= [Just 10]



spec :: Spec
spec = do
  fromHUnitTest test_basic
