import Toybox.Application;
import Toybox.Background;
import Toybox.System;
import Toybox.Time;
import Toybox.WatchUi;

(:typecheck(disableBackgroundCheck))
class TickTickApp extends Application.AppBase {

    private var _view as TickTickView?;

    function initialize() {
        AppBase.initialize();
    }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        Background.registerForTemporalEvent(new Time.Duration(3600)); // 每 1 小時
        _view = new TickTickView();
        var delegate = new TickTickDelegate(_view as TickTickView);
        return [_view, delegate];
    }

    function getServiceDelegate() as [System.ServiceDelegate] {
        return [new TickTickBackground()];
    }

    (:glance)
    function getGlanceView() as [WatchUi.GlanceView] or [WatchUi.GlanceView, WatchUi.GlanceViewDelegate] or Null {
        return [new TickTickGlanceView()];
    }
}
