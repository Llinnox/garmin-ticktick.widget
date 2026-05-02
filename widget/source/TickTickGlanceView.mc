import Toybox.Application.Storage;
import Toybox.Graphics;
import Toybox.WatchUi;
import Toybox.System;
import Toybox.Lang;

(:glance)
class TickTickGlanceView extends WatchUi.GlanceView {

    (:glance)
    function initialize() {
        GlanceView.initialize();
    }

    (:glance)
    function onUpdate(dc as Graphics.Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        // ── Read storage ──────────────────────────────────────────────────────
        var rawTotal    = Storage.getValue("glanceTotal");
        var rawDone     = Storage.getValue("glanceDone");
        var rawNextMins = Storage.getValue("glanceNextMins");

        var total = (rawTotal != null) ? rawTotal as Number : 0;
        var done  = (rawDone  != null) ? rawDone  as Number : 0;
        var grand = total + done;
        var pct   = (grand > 0) ? (done * 100 / grand) : 0;

        var padL = 8;
        var rowH = (h / 4).toNumber();

        // Row 1 — "Today Tasks"
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(padL, rowH * 0 + rowH / 2, Graphics.FONT_XTINY, "Today Tasks",
                    Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        // Row 2 — progress bar + %
        var barW = (w * 0.60).toNumber();
        var barH = 7;
        var barY = rowH * 1 + (rowH - barH) / 2;
        var fill = (grand > 0) ? (done * barW / grand) : 0;

        dc.setColor(0x444444, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(padL, barY, barW, barH);
        if (fill > 0) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(padL, barY, fill, barH);
        }
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(padL + barW + 6, rowH * 1 + rowH / 2, Graphics.FONT_XTINY,
                    pct.toString() + "%",
                    Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        // Row 3 — "2 / 5 Done"
        dc.setColor(0xAAAAAA, Graphics.COLOR_TRANSPARENT);
        dc.drawText(padL, rowH * 2 + rowH / 2, Graphics.FONT_XTINY,
                    done.toString() + " / " + grand.toString() + " Done",
                    Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        // Row 4 — "Next: 50 Min" / "Next: 14:30" / "Next: Done"
        var nextLabel = "Next: Done";
        if (rawNextMins != null && (rawNextMins as Number) >= 0) {
            var taskMins = rawNextMins as Number;
            var clock    = System.getClockTime();
            var nowMins  = clock.hour * 60 + clock.min;
            var diff     = taskMins - nowMins;

            if (diff <= 0) {
                nextLabel = "Next: Now";
            } else if (diff <= 60) {
                nextLabel = "Next: " + diff.toString() + " Min";
            } else {
                var h2   = taskMins / 60;
                var m2   = taskMins % 60;
                var mStr = (m2 < 10 ? "0" : "") + m2.toString();
                nextLabel = "Next: " + h2.toString() + ":" + mStr;
            }
        }

        dc.setColor(0xCCCCCC, Graphics.COLOR_TRANSPARENT);
        dc.drawText(padL, rowH * 3 + rowH / 2, Graphics.FONT_XTINY, nextLabel,
                    Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}
