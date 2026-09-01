import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland._GlobalShortcuts
import Quickshell.Hyprland._FocusGrab

// Dev servers: every TCP socket you have in LISTEN state, one row per process,
// named by the git project it was started in. Open it, copy its URL, or stop it.
// Toggle with SUPER + P.
//
// The idea and the data layer come from rubenmeza/omarchy-ports (MIT License,
// Copyright (c) 2026 Ruben Meza): https://github.com/rubenmeza/omarchy-ports.
// ports-scan and ports-stop are vendored from it unmodified, and Scanner.qml is
// a light port. Its Panel.qml is built on Omarchy Quattro's qs.Commons/qs.Ui
// component library, which this repo does not have, so this file is a fresh
// implementation against this repo's own PanelWindow/Theme conventions --
// carrying over the panel's cursor model, the browsable/exposed distinctions
// and the two-step stop flow.
//
// j/k or arrows move the cursor, Enter opens a web server (or copies the URL of
// anything else), o opens, c copies, x stops, r rescans, Esc closes.
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

    implicitWidth: Theme.s(440)
    // Derived from the chrome rather than a guessed constant, same as the
    // volume panel: the list is short most days and there is no reason to
    // reserve height for servers nobody is running.
    implicitHeight: col.y + col.implicitHeight
                    + Theme.s(12) + hintSep.height + Theme.s(8)
                    + hintBar.height + Theme.s(14)

    readonly property var servers: scanner.servers
    readonly property int count: servers.length

    // The cursor only exists once a key or the pointer has asked for it, so an
    // opened panel does not highlight a row nobody pointed at.
    property bool cursorActive: false
    property int cursorIndex: 0

    readonly property var selected: count > 0 && cursorIndex >= 0 && cursorIndex < count
        ? servers[cursorIndex] : null

    // Stopping a server is two separate decisions. `pendingServer` is the one
    // being asked about; `pendingHard` says the question is now about SIGKILL.
    property var pendingServer: null
    property bool pendingHard: false
    readonly property bool confirmOpen: pendingServer !== null
    property var stoppedServer: null

    onCountChanged: if (cursorIndex >= count) cursorIndex = Math.max(0, count - 1)

    function moveCursor(delta) {
        if (count === 0) return
        win.cursorActive = true
        win.cursorIndex = Math.max(0, Math.min(count - 1, win.cursorIndex + delta))
    }

    function portsLabel(server) {
        var out = []
        for (var i = 0; i < server.ports.length; i++) out.push(":" + server.ports[i])
        return out.join(" ")
    }

    function metaLine(server) {
        var parts = [server.comm, win.portsLabel(server), "pid " + server.pid]
        if (server.shared) parts.push("+ workers")
        if (server.cwdDeleted) parts.push("directory deleted")
        return parts.join(" · ")
    }

    function askStop(server) {
        if (!server) return
        win.pendingHard = false
        win.pendingServer = server
    }

    function confirmStop() {
        var server = win.pendingServer
        var hard = win.pendingHard
        win.pendingServer = null
        if (!server) return
        win.stoppedServer = null
        scanner.stopServer(server, hard)
    }

    function cancelStop() {
        win.pendingServer = null
        win.pendingHard = false
    }

    function open() {
        win.visible = true
        win.cursorActive = false
        win.cursorIndex = 0
        win.cancelStop()
        listFlick.contentY = 0
        scanner.scan()
        Qt.callLater(function() { panelBg.forceActiveFocus() })
    }

    function close() {
        win.visible = false
        win.cancelStop()
    }

    Scanner {
        id: scanner
        // A closed panel still scans, slowly: it is what keeps the five-second
        // SIGKILL check below honest when the panel has drifted closed since
        // the SIGTERM was sent.
        active: win.visible
    }

    Connections {
        target: scanner
        // The grace period only starts once a SIGTERM was really delivered. A
        // stop the helper refused -- the process had gone, or the pid was no
        // longer it -- has nothing to follow up on, and offering SIGKILL for it
        // would be asking about a process nobody has signalled.
        function onStopFinished(server, hard, refused) {
            if (hard || refused) return
            win.stoppedServer = server
            stopWatch.restart()
        }
    }

    Timer {
        id: stopWatch
        interval: 5000
        repeat: false
        onTriggered: {
            var server = win.stoppedServer
            win.stoppedServer = null
            if (!server) return
            // Still listening, and still the same process: a pid that came back
            // as something else has no question left to ask about it.
            if (!scanner.isListening(server)) return
            // The question was asked for; dropping it because the panel drifted
            // closed would leave a server you told us to stop still running,
            // with nothing said about it. open() clears any pending question,
            // so it has to run before this one is set, not after.
            if (!win.visible) win.open()
            win.pendingServer = server
            win.pendingHard = true
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

        // Escape is handled by the top-level Shortcut below, not here -- Qt
        // matches Shortcut sequences during shortcut-override, ahead of
        // whatever's focused, so a branch for it here would never fire.
        Keys.onPressed: event => {
            var txt = event.text
            var k = event.key
            if (win.confirmOpen) {
                if (k === Qt.Key_Return || k === Qt.Key_Enter) { win.confirmStop(); event.accepted = true }
                return
            }
            if (txt === "j" || k === Qt.Key_Down) { win.moveCursor(1); event.accepted = true }
            else if (txt === "k" || k === Qt.Key_Up) { win.moveCursor(-1); event.accepted = true }
            else if (k === Qt.Key_Return || k === Qt.Key_Enter) { scanner.activateServer(win.selected); event.accepted = true }
            else if (txt === "o" || txt === "O") { scanner.openServer(win.selected); event.accepted = true }
            else if (txt === "c" || txt === "C") { scanner.copyServer(win.selected); event.accepted = true }
            else if (txt === "x" || txt === "X") { win.askStop(win.selected); event.accepted = true }
            else if (txt === "r" || txt === "R") { scanner.scan(); event.accepted = true }
        }

        Column {
            id: col
            anchors.top: parent.top; anchors.topMargin: Theme.s(16)
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            spacing: Theme.s(10)

            Column {
                width: parent.width
                spacing: Theme.s(2)
                Text {
                    text: "Dev servers"
                    color: Theme.text
                    font.family: Theme.mono
                    font.pixelSize: Theme.s(15)
                    font.bold: true
                }
                Text {
                    width: parent.width
                    text: !scanner.scanned ? "Looking…"
                        : win.count === 0 ? "Nothing is listening."
                        : win.count + (win.count === 1 ? " process listening" : " processes listening")
                    color: Theme.dim
                    font.family: Theme.mono
                    font.pixelSize: Theme.s(11)
                }
            }

            Rectangle { width: parent.width; height: 1; color: Theme.line }

            Item {
                width: parent.width
                // Grows with the list up to a cap; past that the flickable
                // scrolls and the track appears.
                height: Math.min(listCol.implicitHeight, Theme.s(400))
                visible: win.count > 0

                Flickable {
                    id: listFlick
                    anchors.left: parent.left
                    anchors.right: scrollTrack.left
                    anchors.rightMargin: Theme.s(8)
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    contentWidth: width
                    contentHeight: listCol.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    flickableDirection: Flickable.VerticalFlick

                    WheelHandler {
                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                        onWheel: event => {
                            var dy = event.pixelDelta.y !== 0 ? event.pixelDelta.y * 1.8 : (event.angleDelta.y / 120) * Theme.s(40)
                            var maxY = Math.max(0, listFlick.contentHeight - listFlick.height)
                            listFlick.contentY = Math.max(0, Math.min(maxY, listFlick.contentY - dy))
                        }
                    }

                    Column {
                        id: listCol
                        width: listFlick.width
                        spacing: Theme.s(2)

                        Repeater {
                            model: win.servers
                            delegate: Rectangle {
                                id: rowItem
                                required property var modelData
                                required property int index
                                readonly property bool selected: win.cursorActive && win.cursorIndex === index
                                readonly property bool showActions: rowMouse.containsMouse || selected

                                width: listCol.width
                                implicitHeight: info.implicitHeight + Theme.s(12)
                                height: implicitHeight
                                radius: Theme.s(6)
                                color: selected ? Theme.surfaceAlt : "transparent"
                                border.width: selected ? 1 : 0
                                border.color: Theme.accent

                                onSelectedChanged: if (selected && win.cursorActive) Qt.callLater(function() {
                                    var top = rowItem.y
                                    var bottom = top + rowItem.height
                                    var margin = Theme.s(6)
                                    var maxY = Math.max(0, listFlick.contentHeight - listFlick.height)
                                    if (top < listFlick.contentY + margin)
                                        listFlick.contentY = Math.max(0, top - margin)
                                    else if (bottom > listFlick.contentY + listFlick.height - margin)
                                        listFlick.contentY = Math.min(maxY, bottom + margin - listFlick.height)
                                })

                                // Stops short of the action buttons rather than
                                // filling the row: a click meant for Stop must
                                // not fall through and open a browser tab.
                                MouseArea {
                                    id: rowMouse
                                    anchors.left: parent.left
                                    anchors.right: actions.visible ? actions.left : parent.right
                                    anchors.top: parent.top
                                    anchors.bottom: parent.bottom
                                    hoverEnabled: true
                                    cursorShape: rowItem.modelData.browsable ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onEntered: { win.cursorActive = true; win.cursorIndex = rowItem.index }
                                    onClicked: scanner.activateServer(rowItem.modelData)
                                }

                                Text {
                                    id: glyph
                                    anchors.left: parent.left; anchors.leftMargin: Theme.s(10)
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: rowItem.modelData.browsable ? "󰖟" : "󰒉"
                                    color: rowItem.modelData.browsable ? Theme.accent : Theme.muted
                                    font.family: Theme.mono
                                    font.pixelSize: Theme.s(13)
                                }

                                Column {
                                    id: info
                                    anchors.left: glyph.right; anchors.leftMargin: Theme.s(9)
                                    anchors.right: actions.visible ? actions.left : parent.right
                                    anchors.rightMargin: Theme.s(10)
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.s(1)

                                    Row {
                                        width: parent.width
                                        spacing: Theme.s(6)
                                        Text {
                                            text: rowItem.modelData.project
                                            color: Theme.text
                                            font.family: Theme.mono
                                            font.pixelSize: Theme.s(12)
                                            elide: Text.ElideRight
                                        }
                                        // A server bound past loopback is
                                        // reachable by anything on the network,
                                        // which is worth seeing before you leave
                                        // the café.
                                        Text {
                                            visible: rowItem.modelData.exposed
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: "exposed"
                                            color: Theme.warn
                                            font.family: Theme.mono
                                            font.pixelSize: Theme.s(9)
                                        }
                                    }

                                    Text {
                                        width: parent.width
                                        text: win.metaLine(rowItem.modelData)
                                        color: Theme.dim
                                        font.family: Theme.mono
                                        font.pixelSize: Theme.s(10)
                                        elide: Text.ElideRight
                                    }
                                }

                                Row {
                                    id: actions
                                    anchors.right: parent.right; anchors.rightMargin: Theme.s(8)
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.s(2)
                                    visible: rowItem.showActions

                                    Rectangle {
                                        visible: rowItem.modelData.browsable
                                        width: Theme.s(24); height: Theme.s(24)
                                        radius: Theme.s(5)
                                        color: openMouse.containsMouse ? Theme.surface : "transparent"
                                        Text {
                                            anchors.centerIn: parent
                                            text: "󰖟"
                                            color: openMouse.containsMouse ? Theme.accent : Theme.dim
                                            font.family: Theme.mono
                                            font.pixelSize: Theme.s(12)
                                        }
                                        MouseArea {
                                            id: openMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: scanner.openServer(rowItem.modelData)
                                        }
                                    }

                                    Rectangle {
                                        width: Theme.s(24); height: Theme.s(24)
                                        radius: Theme.s(5)
                                        color: copyMouse.containsMouse ? Theme.surface : "transparent"
                                        Text {
                                            anchors.centerIn: parent
                                            text: "󰆏"
                                            color: copyMouse.containsMouse ? Theme.accent : Theme.dim
                                            font.family: Theme.mono
                                            font.pixelSize: Theme.s(12)
                                        }
                                        MouseArea {
                                            id: copyMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: scanner.copyServer(rowItem.modelData)
                                        }
                                    }

                                    Rectangle {
                                        width: Theme.s(24); height: Theme.s(24)
                                        radius: Theme.s(5)
                                        color: stopMouse.containsMouse ? Theme.surface : "transparent"
                                        Text {
                                            anchors.centerIn: parent
                                            text: "󰝤"
                                            color: stopMouse.containsMouse ? Theme.danger : Theme.dim
                                            font.family: Theme.mono
                                            font.pixelSize: Theme.s(12)
                                        }
                                        MouseArea {
                                            id: stopMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: win.askStop(rowItem.modelData)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                ScrollTrack {
                    id: scrollTrack
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    flick: listFlick
                }
            }

            // One line for whatever the cursor is on: the URL a row would open
            // or copy, and the directory it was started in. Upstream put the
            // directory in a hover tooltip; this repo has no tooltip component,
            // and a fixed line reads the same without one.
            Text {
                // Always present, even empty: with no cursor yet `selected` is
                // still the first row, so filling this in would describe a row
                // nothing is highlighting -- but letting the line appear on the
                // first keypress would resize the panel under the pointer.
                visible: win.count > 0
                width: parent.width
                text: win.cursorActive && win.selected
                    ? scanner.urlFor(win.selected)
                      + (win.selected.browsable ? "" : "  (not HTTP)")
                      + (win.selected.cwd !== "" ? "  ·  " + win.selected.cwd : "")
                    : ""
                color: Theme.muted
                font.family: Theme.mono
                font.pixelSize: Theme.s(10)
                elide: Text.ElideMiddle
            }

            Text {
                visible: scanner.errorText !== ""
                width: parent.width
                text: scanner.errorText
                color: Theme.danger
                font.family: Theme.mono
                font.pixelSize: Theme.s(10)
                wrapMode: Text.WordWrap
            }

            // A stop that signalled nothing has to say so. Silence would read as
            // a stop button that does nothing.
            Text {
                visible: scanner.refusalText !== ""
                width: parent.width
                text: "Nothing was stopped: " + scanner.refusalText
                color: Theme.danger
                font.family: Theme.mono
                font.pixelSize: Theme.s(10)
                wrapMode: Text.WordWrap
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
            anchors.bottom: parent.bottom; anchors.bottomMargin: Theme.s(12)
            elide: Text.ElideRight
            text: "j/k move · Enter open · c copy · x stop · r rescan · Esc close"
            color: Theme.dim
            font.family: Theme.mono
            font.pixelSize: Theme.s(10)
        }

        // ---- stop confirmation ------------------------------------------
        // Both questions -- SIGTERM, then SIGKILL five seconds later -- come
        // through here. Nothing is ever escalated without one.
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            visible: win.confirmOpen
            color: "#e60c0e11"

            // Swallows clicks so nothing behind the question can be reached
            // while it is up.
            MouseArea { anchors.fill: parent; hoverEnabled: true }

            Rectangle {
                anchors.centerIn: parent
                width: parent.width - Theme.s(48)
                implicitHeight: confirmCol.implicitHeight + Theme.s(28)
                radius: Theme.s(12)
                color: Theme.surface
                border.width: 1
                border.color: win.pendingHard ? Theme.danger : Theme.line

                Column {
                    id: confirmCol
                    anchors.centerIn: parent
                    width: parent.width - Theme.s(28)
                    spacing: Theme.s(8)

                    Text {
                        width: parent.width
                        text: !win.pendingServer ? ""
                            : win.pendingHard
                              ? "Force kill " + win.pendingServer.project + "?"
                              : "Stop " + win.pendingServer.project + "?"
                        color: Theme.text
                        font.family: Theme.mono
                        font.pixelSize: Theme.s(13)
                        font.bold: true
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        width: parent.width
                        text: !win.pendingServer ? ""
                            : (win.pendingHard
                               ? "Still listening 5 seconds after SIGTERM.\n"
                               : "")
                              + win.metaLine(win.pendingServer)
                        color: Theme.dim
                        font.family: Theme.mono
                        font.pixelSize: Theme.s(10)
                        wrapMode: Text.WordWrap
                    }

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: Theme.s(8)

                        Rectangle {
                            width: Theme.s(96); height: Theme.s(26)
                            radius: Theme.s(6)
                            color: confirmMouse.containsMouse ? Theme.surfaceAlt : "transparent"
                            border.width: 1
                            border.color: win.pendingHard ? Theme.danger : Theme.accent
                            Text {
                                anchors.centerIn: parent
                                text: win.pendingHard ? "Force kill" : "Stop"
                                color: win.pendingHard ? Theme.danger : Theme.accent
                                font.family: Theme.mono
                                font.pixelSize: Theme.s(11)
                            }
                            MouseArea {
                                id: confirmMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: win.confirmStop()
                            }
                        }

                        Rectangle {
                            width: Theme.s(96); height: Theme.s(26)
                            radius: Theme.s(6)
                            color: cancelMouse.containsMouse ? Theme.surfaceAlt : "transparent"
                            border.width: 1
                            border.color: Theme.line
                            Text {
                                anchors.centerIn: parent
                                text: "Cancel"
                                color: Theme.dim
                                font.family: Theme.mono
                                font.pixelSize: Theme.s(11)
                            }
                            MouseArea {
                                id: cancelMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: win.cancelStop()
                            }
                        }
                    }

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "Enter confirm · Esc cancel"
                        color: Theme.muted
                        font.family: Theme.mono
                        font.pixelSize: Theme.s(9)
                    }
                }
            }
        }
    }

    Shortcut {
        sequence: "Esc"
        onActivated: {
            if (win.confirmOpen) win.cancelStop()
            else win.close()
        }
    }

    GlobalShortcut {
        appid: "quickshell"
        name: "toggle-ports"
        description: "Toggle dev servers panel"
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
