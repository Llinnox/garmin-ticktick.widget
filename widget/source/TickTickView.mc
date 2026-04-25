import Toybox.Application;
import Toybox.Graphics;
import Toybox.WatchUi;
import Toybox.Communications;
import Toybox.Timer;
import Toybox.Lang;
import Toybox.PersistedContent;
import Toybox.System;

// ---------------------------------------------------------------------------
// State machine:
//   ST_LOADING  → waiting for HTTP
//   ST_LIST     → browsing; UP/DOWN scroll, ENTER selects
//   ST_SELECTED → UP=complete, DOWN=postpone, BACK=cancel
//   ST_CONFIRM  → 2-second confirmation, then refresh
//   ST_ERROR    → network/server error
// ---------------------------------------------------------------------------

class TickTickView extends WatchUi.View {

    // ngrok HTTPS URL — update after each ngrok restart
    private const SERVER     = "https://flyover-zipping-hurler.ngrok-free.dev";
    private const VISIBLE    = 4;
    private const CONFIRM_MS = 2000;

    // Marquee
    private const SCROLL_STEP    = 2;   // px per tick (forward)
    private const SCROLL_MS      = 33;  // timer interval ms (~30 Hz)
    private const SCROLL_PAUSE_S = 54;  // ticks at start  → 54 × 33ms ≈ 1.8s
    private const SCROLL_PAUSE_E = 36;  // ticks at end    → 36 × 33ms ≈ 1.2s

    // Marquee scroll sub-states
    private const SS_PAUSE_START = 0;
    private const SS_FORWARD     = 1;
    private const SS_PAUSE_END   = 2;
    private const SS_BACK        = 3;
    private const SS_DONE        = 4;  // one loop finished, wait for user action

    // States
    private const ST_LOADING  = 0;
    private const ST_LIST     = 1;
    private const ST_SELECTED = 2;
    private const ST_CONFIRM  = 3;
    private const ST_ERROR    = 4;

    // Runtime state
    private var _state   as Number = ST_LOADING;
    private var _tasks   as Array  = [];
    private var _offset  as Number = 0;
    private var _cursor  as Number = 0;
    private var _msg     as String = "";
    private var _timer   as Timer.Timer? = null;
    private var _cjkFont   as WatchUi.FontResource? = null;
    private var _charMap   as Dictionary? = null;
    private var _checked      as Dictionary = {};
    private var _listY        as Number = 0;
    private var _rowH         as Number = 0;
    private var _lastTapRow   as Number = -1;
    private var _lastTapTime  as Number = 0;

    // Marquee scroll state
    private var _scrollPx    as Number = 0;
    private var _scrollState as Number = 0;  // 0=pause, 1=forward, 2=back
    private var _scrollMax   as Number = 0;
    private var _scrollCount as Number = 0;
    private var _scrollTimer as Timer.Timer? = null;

    // Sync-on-exit state
    private var _syncIds   as Array   = [];
    private var _syncIdx   as Number  = 0;
    private var _isSyncing as Boolean = false;

    function initialize() {
        View.initialize();
    }

    function onLayout(dc as Graphics.Dc) as Void {
        _cjkFont = Application.loadResource(Rez.Fonts.CJKFont) as WatchUi.FontResource;
        _charMap = Application.loadResource(Rez.JsonData.charMap) as Dictionary;
    }

    // Convert a string to renderable form using charMap (each char → chr(index))
    private function toMapped(text as String) as String {
        var out = "";
        var chars = text.toCharArray();
        for (var i = 0; i < chars.size(); i++) {
            var code = chars[i].toNumber();
            var idx = (_charMap as Dictionary).get(code.toString());
            if (idx != null) {
                out = out + (idx as Number).toChar().toString();
            } else {
                out = out + "?";
            }
        }
        return out;
    }

    function onShow() as Void {
        fetchTasks();
        _scrollTimer = new Timer.Timer();
        _scrollTimer.start(method(:onScrollTick), SCROLL_MS, true);
    }

    function onHide() as Void {
        if (_scrollTimer != null) {
            _scrollTimer.stop();
            _scrollTimer = null;
        }
    }

