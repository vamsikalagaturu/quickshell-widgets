import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland._GlobalShortcuts
import Quickshell.Hyprland._FocusGrab

// App launcher, styled to match the network panel (connectivity/) and using
// the same modal keyboard model as the clipboard picker.
//
//   list    (default)  j/k move, g/G ends, Enter launch, / search, Esc close
//   search  ('/')      typing filters, Esc cancels, Enter launches,
//                      arrows / Ctrl+N/P still move the selection
//
// Single-letter bindings are safe because the TextInput only holds focus
// while mode === "search"; panelBg owns keys otherwise.
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
    property string filterText: ""

    // "list" | "search"
    property string mode: "list"

    readonly property int rowHeight: Theme.s(46)

    function enterList() {
        win.mode = "list"
        panelBg.forceActiveFocus()
    }

    function enterSearch() {
        win.mode = "search"
        query.forceActiveFocus()
    }

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
        var q = win.filterText.trim().toLowerCase()
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
        win.filterText = ""
        query.text = ""
        updateFilter()
        win.enterList()
    }

    function closeLauncher() {
        win.visible = false
        win.filterText = ""
        query.text = ""
        win.mode = "list"
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
        focus: true

        // ---- list-mode key router ----
        Keys.onPressed: event => {
            var txt = event.text
            var k = event.key

            if (k === Qt.Key_Escape) { win.closeLauncher(); event.accepted = true }
            else if (txt === "j" || k === Qt.Key_Down) { win.move(1); event.accepted = true }
            else if (txt === "k" || k === Qt.Key_Up) { win.move(-1); event.accepted = true }
            else if (txt === "g") { win.jump(false); event.accepted = true }
            else if (txt === "G") { win.jump(true); event.accepted = true }
            else if (k === Qt.Key_PageDown) { win.move(8); event.accepted = true }
            else if (k === Qt.Key_PageUp) { win.move(-8); event.accepted = true }
            else if (txt === "/") { win.enterSearch(); event.accepted = true }
            else if (k === Qt.Key_Return || k === Qt.Key_Enter) {
                win.launchCurrent(); event.accepted = true
            }
        }

        // ---- search ----
        Rectangle {
            id: searchBox
            anchors.top: parent.top; anchors.topMargin: Theme.s(16)
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            height: Theme.s(44)
            radius: Theme.s(10)
            color: Theme.surfaceAlt
            border.width: win.mode === "search" ? 1 : 0
            border.color: Theme.accent

            Text {
                anchors.left: parent.left
                anchors.leftMargin: Theme.s(14)
                anchors.verticalCenter: parent.verticalCenter
                visible: win.filterText.length === 0
                text: win.mode === "search" ? "type to filter…" : "press / to search apps"
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
                activeFocusOnTab: false
                onTextChanged: { win.filterText = text; win.updateFilter() }

                Keys.onPressed: event => {
                    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
                    if (event.key === Qt.Key_Escape) {
                        // cancel the search, back to list mode -- Esc again closes
                        query.text = ""
                        win.filterText = ""
                        win.updateFilter()
                        win.enterList()
                        event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        // launch straight from search; the clipboard picker
                        // returns to list here instead, but a launcher's whole
                        // point is type-then-go, and a second Enter would be
                        // friction on every single launch
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
                    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
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
            text: win.filterText.trim() === "" ? "no applications found"
                                              : "no matches for “" + win.filterText.trim() + "”"
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
                text: win.mode === "search"
                    ? "type to filter  ·  ↑↓ or Ctrl+n/p move  ·  Enter launch  ·  Esc cancel search"
                    : "j/k move  ·  g/G ends  ·  / search  ·  Enter launch  ·  Esc close"
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
