import Toybox.Application;
import Toybox.WatchUi;

(:typecheck(disableBackgroundCheck))
class TickTickApp extends Application.AppBase {

    private var _view as TickTickView?;

    function initialize() {
        AppBase.initialize();
    }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        _view = new TickTickView();
        var delegate = new TickTickDelegate(_view as TickTickView);
        return [_view, delegate];
    }
}