    // Reset marquee to initial state (call on cursor change)
    private function resetScroll() as Void {
        _scrollPx    = 0;
        _scrollMax   = 0;
        _scrollState = 0;
        _scrollCount = 0;
    }

    // Marquee timer callback — drives text scrolling (one-shot loop)
    function onScrollTick() as Void {
        if (_state != ST_LIST || _scrollMax == 0) { return; }
        if (_scrollState == SS_DONE) { return; }

        if (_scrollState == SS_PAUSE_START) {
            _scrollCount++;
            if (_scrollCount >= SCROLL_PAUSE_S) {
                _scrollState = SS_FORWARD;
                _scrollCount = 0;
            }
            return;

        } else if (_scrollState == SS_FORWARD) {
            _scrollPx += SCROLL_STEP;
            if (_scrollPx >= _scrollMax) {
                _scrollPx = _scrollMax;
                _scrollState = SS_PAUSE_END;
                _scrollCount = 0;
            }

        } else if (_scrollState == SS_PAUSE_END) {
            _scrollCount++;
            if (_scrollCount >= SCROLL_PAUSE_E) {
                _scrollState = SS_BACK;
                _scrollCount = 0;
            }
            return;

        } else if (_scrollState == SS_BACK) {
            // Ease-out: step = scrollPx/3, minimum 1px → converges in ~12 ticks (~0.4s)
            var step = _scrollPx / 3;
            if (step < 1) { step = 1; }
            _scrollPx -= step;
            if (_scrollPx <= 0) {
                _scrollPx = 0;
                _scrollState = SS_DONE;  // stop here; resetScroll() restarts on next user action
                WatchUi.requestUpdate();
                return;
            }
        }

        WatchUi.requestUpdate();
    }

    // -----------------------------------------------------------------------
    // HTTP
    // -----------------------------------------------------------------------

    function fetchTasks() as Void {
        _state = ST_LOADING;
        WatchUi.requestUpdate();
        Communications.makeWebRequest(
            SERVER + "/tasks",
            null,
            {
                :method       => Communications.HTTP_REQUEST_METHOD_GET,
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
                :headers      => { "ngrok-skip-browser-warning" => "1" }
            },
            method(:onTasksReceived)
        );
    }

    function onTasksReceived(code as Number, raw as Dictionary or String or PersistedContent.Iterator or Null) as Void {
        if (code == 200 && raw instanceof Dictionary) {
            var list = (raw as Dictionary)["data"];
            _tasks  = (list != null) ? list as Array : [];
            _offset = 0;
            _cursor = 0;
            _state  = ST_LIST;
            resetScroll();
        } else {
            _msg   = "Error: " + code.toString();
            _state = ST_ERROR;
        }
        WatchUi.requestUpdate();
    }

    private function postAction(path as String, confirmMsg as String) as Void {
        _msg   = confirmMsg;
        _state = ST_CONFIRM;
        WatchUi.requestUpdate();
        Communications.makeWebRequest(
            SERVER + path,
            null,
            {
                :method       => Communications.HTTP_REQUEST_METHOD_POST,
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
                :headers      => { "ngrok-skip-browser-warning" => "1" }
            },
            method(:onActionReceived)
        );
        _timer = new Timer.Timer();
        _timer.start(method(:onTimerExpired), CONFIRM_MS, false);
    }

    function onActionReceived(code as Number, raw as Dictionary or String or PersistedContent.Iterator or Null) as Void {
    }

    function onTimerExpired() as Void {
        _timer = null;
        fetchTasks();
    }

    // -----------------------------------------------------------------------
    // Input (called by TickTickDelegate)
    // -----------------------------------------------------------------------

    function handleUp() as Void {
        if (_state == ST_LIST) {
            if (_cursor > 0) { _cursor--; }
            else if (_offset > 0) { _offset--; }
            resetScroll();
            WatchUi.requestUpdate();
        }
    }

