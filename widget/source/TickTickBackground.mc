import Toybox.Background;
import Toybox.Communications;
import Toybox.Application.Storage;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.Lang;

(:background)
class TickTickBackground extends System.ServiceDelegate {

    private const SERVER = "https://web-production-0de0a.up.railway.app";

    (:background)
    function initialize() {
        ServiceDelegate.initialize();
    }

    (:background)
    function onTemporalEvent() as Void {
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

    (:background)
    function onTasksReceived(code as Number, raw as Dictionary or Null) as Void {
        if (code == 200 && raw instanceof Dictionary) {
            var list  = (raw as Dictionary)["data"];
            var tasks = (list != null) ? list as Array : [];

            Storage.setValue("glanceTotal", tasks.size());

            // Date reset — same logic as foreground
            var today      = getTodayString();
            var storedDate = Storage.getValue("glanceDate");
            if (storedDate == null || !(storedDate as String).equals(today)) {
                Storage.setValue("glanceDone", 0);
                Storage.setValue("glanceDoneIds", []);
                Storage.setValue("glanceDate", today);
            }

            cacheNextTaskTime(tasks);
        }
        Background.exit(null);
    }

    (:background)
    private function getTodayString() as String {
        var info = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        var mo = info.month as Number;
        var d  = info.day   as Number;
        return (info.year as Number).toString()
             + "-" + (mo < 10 ? "0" : "") + mo.toString()
             + "-" + (d  < 10 ? "0" : "") + d.toString();
    }

    (:background)
    private function cacheNextTaskTime(tasks as Array) as Void {
        var utcNow    = Time.now();
        var localInfo = Gregorian.info(utcNow, Time.FORMAT_SHORT);

        var utcSec  = utcNow.value() % 86400;
        var locSec  = (localInfo.hour as Number) * 3600
                    + (localInfo.min  as Number) * 60
                    + (localInfo.sec  as Number);
        var tzMin   = (locSec - utcSec) / 60;
        if (tzMin >  720) { tzMin -= 1440; }
        if (tzMin < -720) { tzMin += 1440; }

        var todayY  = localInfo.year  as Number;
        var todayMo = localInfo.month as Number;
        var todayD  = localInfo.day   as Number;
        var nowMins = (localInfo.hour as Number) * 60 + (localInfo.min as Number);
        var bestMins = -1;

        for (var i = 0; i < tasks.size(); i++) {
            var t      = tasks[i] as Dictionary;
            var dueRaw = t.get("dueDate");
            if (dueRaw == null) { continue; }
            var s = dueRaw as String;
            if (s.length() < 16) { continue; }

            var utcY  = s.substring(0,  4).toNumber();
            var utcMo = s.substring(5,  7).toNumber();
            var utcD  = s.substring(8,  10).toNumber();
            var utcH  = s.substring(11, 13).toNumber();
            var utcM  = s.substring(14, 16).toNumber();
            if (utcY == null || utcMo == null || utcD == null ||
                utcH == null || utcM == null) { continue; }

            var localMins = (utcH as Number) * 60 + (utcM as Number) + tzMin;
            var localD    = utcD as Number;
            if (localMins >= 1440) { localMins -= 1440; localD += 1; }
            if (localMins <     0) { localMins += 1440; localD -= 1; }

            if ((utcY as Number) != todayY || (utcMo as Number) != todayMo ||
                localD != todayD) { continue; }
            if (localMins <= nowMins) { continue; }

            if (bestMins < 0 || localMins < bestMins) { bestMins = localMins; }
        }

        Storage.setValue("glanceNextMins", bestMins);
    }
}
