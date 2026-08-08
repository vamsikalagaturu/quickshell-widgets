import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland._GlobalShortcuts
import Quickshell.Hyprland._FocusGrab

PanelWindow {
    id: win
    visible: false
    color: "transparent"
    implicitWidth: 640
    anchors.top: true
    margins.top: Math.max(0, (win.screen.height - win.implicitHeight) / 2)
    margins.left: Math.max(0, (win.screen.width - 640) / 2)
    focusable: true
    aboveWindows: true
    exclusionMode: ExclusionMode.Ignore

    property var allApps: DesktopEntries.applications
    property var filtered: []
    property int selection: 0

    implicitHeight: box.implicitHeight

    function matches(a, q) {
        if (a.noDisplay) return false
        if (!q) return true
        var s = (a.name + " " + (a.genericName || "") + " " + (a.comment || "") + " " + (a.keywords || []).join(" ")).toLowerCase()
        return s.indexOf(q) >= 0
    }

    function updateFilter() {
        var q = query.text.trim().toLowerCase()
        var out = []
        var vals = allApps.values
        for (var i = 0; i < vals.length; i++)
            if (matches(vals[i], q)) out.push(vals[i])
        out.sort(function(x, y) { return (x.name || "").localeCompare(y.name || "") })
        filtered = out
        selection = 0
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
        id: box
        width: parent.width
        implicitHeight: col.implicitHeight + 24
        radius: 16
        color: "#e60f1011"
        border.color: "#2d3136"
        border.width: 1

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Down) {
                selection = Math.min(selection + 1, filtered.length - 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Up) {
                selection = Math.max(selection - 1, 0)
                event.accepted = true
            } else if (event.key === Qt.Key_Escape) {
                closeLauncher()
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                launchCurrent()
                event.accepted = true
            }
        }

        Column {
            id: col
            anchors.centerIn: parent
            width: parent.width - 32
            spacing: 10

            Rectangle {
                id: searchBox
                width: parent.width
                height: 48
                radius: 12
                color: "#191d22"
                border.color: "#2d3136"
                border.width: 1

                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: 16
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 10

                    Text {
                        visible: query.text.length === 0
                        text: "Search apps"
                        font.pixelSize: 15
                        color: "#6f7378"
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    TextInput {
                        id: query
                        width: searchBox.width - 44
                        anchors.verticalCenter: parent.verticalCenter
                        font.pixelSize: 15
                        color: "#e6e6e6"
                        clip: true
                        onTextChanged: win.updateFilter()
                    }
                }

                Rectangle {
                    visible: query.activeFocus
                    height: 18
                    width: 2
                    radius: 1
                    color: "#b9bdc4"
                    anchors.right: parent.right
                    anchors.rightMargin: 16
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            ListView {
                id: list
                width: parent.width
                implicitHeight: Math.min(contentHeight, 8 * 48 + 8)
                model: win.filtered
                clip: true
                currentIndex: win.selection

                delegate: Rectangle {
                    width: list.width
                    height: 48
                    radius: 10
                    color: list.currentIndex === index ? "#2d3238" : "transparent"

                    Rectangle {
                        visible: list.currentIndex === index
                        width: 3
                        height: 20
                        radius: 1.5
                        color: "#b9bdc4"
                        anchors.left: parent.left
                        anchors.leftMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        anchors.right: parent.right
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 12

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 38
                            height: 38
                            radius: 9
                            color: "#23272d"

                            Image {
                                anchors.centerIn: parent
                                width: 26
                                height: 26
                                source: modelData.icon ? Quickshell.iconPath(modelData.icon) : ""
                                sourceSize: Qt.size(26, 26)
                            }
                        }

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2

                            Text {
                                text: modelData.name || ""
                                font.pixelSize: 14
                                font.weight: Font.DemiBold
                                color: "#e6e6e6"
                            }

                            Text {
                                text: modelData.genericName || modelData.comment || ""
                                font.pixelSize: 11
                                color: "#8f949b"
                            }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: { win.selection = index; win.launchCurrent() }
                    }
                }
            }

            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: "↑↓ navigate  ·  enter launch  ·  esc close"
                font.pixelSize: 11
                color: "#6f7378"
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
