import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland._GlobalShortcuts
import Quickshell.Hyprland._FocusGrab

// Power menu, replacing the old rofi/walker Powermenu.sh bound to SUPER+Escape.
// j/k or arrows move, Enter act (run the action, or flip the toggle row and
// stay open), Esc close.
PanelWindow {
    id: win
    visible: false
    color: "transparent"
    // ponytail: no anchors on purpose. wlr-layer-shell centres a surface on
    // whichever axis it isn't anchored to, on the focused output, and it does
    // that in logical pixels -- so fractional scale and rotation come out
    // right for free. Computing margins by hand got both wrong: Hyprland's
    // monitor width/height are raw physical pixels, and Hyprland.focusedMonitor
    // is null until the monitor list has been populated over IPC, so it fell
    // back to win.screen (the laptop) nearly every time.
    // Normal (not Ignore) with no anchors => exclusive zone 0: the surface
    // reserves nothing itself but is centred in the area left over by bars
    // that do. Ignore (-1) centres on the raw output, which sits the panel
    // half of waybar's height too low.
    exclusionMode: ExclusionMode.Normal
    aboveWindows: true
    focusable: true

    implicitWidth: Theme.s(320)
    implicitHeight: col.implicitHeight + Theme.s(32)

    readonly property string inhibitWho: "quickshell-powermenu"
    property bool lidAwake: false
    property int selection: 0

    readonly property var items: [
        { kind: "action", label: "Lock", icon: "", cmd: ["loginctl", "lock-session"] },
        { kind: "action", label: "Suspend", icon: "", cmd: ["systemctl", "suspend"] },
        { kind: "action", label: "Reboot", icon: "", cmd: ["systemctl", "reboot"] },
        { kind: "action", label: "Shutdown", icon: "", cmd: ["systemctl", "poweroff"] },
        { kind: "action", label: "Logout", icon: "", cmd: ["hyprctl", "dispatch", "exit", "0"] },
        { kind: "toggle", label: "Stay awake (lid closed)", icon: "" }
    ]

    function open() {
        win.visible = true
        win.selection = 0
        lidCheckProc.running = true
    }

    function close() { win.visible = false }

    function move(delta) {
        win.selection = (win.selection + delta + items.length) % items.length
    }

    function setLidAwake(on) {
        win.lidAwake = on
        lidProc.running = false
        if (on) {
            lidProc.command = ["systemd-inhibit",
                "--what=handle-lid-switch", "--who=" + win.inhibitWho,
                "--why=stay awake with lid closed", "--mode=block",
                "sleep", "infinity"]
            lidProc.running = true
        }
    }

    function activate() {
        var it = items[win.selection]
        if (it.kind === "toggle") { win.setLidAwake(!win.lidAwake); return }
        actionProc.command = it.cmd
        actionProc.running = true
        win.close()
    }

    Process { id: actionProc }

    // Held open only while the toggle is on -- release (running: false) drops
    // the inhibitor lock immediately, no separate "off" command needed.
    Process { id: lidProc }

    // Re-derive state on open instead of persisting it: the widget process
    // outlives lock/suspend/reboot cycles, but re-checking is one cheap call
    // and survives a `hyprctl reload` or manual `pkill systemd-inhibit` too.
    Process {
        id: lidCheckProc
        command: ["systemd-inhibit", "--list", "--no-pager"]
        stdout: StdioCollector { id: lidCheckOut }
        onExited: code => {
            win.lidAwake = code === 0 && lidCheckOut.text.indexOf(win.inhibitWho) !== -1
        }
    }

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
            else if (k === Qt.Key_Return || k === Qt.Key_Enter || txt === " ") {
                win.activate(); event.accepted = true
            }
        }

        Column {
            id: col
            anchors.top: parent.top; anchors.topMargin: Theme.s(16)
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            spacing: Theme.s(2)

            Repeater {
                model: win.items
                delegate: Rectangle {
                    required property var modelData
                    required property int index

                    width: col.width
                    height: Theme.s(42)
                    radius: Theme.s(8)
                    color: index === win.selection ? Theme.surfaceAlt : "transparent"
                    border.width: index === win.selection ? 1 : 0
                    border.color: Theme.accent

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { win.selection = index; win.activate() }
                    }

                    Row {
                        anchors.left: parent.left; anchors.leftMargin: Theme.s(14)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.s(12)

                        Text {
                            width: Theme.s(18)
                            anchors.verticalCenter: parent.verticalCenter
                            horizontalAlignment: Text.AlignHCenter
                            text: modelData.icon
                            font.family: "JetBrainsMono Nerd Font Mono"
                            font.pixelSize: Theme.s(14)
                            color: index === win.selection ? Theme.accent : Theme.dim
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.label
                            font.pixelSize: Theme.s(13)
                            color: index === win.selection ? Theme.text : Theme.dim
                        }
                    }

                    Toggle {
                        visible: modelData.kind === "toggle"
                        anchors.right: parent.right; anchors.rightMargin: Theme.s(14)
                        anchors.verticalCenter: parent.verticalCenter
                        checked: win.lidAwake
                        onToggled: { win.selection = index; win.setLidAwake(!win.lidAwake) }
                    }
                }
            }
        }
    }

    GlobalShortcut {
        appid: "quickshell"
        name: "toggle-powermenu"
        description: "Toggle power menu"
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
