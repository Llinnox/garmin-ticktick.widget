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
//   ST_FOCUS    → C view: UP/DOWN scroll, ENTER toggle done, BACK sync+exit
//   ST_CONFIRM  → "Syncing..." while batch-POSTing on exit
//   ST_ERROR    → network/server error
// ---------------------------------------------------------------------------

class TickTickView extends WatchUi.View {

    private const SERVER = "https://web-production-0de0a.up.railway.app";

    // Marquee
    private const SCROLL_STEP    = 2;
    private const SCROLL_MS      = 33;
    private const SCROLL_PAUSE_S = 54;
    private const SCROLL_PAUSE_E = 36;

    private const SS_PAUSE_START = 0;
    private const SS_FORWARD     = 1;
    private const SS_PAUSE_END   = 2;
    private const SS_BACK        = 3;
    private const SS_DONE        = 4;

    // States
    private const ST_LOADING  = 0;
    private const ST_FOCUS    = 1;
    private const ST_CONFIRM  = 2;
    private const ST_ERROR    = 3;

    // Runtime
    private var _state   as Number  = ST_LOADING;
    private var _tasks   as Array   = [];
    private var _cursor  as Number  = 0;
    private var _msg     as String  = "";
    private var _cjkFont   as WatchUi.FontResource? = null;
    private var _cjkFontSm as WatchUi.FontResource? = null;
    private var _charMap   as Dictionary? = null;
    private var _checked   as Dictionary  = {};  // taskId → true (local toggle)

    // Marquee
    private var _scrollPx    as Number = 0;
    private var _scrollState as Number = SS_PAUSE_START;
    private var _scrollMax   as Number = 0;
    private var _scrollCount as Number = 0;
    private var _scrollTimer as Timer.Timer? = null;

    // Batch-sync on exit
    private var _syncIds   as Array   = [];
    private var _syncIdx   as Number  = 0;
    private var _isSyncing as Boolean = false;

    // Tap-zone cache
    private var _focusedTapY as Number = 0;
    private var _focusedTapH as Number = 0;
    private var _othersY     as Number = 0;
    private var _otherRowH   as Number = 0;
    private var _otherCount  as Number = 0;

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    function initialize() {
        View.initialize();
    }

    function onLayout(dc as Graphics.Dc) as Void {
        _cjkFont   = Application.loadResource(Rez.Fonts.CJKFont)   as WatchUi.FontResource;
        _cjkFontSm = Application.loadResource(Rez.Fonts.CJKFontSm) as WatchUi.FontResource;
        _charMap   = Application.loadResource(Rez.JsonData.charMap) as Dictionary;
    }

    function onShow() as Void {
        fetchTasks();
        _scrollTimer = new Timer.Timer();
        (_scrollTimer as Timer.Timer).start(method(:onScrollTick), SCROLL_MS, true);
    }

    function onHide() as Void {
        if (_scrollTimer != null) {
            (_scrollTimer as Timer.Timer).stop();
            _scrollTimer = null;
        }
    }

    // -----------------------------------------------------------------------
    // charMap conversion
    // -----------------------------------------------------------------------

    private function toMapped(text as String) as String {
        var out  = "";
        var map  = _charMap as Dictionary;
        var chars = text.toCharArray();
        for (var i = 0; i < chars.size(); i++) {
            var idx = map.get(chars[i].toNumber().toString());
            if (idx != null) {
                out = out + (idx as Number).toChar().toString();
            } else {
                out = out + "?";
            }
        }
        return out;
    }

    // -----------------------------------------------------------------------
    // Marquee
    // -----------------------------------------------------------------------

    private function resetScroll() as Void {
        _scrollPx    = 0;
        _scrollMax   = 0;
        _scrollState = SS_PAUSE_START;
        _scrollCount = 0;
    }

