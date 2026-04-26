import Toybox.Application;
import Toybox.Graphics;
import Toybox.WatchUi;
import Toybox.Communications;
import Toybox.Timer;
import Toybox.Lang;
import Toybox.PersistedContent;
import Toybox.System;
import Toybox.Math;

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
    private const ST_ALL_DONE = 4;

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

    // All-done entrance animation
    private var _animTick  as Number       = 0;
    private var _animTimer as Timer.Timer? = null;
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
        if (_animTimer != null) {
            (_animTimer as Timer.Timer).stop();
            _animTimer = null;
        }
    }

    // -----------------------------------------------------------------------
    // charMap conversion
    // -----------------------------------------------------------------------

    private function toMapped(text as String) as String {
        var out   = "";
        var map   = _charMap as Dictionary;
        var chars = text.toCharArray();
        for (var i = 0; i < chars.size(); i++) {
            var cp  = chars[i].toNumber();
            var idx = map.get(cp.toString());
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
            if (_tasks.size() == 0) {
                _state    = ST_ALL_DONE;
                _animTick = 0;
                _animTimer = new Timer.Timer();
                (_animTimer as Timer.Timer).start(method(:onAnimTick), SCROLL_MS, true);
            } else {
                _state = ST_FOCUS;
                resetScroll();
            }
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
        if (_state == ST_ALL_DONE) { return true; }
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
    // All-done animation tick
    // -----------------------------------------------------------------------

    function onAnimTick() as Void {
        if (_state != ST_ALL_DONE) { return; }
        _animTick++;
        WatchUi.requestUpdate();
    }

    // -----------------------------------------------------------------------
    // Animation helpers
    // -----------------------------------------------------------------------

    private function easeOutCubic(t as Float) as Float {
        var u = 1.0f - t;
        return 1.0f - u * u * u;
    }

    private function easeOutBack(t as Float) as Float {
        var c1 = 1.70158f;
        var c3 = c1 + 1.0f;
        var u  = t - 1.0f;
        return 1.0f + c3 * u * u * u + c1 * u * u;
    }

    private function animProgress(t as Float, start as Float, end_ as Float) as Float {
        if (end_ <= start) { return 1.0f; }
        var v = (t - start) / (end_ - start);
        if (v < 0.0f) { return 0.0f; }
        if (v > 1.0f) { return 1.0f; }
        return v;
    }

    private function lerpN(a as Number, b as Number, t as Float) as Number {
        return (a.toFloat() + (b - a).toFloat() * t).toNumber();
    }

    // Blend a channel from bg toward fg by alpha ∈ [0,1]
    private function blendCh(bg as Number, fg as Number, alpha as Float) as Number {
        var v = (bg.toFloat() + (fg - bg).toFloat() * alpha).toNumber();
        if (v < 0)   { v = 0; }
        if (v > 255) { v = 255; }
        return v;
    }

    // Soft radial halo: draw concentric fills from outer → inner so the
    // inner area ends up brighter (inner circle later paints over the center).
    private function drawHalo(dc as Graphics.Dc,
                               cx as Number, cy as Number, radius as Number,
                               breathIn as Float, pulse as Float,
                               baseAlpha as Float) as Void {
        var overall = breathIn * (0.8f + 0.2f * pulse);
        var steps   = 5;
        for (var s = 0; s < steps; s++) {
            var r = radius - s * radius / steps;
            if (r <= 1) { continue; }
            // frac = 0 at outermost step, 1 at innermost → brighter toward center
            var frac = s.toFloat() / (steps.toFloat() - 1.0f);
            var ea   = overall * baseAlpha * (0.2f + 0.8f * frac) * (0.6f + 0.4f * pulse);
            var g    = (140.0f * ea).toNumber();
            var rb   = ( 55.0f * ea).toNumber();
            if (g > 2) {
                dc.setColor((rb << 16) | (g << 8) | rb, Graphics.COLOR_TRANSPARENT);
                dc.fillCircle(cx, cy, r);
            }
        }
    }

    // -----------------------------------------------------------------------
    // All-done entrance + idle animation
    // -----------------------------------------------------------------------

    private function drawAllDone(dc as Graphics.Dc,
                                  w as Number, h as Number, cx as Number) as Void {
        var cy = h / 2;
        var t  = _animTick * 0.033f;           // elapsed seconds (~30 fps)
        var sc = cx.toFloat() / 150.0f;        // scale: spec uses 150px center

        // ── Layer 01: Watch Bezel (static) ──────────────────────────────────
        dc.setPenWidth(3);
        dc.setColor(0x1a1a1e, Graphics.COLOR_TRANSPARENT);
        dc.drawArc(cx, cy, (148.0f * sc).toNumber(), Graphics.ARC_CLOCKWISE, 89, 90);
        dc.setPenWidth(1);
        dc.setColor(0x111114, Graphics.COLOR_TRANSPARENT);
        dc.drawArc(cx, cy, (143.0f * sc).toNumber(), Graphics.ARC_CLOCKWISE, 89, 90);

        // ── Layer 02: Orbit Ring dashed (0.3 → 0.9 s) ───────────────────────
        var ringA = easeOutCubic(animProgress(t, 0.3f, 0.9f));
        if (ringA > 0.01f) {
            var ringR = (132.0f * sc).toNumber();
            // #3a6a3a at alpha 0.25 blended onto #060608 background
            var rr = blendCh(0x06, 0x3a, ringA * 0.25f);
            var rg = blendCh(0x06, 0x6a, ringA * 0.25f);
            var rb_ = blendCh(0x08, 0x3a, ringA * 0.25f);
            dc.setColor((rr << 16) | (rg << 8) | rb_, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(1);
            // Dashed: 18 arcs of 8° each with 12° gaps (18×20° = 360°)
            for (var d = 0; d < 18; d++) {
                var sd = 90 - d * 20;
                var ed = sd - 8;
                dc.drawArc(cx, cy, ringR, Graphics.ARC_CLOCKWISE, sd, ed);
            }
        }

        // ── Layer 03: Breathing Halos ×3 (1.6 s → ∞) ───────────────────────
        var breathIn = easeOutCubic(animProgress(t, 1.6f, 2.3f));
        if (breathIn > 0.01f) {
            var p0 = 0.5f + 0.5f * Math.sin(t * 0.9f).toFloat();
            var p1 = 0.5f + 0.5f * Math.sin(t * 0.9f + (Math.PI * 0.66).toFloat()).toFloat();
            var p2 = 0.5f + 0.5f * Math.sin(t * 0.9f + (Math.PI * 1.33).toFloat()).toFloat();
            drawHalo(dc, cx, cy, (122.0f * sc).toNumber(), breathIn, p0, 0.10f);
            drawHalo(dc, cx, cy, (100.0f * sc).toNumber(), breathIn, p1, 0.16f);
            drawHalo(dc, cx, cy, ( 78.0f * sc).toNumber(), breathIn, p2, 0.22f);
        }

        // ── Layer 04: Inner Circle (1.4 → 2.1 s, easeOutBack) ───────────────
        var circleP = easeOutBack(animProgress(t, 1.4f, 2.1f));
        if (circleP > 0.01f) {
            var maxIR  = (62.0f * sc).toNumber();
            var innerR = (62.0f * sc * circleP).toNumber();
            if (innerR < 0)         { innerR = 0; }
            if (innerR > maxIR + 5) { innerR = maxIR + 5; }  // clamp overshoot

            // Dark fill
            dc.setColor(0x0f1f0f, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(cx, cy, innerR);

            // Border ring
            var borderA = easeOutCubic(animProgress(t, 1.4f, 2.0f));
            if (borderA > 0.01f) {
                var br2 = blendCh(0x00, 0x2a, borderA);
                var bg2 = blendCh(0x00, 0x4a, borderA);
                dc.setColor((br2 << 16) | (bg2 << 8) | br2, Graphics.COLOR_TRANSPARENT);
                dc.setPenWidth(2);
                dc.drawArc(cx, cy, innerR, Graphics.ARC_CLOCKWISE, 89, 90);
                dc.setPenWidth(1);
            }
        }

        // ── Layer 05: Checkmark (1.9 → 2.5 s) ──────────────────────────────
        var checkP = easeOutCubic(animProgress(t, 1.9f, 2.5f));
        if (checkP > 0.01f) {
            // Points relative to center (spec center = 150,150)
            var p1x = cx + (-24.0f * sc).toNumber();
            var p1y = cy + (  2.0f * sc).toNumber();
            var p2x = cx + ( -6.0f * sc).toNumber();
            var p2y = cy + ( 20.0f * sc).toNumber();
            var p3x = cx + ( 28.0f * sc).toNumber();
            var p3y = cy + (-18.0f * sc).toNumber();

            var ckR = blendCh(0x00, 0x78, checkP);
            var ckG = blendCh(0x00, 0xcc, checkP);
            dc.setColor((ckR << 16) | (ckG << 8) | ckR, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(3);

            if (checkP < 0.5f) {
                var seg = checkP / 0.5f;
                dc.drawLine(p1x, p1y, lerpN(p1x, p2x, seg), lerpN(p1y, p2y, seg));
            } else {
                var seg2 = (checkP - 0.5f) / 0.5f;
                dc.drawLine(p1x, p1y, p2x, p2y);
                dc.drawLine(p2x, p2y, lerpN(p2x, p3x, seg2), lerpN(p2y, p3y, seg2));
            }
            dc.setPenWidth(1);
        }

        // ── Layer 06: Text (2.4 → 3.1 s) ────────────────────────────────────
        var textA = easeOutCubic(animProgress(t, 2.4f, 3.1f));
        if (textA > 0.01f) {

            // Main text
            var txR = blendCh(0x00, 0x8a, textA);
            var txG = blendCh(0x00, 0xbf, textA);
            dc.setColor((txR << 16) | (txG << 8) | txR, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, cy + (90.0f * sc).toNumber(),
                        _cjkFontSm, toMapped("所有任務完成"),
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            // Sub text — use system font to avoid charmap dependency
            var sbR = blendCh(0x00, 0x3a, textA);
            var sbG2 = blendCh(0x00, 0x5a, textA);
            dc.setColor((sbR << 16) | (sbG2 << 8) | sbR, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, cy + (108.0f * sc).toNumber(),
                        _cjkFontSm, toMapped("休息一下"),
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        }
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

        } else if (_state == ST_ALL_DONE) {
            drawAllDone(dc, w, h, cx);

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

        // Title — marquee scroll if too wide, bold double-draw
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var mappedAll = toMapped(title);
        var clipW  = lineX + lineW - textX;
        var fullPx = dc.getTextWidthInPixels(mappedAll, _cjkFont);
        if (fullPx > clipW) {
            var newMax = fullPx - clipW;
            if (newMax < 0) { newMax = 0; }
            _scrollMax = newMax;
            if (_scrollPx > _scrollMax) { _scrollPx = _scrollMax; }
            dc.setClip(textX, focY, clipW, cellH);
            dc.drawText(textX - _scrollPx,     focY, _cjkFont, mappedAll, Graphics.TEXT_JUSTIFY_LEFT);
            dc.drawText(textX - _scrollPx + 1, focY, _cjkFont, mappedAll, Graphics.TEXT_JUSTIFY_LEFT);
            dc.clearClip();
        } else {
            _scrollMax = 0;
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
