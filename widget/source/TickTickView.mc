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
        return true;
    }

    function handleMenu() as Void {
        fetchTasks();
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
            _cursor = row;
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

            // Title (overdue prefix)
            var prefix = (overdue != null && overdue == true) ? "! " : "";
            var fullTitle = prefix + title;
            var maxChars = 14;
            if (fullTitle.length() > maxChars) {
                fullTitle = fullTitle.substring(0, maxChars - 1) + "~";
            }

            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(rowX + 36, rowY + rowH / 2 - 14, _cjkFont, toMapped(fullTitle),
                        Graphics.TEXT_JUSTIFY_LEFT);
        }

        // Scrollbar
        if (_tasks.size() > VISIBLE) {
            var barX   = rowX + rowW + 4;
            var barH   = VISIBLE * rowH;
            var total  = _tasks.size();
            var tH     = (barH * VISIBLE / total).toNumber();
            var tY     = listY + (barH * _offset / total).toNumber();
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(barX, tY, 3, tH);
        }
    }
}
