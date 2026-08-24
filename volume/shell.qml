import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import Quickshell.Hyprland._GlobalShortcuts
import Quickshell.Hyprland._FocusGrab

// Volume panel: every audio device and every playing stream, with its level.
//
//   j/k or arrows   move          h/l or ←/→   volume -/+ 5%
//   Space or m      mute          Enter        make this the default device
//   Esc             close         wheel/click  adjust straight from the bar
//
// On a NOW PLAYING row the two horizontal keys mean previous/next track and
// Enter/Space is play/pause -- a media row has no level to slide, so the keys
// would otherwise do nothing there.
//
// Everything comes from Quickshell's native Pipewire service -- no wpctl/pactl
// shelling out, so levels track other apps live instead of on a poll. Nodes
// only publish their audio properties while something holds them open, which
// is what the PwObjectTracker below is for.
//
// The playback/recording split below is taken from Advanced Audio Control for
// Omarchy (ssupt, MIT -- github.com/ssupt/omarchy-audio-control, Model.js
// isPlaybackStream/isRecordingStream). Its own media.class string fallback is
// dead weight on this Quickshell build -- PwNode.type is a numeric flags enum
// here (AudioOutStream=21, AudioInStream=13), so isSink is the live signal,
// measured against a paplay and a pw-record stream. No other code is shared:
// that plugin targets Omarchy Quattro's shell host (qs.Ui / qs.Commons, a
// manifest.json plugin API and ~20 pactl/wpctl helper scripts), none of which
// exists outside Omarchy.
//
// This does NOT replace the XF86Audio keys (they still run Volume.sh, which
// draws its own OSD); it is the panel you open when you want to see and move
// several devices at once.
PanelWindow {
    id: win
    visible: false
    color: "transparent"
    // ponytail: no anchors on purpose -- see the other widgets. wlr-layer-shell
    // centres an unanchored surface on the focused output, in logical pixels,
    // which is the only version of this that survives fractional scaling.
    exclusionMode: ExclusionMode.Normal
    aboveWindows: true
    focusable: true

    implicitWidth: Theme.s(420)
    // Derived from the chrome instead of a guessed constant: a fixed pad was
    // 23px short, so the last row rendered underneath the hint separator.
    // col.y / *.height are safe to read here -- none of them depend on the
    // window height, only the hint bar's y does.
    implicitHeight: col.y + col.implicitHeight
                    + Theme.s(12) + hintSep.height + Theme.s(8)
                    + hintBar.height + Theme.s(14)

    property int selection: 0

    readonly property real step: 0.05

    // Nodes publish volume/mute only while they are bound. Track every audio
    // node we might draw, not just the default ones.
    readonly property var audioNodes: Pipewire.nodes.values.filter(n => n.audio)
    PwObjectTracker { objects: win.audioNodes }

    readonly property var sinks: audioNodes.filter(n => n.isSink && !n.isStream)
    readonly property var sources: audioNodes.filter(n => !n.isSink && !n.isStream)
    // A mic capture is a stream too -- filing it under "playing" is how a
    // Zoom call ends up looking like music.
    readonly property var playbackStreams: audioNodes.filter(n => n.isStream && n.isSink)
    readonly property var recordStreams: audioNodes.filter(n => n.isStream && !n.isSink)

    // Transport for whatever is actually playing. The per-app stream rows above
    // already carry app volume, so these rows carry title/artist instead.
    readonly property var players: {
        var all = Mpris.players.values.filter(p => p.canControl)
        // VLC registers both `…MediaPlayer2.vlc` and `….vlc.instance987498`:
        // the same player twice. Drop any name that is a prefix of another.
        // Two Firefox tabs still get a row each -- neither of their instance
        // names is a prefix of the other.
        return all.filter(p => !all.some(o => o !== p
            && o.dbusName.indexOf(p.dbusName + ".") === 0))
    }

    function playerLabel(p) {
        var t = p.trackTitle || p.identity || "unknown"
        return p.trackArtist ? t + "  —  " + p.trackArtist : t
    }

    function label(n) {
        if (n.isStream)
            return n.properties["application.name"] || n.description || n.name
        return n.description || n.nickname || n.name
    }

    // One flat model holding section headers and rows alike -- move() steps
    // over the headers. Two parallel models (one to draw, one to focus) is the
    // version of this that drifts.
    readonly property var rows: {
        var out = []
        if (sinks.length) {
            out.push({ kind: "header", label: "OUTPUT" })
            for (var i = 0; i < sinks.length; i++) out.push({ kind: "sink", node: sinks[i] })
        }
        if (sources.length) {
            out.push({ kind: "header", label: "INPUT" })
            for (var j = 0; j < sources.length; j++) out.push({ kind: "source", node: sources[j] })
        }
        if (playbackStreams.length) {
            out.push({ kind: "header", label: "PLAYING" })
            for (var k = 0; k < playbackStreams.length; k++)
                out.push({ kind: "stream", node: playbackStreams[k] })
        }
        if (recordStreams.length) {
            out.push({ kind: "header", label: "RECORDING" })
            for (var m = 0; m < recordStreams.length; m++)
                out.push({ kind: "recstream", node: recordStreams[m] })
        }
        if (players.length) {
            out.push({ kind: "header", label: "NOW PLAYING" })
            for (var q = 0; q < players.length; q++)
                out.push({ kind: "player", player: players[q] })
        }
        return out
    }

    onRowsChanged: if (!rows[selection] || rows[selection].kind === "header") selectFirst()

    function selectFirst() {
        for (var i = 0; i < rows.length; i++)
            if (rows[i].kind !== "header") { win.selection = i; return }
        win.selection = 0
    }

    function move(delta) {
        if (rows.length === 0) return
        // step past headers; bail after a full lap so an all-header list
        // (no audio devices at all) can't spin forever
        var i = win.selection
        for (var n = 0; n < rows.length; n++) {
            i = (i + delta + rows.length) % rows.length
            if (rows[i].kind !== "header") { win.selection = i; return }
        }
    }

    function current() {
        var r = rows[win.selection]
        return r && r.kind !== "header" ? r : null
    }

    function isDefault(r) {
        if (r.kind === "player") return r.player.isPlaying
        if (r.kind === "sink") return Pipewire.defaultAudioSink === r.node
        if (r.kind === "source") return Pipewire.defaultAudioSource === r.node
        return false
    }

    // ponytail: capped at 100%. PipeWire will happily amplify past 1.0, and
    // the one thing a volume panel must never do is blow someone's ears out
    // because a key repeated. Raise the cap here if you ever want boost.
    function setVolume(r, v) {
        if (!r || r.kind === "player" || !r.node.audio) return
        r.node.audio.volume = Math.max(0, Math.min(1, v))
    }

    function bump(delta) {
        var r = current()
        if (!r) return
        // h/l on a media row seeks tracks -- there is no level to move
        if (r.kind === "player") {
            if (delta > 0) { if (r.player.canGoNext) r.player.next() }
            else if (r.player.canGoPrevious) r.player.previous()
            return
        }
        if (!r.node.audio) return
        setVolume(r, r.node.audio.volume + delta)
        // turning it up is an unambiguous "I want to hear this"
        if (delta > 0 && r.node.audio.muted) r.node.audio.muted = false
    }

    function toggleMute() {
        var r = current()
        if (!r) return
        if (r.kind === "player") { r.player.togglePlaying(); return }
        if (r.node.audio) r.node.audio.muted = !r.node.audio.muted
    }

    function makeDefault() {
        var r = current()
        if (!r) return
        if (r.kind === "player") { r.player.togglePlaying(); return }
        if (r.kind === "sink") Pipewire.preferredDefaultAudioSink = r.node
        else if (r.kind === "source") Pipewire.preferredDefaultAudioSource = r.node
    }

    function open() {
        win.visible = true
        win.selectFirst()
    }

    function close() { win.visible = false }

    Rectangle {
        id: panelBg
        anchors.fill: parent
        radius: Theme.s(18)
        color: "#f20c0e11"
        border.width: 1
        border.color: "#1e2228"
        focus: true

        Keys.onPressed: event => {
            var txt = event.text
            var k = event.key
            if (k === Qt.Key_Escape) { win.close(); event.accepted = true }
            else if (txt === "j" || k === Qt.Key_Down) { win.move(1); event.accepted = true }
            else if (txt === "k" || k === Qt.Key_Up) { win.move(-1); event.accepted = true }
            else if (txt === "h" || k === Qt.Key_Left) { win.bump(-win.step); event.accepted = true }
            else if (txt === "l" || k === Qt.Key_Right) { win.bump(win.step); event.accepted = true }
            else if (txt === "m" || k === Qt.Key_Space) { win.toggleMute(); event.accepted = true }
            else if (k === Qt.Key_Return || k === Qt.Key_Enter) { win.makeDefault(); event.accepted = true }
        }

        Text {
            id: title
            anchors.top: parent.top; anchors.topMargin: Theme.s(16)
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            text: "VOLUME"
            font.pixelSize: Theme.s(13)
            font.bold: true
            font.letterSpacing: 2
            color: Theme.dim
        }

        Text {
            anchors.verticalCenter: title.verticalCenter
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            visible: !Pipewire.ready
            text: "connecting to pipewire…"
            font.pixelSize: Theme.s(11)
            color: Theme.warn
        }

        Column {
            id: col
            anchors.top: title.bottom; anchors.topMargin: Theme.s(12)
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            spacing: Theme.s(2)

            Repeater {
                model: win.rows

                delegate: Item {
                    id: row
                    required property var modelData
                    required property int index

                    readonly property bool isHeader: modelData.kind === "header"
                    readonly property bool focused: index === win.selection
                    readonly property bool isPlayer: modelData.kind === "player"
                    readonly property bool hasLevel: !isHeader && !isPlayer
                    readonly property var audio: hasLevel ? modelData.node.audio : null
                    readonly property real vol: audio ? audio.volume : 0
                    readonly property bool muted: audio ? audio.muted : false

                    width: col.width
                    height: isHeader ? Theme.s(26) : Theme.s(40)

                    // ---- section header ----
                    Text {
                        visible: row.isHeader
                        anchors.left: parent.left; anchors.leftMargin: Theme.s(4)
                        anchors.bottom: parent.bottom; anchors.bottomMargin: Theme.s(4)
                        // device rows have no .label -- binding it raw warns
                        // once per row on every model change
                        text: row.isHeader ? row.modelData.label : ""
                        font.pixelSize: Theme.s(10)
                        font.letterSpacing: 1.5
                        color: Theme.muted
                    }

                    // ---- device / stream row ----
                    Rectangle {
                        visible: !row.isHeader
                        anchors.fill: parent
                        radius: Theme.s(8)
                        color: row.focused ? Theme.surfaceAlt : "transparent"
                        border.width: row.focused ? 1 : 0
                        border.color: Theme.accent

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: win.selection = row.index
                            onDoubleClicked: { win.selection = row.index; win.makeDefault() }
                            onWheel: wheel => {
                                win.selection = row.index
                                win.bump(wheel.angleDelta.y > 0 ? win.step : -win.step)
                            }
                        }

                        Text {
                            id: rowIcon
                            anchors.left: parent.left; anchors.leftMargin: Theme.s(12)
                            anchors.verticalCenter: parent.verticalCenter
                            width: Theme.s(18)
                            horizontalAlignment: Text.AlignHCenter
                            font.family: Theme.mono
                            font.pixelSize: Theme.s(14)
                            color: row.muted ? Theme.danger
                                 : (row.focused || (row.isPlayer && row.modelData.player.isPlaying))
                                   ? Theme.accent : Theme.dim
                            text: {
                                if (row.isHeader) return ""
                                if (row.isPlayer)
                                    return row.modelData.player.isPlaying ? "\uf04c" : "\uf04b"
                                if (row.modelData.kind === "source"
                                    || row.modelData.kind === "recstream")
                                    return row.muted ? "" : ""
                                if (row.modelData.kind === "stream") return ""
                                return row.muted ? "" : ""
                            }
                        }

                        // A dot on the row that audio actually goes to, so
                        // "which one is live" is answerable at a glance.
                        Rectangle {
                            id: defaultDot
                            visible: !row.isHeader && win.isDefault(row.modelData)
                            anchors.left: rowIcon.right; anchors.leftMargin: Theme.s(8)
                            anchors.verticalCenter: parent.verticalCenter
                            width: Theme.s(6); height: Theme.s(6); radius: Theme.s(3)
                            color: Theme.accent
                        }

                        Text {
                            id: rowLabel
                            anchors.left: rowIcon.right
                            anchors.leftMargin: Theme.s(8) + (defaultDot.visible ? Theme.s(12) : 0)
                            // stop at whichever right-hand element this row
                            // actually has, or a media row leaves a bar-shaped hole
                            anchors.right: row.hasLevel ? bar.left : playerId.left
                            anchors.rightMargin: Theme.s(12)
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                            text: row.isHeader ? ""
                                : row.isPlayer ? win.playerLabel(row.modelData.player)
                                : win.label(row.modelData.node)
                            font.pixelSize: Theme.s(12)
                            color: row.focused ? Theme.text : Theme.dim
                        }

                        // ---- level bar ----
                        Rectangle {
                            id: bar
                            visible: row.hasLevel
                            anchors.right: pct.left; anchors.rightMargin: Theme.s(10)
                            anchors.verticalCenter: parent.verticalCenter
                            width: Theme.s(120)
                            height: Theme.s(6)
                            radius: height / 2
                            color: Theme.line

                            Rectangle {
                                width: parent.width * row.vol
                                height: parent.height
                                radius: parent.radius
                                color: row.muted ? Theme.muted
                                     : row.focused ? Theme.accent : Theme.accentDim
                                Behavior on width { NumberAnimation { duration: 90 } }
                            }

                            // Click anywhere on the track to jump there --
                            // taller than the bar so it is actually hittable.
                            MouseArea {
                                anchors.fill: parent
                                anchors.topMargin: -Theme.s(12)
                                anchors.bottomMargin: -Theme.s(12)
                                cursorShape: Qt.PointingHandCursor
                                onPressed: mouse => {
                                    win.selection = row.index
                                    win.setVolume(row.modelData, mouse.x / width)
                                }
                                onPositionChanged: mouse => {
                                    if (pressed) win.setVolume(row.modelData, mouse.x / width)
                                }
                            }
                        }

                        Text {
                            id: pct
                            visible: row.hasLevel
                            anchors.right: parent.right; anchors.rightMargin: Theme.s(12)
                            anchors.verticalCenter: parent.verticalCenter
                            width: Theme.s(38)
                            horizontalAlignment: Text.AlignRight
                            text: row.muted ? "mute" : Math.round(row.vol * 100) + "%"
                            font.family: Theme.mono
                            font.pixelSize: Theme.s(11)
                            color: row.muted ? Theme.danger : Theme.dim
                        }

                        // Which app the transport belongs to, where a device
                        // row would put its percentage.
                        Text {
                            id: playerId
                            visible: row.isPlayer
                            anchors.right: parent.right; anchors.rightMargin: Theme.s(12)
                            anchors.verticalCenter: parent.verticalCenter
                            text: row.isPlayer ? row.modelData.player.identity : ""
                            font.family: Theme.mono
                            font.pixelSize: Theme.s(11)
                            color: Theme.muted
                        }
                    }
                }
            }

            Text {
                visible: win.rows.length === 0
                width: col.width
                height: Theme.s(40)
                verticalAlignment: Text.AlignVCenter
                text: Pipewire.ready ? "no audio devices" : "waiting for pipewire…"
                font.pixelSize: Theme.s(12)
                color: Theme.muted
            }
        }

        Rectangle {
            id: hintSep
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            anchors.bottom: hintBar.top; anchors.bottomMargin: Theme.s(8)
            height: 1
            color: Theme.line
        }

        Text {
            id: hintBar
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            anchors.bottom: parent.bottom; anchors.bottomMargin: Theme.s(14)
            elide: Text.ElideRight
            text: win.current() && win.current().kind === "player"
                  ? "j/k move  ·  h/l prev/next  ·  Space play/pause  ·  Esc close"
                  : "j/k move  ·  h/l ±5%  ·  Space mute  ·  Enter set default  ·  Esc close"
            font.pixelSize: Theme.s(11)
            color: Theme.dim
        }
    }

    GlobalShortcut {
        appid: "quickshell"
        name: "toggle-volume"
        description: "Toggle volume panel"
        onPressed: {
            if (win.visible) win.close()
            else win.open()
        }
    }

    HyprlandFocusGrab {
        active: win.visible
        windows: [win]
    }
}
