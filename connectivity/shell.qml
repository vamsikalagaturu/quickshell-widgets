import QtQuick
import QtQuick as QQ
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Networking
import Quickshell.Hyprland._GlobalShortcuts
import Quickshell.Hyprland._FocusGrab

// ============================================================================
// Flat focus-ring keyboard model.
//
// panelBg is the ONE Item in this file that owns Qt focus in normal mode.
// Its Keys.onPressed is the single key router for the whole widget. Panes
// (Wifi/Wired/Bt) never take Qt focus themselves -- they expose
// focusIdx/focusCount/activate()/toggleItem()/yank()/refresh()/hints and the
// router drives them. The ONLY thing that takes real Qt focus is a Field's
// TextInput, and only while `win.insert` is true. Losing activeFocus is NOT
// enough to suspend the bindings on its own: keys the TextInput declines
// (Tab, Up, Down) propagate up the focus chain to panelBg. The router's
// `if (win.insert) return` guard is what actually suspends them.
//
// Three tabs only (Wi-Fi / Wired / Bluetooth) -- there is no Config tab and
// no Speed tab. 'e' expands/collapses an inline config block under the
// focused row without ever touching win.tab. The speed test lives in a
// SpeedSection at the bottom of the Wi-Fi and Wired panes, backed by the
// SpeedTest singleton so both views share one run.
// ============================================================================

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

    implicitWidth: Theme.s(760)
    implicitHeight: Theme.s(620)

    // ---- shell-owned state ----
    property int tab: 0
    readonly property var tabIds: ["wifi", "wired", "bluetooth"]
    property bool insert: false
    property bool cheatsheet: false
    property bool confirmArmed: false
    property string confirmLabel: ""
    property var confirmAction: null
    property string flashMsg: ""

    readonly property var panes: [wifiPane, wiredPane, btPane]
    readonly property var currentPane: panes[tab]

    function flash(msg) {
        win.flashMsg = msg
        flashTimer.restart()
    }

    function exitInsert() {
        win.insert = false
        panelBg.forceActiveFocus()
    }

    function moveFocus(delta) {
        var p = win.currentPane
        if (!p || p.focusCount <= 0) return
        p.focusIdx = (p.focusIdx + delta + p.focusCount) % p.focusCount
    }

    function jumpFocus(toLast) {
        var p = win.currentPane
        if (!p || p.focusCount <= 0) return
        p.focusIdx = toLast ? p.focusCount - 1 : 0
    }

    function nextTab(delta) {
        win.tab = (win.tab + delta + 3) % 3
    }

    function armConfirm(label, action) {
        win.confirmLabel = label
        win.confirmAction = action
        win.confirmArmed = true
    }

    // NetworkConnectivity.toString() returns NM's verbose wording ("Full
    // internet connectivity"), which reads like a stray sentence in the
    // corner. Short status word instead, prefixed so it's obvious what it
    // is describing.
    function connText() {
        switch (Networking.connectivity) {
            case NetworkConnectivity.Full: return "Internet: online"
            case NetworkConnectivity.Portal: return "Internet: captive portal"
            case NetworkConnectivity.Limited: return "Internet: limited"
            case NetworkConnectivity.None: return "Internet: offline"
            default: return "Internet: unknown"
        }
    }

    function connColor() {
        switch (Networking.connectivity) {
            case NetworkConnectivity.Full: return Theme.accent
            case NetworkConnectivity.Portal: return Theme.warn
            case NetworkConnectivity.Limited: return Theme.warn
            case NetworkConnectivity.None: return Theme.danger
            default: return Theme.muted
        }
    }

    // ---- prefs: last tab only (speed settings live on the SpeedTest
    // singleton now, shared by both panes that render it) ----
    FileView {
        id: prefsFile
        path: Quickshell.env("HOME") + "/.config/quickshell/network.json"
        watchChanges: true
        printErrors: false
        onAdapterUpdated: writeAdapter()
        onLoaded: {
            var i = win.tabIds.indexOf(prefs.lastTab)
            win.tab = i >= 0 ? i : 0
        }

        JsonAdapter {
            id: prefs
            property string lastTab: "wifi"
        }
    }

    onTabChanged: prefs.lastTab = win.tabIds[win.tab]

    Timer { id: flashTimer; interval: 2000; onTriggered: win.flashMsg = "" }

    Rectangle {
        id: panelBg
        anchors.fill: parent
        radius: Theme.s(18)
        color: "#f20c0e11"
        border.width: 1
        border.color: "#1e2228"
        focus: true

        Keys.onPressed: event => {
            var key = event.key
            var txt = event.text

            // While a Field is being edited it owns activeFocus, but keys it
            // does NOT consume (Tab, Up, Down) still propagate up to here and
            // would switch tabs / move the ring out from under the cursor.
            // Esc and Enter never reach this point -- Field accepts them.
            if (win.insert) return

            if (win.cheatsheet) {
                if (key === Qt.Key_Escape || txt === "?") { win.cheatsheet = false; event.accepted = true }
                return
            }

            if (win.confirmArmed) {
                if (txt.toLowerCase() === "y") {
                    win.confirmArmed = false
                    if (win.confirmAction) win.confirmAction()
                    event.accepted = true
                } else if (key === Qt.Key_Escape || txt.toLowerCase() === "n") {
                    win.confirmArmed = false
                    event.accepted = true
                }
                return
            }

            if (txt === "?") { win.cheatsheet = true; event.accepted = true; return }

            var pane = win.currentPane

            if (key === Qt.Key_Escape) {
                // insert -> (handled by Field, never reaches here) ->
                // collapse expansion -> clear filter -> close.
                if (pane && pane.hasExpansion && pane.hasExpansion()) {
                    pane.collapseExpansion()
                } else if (pane && pane.filterText) {
                    pane.clearFilter()
                } else {
                    win.visible = false
                }
                event.accepted = true
                return
            }

            if (key >= Qt.Key_1 && key <= Qt.Key_3) {
                win.tab = key - Qt.Key_1
                event.accepted = true
            } else if (key === Qt.Key_Tab) {
                win.nextTab((event.modifiers & Qt.ShiftModifier) ? -1 : 1)
                event.accepted = true
            } else if (key === Qt.Key_Backtab) {
                win.nextTab(-1)
                event.accepted = true
            } else if (txt === "h") {
                win.nextTab(-1); event.accepted = true
            } else if (txt === "l") {
                win.nextTab(1); event.accepted = true
            } else if (txt === "j" || key === Qt.Key_Down) {
                win.moveFocus(1); event.accepted = true
            } else if (txt === "k" || key === Qt.Key_Up) {
                win.moveFocus(-1); event.accepted = true
            } else if (txt === "G") {
                win.jumpFocus(true); event.accepted = true
            } else if (txt === "g") {
                win.jumpFocus(false); event.accepted = true
            } else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
                if (pane && pane.activate) pane.activate()
                event.accepted = true
            } else if (key === Qt.Key_Space) {
                if (pane && pane.toggleItem) pane.toggleItem()
                event.accepted = true
            } else if (txt === "/") {
                if (pane && pane.startFilter) pane.startFilter()
                event.accepted = true
            } else if (txt === "y") {
                if (pane && pane.yank) pane.yank()
                event.accepted = true
            } else if (txt === "r") {
                if (pane && pane.refresh) pane.refresh()
                event.accepted = true
            } else if (txt === "e") {
                // Expands/collapses inline config on the focused row of the
                // current pane. Never switches tab -- that hand-off is
                // exactly what the old Config tab did and was rejected.
                if (pane && pane.edit) pane.edit()
                event.accepted = true
            } else if (txt === "d") {
                if (pane && pane.deleteLabel) {
                    win.armConfirm(pane.deleteLabel, () => pane.deleteFocused())
                }
                event.accepted = true
            } else if (txt === "s") {
                if (win.tab === 0 || win.tab === 1) SpeedTest.start()
                event.accepted = true
            } else if (txt === "x") {
                if (win.tab === 0 || win.tab === 1) SpeedTest.abort()
                event.accepted = true
            }
        }

        // ---- top bar ----
        Item {
            id: topBar
            anchors.top: parent.top; anchors.topMargin: Theme.s(16)
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            height: Theme.s(22)

            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "NETWORK"
                font.pixelSize: Theme.s(13)
                font.bold: true
                font.letterSpacing: 2
                color: Theme.dim
            }

            Rectangle {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: pillRow.implicitWidth + Theme.s(18)
                height: Theme.s(22)
                radius: height / 2
                color: Theme.surfaceAlt

                QQ.Row {
                    id: pillRow
                    anchors.centerIn: parent
                    spacing: Theme.s(6)
                    Rectangle {
                        width: Theme.s(8); height: Theme.s(8); radius: Theme.s(4)
                        anchors.verticalCenter: parent.verticalCenter
                        color: win.connColor()
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: win.connText()
                        font.pixelSize: Theme.s(11)
                        color: Theme.text
                    }
                }
            }
        }

        // ---- tab strip ----
        Item {
            id: tabStrip
            anchors.top: topBar.bottom; anchors.topMargin: Theme.s(14)
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            height: Theme.s(26)

            QQ.Row {
                id: tabRow
                anchors.left: parent.left
                anchors.top: parent.top
                spacing: Theme.s(22)

                Repeater {
                    id: tabRepeater
                    model: ["Wi-Fi", "Wired", "Bluetooth"]
                    delegate: Item {
                        required property string modelData
                        required property int index
                        width: tabLabel.implicitWidth
                        height: Theme.s(22)

                        Text {
                            id: tabLabel
                            anchors.fill: parent
                            verticalAlignment: Text.AlignVCenter
                            text: (index + 1) + " " + modelData
                            font.pixelSize: Theme.s(12)
                            font.bold: win.tab === index
                            color: win.tab === index ? Theme.text : Theme.dim
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: win.tab = index
                        }
                    }
                }
            }

            Rectangle {
                height: Theme.s(2)
                radius: height / 2
                color: Theme.accent
                y: tabRow.y + tabRow.height + Theme.s(4)
                x: tabRepeater.itemAt(win.tab) ? tabRepeater.itemAt(win.tab).x : 0
                width: tabRepeater.itemAt(win.tab) ? tabRepeater.itemAt(win.tab).width : 0
                Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                Behavior on width { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
            }
        }

        // ---- content: all three panes instantiated once, visibility
        //      toggled so filter text / focusIdx / expansion state survive
        //      tab switches. Each pane owns its own Flickable and scrolls
        //      itself to follow the focus ring. ----
        Item {
            id: content
            anchors.top: tabStrip.bottom; anchors.topMargin: Theme.s(10)
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            anchors.bottom: keyhintSep.top; anchors.bottomMargin: Theme.s(8)
            clip: true

            WifiPane {
                id: wifiPane
                anchors.fill: parent
                shellRoot: win
                visible: win.tab === 0
            }
            WiredPane {
                id: wiredPane
                anchors.fill: parent
                shellRoot: win
                visible: win.tab === 1
            }
            BtPane {
                id: btPane
                anchors.fill: parent
                shellRoot: win
                visible: win.tab === 2
            }
        }

        // ---- bottom keyhint bar ----
        Rectangle {
            id: keyhintSep
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            anchors.bottom: keyhintBar.top; anchors.bottomMargin: Theme.s(10)
            height: 1
            color: Theme.line
        }

        Item {
            id: keyhintBar
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            anchors.bottom: parent.bottom; anchors.bottomMargin: Theme.s(14)
            height: Theme.s(18)

            Text {
                visible: win.confirmArmed
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                text: win.confirmLabel + "?  y/n"
                font.pixelSize: Theme.s(13)
                color: Theme.warn
            }
            Text {
                visible: !win.confirmArmed && win.flashMsg !== ""
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                text: win.flashMsg
                font.pixelSize: Theme.s(13)
                color: Theme.accent
            }
            Text {
                visible: !win.confirmArmed && win.flashMsg === ""
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                text: (win.currentPane ? win.currentPane.hints : "") + "   ·   ? for help"
                font.pixelSize: Theme.s(12)
                color: Theme.dim
            }
        }

        // ---- cheatsheet overlay ----
        Rectangle {
            anchors.fill: parent
            radius: Theme.s(18)
            color: "black"
            opacity: win.cheatsheet ? 0.65 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 120 } }
            MouseArea { anchors.fill: parent; onClicked: win.cheatsheet = false }
        }

        Rectangle {
            visible: win.cheatsheet
            anchors.centerIn: parent
            width: Theme.s(460)
            implicitHeight: cheatCol.implicitHeight + Theme.s(32)
            radius: Theme.s(14)
            color: Theme.surface
            border.width: 1
            border.color: Theme.line

            QQ.Column {
                id: cheatCol
                anchors.top: parent.top; anchors.topMargin: Theme.s(16)
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width - Theme.s(32)
                spacing: Theme.s(6)

                Text { text: "Keyboard"; font.bold: true; font.pixelSize: Theme.s(14); color: Theme.text }

                Repeater {
                    model: [
                        ["1-3", "jump to tab"],
                        ["Tab / Shift+Tab", "next / prev tab"],
                        ["h / l", "prev / next tab"],
                        ["j / k, ↓ / ↑", "move focus (wraps)"],
                        ["g / G", "first / last item"],
                        ["Enter", "activate focused item"],
                        ["Space", "toggle focused item"],
                        ["/", "filter list (Esc clears)"],
                        ["e", "expand/collapse inline config"],
                        ["y", "copy focused value"],
                        ["r", "refresh / rescan"],
                        ["d, y", "forget / delete (confirm)"],
                        ["s / x", "start / abort speed test"],
                        ["?", "toggle this cheatsheet"],
                        ["Esc", "collapse / clear filter / close"]
                    ]
                    delegate: QQ.Row {
                        required property var modelData
                        width: cheatCol.width
                        spacing: Theme.s(10)
                        Text {
                            width: Theme.s(150)
                            text: modelData[0]
                            font.family: Theme.mono
                            font.pixelSize: Theme.s(11)
                            color: Theme.accent
                        }
                        Text {
                            width: parent.width - Theme.s(160)
                            text: modelData[1]
                            font.pixelSize: Theme.s(11)
                            color: Theme.dim
                            wrapMode: Text.WordWrap
                        }
                    }
                }
            }
        }
    }

    // Esc closes from any mode. The per-mode Esc handlers (collapse expansion,
    // clear filter, cancel a confirm, leave a Field) still exist, but they no
    // longer eat the keypress -- a Shortcut is matched during shortcut
    // override, before the focused item's Keys handler sees the event.
    Shortcut { sequence: "Esc"; onActivated: win.visible = false }

    GlobalShortcut {
        appid: "quickshell"
        name: "toggle-connectivity"
        description: "Toggle connectivity widget"
        onPressed: {
            win.visible = !win.visible
            if (win.visible) {
                win.insert = false
                win.cheatsheet = false
                win.confirmArmed = false
                win.flashMsg = ""
                panelBg.forceActiveFocus()
            }
        }
    }

    HyprlandFocusGrab {
        active: win.visible
        windows: [win]
    }
}
