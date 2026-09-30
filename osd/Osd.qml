import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Wayland._WlrLayerShell
import Quickshell.Services.Pipewire
import Quickshell.Hyprland._GlobalShortcuts
import "../common"

// On-screen display for the media keys, replacing the notify-send popups that
// Volume.sh and Brightness.sh drew.
//
// This widget OWNS those keys (hyprland binds them to quickshell:volume-* /
// brightness-*) and performs the change itself: volume natively through
// Pipewire, brightness through brightnessctl. Owning the key is what makes a
// brightness OSD possible at all -- sysfs backlight files do not deliver
// inotify events, so there is no state to watch, and polling one every 200ms
// forever to catch a keypress that happens twice a day is not a trade worth
// making.
//
// Volume is the exception: it is watched as state as well, so a change made by
// pavucontrol or an app also raises the OSD, not just our own keys.
//
// ponytail: volume caps at 100%. Volume.sh allowed boost to 150% -- if you
// want that back it is the `maxVolume` line below, but boost past 100 is
// clipping, not loudness.
PanelWindow {
    id: win

    property real maxVolume: 1.0

    // Not focusable and not grabbing: an OSD that steals focus eats the next
    // keystroke of whatever you were typing into.
    focusable: false
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    // PanelWindow has no `layer` of its own -- it comes from the layershell
    // attached type. Overlay so the OSD shows over fullscreen video too.
    WlrLayershell.layer: WlrLayer.Overlay
    anchors.bottom: true
    margins.bottom: Theme.s(140)

    implicitWidth: Theme.s(300)
    implicitHeight: Theme.s(62)

    visible: showing

    property bool showing: false
    property string kind: "volume"        // "volume" | "mic" | "brightness"
    property real value: 0                // 0..1
    property bool muted: false

    function flash(k, v, m) {
        win.kind = k
        win.value = Math.max(0, Math.min(1, v))
        win.muted = m
        win.showing = true
        hideTimer.restart()
    }

    Timer { id: hideTimer; interval: 1400; onTriggered: win.showing = false }

    // ---- audio ----
    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var source: Pipewire.defaultAudioSource
    PwObjectTracker { objects: [win.sink, win.source].filter(n => n !== null) }

    // Pipewire populates asynchronously; without this the first volume binding
    // to arrive would pop the OSD up on login.
    property bool armed: false
    Timer { id: armTimer; interval: 2500; running: true; onTriggered: win.armed = true }

    function showVolume() {
        if (win.sink && win.sink.audio)
            win.flash("volume", win.sink.audio.volume, win.sink.audio.muted)
    }

    function showMic() {
        if (win.source && win.source.audio)
            win.flash("mic", win.source.audio.volume, win.source.audio.muted)
    }

    Connections {
        target: win.sink && win.sink.audio ? win.sink.audio : null
        enabled: win.armed
        function onVolumeChanged() { win.showVolume() }
        function onMutedChanged() { win.showVolume() }
    }

    Connections {
        target: win.source && win.source.audio ? win.source.audio : null
        enabled: win.armed
        function onMutedChanged() { win.showMic() }
    }

    function volumeBy(delta) {
        if (!win.sink || !win.sink.audio) return
        var a = win.sink.audio
        a.volume = Math.max(0, Math.min(win.maxVolume, a.volume + delta))
        if (delta > 0 && a.muted) a.muted = false
        win.showVolume()   // also covers the case where the value did not move
    }

    function toggleMute() {
        if (!win.sink || !win.sink.audio) return
        win.sink.audio.muted = !win.sink.audio.muted
        win.showVolume()
    }

    function toggleMicMute() {
        if (!win.source || !win.source.audio) return
        win.source.audio.muted = !win.source.audio.muted
        win.showMic()
    }

    // ---- brightness ----
    // `-m` prints one CSV line: name,class,raw,PCT%,max -- so a single call
    // both applies the change and reports the value to draw.
    readonly property string backlight: "intel_backlight"

    Process {
        id: brightProc
        stdout: StdioCollector { id: brightOut }
        onExited: code => {
            if (code !== 0) return
            var parts = brightOut.text.trim().split(",")
            if (parts.length < 4) return
            var pct = parseInt(parts[3])
            if (!isNaN(pct)) win.flash("brightness", pct / 100, false)
        }
    }

    function brightnessBy(step) {
        brightProc.running = false
        brightProc.command = ["brightnessctl", "-m", "-d", win.backlight,
                              "set", Math.abs(step) + (step > 0 ? "%+" : "%-")]
        brightProc.running = true
    }

    // ---- chrome ----
    Card {
        anchors.fill: parent
        radius: Theme.s(14)

        Text {
            id: glyph
            anchors.left: parent.left; anchors.leftMargin: Theme.s(18)
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.s(22)
            horizontalAlignment: Text.AlignHCenter
            font.family: Theme.mono
            font.pixelSize: Theme.s(16)
            color: win.muted ? Theme.danger : Theme.accent
            text: {
                if (win.kind === "brightness") return ""
                if (win.kind === "mic") return win.muted ? "" : ""
                if (win.muted) return ""
                return win.value < 0.34 ? "" : ""
            }
        }

        Rectangle {
            id: track
            anchors.left: glyph.right; anchors.leftMargin: Theme.s(14)
            anchors.right: readout.left; anchors.rightMargin: Theme.s(12)
            anchors.verticalCenter: parent.verticalCenter
            height: Theme.s(6)
            radius: height / 2
            color: Theme.line

            Rectangle {
                width: parent.width * win.value
                height: parent.height
                radius: parent.radius
                color: win.muted ? Theme.muted : Theme.accent
                Behavior on width { NumberAnimation { duration: 90 } }
            }
        }

        Text {
            id: readout
            anchors.right: parent.right; anchors.rightMargin: Theme.s(18)
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.s(42)
            horizontalAlignment: Text.AlignRight
            text: win.muted ? "mute" : Math.round(win.value * 100) + "%"
            font.family: Theme.mono
            font.pixelSize: Theme.s(12)
            color: win.muted ? Theme.danger : Theme.text
        }
    }

    // ---- the media keys ----
    GlobalShortcut {
        appid: "quickshell"; name: "volume-up"; description: "Volume up"
        onPressed: win.volumeBy(0.05)
    }
    GlobalShortcut {
        appid: "quickshell"; name: "volume-down"; description: "Volume down"
        onPressed: win.volumeBy(-0.05)
    }
    GlobalShortcut {
        appid: "quickshell"; name: "volume-up-fine"; description: "Volume up (1%)"
        onPressed: win.volumeBy(0.01)
    }
    GlobalShortcut {
        appid: "quickshell"; name: "volume-down-fine"; description: "Volume down (1%)"
        onPressed: win.volumeBy(-0.01)
    }
    GlobalShortcut {
        appid: "quickshell"; name: "volume-mute"; description: "Mute output"
        onPressed: win.toggleMute()
    }
    GlobalShortcut {
        appid: "quickshell"; name: "mic-mute"; description: "Mute microphone"
        onPressed: win.toggleMicMute()
    }
    GlobalShortcut {
        appid: "quickshell"; name: "brightness-up"; description: "Brightness up"
        onPressed: win.brightnessBy(10)
    }
    GlobalShortcut {
        appid: "quickshell"; name: "brightness-down"; description: "Brightness down"
        onPressed: win.brightnessBy(-10)
    }
}