    function handleDown() as Void {
        if (_state == ST_LIST) {
            var absIdx = _offset + _cursor;
            if (absIdx < _tasks.size() - 1) {
                if (_cursor < VISIBLE - 1) { _cursor++; }
                else { _offset++; }
            }
            resetScroll();
            WatchUi.requestUpdate();
        }
    }

    function handleEnter() as Void {
        if (_state == ST_LIST && _tasks.size() > 0) {
            var task = _tasks[_offset + _cursor] as Dictionary;
            var id = task["id"] as String;
            if (_checked.get(id) != null) {
                _checked.remove(id);
            } else {
                _checked.put(id, true);
            }
            WatchUi.requestUpdate();
        }
    }

    function handleBack() as Boolean {
        if (_isSyncing) { return false; }

        var ids = _checked.keys();
        if (ids.size() == 0) {
            return true;  // 沒有勾選，直接退出
        }

        // 有勾選任務 → 依序 POST /complete，全部完成後再退出
        _syncIds   = ids;
        _syncIdx   = 0;
        _isSyncing = true;
        _msg       = "Syncing...";
        _state     = ST_CONFIRM;
        WatchUi.requestUpdate();
        postNextComplete();
        return false;
    }

    private function postNextComplete() as Void {
        if (_syncIdx >= _syncIds.size()) {
            WatchUi.popView(WatchUi.SLIDE_DOWN);
            return;
        }
        var taskId = _syncIds[_syncIdx] as String;
        _syncIdx++;
        Communications.makeWebRequest(
            SERVER + "/complete/" + taskId,
            null,
            {
                :method       => Communications.HTTP_REQUEST_METHOD_POST,
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
                :headers      => { "ngrok-skip-browser-warning" => "1" }
            },
            method(:onCompleteReceived)
        );
    }

    function onCompleteReceived(code as Number, raw as Dictionary or String or PersistedContent.Iterator or Null) as Void {
        postNextComplete();
    }

    function handleTap(y as Number) as Void {
        if (_state != ST_LIST || _tasks.size() == 0 || _rowH == 0) { return; }
        if (y < _listY) { return; }

        var row = (y - _listY) / _rowH;
        if (row < 0 || row >= VISIBLE) { return; }

        var absIdx = _offset + row;
        if (absIdx >= _tasks.size()) { return; }

        var now = System.getTimer();

        if (_lastTapRow == row && (now - _lastTapTime) < 500) {
            // 雙擊 → 切換核取方塊
            var task = _tasks[absIdx] as Dictionary;
            var id = task["id"] as String;
            if (_checked.get(id) != null) {
                _checked.remove(id);
            } else {
                _checked.put(id, true);
            }
            _lastTapRow = -1;
        } else {
            // 單擊 → 移動游標
            if (_cursor != row) {
                _cursor = row;
                resetScroll();
            }
            _lastTapRow = row;
            _lastTapTime = now;
        }
        WatchUi.requestUpdate();
    }

    // -----------------------------------------------------------------------
    // Drawing — all coordinates derived from dc.getWidth() / dc.getHeight()
    // -----------------------------------------------------------------------

