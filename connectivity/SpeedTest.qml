pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Shared speedtest state. Wi-Fi and Wired tabs both render SpeedSection
// bound to this singleton, so starting a run on one tab and switching to the
// other neither restarts nor loses it -- there is exactly one Process, one
// set of results, regardless of which pane is visible.
QtObject {
    id: st

    property int duration: 10
    property bool uploadEnabled: true

    property bool running: false
    property string phase: ""
    property real pct: 0
    property real down: 0
    property real up: 0
    property real ping: 0
    property real jitter: 0
    property string colo: ""
    property string errorMsg: ""
    property var samples: []
    property var history: []

    function start() {
        if (running) return
        errorMsg = ""
        phase = "meta"
        pct = 0
        down = 0
        up = 0
        ping = 0
        jitter = 0
        samples = []
        var args = ["speedtest", "--duration", String(duration)]
        if (!uploadEnabled) args.push("--no-upload")
        proc.command = ["python3", Quickshell.shellPath("net.py")].concat(args)
        running = true
        proc.running = true
    }

    function abort() {
        if (!running) return
        proc.signal(15)
    }

    function handleLine(line) {
        line = line.trim()
        if (line === "") return
        var obj
        try { obj = JSON.parse(line) } catch (e) { return }
        phase = obj.phase || phase
        if (obj.phase === "meta") {
            colo = obj.colo || colo
        } else if (obj.phase === "latency") {
            ping = obj.ms !== undefined ? obj.ms : ping
            jitter = obj.jitter !== undefined ? obj.jitter : jitter
            pct = obj.pct !== undefined ? obj.pct : pct
        } else if (obj.phase === "down") {
            down = obj.mbps !== undefined ? obj.mbps : down
            pct = obj.pct !== undefined ? obj.pct : pct
            samples = samples.concat([down]).slice(-60)
        } else if (obj.phase === "up") {
            up = obj.mbps !== undefined ? obj.mbps : up
            pct = obj.pct !== undefined ? obj.pct : pct
            samples = samples.concat([up]).slice(-60)
        } else if (obj.phase === "done") {
            down = obj.down !== undefined ? obj.down : down
            up = obj.up !== undefined ? obj.up : up
            ping = obj.ping !== undefined ? obj.ping : ping
            jitter = obj.jitter !== undefined ? obj.jitter : jitter
            colo = obj.colo || colo
            history = [obj].concat(history).slice(0, 5)
            running = false
        } else if (obj.phase === "error") {
            errorMsg = obj.msg || "speedtest failed"
            running = false
        }
    }

    property Process _proc: Process {
        id: proc
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => st.handleLine(line)
        }
        stderr: StdioCollector { id: errCollector }
        onExited: (code, status) => {
            st.running = false
            if (code !== 0 && st.errorMsg === "" && errCollector.text.trim() !== "")
                st.errorMsg = errCollector.text.trim()
        }
    }
}
