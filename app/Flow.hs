{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RecursiveDo     #-}

module Flow (
  flowMain
) where
import           Relude

import           Potato.Flow
import           Potato.Flow.Reflex.Vty.Attrs
import           Potato.Flow.Reflex.Vty.Canvas
import           Potato.Flow.Reflex.Vty.Layer
import           Potato.Flow.Reflex.Vty.Manipulator
import           Potato.Flow.Reflex.Vty.Params
import           Potato.Flow.Reflex.Vty.PFWidgetCtx
import           Potato.Flow.Reflex.Vty.Selection
import           Potato.Flow.Reflex.Vty.Tools
import           Potato.Reflex.Vty.Helpers
import           Potato.Reflex.Vty.Widget


import           Control.Monad.Fix
import           Control.Monad.NodeId
import           Data.Time.Clock

import qualified Graphics.Vty                       as V
import           Reflex
import           Reflex.Potato.Helpers
import           Reflex.Vty


flowMain :: IO ()
flowMain = mainWidget mainPFWidget


mainPFWidget :: forall t m. (Reflex t, MonadHold t m, MonadFix m, NotReady t m, Adjustable t m, PostBuild t m, PerformEvent t m, TriggerEvent t m, MonadNodeId m, MonadIO (Performable m), MonadIO m)
  => VtyWidget t m (Event t ())
mainPFWidget = mdo
  -- external inputs
  currentTime <- liftIO $ getCurrentTime
  tickEv <- tickLossy 1 currentTime
  ticks <- foldDyn (+) (0 :: Int) (fmap (const 1) tickEv)
  inp <- input

  let
    pfctx = PFWidgetCtx {
        _pFWidgetCtx_attr_default = constDyn lg_default
        , _pFWidgetCtx_attr_manipulator = constDyn lg_manip
        , _pFWidgetCtx_ev_cancel        = fforMaybe inp $ \case
          V.EvKey (V.KEsc) [] -> Just ()
          _ -> Nothing
        , _pFWidgetCtx_ev_input = inp
        , _pFWidgetCtx_pfo = pfo
      }

  -- potato flow stuff
  let
    -- TODO disable when manipulating _canvasWidget_isManipulating
    undoEv = fforMaybe inp $ \case
      V.EvKey (V.KChar 'z') [V.MCtrl] -> Just ()
      _ -> Nothing
    redoEv = fforMaybe inp $ \case
      V.EvKey (V.KChar 'y') [V.MCtrl] -> Just ()
      _ -> Nothing

    pfc = PFConfig {
        _pfc_addElt     = doNewElt
        , _pfc_removeElt  = never
        , _pfc_manipulate = doManipulate
        , _pfc_undo       = leftmost [undoEv, undoBeforeManipulate, undoBeforeNewAdd]
        , _pfc_redo       = redoEv
        , _pfc_save = never
        , _pfc_load = never
        , _pfc_resizeCanvas = never
        , _pfc_addFolder = never
      }
  pfo <- holdPF pfc

  -- ::selection stuff::
  selectionManager <- holdSelectionManager
    SelectionManagerConfig {
      _selectionManagerConfig_pfctx = pfctx
      , _selectionManagerConfig_newElt_layerPos = doNewElt
      , _selectionManagerConfig_sEltLayerTree = _pfo_layers pfo
      , _selectionManagerConfig_select = never
    }

  -- main panels
  let
    leftPanel = col $ do
      fixed 5 $ debugStream [
        never
        , fmapLabelShow "undo" $ _canvasWidget_addSEltLabel canvasW
        --, fmapLabelShow "input" inp
        --, fmapLabelShow "tool" (_toolWidget_tool tools)
        --, fmapLabelShow "canvas size" $ updated . _canvas_box $ _pfo_canvas pfo
        --, fmapLabelShow "render" $ fmap fst3 (_broadPhase_render broadPhase)
        --, fmapLabelShow "change" $ fmap (fmap snd) $ _sEltLayerTree_changeView (_pfo_layers pfo)
        ]
      tools' <- fixed 3 $ holdToolsWidget $  ToolWidgetConfig {
          _toolWidgetConfig_pfctx = pfctx
          -- TODO hook up to new elt created I guess
          , _toolWidgetConfig_setDefault = never
        }

      layers' <- stretch $ holdLayerWidget $ LayerWidgetConfig {
            _layerWidgetConfig_pfctx              = pfctx
            -- TODO fix or delete
            , _layerWidgetConfig_temp_sEltTree    = constDyn []
            , _layerWidgetConfig_selectionManager = selectionManager
          }
      params' <- fixed 5 $ holdParamsWidget $ ParamsWidgetConfig {
          _paramsWidgetConfig_pfctx = pfctx
        }
      return (layers', tools', params')

    rightPanel = holdCanvasWidget $ CanvasWidgetConfig {
        _canvasWidgetConfig_pfctx = pfctx
        , _canvasWidgetConfig_tool = (_toolWidget_tool tools)
        , _canvasWidgetConfig_pfo = pfo
        , _canvasWidgetConfig_selectionManager = selectionManager
      }

  ((layersW, tools, _), canvasW) <- splitHDrag 35 (fill '*') leftPanel rightPanel

  -- prep newAdd event
  -- MANY FRAMES
  let
    undoBeforeNewAdd = fmapMaybe (\x -> if fst x then Just () else Nothing) $ _canvasWidget_addSEltLabel canvasW
    doNewElt' = fmap snd $ _canvasWidget_addSEltLabel canvasW
  doNewElt <- sequenceEvents undoBeforeNewAdd doNewElt'


  -- prep manipulate event
  -- MANY FRAMES via ManipulatorWidget (ok, as undo manipulation currently is 1 frame in potato-flow, and the previous operation to undo is always a manipulate operation)
  let
    undoBeforeManipulate = fmapMaybe (\x -> if fst x then Just () else Nothing) $ _canvasWidget_modify canvasW
    doManipulate' = fmap snd $ _canvasWidget_modify canvasW
  doManipulate <- sequenceEvents undoBeforeManipulate doManipulate'

  -- handle escape events
  return $ fforMaybe inp $ \case
    V.EvKey (V.KChar 'c') [V.MCtrl] -> Just ()
    _ -> Nothing
