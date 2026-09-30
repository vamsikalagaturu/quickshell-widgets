import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.UPower
import "../common"

// Power menu, replacing the old rofi/walker Powermenu.sh bound to SUPER+Escape.
//
// The search box holds focus the whole time the menu is open, so typing
// filters immediately -- there is no mode to enter first. That rules out
// single-letter j/k bindings (they would just type): move with the arrows or
// Ctrl+N/P, Enter acts (runs the action, or flips a toggle row and stays
// open), Esc clears a filter and then closes.
//
// This widget also carries the low-battery watchdog (see "battery" below):
// it is the one always-running piece that is already about power, so the
// alternative was a second exec-once script doing nothing else.
Popup {
    id: win
    shortcut: "toggle-powermenu"
    shortcutDescription: "Toggle power menu"

    implicitWidth: Theme.s(320)
    implicitHeight: col.implicitHeight + Theme.s(32)

    property bool lidAwake: false
    property bool idleAwake: false
    property int selection: 0
    property string filterText: ""

    readonly property var items: [
        { kind: "action", label: "Lock", icon: "\uf023", cmd: ["loginctl", "lock-session"] },
        { kind: "action", label: "Suspend", icon: "\uf186", cmd: ["systemctl", "suspend"] },
        { kind: "action", label: "Reboot", icon: "\uf021", cmd: ["systemctl", "reboot"] },
        { kind: "action", label: "Shutdown", icon: "\uf011", cmd: ["systemctl", "poweroff"] },
        { kind: "action", label: "Logout", icon: "\uf2f5", cmd: ["hyprctl", "dispatch", "exit", "0"] },
        { kind: "toggle", id: "lid", label: "Stay awake (lid closed)", icon: "\uf108" },
        { kind: "toggle", id: "idle", label: "Keep screen on (no idle lock)", icon: "\uf0eb" },
        { kind: "profile", label: "Power profile", icon: "\uf0e7" }
    ]

    readonly property var filtered: {
        var q = win.filterText.trim().toLowerCase()
        if (!q) return win.items
        return win.items.filter(it => it.label.toLowerCase().indexOf(q) !== -1)
    }

    onFilteredChanged: if (win.selection >= filtered.length) win.selection = 0

    function open() {
        win.visible = true
        win.selection = 0
        win.filterText = ""
        query.text = ""
        query.forceActiveFocus()
        inhibitCheckProc.running = true
    }

    function close() {
        win.visible = false
        win.filterText = ""
        query.text = ""
    }

    function move(delta) {
        if (filtered.length === 0) return
        win.selection = (win.selection + delta + filtered.length) % filtered.length
    }

    // ---- idle / lid inhibitors -------------------------------------------
    // Both are the same trick: a systemd-inhibit process held open for as
    // long as the toggle is on. Releasing (running: false) drops the lock
    // immediately, so there is no separate "off" command.
    //
    // --what=idle is what stops the screen going away: hypridle's listeners
    // (notify at 9min, loginctl lock-session at 10min) honour logind idle
    // inhibitors unless general:ignore_systemd_inhibit is set, and it isn't.
    //
    // The two --who strings must not be prefixes of each other -- the check
    // below is a substring match on `systemd-inhibit --list`.
    readonly property string lidWho: "quickshell-powermenu-lid"
    readonly property string idleWho: "quickshell-powermenu-idle"

    function setLidAwake(on) {
        win.lidAwake = on
        lidProc.running = false
        if (!on) return
        lidProc.command = ["systemd-inhibit",
            "--what=handle-lid-switch", "--who=" + win.lidWho,
            "--why=stay awake with lid closed", "--mode=block",
            "sleep", "infinity"]
        lidProc.running = true
    }

    function setIdleAwake(on) {
        win.idleAwake = on
        idleProc.running = false
        if (!on) return
        idleProc.command = ["systemd-inhibit",
            "--what=idle", "--who=" + win.idleWho,
            "--why=keep the screen on", "--mode=block",
            "sleep", "infinity"]
        idleProc.running = true
    }

    function toggleAt(it) {
        if (it.id === "lid") setLidAwake(!win.lidAwake)
        else setIdleAwake(!win.idleAwake)
    }

    function toggleState(it) {
        return it.id === "lid" ? win.lidAwake : win.idleAwake
    }

    // One row that cycles rather than three that mostly sit unused. Machines
    // without a performance profile (ppd reports hasPerformanceProfile=false)
    // cycle the two they do have instead of landing on a dead value.
    readonly property var profileOrder: PowerProfiles.hasPerformanceProfile
        ? [PowerProfile.PowerSaver, PowerProfile.Balanced, PowerProfile.Performance]
        : [PowerProfile.PowerSaver, PowerProfile.Balanced]

    function cycleProfile() {
        var i = win.profileOrder.indexOf(PowerProfiles.profile)
        PowerProfiles.profile = win.profileOrder[(i + 1) % win.profileOrder.length]
    }

    function activate() {
        var it = filtered[win.selection]
        if (!it) return
        if (it.kind === "toggle") { win.toggleAt(it); return }
        if (it.kind === "profile") { win.cycleProfile(); return }
        actionProc.command = it.cmd
        actionProc.running = true
        win.close()
    }

    Process { id: actionProc }
    Process { id: lidProc }
    Process { id: idleProc }
    Process { id: notifyProc }

    // Re-derive state on open instead of persisting it: the widget process
    // outlives lock/suspend/reboot cycles, but re-checking is one cheap call
    // and survives a `hyprctl reload` or manual `pkill systemd-inhibit` too.
    Process {
        id: inhibitCheckProc
        command: ["systemd-inhibit", "--list", "--no-pager"]
        stdout: StdioCollector { id: inhibitCheckOut }
        onExited: code => {
            var t = code === 0 ? inhibitCheckOut.text : ""
            win.lidAwake = t.indexOf(win.lidWho) !== -1
            win.idleAwake = t.indexOf(win.idleWho) !== -1
        }
    }

    // ---- battery watchdog -------------------------------------------------
    // Warn at <15%, suspend at <10% so the session survives a flat battery.
    // UPowerDevice.percentage is 0..1, and `ready` stays false for the first
    // second or two while the DBus objects populate -- acting on 0% before
    // then would suspend the machine on every login.
    readonly property var battery: UPower.displayDevice
    readonly property int batteryPct: battery && battery.ready
        ? Math.round(battery.percentage * 100) : -1
    readonly property bool discharging: UPower.onBattery

    property bool lowWarned: false
    property bool autoSuspended: false

    function notify(urgency, icon, title, body) {
        notifyProc.command = ["notify-send", "-u", urgency, "-i", icon,
                              "-a", "power", title, body]
        notifyProc.running = true
    }

    function checkBattery() {
        if (!battery || !battery.ready) return

        // Plugged back in: re-arm both thresholds. The latches are cleared
        // ONLY here, so waking the machine back up at 9% on a dead charger
        // gives you a working session instead of an instant re-suspend loop.
        if (!win.discharging) {
            win.lowWarned = false
            win.autoSuspended = false
            return
        }

        var pct = win.batteryPct
        if (pct < 0) return

        if (pct < 10 && !win.autoSuspended) {
            win.autoSuspended = true
            win.lowWarned = true
            win.notify("critical", "battery-empty",
                       "Battery critical — suspending",
                       pct + "% left. Plug in, then wake to resume.")
            actionProc.command = ["systemctl", "suspend"]
            actionProc.running = true
        } else if (pct < 15 && !win.lowWarned) {
            win.lowWarned = true
            win.notify("critical", "battery-caution",
                       "Battery low — " + pct + "%",
                       "Save your work. Suspending automatically below 10%.")
        }
    }

    onBatteryPctChanged: win.checkBattery()
    onDischargingChanged: win.checkBattery()

    Card {
        id: panelBg
        anchors.fill: parent
        focus: true

        // Fallback only -- `query` owns the keyboard while the menu is open.
        Keys.onPressed: event => {
            var k = event.key
            if (k === Qt.Key_Escape) { win.close(); event.accepted = true }
            else if (k === Qt.Key_Down) { win.move(1); event.accepted = true }
            else if (k === Qt.Key_Up) { win.move(-1); event.accepted = true }
            else if (k === Qt.Key_Return || k === Qt.Key_Enter) {
                win.activate(); event.accepted = true
            }
        }

        Column {
            id: col
            anchors.top: parent.top; anchors.topMargin: Theme.s(16)
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            spacing: Theme.s(2)

            Rectangle {
                id: searchBox
                width: col.width
                height: Theme.s(38)
                radius: Theme.s(10)
                color: Theme.surfaceAlt
                border.width: 1
                border.color: query.activeFocus ? Theme.accent : Theme.line

                Text {
                    anchors.left: parent.left; anchors.leftMargin: Theme.s(14)
                    anchors.verticalCenter: parent.verticalCenter
                    visible: win.filterText.length === 0
                    text: "type to filter…"
                    font.pixelSize: Theme.s(12)
                    color: Theme.muted
                }

                TextInput {
                    id: query
                    anchors.left: parent.left
                    anchors.right: battLabel.left
                    anchors.leftMargin: Theme.s(14)
                    anchors.rightMargin: Theme.s(10)
                    anchors.verticalCenter: parent.verticalCenter
                    font.pixelSize: Theme.s(12)
                    color: Theme.text
                    selectionColor: Theme.accentDim
                    clip: true
                    activeFocusOnTab: false
                    onTextChanged: win.filterText = text

                    Keys.onPressed: event => {
                        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
                        if (event.key === Qt.Key_Escape) {
                            // clear a filter first, close on the second press
                            if (win.filterText !== "") {
                                query.text = ""
                                win.selection = 0
                            } else {
                                win.close()
                            }
                            event.accepted = true
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            win.activate(); event.accepted = true
                        } else if (event.key === Qt.Key_Down
                                   || (ctrl && (event.key === Qt.Key_N || event.key === Qt.Key_J))) {
                            win.move(1); event.accepted = true
                        } else if (event.key === Qt.Key_Up
                                   || (ctrl && (event.key === Qt.Key_P || event.key === Qt.Key_K))) {
                            win.move(-1); event.accepted = true
                        } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                            event.accepted = true
                        }
                    }
                }

                // Doubles as the search box's right-hand label and the only
                // place the watchdog's input is visible at a glance.
                Text {
                    id: battLabel
                    anchors.right: parent.right; anchors.rightMargin: Theme.s(14)
                    anchors.verticalCenter: parent.verticalCenter
                    visible: win.batteryPct >= 0
                    text: win.batteryPct + "%" + (win.discharging ? "" : " \uf1e6")
                    font.family: Theme.mono
                    font.pixelSize: Theme.s(11)
                    color: win.discharging && win.batteryPct < 15 ? Theme.warn : Theme.muted
                }
            }

            Item { width: 1; height: Theme.s(6) }

            Repeater {
                model: win.filtered
                delegate: Rectangle {
                    required property var modelData
                    required property int index

                    width: col.width
                    height: Theme.s(42)
                    radius: Theme.s(8)
                    color: index === win.selection ? Theme.surfaceAlt : "transparent"

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
                            font.family: Theme.mono
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

                    Text {
                        visible: modelData.kind === "profile"
                        anchors.right: parent.right; anchors.rightMargin: Theme.s(14)
                        anchors.verticalCenter: parent.verticalCenter
                        text: PowerProfile.toString(PowerProfiles.profile)
                             + (PowerProfiles.degradationReason !== PerformanceDegradationReason.None
                                ? "  (throttled)" : "")
                        font.family: Theme.mono
                        font.pixelSize: Theme.s(11)
                        color: PowerProfiles.profile === PowerProfile.Performance ? Theme.warn
                             : PowerProfiles.profile === PowerProfile.PowerSaver ? Theme.accent
                             : Theme.dim
                    }

                    Toggle {
                        visible: modelData.kind === "toggle"
                        anchors.right: parent.right; anchors.rightMargin: Theme.s(14)
                        anchors.verticalCenter: parent.verticalCenter
                        checked: modelData.kind === "toggle" && win.toggleState(modelData)
                        onToggled: { win.selection = index; win.toggleAt(modelData) }
                    }
                }
            }

            Text {
                visible: win.filtered.length === 0
                width: col.width
                height: Theme.s(42)
                verticalAlignment: Text.AlignVCenter
                leftPadding: Theme.s(14)
                text: "no matches"
                font.pixelSize: Theme.s(12)
                color: Theme.muted
            }
        }
    }
}
