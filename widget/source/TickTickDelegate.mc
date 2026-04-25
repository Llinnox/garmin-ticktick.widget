import Toybox.WatchUi;
import Toybox.Lang;

// ---------------------------------------------------------------------------
// Button mapping for Forerunner 955 Solar:
//   KEY_UP    → UP physical button   (middle-right)
//   KEY_DOWN  → DOWN physical button (lower-right)
//   KEY_ENTER → START/STOP button    (bottom-right accent)
//   KEY_ESC   → BACK/LAP button      (bottom-left)
// ---------------------------------------------------------------------------

class TickTickDelegate extends WatchUi.BehaviorDelegate {

    private var _view as TickTickView;

    function initialize(view as TickTickView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onKey(event as WatchUi.KeyEvent) as Boolean {
        var key = event.getKey();

        if (key == WatchUi.KEY_UP) {
            _view.handleUp();
            return true;
        }

        if (key == WatchUi.KEY_DOWN) {
            _view.handleDown();
            return true;
        }

        if (key == WatchUi.KEY_ENTER) {
            _view.handleEnter();
            return true;
        }

        if (key == WatchUi.KEY_ESC) {
            if (_view.handleBack()) {
                // Not consumed by view → exit widget
                WatchUi.popView(WatchUi.SLIDE_DOWN);
            }
            return true;
        }

        return false;
    }

    // Tap gesture (touchscreen)
    function onTap(clickEvent as WatchUi.ClickEvent) as Boolean {
        var coords = clickEvent.getCoordinates();
        _view.handleTap(coords[1]);
        return true;
    }

    // Swipe gestures (optional, touchscreen support)
    function onSwipe(swipeEvent as WatchUi.SwipeEvent) as Boolean {
        var dir = swipeEvent.getDirection();
        if (dir == WatchUi.SWIPE_UP) {
            _view.handleUp();
            return true;
        }
        if (dir == WatchUi.SWIPE_DOWN) {
            _view.handleDown();
            return true;
        }
        return false;
    }

    // Menu button (if long-pressing UP) – force refresh
    function onMenu() as Boolean {
        _view.fetchTasks();
        return true;
    }
}
