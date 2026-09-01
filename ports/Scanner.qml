import QtQuick
import Quickshell
import Quickshell.Io

// Dev-server data layer: schedules ports-scan, remembers which sockets answered
// HTTP, and carries out the row actions.
//
// Ported from rubenmeza/omarchy-ports' Scanner.qml (MIT License, Copyright (c)
// 2026 Ruben Meza): https://github.com/rubenmeza/omarchy-ports -- it had no
// Omarchy imports, so the changes here are only: the plugin settings object
// replaced with plain properties (this repo has no settings host), the helper
// paths pointed at this directory, and omarchy-launch-browser swapped for
// xdg-open, which is what the other widgets here open URLs with.
Item {
    id: root
    visible: false

    // An open panel buys a faster scan. A closed one only has to keep the
    // count honest, which nobody watches by the second.
    property bool active: false
    property int idleIntervalSec: 30
    property int activeIntervalSec: 2

    property var rows: []
    property bool scanned: false
    property string errorText: ""

    // Why a stop signalled nothing, kept until the next stop is asked for. It
    // outlives scans deliberately: a refusal the next scan wiped a second later
    // would be a stop button that silently does nothing.
    property string refusalText: ""

    // Emitted once per stop attempt. `refused` says the helper sent nothing --
    // the process was gone, the pid had been reused, or the sockets had moved.
    signal stopFinished(var server, bool hard, bool refused)

    // One helper at a time, so two rows stopped in quick succession are two
    // separate verified signals rather than one command line overwriting another.
    property var stopQueue: []

    readonly property string scanPath: String(Qt.resolvedUrl("ports-scan")).replace(/^file:\/\//, "")
    readonly property string stopPath: String(Qt.resolvedUrl("ports-stop")).replace(/^file:\/\//, "")

    // ---- browsable -------------------------------------------------------
    // Whether a port speaks HTTP is a fact about the running server, so it is
    // asked once per socket and remembered for as long as that socket lives. A
    // server still starting up answers nothing yet, so one retry is allowed --
    // on a later scan, not milliseconds later, which would only ask the same
    // unfinished server again.

    // socketKey -> { verdict: "http" | "notHttp" | "retry" | "pending", attempts: int }
    property var probes: ({})
    property int probeRevision: 0

    function socketKey(pid, port) { return pid + ":" + port }

    function probeVerdict(pid, port) {
        var probe = probes[socketKey(pid, port)]
        return probe ? probe.verdict : ""
    }

    // Every walk over the inventory goes through here, so the shape of a row --
    // a process holding several sockets -- is described in one place.
    function eachSocket(callback) {
        for (var i = 0; i < rows.length; i++) {
            var sockets = rows[i].sockets || []
            for (var s = 0; s < sockets.length; s++) {
                var result = callback(rows[i], sockets[s])
                if (result !== undefined) return result
            }
        }
        return undefined
    }

    readonly property var servers: {
        var revision = probeRevision
        var out = []
        for (var i = 0; i < rows.length; i++) {
            var row = rows[i]
            var sockets = row.sockets || []
            var httpSockets = []
            for (var s = 0; s < sockets.length; s++)
                if (probeVerdict(row.pid, sockets[s].port) === "http") httpSockets.push(sockets[s])
            // What Open and Copy act on: the socket that answered HTTP when
            // there is one, otherwise the lowest port the process holds.
            var primary = httpSockets.length > 0 ? httpSockets[0] : (sockets.length > 0 ? sockets[0] : null)
            out.push({
                pid: row.pid,
                // Carried so an action taken later can prove the pid is still
                // this process. See ports-stop.
                startTime: Number(row.startTime || 0),
                comm: String(row.comm || ""),
                ports: row.ports || [],
                sockets: sockets,
                exposed: row.exposed === true,
                shared: row.shared === true,
                cwd: String(row.cwd || ""),
                cwdDeleted: row.cwdDeleted === true,
                project: String(row.project || row.comm || ""),
                browsable: httpSockets.length > 0,
                primaryPort: primary ? primary.port : 0,
                primaryHost: primary ? String(primary.probeHost || "127.0.0.1") : "127.0.0.1"
            })
        }
        return out
    }

    readonly property int count: servers.length

    // Identity, not just a number: a pid the kernel handed to something else
    // since the last scan is not the server that was asked about.
    function isListening(server) {
        if (!server) return false
        for (var i = 0; i < rows.length; i++)
            if (rows[i].pid === server.pid && Number(rows[i].startTime) === Number(server.startTime)) return true
        return false
    }

    // ---- scan ------------------------------------------------------------

    function scan() { if (!scanProcess.running) scanProcess.running = true }

    Process {
        id: scanProcess
        running: false
        command: [root.scanPath]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.applyScan(text)
        }
        stderr: StdioCollector {
            waitForEnd: true
            onStreamFinished: if (text.trim() !== "") root.errorText = text.trim().split("\n")[0]
        }
    }

    function applyScan(output) {
        var parsed = []
        try {
            parsed = JSON.parse(String(output || "[]"))
        } catch (e) {
            root.errorText = "ports-scan produced output that is not JSON"
            return
        }
        if (!Array.isArray(parsed)) parsed = []
        root.errorText = ""
        root.scanned = true
        root.rows = parsed
        root.refreshProbes()
        root.probeNext()
    }

    Timer {
        interval: 1000 * (root.active ? root.activeIntervalSec : root.idleIntervalSec)
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.scan()
    }

    // ---- probe -----------------------------------------------------------

    // A verdict outlives nothing: once its socket is gone the record goes too,
    // so a port reused by the next server is asked again rather than inheriting
    // an answer about a program that has exited. A socket left in "retry" by the
    // previous scan becomes askable again here, which is what spaces the second
    // attempt a whole scan interval away from the first.
    function refreshProbes() {
        var live = ({})
        eachSocket(function(row, socket) {
            var key = root.socketKey(row.pid, socket.port)
            var previous = root.probes[key]
            if (previous) live[key] = previous.verdict === "retry" ? { verdict: "", attempts: previous.attempts } : previous
        })
        probes = live
    }

    function probeNext() {
        if (probeProcess.running) return
        var pending = eachSocket(function(row, socket) {
            var probe = root.probes[root.socketKey(row.pid, socket.port)]
            if (!probe || probe.verdict === "") return { row: row, socket: socket }
            return undefined
        })
        if (!pending) return

        var key = socketKey(pending.row.pid, pending.socket.port)
        var attempts = (probes[key] ? probes[key].attempts : 0) + 1
        probes[key] = { verdict: "pending", attempts: attempts }
        probeProcess.key = key
        probeProcess.command = ["curl", "--silent", "--output", "/dev/null", "--max-time", "0.4",
                                "--head", "http://" + pending.socket.probeHost + ":" + pending.socket.port]
        probeProcess.running = true
    }

    Process {
        id: probeProcess
        property string key: ""
        running: false
        onExited: function(exitCode) {
            var probe = root.probes[probeProcess.key]
            var attempts = probe ? probe.attempts : 1
            var verdict = exitCode === 0 ? "http" : (attempts >= 2 ? "notHttp" : "retry")
            root.probes[probeProcess.key] = { verdict: verdict, attempts: attempts }
            root.probeRevision++
            Qt.callLater(root.probeNext)
        }
    }

    // ---- actions ---------------------------------------------------------

    function urlFor(server) {
        if (!server) return ""
        var host = server.primaryHost === "127.0.0.1" || server.primaryHost === "[::1]"
            ? "localhost" : server.primaryHost
        return "http://" + host + ":" + server.primaryPort
    }

    function openServer(server) {
        if (!server || !server.browsable) return
        Quickshell.execDetached(["xdg-open", urlFor(server)])
    }

    // The URL is passed as an argument rather than through a shell, so nothing
    // in a project name or address can be interpreted as a command.
    function copyServer(server) {
        if (!server) return
        Quickshell.execDetached(["wl-copy", urlFor(server)])
    }

    // Clicking or pressing Enter on a row does the useful thing for what that
    // row is: visit a web server, or take the URL of anything else.
    function activateServer(server) {
        if (!server) return
        if (server.browsable) openServer(server)
        else copyServer(server)
    }

    // SIGTERM by default, and only ever the pid that owns the socket: a wrapper
    // like `pnpm dev` is left to notice its child has gone. SIGKILL is a second,
    // separately confirmed step, never an automatic escalation.
    //
    // The signal goes through ports-stop rather than through `kill`, because the
    // row being acted on was drawn by an earlier scan and the confirmation took
    // human time. The helper re-checks that the pid is still the same process
    // and still owns the reviewed sockets, and refuses otherwise; that check has
    // to happen in the same breath as the signal, which is why it is not done
    // here first. Nothing is detached either: a refusal is only useful if it
    // comes back.
    function stopServer(server, hard) {
        if (!server) return
        root.refusalText = ""
        stopQueue = stopQueue.concat([{
            server: server,
            hard: hard === true,
            command: [root.stopPath,
                      "--pid", String(server.pid),
                      "--start-time", String(server.startTime),
                      "--ports", (server.ports || []).join(","),
                      "--signal", hard === true ? "KILL" : "TERM"]
        }])
        runNextStop()
    }

    function runNextStop() {
        if (stopProcess.running || stopQueue.length === 0) return
        var request = stopQueue[0]
        stopQueue = stopQueue.slice(1)
        stopProcess.request = request
        stopProcess.command = request.command
        stopProcess.running = true
    }

    Process {
        id: stopProcess
        property var request: null
        running: false

        // Refusals accumulate rather than overwrite: two rows stopped together
        // are two answers owed, and the second arriving is no reason to drop
        // the first.
        stderr: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                if (text.trim() === "") return
                var reason = text.trim().split("\n").pop().replace(/^ports-stop: /, "")
                root.refusalText = root.refusalText === "" ? reason : root.refusalText + " · " + reason
            }
        }

        onExited: function(exitCode) {
            var request = stopProcess.request
            stopProcess.request = null
            if (request) root.stopFinished(request.server, request.hard, exitCode !== 0)
            root.scan()
            Qt.callLater(root.runNextStop)
        }
    }
}
