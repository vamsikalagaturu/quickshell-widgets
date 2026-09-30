import QtQuick
import Quickshell
import Quickshell.Io
import "../common"

// Searchable list of the live Hyprland keybinds (hyprctl binds -j): type to filter, Esc closes.
Popup {
    id: win
    shortcut: "toggle-keybinds"
    shortcutDescription: "Search keybinds"

    implicitWidth: Theme.s(640)
    implicitHeight: Theme.s(540)

    property var binds: []
    property string filterText: ""
    readonly property var shown: {
        var q = filterText.toLowerCase()
        return binds.filter(b => !q || (b.combo + " " + b.what).toLowerCase().indexOf(q) >= 0)
    }

    function open() {
        visible = true
        query.text = ""
        filterText = ""
        loader.exec(["hyprctl", "binds", "-j"])
        query.forceActiveFocus()
    }

    function comboOf(b) {
        var parts = []
        if (b.modmask & 64) parts.push("Super")
        if (b.modmask & 4) parts.push("Ctrl")
        if (b.modmask & 8) parts.push("Alt")
        if (b.modmask & 1) parts.push("Shift")
        var names = { "mouse:272": "Left click", "mouse:273": "Right click", "mouse_down": "Wheel down", "mouse_up": "Wheel up" }
        var key = names[b.key] || (b.key.length === 1 ? b.key.toUpperCase() : b.key)
        parts.push(key)
        return parts.join(" + ")
    }

    Process {
        id: loader
        stdout: StdioCollector { id: collector }
        onExited: {
            try {
                win.binds = JSON.parse(collector.text)
                    .filter(b => b.key !== "")
                    .map(b => ({
                        combo: win.comboOf(b),
                        what: b.has_description && b.description ? b.description : (b.dispatcher + (b.arg ? " " + b.arg : ""))
                    }))
            } catch (e) {
                win.binds = []
            }
        }
    }

    Card {
        id: panelBg
        anchors.fill: parent

        Rectangle {
            id: searchBox
            anchors.top: parent.top; anchors.topMargin: Theme.s(16)
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            height: Theme.s(40)
            radius: Theme.s(10)
            color: Theme.surface
            border.width: 1
            border.color: query.activeFocus ? Qt.alpha(Theme.accent, 0.6) : Theme.line

            Text {
                anchors.left: parent.left; anchors.leftMargin: Theme.s(14)
                anchors.verticalCenter: parent.verticalCenter
                visible: query.text.length === 0
                text: "type to search keybinds…"
                font.pixelSize: Theme.s(13)
                color: Theme.muted
            }

            TextInput {
                id: query
                anchors.left: parent.left; anchors.leftMargin: Theme.s(14)
                anchors.right: countLabel.left; anchors.rightMargin: Theme.s(10)
                anchors.verticalCenter: parent.verticalCenter
                font.pixelSize: Theme.s(13)
                color: Theme.text
                selectionColor: Theme.accentDim
                clip: true
                onTextChanged: win.filterText = text
                Keys.onEscapePressed: win.close()
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Down || event.key === Qt.Key_PageDown) { list.flick(0, -Theme.s(1500)); event.accepted = true }
                    else if (event.key === Qt.Key_Up || event.key === Qt.Key_PageUp) { list.flick(0, Theme.s(1500)); event.accepted = true }
                }
            }

            Text {
                id: countLabel
                anchors.right: parent.right; anchors.rightMargin: Theme.s(14)
                anchors.verticalCenter: parent.verticalCenter
                text: win.shown.length + " binds"
                font.family: Theme.mono
                font.pixelSize: Theme.s(10)
                color: Theme.muted
            }
        }

        ListView {
            id: list
            anchors.top: searchBox.bottom; anchors.topMargin: Theme.s(10)
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(22)
            anchors.bottom: parent.bottom; anchors.bottomMargin: Theme.s(14)
            clip: true
            model: win.shown
            boundsBehavior: Flickable.StopAtBounds

            delegate: Item {
                required property var modelData
                width: list.width
                height: Theme.s(30)

                Text {
                    id: combo
                    width: Theme.s(230)
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    text: parent.modelData.combo
                    font.family: Theme.mono
                    font.pixelSize: Theme.s(11)
                    color: Theme.accent
                }
                Text {
                    anchors.left: combo.right; anchors.leftMargin: Theme.s(12)
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    text: parent.modelData.what
                    font.pixelSize: Theme.s(12)
                    color: Theme.text
                }
            }
        }

        ScrollTrack {
            anchors.top: list.top
            anchors.bottom: list.bottom
            anchors.left: list.right; anchors.leftMargin: Theme.s(4)
            flick: list
        }
    }
}
