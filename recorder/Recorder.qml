import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Wayland._WlrLayerShell
import Quickshell.Hyprland
import Quickshell.Hyprland._GlobalShortcuts
import Quickshell.Services.Pipewire
import "../common"

// Screen recorder around wf-recorder.
//
// SUPER+F10 opens the panel (source, audio, countdown); pressed while
// recording it stops. SUPER+Shift+R skips the panel: region straight away,
// with the panel's last audio choice. The pill is the only recording status.
Scope {
    id: rec

    // idle | picking | countdown | recording | stopping | saved
    property string phase: "idle"
    property int sourceIndex: 0
    property string audio: "mic"            // none | mic | system
    property bool useCountdown: true
    property bool skipCountdown: false
    property int remaining: 0
    property int elapsed: 0
    property string file: ""
    property string geometry: ""            // "x,y wxh" when recording a region
    property string outputName: ""          // monitor when recording a whole screen
    property bool discard: false
    property bool stopRequested: false
    property string lastError: ""

    readonly property string videos: Quickshell.env("HOME") + "/Videos"

    // The env points libva at nvidia, which can't encode here; the Intel iGPU
    // can. renderD128/129 swap between boots, so address it by PCI path.
    readonly property string renderNode: "/dev/dri/by-path/pci-0000:00:02.0-render"

    readonly property var sources: Quickshell.screens.map(s => ({
        kind: "screen", name: s.name, label: s.name, detail: s.width + "×" + s.height
    })).concat([{ kind: "region", name: "", label: "Region", detail: "drag, or click a window" }])

    readonly property var audioModes: [
        { id: "none", label: "None", icon: String.fromCodePoint(0xF0581) },
        { id: "mic", label: "Mic", icon: "" },
        { id: "system", label: "System", icon: "" }
    ]

    readonly property bool busy: phase !== "idle" && phase !== "saved"

    // Theme.mono wants the "Nerd Font Mono" variant, which isn't installed here;
    // its fallback (plain monospace) only borrows the glyphs, small and off-size.
    readonly property string iconFont: Qt.fontFamilies().indexOf("JetBrainsMono Nerd Font") !== -1
        ? "JetBrainsMono Nerd Font" : Theme.mono

    // ---- screens -----------------------------------------------------------

    function screenNamed(name) {
        return Quickshell.screens.find(s => s.name === name) || null
    }

    function parseGeometry(g) {
        var m = /^(-?\d+),(-?\d+) (\d+)x(\d+)$/.exec(g.trim())
        return m ? { x: +m[1], y: +m[2], w: +m[3], h: +m[4] } : null
    }

    readonly property var region: geometry ? parseGeometry(geometry) : null

    readonly property var targetScreen: {
        if (outputName) return screenNamed(outputName)
        if (!region) return null
        return Quickshell.screens.find(s => region.x >= s.x && region.x < s.x + s.width
                                         && region.y >= s.y && region.y < s.y + s.height) || null
    }

    // wf-recorder can't leave a layer surface out of a capture, so a whole-screen
    // recording puts the pill on another screen (the focused one if it can);
    // a region keeps it on its own screen, outside the region. Chosen once per
    // recording so it doesn't follow focus around.
    property string pillOn: ""

    function choosePillScreen() {
        var t = targetScreen
        if (!outputName) return t ? t.name : ""
        var f = Hyprland.focusedMonitor ? screenNamed(Hyprland.focusedMonitor.name) : null
        if (f && f !== t) return f.name
        var other = Quickshell.screens.find(s => s !== t)
        return other ? other.name : (t ? t.name : "")
    }

    readonly property var pillScreen: screenNamed(pillOn) || targetScreen || Quickshell.screens[0]

    // Bottom of the screen, unless a recorded region reaches down there.
    readonly property bool pillAtBottom: !(region !== null && pillScreen === targetScreen
        && targetScreen.y + targetScreen.height - (region.y + region.h) < Theme.s(80))

    // Where the pill was dragged to, per screen, in the overlay's coordinates.
    property var pillPos: ({})
    readonly property var pillPosHere: pillPos[pillScreen ? pillScreen.name : ""] || null

    function nextPillScreen() {
        var all = Quickshell.screens
        pillOn = all[(all.indexOf(pillScreen) + 1) % all.length].name
    }

    function savePill(x, y) {
        var p = Object.assign({}, pillPos)
        p[pillScreen.name] = { x: x, y: y }
        pillPos = p
    }

    function resetPill() {
        var p = Object.assign({}, pillPos)
        delete p[pillScreen ? pillScreen.name : ""]
        pillPos = p
    }

    // ---- flow --------------------------------------------------------------

    // quick: SUPER+Shift+R -- region, no countdown, panel settings untouched.
    function start(quick) {
        panel.close()
        lastError = ""
        discard = false
        stopRequested = false
        skipCountdown = !!quick
        var src = quick ? sources[sources.length - 1] : sources[sourceIndex]
        if (src.kind === "region") {
            phase = "picking"
            geometry = ""
            outputName = ""
            pickProc.running = true
        } else {
            outputName = src.name
            geometry = ""
            beginCountdown()
        }
    }

    function quickRegion() {
        if (phase === "recording") { stop(); return }
        if (busy) return
        start(true)
    }

    function beginCountdown() {
        pillOn = choosePillScreen()
        if (!useCountdown || skipCountdown) { startRecording(); return }
        phase = "countdown"
        remaining = 3
        countTimer.restart()
    }

    function startRecording() {
        var stamp = Qt.formatDateTime(new Date(), "yyyy-MM-dd_HH-mm-ss")
        file = videos + "/" + stamp + ".mp4"
        var cmd = ["wf-recorder", "-c", "h264_vaapi", "-d", renderNode, "-f", file]
        cmd = cmd.concat(geometry ? ["-g", geometry] : ["-o", outputName])
        var src = audioSource()
        if (src) cmd.push("--audio=" + src)
        wfProc.command = cmd
        elapsed = 0
        phase = "recording"
        wfProc.running = true
    }

    function audioSource() {
        if (audio === "mic" && Pipewire.defaultAudioSource) return Pipewire.defaultAudioSource.name
        if (audio === "system" && Pipewire.defaultAudioSink) return Pipewire.defaultAudioSink.name + ".monitor"
        return ""
    }

    function stop() {
        if (phase !== "recording") return
        stopRequested = true
        phase = "stopping"
        wfProc.signal(2)    // SIGINT: wf-recorder finalises the mp4
        killTimer.restart()
    }

    function cancel() {
        if (phase === "countdown") { countTimer.stop(); phase = "idle"; return }
        if (phase === "recording") { discard = true; stop() }
    }

    function finished(code) {
        killTimer.stop()
        tick.stop()
        if (discard) {
            run(["trash-put", file])
            phase = "idle"
        } else if (!stopRequested) {
            phase = "idle"
            notify(["-u", "critical", "Recording failed",
                    lastError || ("wf-recorder exited with " + code)])
        } else {
            phase = "saved"
        }
    }

    readonly property string shortFile: file.replace(Quickshell.env("HOME"), "~")

    function openFile() { run(["xdg-open", file]); phase = "idle" }
    function showFolder() { run(["xdg-open", videos]); phase = "idle" }
    function deleteFile() { run(["trash-put", file]); phase = "idle" }
    function dismiss() { if (phase === "saved") phase = "idle" }

    // ---- waybar dock -------------------------------------------------------
    // Dropping the pill on a waybar docks it: the pill hides and waybar's
    // group/recorder (scripts/recorder.sh, one module per button) shows the
    // same controls, read from this status file. Waybar's clicks come back
    // through the IpcHandler below. RTMIN+8 makes the buttons re-read it on a
    // state change; only the timer module polls.

    property bool docked: false
    property var bars: ({})                 // screen name -> [{ y, h }] in global coordinates

    readonly property string statusJson: JSON.stringify({
        docked: docked, phase: phase,
        time: phase === "countdown" ? String(remaining) : clock(elapsed),
        file: shortFile, source: geometry ? "Region" : outputName
    })
    onStatusJsonChanged: statusFile.setText(statusJson)

    readonly property string barShape: (docked ? "docked-" : "floating-") + phase
    onBarShapeChanged: run(["pkill", "-RTMIN+8", "waybar"])

    function overBar(item, scr) {
        var cy = scr.y + item.y + item.height / 2
        return (bars[scr.name] || []).some(b => cy >= b.y - Theme.s(8) && cy <= b.y + b.h + Theme.s(8))
    }

    function undock() {
        docked = false
        resetPill()
    }

    FileView {
        id: statusFile
        path: Quickshell.env("XDG_RUNTIME_DIR") + "/quickshell-recorder.json"
        printErrors: false
        Component.onCompleted: setText(rec.statusJson)
    }

    Process {
        id: barsProc
        command: ["hyprctl", "layers", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                var out = {}
                try {
                    var d = JSON.parse(text)
                    for (var mon in d)
                        for (var lv in d[mon].levels)
                            d[mon].levels[lv].forEach(l => {
                                if (l.namespace !== "waybar") return
                                if (!out[mon]) out[mon] = []
                                out[mon].push({ y: l.y, h: l.h })
                            })
                } catch (e) {}
                rec.bars = out
            }
        }
    }

    function clock(sec) {
        var h = Math.floor(sec / 3600), m = Math.floor(sec / 60) % 60, s = sec % 60
        var mm = (m < 10 ? "0" : "") + m, ss = (s < 10 ? "0" : "") + s
        return h > 0 ? h + ":" + mm + ":" + ss : mm + ":" + ss
    }

    function notify(args) { run(["notify-send", "-a", "recorder"].concat(args)) }

    function run(cmd) {
        var p = runner.createObject(rec, { command: cmd })
        p.running = true
    }

    Component {
        id: runner
        Process { onExited: destroy() }
    }

    // ---- processes ---------------------------------------------------------

    Process {
        id: wfProc
        environment: ({ LIBVA_DRIVER_NAME: "iHD" })
        stderr: SplitParser { onRead: line => { if (line.trim()) rec.lastError = line.trim() } }
        onStarted: tick.restart()
        onExited: code => rec.finished(code)
    }

    // slurp snaps to the boxes it reads on stdin: the windows on every visible workspace.
    Process {
        id: pickProc
        command: ["sh", "-c",
            "ws=$(hyprctl -j monitors | jq -c '[.[].activeWorkspace.id]'); " +
            "hyprctl -j clients | jq -r --argjson ws \"$ws\" " +
            "'.[] | select(.workspace.id as $w | $ws | any(. == $w)) " +
            "| \"\\(.at[0]),\\(.at[1]) \\(.size[0])x\\(.size[1])\"' | slurp"]
        stdout: StdioCollector { id: pickOut }
        onExited: code => {
            var g = pickOut.text.trim()
            if (code !== 0 || !rec.parseGeometry(g)) { rec.phase = "idle"; return }
            rec.geometry = g
            rec.beginCountdown()
        }
    }

    Process {
        id: mkdirProc
        command: ["mkdir", "-p", rec.videos]
        running: true
    }

    Timer {
        id: countTimer
        interval: 1000
        repeat: true
        onTriggered: {
            rec.remaining -= 1
            if (rec.remaining <= 0) { countTimer.stop(); rec.startRecording() }
        }
    }

    Timer { id: tick; interval: 1000; repeat: true; onTriggered: rec.elapsed += 1 }

    // wf-recorder normally finishes the file within a second of SIGINT.
    Timer { id: killTimer; interval: 8000; onTriggered: wfProc.running = false }

    PwObjectTracker {
        objects: [Pipewire.defaultAudioSource, Pipewire.defaultAudioSink].filter(n => n !== null)
    }

    GlobalShortcut {
        appid: "quickshell"
        name: "record-region"
        description: "Record a region (stops a running recording)"
        onPressed: rec.quickRegion()
    }

    IpcHandler {
        target: "recorder"
        function stop(): void { rec.stop() }
        function cancel(): void { rec.cancel() }
        function open(): void { rec.openFile() }
        function folder(): void { rec.showFolder() }
        function remove(): void { rec.deleteFile() }
        function dismiss(): void { rec.dismiss() }
        function undock(): void { rec.undock() }
        function status(): string { return rec.phase }
    }

    // ---- panel -------------------------------------------------------------

    Popup {
        id: panel
        shortcut: "toggle-recorder"
        shortcutDescription: "Screen recorder (stops a running recording)"

        implicitWidth: Theme.s(460)
        implicitHeight: col.implicitHeight + Theme.s(36)

        function open() {
            if (rec.phase === "recording") { rec.stop(); return }
            if (rec.phase === "countdown") { rec.cancel(); return }
            if (rec.busy) return
            rec.dismiss()
            if (rec.sourceIndex >= rec.sources.length) rec.sourceIndex = 0
            visible = true
            card.forceActiveFocus()
        }

        Card {
            id: card
            anchors.fill: parent
            focus: true

            Keys.onPressed: event => {
                var k = event.key
                var n = rec.sources.length
                if (k === Qt.Key_Escape) panel.close()
                else if (k === Qt.Key_Right || k === Qt.Key_L || k === Qt.Key_Tab)
                    rec.sourceIndex = (rec.sourceIndex + 1) % n
                else if (k === Qt.Key_Left || k === Qt.Key_H || k === Qt.Key_Backtab)
                    rec.sourceIndex = (rec.sourceIndex - 1 + n) % n
                else if (k >= Qt.Key_1 && k <= Qt.Key_9 && k - Qt.Key_1 < n)
                    rec.sourceIndex = k - Qt.Key_1
                else if (k === Qt.Key_A) {
                    var i = rec.audioModes.findIndex(m => m.id === rec.audio)
                    rec.audio = rec.audioModes[(i + 1) % rec.audioModes.length].id
                }
                else if (k === Qt.Key_C) rec.useCountdown = !rec.useCountdown
                else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) rec.start()
                else return
                event.accepted = true
            }

            Column {
                id: col
                anchors.top: parent.top; anchors.topMargin: Theme.s(18)
                anchors.left: parent.left; anchors.leftMargin: Theme.s(18)
                anchors.right: parent.right; anchors.rightMargin: Theme.s(18)
                spacing: Theme.s(10)

                Row {
                    spacing: Theme.s(10)
                    Text {
                        text: ""
                        font.family: rec.iconFont
                        font.pixelSize: Theme.s(15)
                        color: Theme.danger
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: "Screen recording"
                        font.pixelSize: Theme.s(14)
                        font.bold: true
                        color: Theme.text
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                SectionLabel { text: "Source" }

                Row {
                    id: tiles
                    spacing: Theme.s(8)
                    readonly property real tileW: (col.width - spacing * (rec.sources.length - 1)) / rec.sources.length

                    Repeater {
                        model: rec.sources
                        delegate: Rectangle {
                            required property var modelData
                            required property int index
                            readonly property bool sel: index === rec.sourceIndex

                            width: tiles.tileW
                            height: Theme.s(76)
                            radius: Theme.s(10)
                            color: sel ? Theme.surfaceAlt : Theme.surface
                            border.width: sel ? 2 : 1
                            border.color: sel ? Theme.accent : Theme.line

                            Column {
                                anchors.centerIn: parent
                                spacing: Theme.s(3)
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: modelData.kind === "region" ? "" : ""
                                    font.family: rec.iconFont
                                    font.pixelSize: Theme.s(18)
                                    color: sel ? Theme.accent : Theme.dim
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: modelData.label
                                    font.pixelSize: Theme.s(11)
                                    font.bold: sel
                                    color: sel ? Theme.text : Theme.dim
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    width: tiles.tileW - Theme.s(8)
                                    horizontalAlignment: Text.AlignHCenter
                                    elide: Text.ElideRight
                                    text: modelData.detail
                                    font.pixelSize: Theme.s(8)
                                    color: Theme.muted
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: rec.sourceIndex = index
                                onDoubleClicked: { rec.sourceIndex = index; rec.start() }
                            }
                        }
                    }
                }

                SectionLabel { text: "Audio" }

                Row {
                    id: audioRow
                    spacing: Theme.s(8)
                    Repeater {
                        model: rec.audioModes
                        delegate: Rectangle {
                            required property var modelData
                            readonly property bool sel: modelData.id === rec.audio
                            width: (col.width - audioRow.spacing * 2) / 3
                            height: Theme.s(34)
                            radius: Theme.s(8)
                            color: sel ? Theme.accentDim : Theme.surface
                            border.width: 1
                            border.color: sel ? Theme.accent : Theme.line

                            Row {
                                anchors.centerIn: parent
                                spacing: Theme.s(7)
                                Text {
                                    text: modelData.icon
                                    font.family: rec.iconFont
                                    font.pixelSize: Theme.s(12)
                                    color: Theme.text
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Text {
                                    text: modelData.label
                                    font.pixelSize: Theme.s(11)
                                    color: Theme.text
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: rec.audio = modelData.id
                            }
                        }
                    }
                }

                Text {
                    width: col.width
                    elide: Text.ElideRight
                    visible: rec.audio !== "none"
                    text: {
                        var n = rec.audio === "mic" ? Pipewire.defaultAudioSource : Pipewire.defaultAudioSink
                        return n ? (n.description || n.nickname || n.name) : "no default device"
                    }
                    font.pixelSize: Theme.s(9)
                    color: Theme.muted
                }

                Item {
                    width: col.width
                    height: Theme.s(30)
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "  Countdown 3 s"
                        font.family: rec.iconFont
                        font.pixelSize: Theme.s(11)
                        color: Theme.dim
                    }
                    Toggle {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        checked: rec.useCountdown
                        onToggled: rec.useCountdown = !rec.useCountdown
                    }
                }

                Rectangle {
                    width: col.width
                    height: Theme.s(42)
                    radius: Theme.s(10)
                    color: startArea.containsMouse ? Qt.lighter(Theme.danger, 1.12) : Theme.danger

                    Text {
                        anchors.centerIn: parent
                        text: "  Start recording"
                        font.family: rec.iconFont
                        font.pixelSize: Theme.s(12)
                        font.bold: true
                        color: Theme.text
                    }

                    MouseArea {
                        id: startArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: rec.start()
                    }
                }

                Text {
                    width: col.width
                    horizontalAlignment: Text.AlignHCenter
                    text: "←/→ or 1–" + rec.sources.length + " source · A audio · C countdown · Enter start · Esc close"
                    font.pixelSize: Theme.s(8)
                    color: Theme.muted
                }
            }
        }
    }

    component SectionLabel: Text {
        font.pixelSize: Theme.s(9)
        font.bold: true
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 1
        color: Theme.muted
    }

    // ---- recording controls ------------------------------------------------

    PanelWindow {
        id: pill
        visible: !rec.docked && (rec.phase === "countdown" || rec.phase === "recording"
                 || rec.phase === "stopping" || rec.phase === "saved")
        screen: rec.pillScreen
        focusable: false
        color: "transparent"
        // A whole-screen, click-through overlay (only the pill takes input) so
        // dragging moves an item inside a fixed surface. Moving the layer
        // surface itself lags the pointer by a configure round-trip and runs
        // away. Ignore so the pill can be dragged over waybar too.
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "quickshell-recorder"
        anchors { top: true; bottom: true; left: true; right: true }
        mask: Region { item: pillBox }

        Rectangle {
            id: pillBox
            width: pillRow.implicitWidth + Theme.s(24)
            height: Theme.s(44)
            radius: height / 2
            color: Qt.alpha(Theme.bg, 0.95)
            border.width: 1
            border.color: Qt.alpha(rec.phase === "saved" ? Theme.ok : Theme.danger, 0.7)

            function place() {
                var p = rec.pillPosHere
                var maxX = Math.max(0, pill.width - width), maxY = Math.max(0, pill.height - height)
                x = p ? Math.min(p.x, maxX) : maxX / 2
                // The default clears a 35 px waybar at either edge.
                y = p ? Math.min(p.y, maxY) : (rec.pillAtBottom ? maxY - Theme.s(36) : Theme.s(36))
            }

            Component.onCompleted: place()
            onWidthChanged: if (!dragArea.drag.active) place()
            Connections {
                target: rec
                function onPillPosHereChanged() { if (!dragArea.drag.active) pillBox.place() }
                function onPillAtBottomChanged() { pillBox.place() }
                function onPillOnChanged() { pillBox.place() }
            }
            Connections {
                target: pill
                function onWidthChanged() { pillBox.place() }
                function onHeightChanged() { pillBox.place() }
            }

            HoverHandler { id: pillHover }

            MouseArea {
                id: dragArea
                anchors.fill: parent
                cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                drag.target: pillBox
                drag.minimumX: 0
                drag.minimumY: 0
                drag.maximumX: pill.width - pillBox.width
                drag.maximumY: pill.height - pillBox.height
                drag.threshold: 2
                property bool moved: false
                onPressed: { moved = false; barsProc.running = true }
                onPositionChanged: if (drag.active) moved = true
                onReleased: {
                    if (!moved) return
                    if (rec.overBar(pillBox, pill.screen)) rec.docked = true
                    else rec.savePill(pillBox.x, pillBox.y)
                }
                onDoubleClicked: rec.resetPill()
            }

            // The saved state lingers until clicked away, or 10 s without the pointer on it.
            Timer {
                interval: 10000
                running: rec.phase === "saved" && !pillHover.hovered
                onTriggered: rec.dismiss()
            }

            Row {
                id: pillRow
                anchors.centerIn: parent
                spacing: Theme.s(12)

                Rectangle {
                    id: dot
                    width: Theme.s(11); height: width; radius: width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    color: rec.phase === "countdown" ? Theme.warn
                         : rec.phase === "saved" ? Theme.ok : Theme.danger
                    SequentialAnimation on opacity {
                        running: rec.phase === "recording"
                        loops: Animation.Infinite
                        onRunningChanged: if (!running) dot.opacity = 1
                        NumberAnimation { to: 0.25; duration: 700 }
                        NumberAnimation { to: 1; duration: 700 }
                    }
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: rec.phase === "countdown" ? "Starting in " + rec.remaining
                        : rec.phase === "stopping" ? "Saving…"
                        : rec.phase === "saved" ? "Saved"
                        : rec.clock(rec.elapsed)
                    font.family: rec.iconFont
                    font.pixelSize: Theme.s(13)
                    font.bold: true
                    color: Theme.text
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: rec.phase === "saved" ? rec.shortFile + "  ·  " + rec.clock(rec.elapsed)
                        : (rec.geometry ? "Region" : rec.outputName)
                        + (rec.audio === "mic" ? "  " : rec.audio === "system" ? "  " : "")
                    font.family: rec.iconFont
                    font.pixelSize: Theme.s(10)
                    color: Theme.muted
                }

                PillButton {
                    visible: Quickshell.screens.length > 1
                    icon: ""
                    tint: Theme.accent
                    hint: "Move to the next screen"
                    onClicked: rec.nextPillScreen()
                }

                PillButton {
                    visible: rec.phase === "recording"
                    icon: ""
                    tint: Theme.danger
                    hint: "Stop and save to ~/Videos"
                    onClicked: rec.stop()
                }

                PillButton {
                    visible: rec.phase === "countdown" || rec.phase === "recording"
                    icon: rec.phase === "countdown" ? "" : ""
                    tint: Theme.muted
                    hint: rec.phase === "countdown" ? "Cancel" : "Stop and discard (moves to trash)"
                    onClicked: rec.cancel()
                }

                PillButton {
                    visible: rec.phase === "saved"
                    icon: ""
                    tint: Theme.ok
                    hint: "Open the video"
                    onClicked: rec.openFile()
                }

                PillButton {
                    visible: rec.phase === "saved"
                    icon: ""
                    tint: Theme.accent
                    hint: "Show in folder"
                    onClicked: rec.showFolder()
                }

                PillButton {
                    visible: rec.phase === "saved"
                    icon: ""
                    tint: Theme.danger
                    hint: "Delete (moves to trash)"
                    onClicked: rec.deleteFile()
                }

                PillButton {
                    visible: rec.phase === "saved"
                    icon: ""
                    tint: Theme.muted
                    hint: "Close"
                    onClicked: rec.dismiss()
                }
            }
        }
    }

    component PillButton: Rectangle {
        id: btn
        property string icon
        property color tint
        property string hint
        signal clicked()

        anchors.verticalCenter: parent.verticalCenter
        width: Theme.s(30); height: width; radius: width / 2
        color: area.containsMouse ? Theme.surfaceAlt : Theme.surface

        Text {
            anchors.centerIn: parent
            text: btn.icon
            font.family: rec.iconFont
            font.pixelSize: Theme.s(12)
            color: btn.tint
        }

        MouseArea {
            id: area
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.clicked()
        }

        PopupWindow {
            visible: area.containsMouse && btn.visible && btn.hint !== ""
            anchor.item: btn
            anchor.edges: rec.pillAtBottom ? Edges.Top : Edges.Bottom
            anchor.gravity: rec.pillAtBottom ? Edges.Top : Edges.Bottom
            anchor.margins.top: rec.pillAtBottom ? 0 : -Theme.s(8)
            anchor.margins.bottom: rec.pillAtBottom ? -Theme.s(8) : 0
            color: "transparent"
            implicitWidth: tip.implicitWidth + Theme.s(18)
            implicitHeight: tip.implicitHeight + Theme.s(10)

            Rectangle {
                anchors.fill: parent
                radius: Theme.s(6)
                color: Theme.surface
                border.width: 1
                border.color: Theme.line

                Text {
                    id: tip
                    anchors.centerIn: parent
                    text: btn.hint
                    font.pixelSize: Theme.s(10)
                    color: Theme.text
                }
            }
        }
    }

    // Red frame just outside the recorded region, click-through, so it marks
    // the area without ending up in the video.
    PanelWindow {
        visible: rec.region !== null && rec.targetScreen !== null
                 && (rec.phase === "countdown" || rec.phase === "recording")
        screen: rec.targetScreen
        focusable: false
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "quickshell-recorder-frame"
        anchors { top: true; bottom: true; left: true; right: true }
        mask: Region {}

        Rectangle {
            readonly property int pad: 3
            x: rec.region && rec.targetScreen ? rec.region.x - rec.targetScreen.x - pad : 0
            y: rec.region && rec.targetScreen ? rec.region.y - rec.targetScreen.y - pad : 0
            width: rec.region ? rec.region.w + pad * 2 : 0
            height: rec.region ? rec.region.h + pad * 2 : 0
            color: "transparent"
            border.width: 2
            border.color: rec.phase === "countdown" ? Theme.warn : Theme.danger
        }
    }
}
