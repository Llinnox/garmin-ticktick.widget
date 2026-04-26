import Toybox.WatchUi;
import Toybox.Lang;

// ---------------------------------------------------------------------------
// Button mapping for Forerunner 955 Solar:
//   KEY_UP    → UP button   (upper-right)  — previous task
//   KEY_DOWN  → DOWN button (lower-right)  — next task
//   KEY_ENTER → START/STOP  (accent)       — toggle current task done/undone
//   KEY_ESC   → BACK/LAP    (lower-left)   — sync checked tasks, then exit
//
// Swipe UP/DOWN → same as KEY_UP / KEY_DOWN
// Tap focused task area → toggle (same as ENTER)
// Tap other-task row   → move cursor to that task
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
                WatchUi.popView(WatchUi.SLIDE_DOWN);
            }
            return true;
        }

        return false;
    }

    function onTap(clickEvent as WatchUi.ClickEvent) as Boolean {
        var coords = clickEvent.getCoordinates();
        _view.handleTap(coords[0], coords[1]);
        return true;
    }

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

    function onMenu() as Boolean {
        return true;
    }
}
