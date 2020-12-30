{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RecursiveDo     #-}

module Flow (
  flowMain
) where
import           Relude

import           Potato.Flow
import           Potato.Flow.Controller
import           Potato.Flow.TestStates
import           Potato.Flow.Vty.Attrs
import           Potato.Flow.Vty.Canvas
import           Potato.Flow.Vty.Input
import           Potato.Flow.Vty.Layer
import           Potato.Flow.Vty.Params
import           Potato.Flow.Vty.PFWidgetCtx
import           Potato.Flow.Vty.Tools
import           Potato.Reflex.Vty.Helpers
import           Potato.Reflex.Vty.Popup
import           Potato.Reflex.Vty.Widget


import           Control.Concurrent
import           Control.Monad.Fix
import           Control.Monad.NodeId
import qualified Data.Aeson                  as Aeson
import qualified Data.Text.Encoding          as T
import qualified Data.Text.Lazy              as LT
import qualified Data.Text.Lazy.Encoding     as LT
import           Data.Time.Clock

import           Network.HTTP.Simple

import qualified Graphics.Vty                as V
import qualified Graphics.Vty.Input.Events   as V
import           Reflex
import           Reflex.Host.Class
import           Reflex.Potato.Helpers
import           Reflex.Vty


flowMain :: IO ()
flowMain = do
  mainWidget mainPFWidget

-- TODO
data MainPFTestOutput t = MainPFTestOutput {
  _mainPFTestOutput_leftPane    :: DynRegion t
  , _mainPFTestOutput_rightPane :: DynRegion t
}

{-
verifyInput :: (Reflex t, MonadHold t m) => Event t VtyEvent -> m (Event t VtyEvent)
verifyInput ev = do
  let
    foldDynMaybeFn = \case
      EvMouseDown _ _ _ _ -> Just True
      EvMouseUp _ _ _ -> Just False
      _ -> Nothing
  isMouseDownDyn <- foldDynMaybe foldDynMaybeFn False ev
  -- TODO check for invalid key presses based on mouse state
-}

fetchMOTD :: IO Text
fetchMOTD = do
  resp <- httpLBS "https://raw.githubusercontent.com/pdlla/potato-flow-vty/refactor-single/MOTD.txt"
  return $ LT.toStrict $ LT.decodeUtf8 (getResponseBody resp)

fetchMOTDAsync :: forall t m. (MonadWidget t m) => Event t () -> VtyWidget t m (Event t Text)
fetchMOTDAsync ev = performEventAsync $ ffor ev $ const $ \f -> liftIO $ do
    forkIO $ do
      motd <- fetchMOTD
      f motd
    return ()

-- NOTE, this will query welcome message each time you recreate this
welcomeWidget :: forall t m. (MonadWidget t m)
  => VtyWidget t m (Event t ())
welcomeWidget = do
  postBuildEv <- getPostBuild
  welcomeMessageEv <- fetchMOTDAsync postBuildEv
  welcomeMessageDyn <- holdDyn "loading..." welcomeMessageEv
  boxTitle (constant def) "potato" $ do
    col $ do
      fixed 10 $ text (current welcomeMessageDyn)
      fixed 3 $ textButton def (constant "bye")


mainPFWidget :: forall t m. (MonadWidget t m)
  => VtyWidget t m (Event t ())
mainPFWidget = mdo
  -- external inputs
  currentTime <- liftIO $ getCurrentTime
  tickEv <- tickLossy 1 currentTime
  ticks <- foldDyn (+) (0 :: Int) (fmap (const 1) tickEv)
  inp <- input
  postBuildEv <- getPostBuild

  let
    pfctx = PFWidgetCtx {
        _pFWidgetCtx_attr_default = constDyn lg_default
        , _pFWidgetCtx_attr_manipulator = constDyn lg_manip
        -- TODO don't do this, we need to break out individual changes instead so we can take advantage of holdUniqDyn
        , _pFWidgetCtx_pFState = fmap goatState_pFState $ _goatWidget_DEBUG_goatState everythingW
        , _pFWidgetCtx_initialPFState = pfstate_basic2
      }

    keyboardEv = fforMaybe inp $ \case
      V.EvKey k mods -> convertKey k >>= (\kbd -> return $ KeyboardData kbd (convertModifiers mods))
      V.EvPaste bs -> Just $ KeyboardData (KeyboardKey_Paste (T.decodeUtf8 bs)) []
      _ -> Nothing



  -- ::save/load file potato::
  -- TODO
  --performEvent_ $ ffor (_pfo_saved pfo) $ \spf -> do
  --  liftIO $ Aeson.encodeFile "potato.flow" spf

  --loadFileEv <- performEvent $ ffor postBuildEv $ \_ -> do
  --  liftIO $ Aeson.decodeFileStrict "potato.flow"

  let
    goatWidgetConfig = GoatWidgetConfig {
        _goatWidgetConfig_initialState = _pFWidgetCtx_initialPFState pfctx
        , _goatWidgetConfig_load = never

        -- canvas direct input
        , _goatWidgetConfig_mouse = leftmostWarn "mouse" [_layerWidget_mouse layersW, _canvasWidget_mouse canvasW]
        , _goatWidgetConfig_keyboard = never

        , _goatWidgetConfig_selectTool = _toolWidget_setTool toolsW

        -- debugging/deprecated stuff
        , _goatWidgetConfig_setDebugLabel = never
      }

  everythingW <- holdGoatWidget goatWidgetConfig


  -- main panels
  let
    leftPanel = col $ do
      fixed 5 $ debugStream [
        never
        ]
      tools' <- fixed 10 $ holdToolsWidget $  ToolWidgetConfig {
          _toolWidgetConfig_pfctx = pfctx
          , _toolWidgetConfig_tool =  _goatWidget_tool everythingW
        }

      -- TODO pass out layer mouse from here
      layers' <- stretch $ holdLayerWidget $ LayerWidgetConfig {
            _layerWidgetConfig_pfctx              = pfctx
            , _layerWidgetConfig_layers = _goatWidget_layers everythingW

            , _layerWidgetConfig_selection = _goatWidget_selection  everythingW
          }
      params' <- fixed 5 $ holdParamsWidget $ ParamsWidgetConfig {
          _paramsWidgetConfig_pfctx = pfctx
        }
      return (layers', tools', params')

    -- TODO pass out canvas mouse from here
    rightPanel = holdCanvasWidget $ CanvasWidgetConfig {
        _canvasWidgetConfig_pfctx = pfctx
        , _canvasWidgetConfig_pan = _goatWidget_pan everythingW
        , _canvasWidgetConfig_broadPhase = _goatWidget_broadPhase everythingW
        , _canvasWidgetConfig_canvas = _goatWidget_canvas everythingW
        , _canvasWidgetConfig_handles = _goatWidget_handlerRenderOutput everythingW
      }

  ((layersW, toolsW, paramsW), canvasW) <- splitHDrag 35 (fill '*') leftPanel rightPanel


  -- render various popups
  (_, popupStateDyn1) <- popupOverrideWidget 40 15 (postBuildEv $> welcomeWidget)


  -- handle escape events
  return $ fforMaybe inp $ \case
    V.EvKey (V.KChar 'c') [V.MCtrl] -> Just ()
    _ -> Nothing
