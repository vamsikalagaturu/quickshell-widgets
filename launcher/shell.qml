import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland._GlobalShortcuts
import Quickshell.Hyprland._FocusGrab

// App launcher, styled to match the network panel (connectivity/): same
// Theme tokens, same 150% scale knob, same row/focus treatment, same
// scroll track and footnote rule.
//
// Keyboard model differs from the network panel on purpose. This is
// search-first -- the TextInput owns focus the whole time -- so single-letter
// vim bindings are impossible. Navigation is arrows plus the readline-style
// Ctrl+N/Ctrl+P, Ctrl+J/Ctrl+K, and Home/End/PageUp/PageDown.
PanelWindow {
    id: win
    visible: false
    color: "transparent"
    anchors.top: true
    anchors.left: true
    margins.top: Math.max(0, (win.screen.height - implicitHeight) / 2)
    margins.left: Math.max(0, (win.screen.width - implicitWidth) / 2)
    exclusionMode: ExclusionMode.Ignore
    aboveWindows: true
    focusable: true

    implicitWidth: Theme.s(640)
    implicitHeight: Theme.s(560)

    property var allApps: DesktopEntries.applications
    property var filtered: []
    property int selection: 0

    readonly property int rowHeight: Theme.s(46)

    function matches(a, q) {
        if (a.noDisplay) return false
        if (!q) return true
        var s = (a.name + " " + (a.genericName || "") + " " + (a.comment || "")
                 + " " + (a.keywords || []).join(" ")).toLowerCase()
        return s.indexOf(q) >= 0
    }

    // Rank exact/prefix name hits above substring hits, so typing "fire"
    // doesn't bury Firefox under something that merely mentions it in a
    // comment. Ties fall back to alphabetical.
    function rank(a, q) {
        if (!q) return 3
        var n = (a.name || "").toLowerCase()
        if (n === q) return 0
        if (n.indexOf(q) === 0) return 1
        if (n.indexOf(q) >= 0) return 2
        return 3
    }

    function updateFilter() {
        var q = query.text.trim().toLowerCase()
        var out = []
        var vals = allApps.values
        for (var i = 0; i < vals.length; i++)
            if (matches(vals[i], q)) out.push(vals[i])
        out.sort(function (x, y) {
            var d = win.rank(x, q) - win.rank(y, q)
            if (d !== 0) return d
            return (x.name || "").localeCompare(y.name || "")
        })
        filtered = out
        selection = 0
        list.positionViewAtBeginning()
    }

    function move(delta) {
        if (filtered.length === 0) return
        selection = (selection + delta + filtered.length) % filtered.length
        list.positionViewAtIndex(selection, ListView.Contain)
    }

    function jump(toLast) {
        if (filtered.length === 0) return
        selection = toLast ? filtered.length - 1 : 0
        list.positionViewAtIndex(selection, ListView.Contain)
    }

    function open() {
        win.visible = true
        query.text = ""
        updateFilter()
        query.forceActiveFocus()
    }

    function closeLauncher() {
        win.visible = false
        query.text = ""
    }

    function launchCurrent() {
        var e = filtered[selection]
        if (!e) return
        closeLauncher()
        e.execute()
    }

    Rectangle {
        id: panelBg
        anchors.fill: parent
        radius: Theme.s(18)
        color: "#f20c0e11"
        border.width: 1
        border.color: "#1e2228"

        // ---- search ----
        Rectangle {
            id: searchBox
            anchors.top: parent.top; anchors.topMargin: Theme.s(16)
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            height: Theme.s(44)
            radius: Theme.s(10)
            color: Theme.surfaceAlt
            border.width: 1
            border.color: query.activeFocus ? Theme.accent : Theme.line

            Text {
                anchors.left: parent.left
                anchors.leftMargin: Theme.s(14)
                anchors.verticalCenter: parent.verticalCenter
                visible: query.text.length === 0
                text: "Search apps"
                font.pixelSize: Theme.s(14)
                color: Theme.muted
            }

            TextInput {
                id: query
                anchors.left: parent.left
                anchors.right: countLabel.left
                anchors.leftMargin: Theme.s(14)
                anchors.rightMargin: Theme.s(10)
                anchors.verticalCenter: parent.verticalCenter
                font.pixelSize: Theme.s(14)
                color: Theme.text
                selectionColor: Theme.accentDim
                clip: true
                onTextChanged: win.updateFilter()

                Keys.onPressed: event => {
                    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
                    if (event.key === Qt.Key_Escape) {
                        win.closeLauncher(); event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        win.launchCurrent(); event.accepted = true
                    } else if (event.key === Qt.Key_Down
                               || (ctrl && (event.key === Qt.Key_N || event.key === Qt.Key_J))) {
                        win.move(1); event.accepted = true
                    } else if (event.key === Qt.Key_Up
                               || (ctrl && (event.key === Qt.Key_P || event.key === Qt.Key_K))) {
                        win.move(-1); event.accepted = true
                    } else if (event.key === Qt.Key_PageDown) {
                        win.move(8); event.accepted = true
                    } else if (event.key === Qt.Key_PageUp) {
                        win.move(-8); event.accepted = true
                    } else if (event.key === Qt.Key_Home && ctrl) {
                        win.jump(false); event.accepted = true
                    } else if (event.key === Qt.Key_End && ctrl) {
                        win.jump(true); event.accepted = true
                    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                        // never let Tab move focus off the search field
                        event.accepted = true
                    }
                }
            }

            Text {
                id: countLabel
                anchors.right: parent.right
                anchors.rightMargin: Theme.s(14)
                anchors.verticalCenter: parent.verticalCenter
                text: win.filtered.length + (win.filtered.length === 1 ? " app" : " apps")
                font.family: Theme.mono
                font.pixelSize: Theme.s(11)
                color: Theme.muted
            }
        }

        // ---- results ----
        ListView {
            id: list
            anchors.top: searchBox.bottom; anchors.topMargin: Theme.s(10)
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(26)
            anchors.bottom: hintSep.top; anchors.bottomMargin: Theme.s(8)
            model: win.filtered
            currentIndex: win.selection
            clip: true
            spacing: Theme.s(2)
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
                required property var modelData
                required property int index

                width: list.width
                height: win.rowHeight
                radius: Theme.s(8)
                // no left accent bar -- border + fill carry focus, matching
                // the network panel's ListRow
                color: index === win.selection ? Theme.surfaceAlt : "transparent"
                border.width: index === win.selection ? 1 : 0
                border.color: Theme.accent

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: win.selection = index
                    onDoubleClicked: { win.selection = index; win.launchCurrent() }
                }

                Rectangle {
                    id: iconBox
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.s(10)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Theme.s(32); height: Theme.s(32)
                    radius: Theme.s(8)
                    color: Theme.surface

                    Image {
                        anchors.centerIn: parent
                        width: Theme.s(22); height: Theme.s(22)
                        source: modelData.icon ? Quickshell.iconPath(modelData.icon, true) : ""
                        sourceSize: Qt.size(Theme.s(22), Theme.s(22))
                        smooth: true
                    }
                }

                Column {
                    anchors.left: iconBox.right
                    anchors.leftMargin: Theme.s(12)
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.s(12)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.s(1)

                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        text: modelData.name || ""
                        font.pixelSize: Theme.s(13)
                        font.weight: Font.DemiBold
                        color: index === win.selection ? Theme.accent : Theme.text
                    }
                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        visible: text !== ""
                        text: modelData.genericName || modelData.comment || ""
                        font.pixelSize: Theme.s(10)
                        color: Theme.muted
                    }
                }
            }
        }

        ScrollTrack {
            flick: list
            anchors.right: parent.right
            anchors.rightMargin: Theme.s(16)
            anchors.top: list.top
            anchors.bottom: list.bottom
        }

        Text {
            visible: win.filtered.length === 0
            anchors.centerIn: list
            text: query.text.trim() === "" ? "no applications found" : "no matches for “" + query.text.trim() + "”"
            font.pixelSize: Theme.s(12)
            color: Theme.muted
        }

        // ---- footnote ----
        Rectangle {
            id: hintSep
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            anchors.bottom: hintBar.top; anchors.bottomMargin: Theme.s(10)
            height: 1
            color: Theme.line
        }

        Item {
            id: hintBar
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            anchors.bottom: parent.bottom; anchors.bottomMargin: Theme.s(14)
            height: Theme.s(18)

            Text {
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                text: "↑↓ or Ctrl+n/p move  ·  Enter launch  ·  PgUp/PgDn page  ·  Esc close"
                font.pixelSize: Theme.s(12)
                color: Theme.dim
            }
        }
    }

    GlobalShortcut {
        appid: "quickshell"
        name: "toggle-launcher"
        description: "Toggle app launcher"
        onPressed: {
            if (win.visible) win.closeLauncher()
            else win.open()
        }
    }

    HyprlandFocusGrab {
        active: win.visible
        windows: [win]
    }
}