    function onUpdate(dc as Graphics.Dc) as Void {
        var w  = dc.getWidth();
        var h  = dc.getHeight();
        var cx = w / 2;
        var cy = h / 2;

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        if (_state == ST_LOADING) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, cy, Graphics.FONT_MEDIUM, "Loading...",
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        } else if (_state == ST_ERROR) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, cy - 30, Graphics.FONT_SMALL, "Connection error",
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, cy + 10, Graphics.FONT_TINY, _msg,
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.drawText(cx, cy + 40, Graphics.FONT_TINY, "Start proxy server",
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        } else if (_state == ST_CONFIRM) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, cy, Graphics.FONT_LARGE, _msg,
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        } else {
            // ST_LIST or ST_SELECTED
            drawList(dc, w, h, cx);
        }
    }

    private function drawList(dc as Graphics.Dc, w as Number, h as Number, cx as Number) as Void {
        var headerY = (h * 0.07).toNumber();
        var listY   = (h * 0.26).toNumber();
        var rowH    = (h * 0.16).toNumber();
        _listY = listY;
        _rowH  = rowH;
        var rowX    = (w * 0.10).toNumber();
        var rowW    = (w * 0.65).toNumber();
        var textX   = rowX + 36;
        var textW   = rowX + rowW - textX;

        // Header
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, headerY, Graphics.FONT_SMALL, "Tasks",
                    Graphics.TEXT_JUSTIFY_CENTER);

        // Divider
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(rowX + 10, listY - 8, rowX + rowW - 10, listY - 8);

        // Empty state
        if (_tasks.size() == 0) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, h / 2, Graphics.FONT_MEDIUM, "All done!",
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            return;
        }

        // Task rows
        var count = _tasks.size() - _offset;
        if (count > VISIBLE) { count = VISIBLE; }

        for (var i = 0; i < count; i++) {
            var task       = _tasks[_offset + i] as Dictionary;
            var title      = task["title"] as String;
            var overdue    = task["isOverdue"];
            var isCursor = (i == _cursor);
            var rowY     = listY + i * rowH;

            // White vertical bar for cursor row
            if (isCursor) {
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.fillRectangle(rowX, rowY + 2, 3, rowH - 8);
            }

            // Checkbox (white outline, 16x16)
            var cbX = rowX + 12;
            var cbY = rowY + rowH / 2 - 8;
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawRectangle(cbX, cbY, 16, 16);

            // Checkmark (green) if checked
            var taskId = task["id"] as String;
            if (_checked.get(taskId) != null) {
                dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
                dc.drawLine(cbX + 2, cbY + 8, cbX + 6, cbY + 12);
                dc.drawLine(cbX + 6, cbY + 12, cbX + 13, cbY + 4);
                dc.drawLine(cbX + 2, cbY + 9, cbX + 6, cbY + 13);
                dc.drawLine(cbX + 6, cbY + 13, cbX + 13, cbY + 5);
            }

            // Title
            var prefix   = (overdue != null && overdue == true) ? "! " : "";
            var rawTitle = prefix + title;

            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);

            if (isCursor && rawTitle.length() > 5) {
                // Marquee: clip window = width of first 5 chars; text scrolls inside it
                var mapped5 = toMapped(rawTitle.substring(0, 5));
                var mapped   = toMapped(rawTitle);
                var clipW    = dc.getTextWidthInPixels(mapped5, _cjkFont);
                var fullPx   = dc.getTextWidthInPixels(mapped, _cjkFont);
                var newMax   = fullPx - clipW;
                if (newMax < 0) { newMax = 0; }
                _scrollMax = newMax;
                if (_scrollPx > _scrollMax) { _scrollPx = _scrollMax; }

                dc.setClip(textX, rowY, clipW, rowH);
                dc.drawText(textX - _scrollPx, rowY + rowH / 2 - 14, _cjkFont, mapped,
                            Graphics.TEXT_JUSTIFY_LEFT);
                dc.clearClip();
            } else {
                // Static: first 5 chars only, no overflow
                var display = rawTitle.length() > 5 ? rawTitle.substring(0, 5) : rawTitle;
                dc.drawText(textX, rowY + rowH / 2 - 14, _cjkFont, toMapped(display),
                            Graphics.TEXT_JUSTIFY_LEFT);
            }
        }

        // Arc scrollbar along right edge of watch face
        if (_tasks.size() > VISIBLE) {
            var radius    = w / 2 - 10;
            var arcTop    = 60;   // degrees from 3-o'clock, upper-right
            var arcBot    = -60;  // degrees, lower-right
            var arcSpan   = 120;
            var total     = _tasks.size();
            var thumbSpan  = (arcSpan * VISIBLE / total).toNumber();
            var thumbStart = arcTop - (arcSpan * _offset / total).toNumber();
            var thumbEnd   = thumbStart - thumbSpan;

            // Track (dim grey)
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(3);
            dc.drawArc(cx, h / 2, radius, Graphics.ARC_CLOCKWISE, arcTop, arcBot);

            // Thumb (white)
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawArc(cx, h / 2, radius, Graphics.ARC_CLOCKWISE, thumbStart, thumbEnd);
            dc.setPenWidth(1);
        }
    }
}