    function onScrollTick() as Void {
        if (_state != ST_FOCUS || _scrollMax == 0) { return; }
        if (_scrollState == SS_DONE) { return; }

        if (_scrollState == SS_PAUSE_START) {
            _scrollCount++;
            if (_scrollCount >= SCROLL_PAUSE_S) { _scrollState = SS_FORWARD; _scrollCount = 0; }
            return;
        } else if (_scrollState == SS_FORWARD) {
            _scrollPx += SCROLL_STEP;
            if (_scrollPx >= _scrollMax) { _scrollPx = _scrollMax; _scrollState = SS_PAUSE_END; _scrollCount = 0; }
        } else if (_scrollState == SS_PAUSE_END) {
            _scrollCount++;
            if (_scrollCount >= SCROLL_PAUSE_E) { _scrollState = SS_BACK; _scrollCount = 0; }
            return;
        } else if (_scrollState == SS_BACK) {
            var step = _scrollPx / 3;
            if (step < 1) { step = 1; }
            _scrollPx -= step;
            if (_scrollPx <= 0) { _scrollPx = 0; _scrollState = SS_DONE; WatchUi.requestUpdate(); return; }
        }
        WatchUi.requestUpdate();
    }

    // -----------------------------------------------------------------------
    // HTTP — fetch tasks
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

    function onTasksReceived(code as Number,
                             raw  as Dictionary or String or PersistedContent.Iterator or Null) as Void {
        if (code == 200 && raw instanceof Dictionary) {
            var list = (raw as Dictionary)["data"];
            _tasks   = (list != null) ? list as Array : [];
            _cursor  = 0;
            _checked = {};
            _state   = ST_FOCUS;
            resetScroll();
        } else {
            _msg   = "Error: " + code.toString();
            _state = ST_ERROR;
        }
        WatchUi.requestUpdate();
    }

    // -----------------------------------------------------------------------
    // HTTP — batch complete on exit
    // -----------------------------------------------------------------------

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

    function onCompleteReceived(code as Number,
                                raw  as Dictionary or String or PersistedContent.Iterator or Null) as Void {
        postNextComplete();
    }

    // -----------------------------------------------------------------------
    // Input
    // -----------------------------------------------------------------------

    // UP — previous task
    function handleUp() as Void {
        if (_state == ST_FOCUS) {
            if (_cursor > 0) { _cursor--; resetScroll(); }
            WatchUi.requestUpdate();
        }
    }

    // DOWN — next task
    function handleDown() as Void {
        if (_state == ST_FOCUS) {
            if (_cursor < _tasks.size() - 1) { _cursor++; resetScroll(); }
            WatchUi.requestUpdate();
        }
    }

    // ENTER — toggle current task complete / incomplete (local)
    function handleEnter() as Void {
        if (_state == ST_FOCUS && _tasks.size() > 0) {
            var task   = _tasks[_cursor] as Dictionary;
            var taskId = task["id"] as String;
            if (_checked.get(taskId) != null) {
                _checked.remove(taskId);
            } else {
                _checked.put(taskId, true);
            }
            WatchUi.requestUpdate();
        }
    }

    // BACK — sync all checked tasks then exit; exit immediately if nothing checked
    function handleBack() as Boolean {
        if (_isSyncing) { return false; }

        var ids = _checked.keys();
        if (ids.size() == 0) {
            return true;   // nothing to sync → exit now
        }

        _syncIds   = ids;
        _syncIdx   = 0;
        _isSyncing = true;
        _msg       = "Syncing...";
        _state     = ST_CONFIRM;
        WatchUi.requestUpdate();
        postNextComplete();
        return false;
    }

