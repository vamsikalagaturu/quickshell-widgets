import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland._GlobalShortcuts

PanelWindow {
    id: win
    visible: true
    color: "transparent"
    anchors.right: true
    anchors.top: true
    margins { top: 12; right: 12 }
    exclusionMode: ExclusionMode.Ignore
    aboveWindows: true
    focusable: false

    property var groups: []

    function refresh(fresh) {
        var args = ["python3", Quickshell.shellPath("usage.py")]
        if (fresh) args.push("--fresh")
        proc.exec(args)
    }

    implicitWidth: card.implicitWidth
    implicitHeight: card.implicitHeight

    Rectangle {
        id: card
        visible: win.groups.length > 0
        implicitWidth: row.implicitWidth + 28
        implicitHeight: row.implicitHeight + 24
        radius: 14
        color: "#e6101318"
        border.color: "#335588ff"
        border.width: 1

        Column {
            id: row
            anchors.centerIn: parent
            spacing: 10

            Repeater {
                model: win.groups
                delegate: Rectangle {
                    implicitWidth: col.implicitWidth + 18
                    implicitHeight: col.implicitHeight + 18
                    radius: 10
                    color: "#1a2633"

                    Column {
                        id: col
                        anchors.centerIn: parent
                        spacing: 8

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: modelData.title.toUpperCase()
                            font.family: "JetBrainsMono Nerd Font Mono"
                            font.pixelSize: 13
                            font.bold: true
                            color: "#5773c7"
                        }

                        Repeater {
                            model: modelData.rows
                            delegate: Row {
                                height: 20
                                spacing: 10

                                Text {
                                    width: 24
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.label
                                    font.family: "JetBrainsMono Nerd Font Mono"
                                    font.pixelSize: 14
                                    font.bold: true
                                    color: "#c8d0da"
                                }

                                Rectangle {
                                    id: track
                                    width: 160
                                    height: 9
                                    radius: 4
                                    color: "#22303c"
                                    anchors.verticalCenter: parent.verticalCenter

                                    Rectangle {
                                        width: Math.min(1, (modelData.pct || 0) / 100) * parent.width
                                        height: parent.height
                                        radius: 4
                                        color: modelData.pct >= 90 ? "#ff5555" : modelData.pct >= 70 ? "#ffb454" : "#57d5a8"
                                    }
                                }

                                Text {
                                    width: 42
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.pct + "%"
                                    font.family: "JetBrainsMono Nerd Font Mono"
                                    font.pixelSize: 14
                                    color: "#e6e6e6"
                                }

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.reset || ""
                                    font.family: "JetBrainsMono Nerd Font Mono"
                                    font.pixelSize: 13
                                    color: "#6c7784"
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        property point last: Qt.point(0, 0)
        onPressed: m => last = Qt.point(m.x, m.y)
        onPositionChanged: m => {
            win.margins.right += (m.x - last.x)
            win.margins.top += (m.y - last.y)
            last = Qt.point(m.x, m.y)
        }
    }

    Process {
        id: proc
        stdout: StdioCollector { id: collector }
        onExited: (code, status) => {
            if (code == 0) {
                try { win.groups = JSON.parse(collector.text.trim()) }
                catch (e) { win.groups = [] }
            }
        }
    }

    Timer {
        id: autoHide
        interval: 5000
        repeat: false
        running: true
        onTriggered: win.visible = false
    }

    Component.onCompleted: refresh(false)

    GlobalShortcut {
        appid: "quickshell"
        name: "toggle-usage"
        description: "Toggle usage widget"
        onPressed: {
            win.visible = !win.visible
            autoHide.stop()
            if (win.visible) {
                refresh(true)
                autoHide.start()
            }
        }
    }
}