    // TAP — toggle focused task; switch cursor to tapped other-task row
    function handleTap(x as Number, y as Number) as Void {
        if (_state != ST_FOCUS || _tasks.size() == 0) { return; }

        // Tap on focused task area → toggle complete
        if (y >= _focusedTapY && y < _focusedTapY + _focusedTapH) {
            handleEnter();
            return;
        }

        // Tap on other-task row → move cursor there
        if (_otherRowH > 0 && y >= _othersY) {
            var row = (y - _othersY) / _otherRowH;
            if (row >= 0 && row < _otherCount) {
                var newCursor = _cursor + 1 + row;
                if (newCursor < _tasks.size()) {
                    _cursor = newCursor;
                    resetScroll();
                    WatchUi.requestUpdate();
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    private function priorityText(p as Number) as String {
        if (p >= 5) { return "高"; }
        if (p >= 3) { return "中"; }
        if (p >= 1) { return "低"; }
        return "無";
    }

    private function drawCheckbox(dc as Graphics.Dc,
                                  x as Number, y as Number,
                                  sz as Number, checked as Boolean) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawRectangle(x, y, sz, sz);
        if (checked) {
            dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
            var x1 = x + sz * 2 / 16;
            var y1 = y + sz * 8 / 16;
            var xm = x + sz * 6 / 16;
            var ym = y + sz * 12 / 16;
            var x2 = x + sz * 13 / 16;
            var y2 = y + sz * 4 / 16;
            dc.drawLine(x1, y1,     xm, ym    );
            dc.drawLine(xm, ym,     x2, y2    );
            dc.drawLine(x1, y1 + 1, xm, ym + 1);
            dc.drawLine(xm, ym + 1, x2, y2 + 1);
        }
    }

    // Position arc: filled = (cursor+1) / total of circle
    private function drawProgressArc(dc as Graphics.Dc,
                                     w as Number, h as Number, cx as Number) as Void {
        var total = _tasks.size();
        if (total == 0) { return; }
        var radius = w / 2 - 8;
        var cy     = h / 2;

        dc.setPenWidth(4);

        // Track — full circle
        dc.setColor(0x555555, Graphics.COLOR_TRANSPARENT);
        dc.drawArc(cx, cy, radius, Graphics.ARC_CLOCKWISE, 89, 90);

        // Position indicator
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        if (_cursor >= total - 1) {
            dc.drawArc(cx, cy, radius, Graphics.ARC_CLOCKWISE, 89, 90);
        } else {
            var span   = 360 * (_cursor + 1) / total;
            var endDeg = 90 - span;
            dc.drawArc(cx, cy, radius, Graphics.ARC_CLOCKWISE, 90, endDeg);
        }

        dc.setPenWidth(1);
    }

    // -----------------------------------------------------------------------
    // onUpdate dispatcher
    // -----------------------------------------------------------------------

    function onUpdate(dc as Graphics.Dc) as Void {
        var w  = dc.getWidth();
        var h  = dc.getHeight();
        var cx = w / 2;

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        if (_state == ST_LOADING) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, h / 2, Graphics.FONT_MEDIUM, "Loading...",
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        } else if (_state == ST_ERROR) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, h / 2 - 30, Graphics.FONT_SMALL, "Connection error",
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.drawText(cx, h / 2 + 10, Graphics.FONT_TINY, _msg,
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.drawText(cx, h / 2 + 40, Graphics.FONT_TINY, "Start proxy server",
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        } else if (_state == ST_CONFIRM) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, h / 2, Graphics.FONT_MEDIUM, _msg,
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        } else {
            drawFocus(dc, w, h, cx);
        }
    }

    // -----------------------------------------------------------------------
    // C · 聚焦當前
    // -----------------------------------------------------------------------

    private function drawFocus(dc as Graphics.Dc,
                                w as Number, h as Number, cx as Number) as Void {
        var total = _tasks.size();

        // ── Shared layout constants ──────────────────────────────────────────
        var cbX      = (w * 0.17).toNumber();
        var cbSzMain = 18;
        var cbSzOth  = 11;
        var textX    = cbX + cbSzMain + 8;
        var lineW    = (w * 0.62).toNumber();
        var lineX    = cx - lineW / 2;
        var cellH    = 28;   // CJKFont   (22 px + 6)
        var cellHSm  = 20;   // CJKFontSm (14 px + 6)

        // ── Header ───────────────────────────────────────────────────────────
        var headerY = (h * 0.13).toNumber();
        dc.setColor(0x888888, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, headerY, Graphics.FONT_XTINY,
                    "TASKS · " + (_cursor + 1).toString() + "/" + total.toString(),
                    Graphics.TEXT_JUSTIFY_CENTER);

        // ── Divider line 1 ────────────────────────────────────────────────────
        var line1Y = headerY + 18;
        dc.setColor(0x333333, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(lineX, line1Y, lineX + lineW, line1Y);

        // ── Empty state ───────────────────────────────────────────────────────
        if (total == 0) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, h / 2, Graphics.FONT_MEDIUM, "All done!",
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            drawProgressArc(dc, w, h, cx);
            return;
        }

        // ── Focused task ──────────────────────────────────────────────────────
        var task      = _tasks[_cursor] as Dictionary;
        var title     = task["title"] as String;
        var taskId    = task["id"]    as String;
        var priRaw    = task["priority"];
        var priority  = (priRaw != null) ? priRaw as Number : 0;
        var isChecked = (_checked.get(taskId) != null);

        var focY = line1Y + 10;
        var cbY  = focY + (cellH - cbSzMain) / 2;

        _focusedTapY = focY;
        _focusedTapH = cellH + 2 + cellHSm + 6;

        drawCheckbox(dc, cbX, cbY, cbSzMain, isChecked);

        // Title — max 4 chars, bold double-draw, brightest white
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var mappedAll = toMapped(title);
        if (title.length() > 4) {
            var mapped4 = toMapped(title.substring(0, 4));
            var window  = dc.getTextWidthInPixels(mapped4, _cjkFont);
            var fullPx  = dc.getTextWidthInPixels(mappedAll, _cjkFont);
            var newMax  = fullPx - window;
            if (newMax < 0) { newMax = 0; }
            _scrollMax = newMax;
            if (_scrollPx > _scrollMax) { _scrollPx = _scrollMax; }
            dc.setClip(textX, focY, window, cellH);
            dc.drawText(textX - _scrollPx,     focY, _cjkFont, mappedAll, Graphics.TEXT_JUSTIFY_LEFT);
            dc.drawText(textX - _scrollPx + 1, focY, _cjkFont, mappedAll, Graphics.TEXT_JUSTIFY_LEFT);
            dc.clearClip();
        } else {
            dc.drawText(textX,     focY, _cjkFont, mappedAll, Graphics.TEXT_JUSTIFY_LEFT);
            dc.drawText(textX + 1, focY, _cjkFont, mappedAll, Graphics.TEXT_JUSTIFY_LEFT);
        }

        // Priority — small font, gray
        var priY = focY + cellH + 2;
        dc.setColor(0x888888, Graphics.COLOR_TRANSPARENT);
        dc.drawText(textX, priY, _cjkFontSm, toMapped(priorityText(priority)),
                    Graphics.TEXT_JUSTIFY_LEFT);

        // ── Divider line 2 ────────────────────────────────────────────────────
        var line2Y = priY + cellHSm + 4;
        dc.setColor(0x333333, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(lineX, line2Y, lineX + lineW, line2Y);

        // ── Other tasks ───────────────────────────────────────────────────────
        var othersY  = line2Y + 8;
        var rowH     = cellHSm + 4;
        var maxOther = 4;
        var numOther = _tasks.size() - _cursor - 1;
        if (numOther > maxOther) { numOther = maxOther; }

        _othersY    = othersY;
        _otherRowH  = rowH;
        _otherCount = numOther;

        for (var i = 0; i < numOther; i++) {
            var idx    = _cursor + 1 + i;
            var oTask  = _tasks[idx] as Dictionary;
            var oTitle = oTask["title"] as String;
            var oId    = oTask["id"]    as String;
            var oCk    = (_checked.get(oId) != null);
            var ry     = othersY + i * rowH;

            drawCheckbox(dc, cbX, ry + (cellHSm - cbSzOth) / 2, cbSzOth, oCk);

            dc.setColor(0xCCCCCC, Graphics.COLOR_TRANSPARENT);
            var disp = oTitle.length() > 8 ? oTitle.substring(0, 8) : oTitle;
            dc.drawText(textX, ry, _cjkFontSm, toMapped(disp), Graphics.TEXT_JUSTIFY_LEFT);
        }

        // ── Progress arc ──────────────────────────────────────────────────────
        drawProgressArc(dc, w, h, cx);
    }
}
