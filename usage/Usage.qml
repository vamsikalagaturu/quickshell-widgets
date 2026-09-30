import QtQuick
import "../common"
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
        var args = ["python3", Paths.local(Qt.resolvedUrl("usage.py"))]
        if (fresh) args.push("--fresh")
        proc.exec(args)
    }

    implicitWidth: card.implicitWidth
    implicitHeight: card.implicitHeight

    Card {
        id: card
        visible: win.groups.length > 0
        implicitWidth: content.implicitWidth + Theme.s(24)
        implicitHeight: content.implicitHeight + Theme.s(18)
        radius: Theme.s(10)

        Column {
            id: content
            anchors.centerIn: parent
            spacing: Theme.s(8)

            Repeater {
                model: win.groups
                delegate: Column {
                    spacing: Theme.s(5)

                    Rectangle {
                        visible: index > 0
                        width: parent.width
                        height: 1
                        color: Theme.line
                    }

                    Text {
                        text: modelData.title
                        font.family: Theme.mono
                        font.pixelSize: Theme.s(8)
                        font.bold: true
                        font.capitalization: Font.AllUppercase
                        font.letterSpacing: 1.5
                        color: Theme.muted
                    }

                    Repeater {
                        model: modelData.rows
                        delegate: Row {
                            spacing: Theme.s(8)

                            Text {
                                width: Theme.s(16)
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.label
                                font.family: Theme.mono
                                font.pixelSize: Theme.s(9)
                                color: Theme.dim
                            }

                            Rectangle {
                                width: Theme.s(110)
                                height: Theme.s(5)
                                radius: height / 2
                                color: Theme.surface
                                anchors.verticalCenter: parent.verticalCenter

                                Rectangle {
                                    width: Math.min(1, (modelData.pct || 0) / 100) * parent.width
                                    height: parent.height
                                    radius: height / 2
                                    color: modelData.pct >= 90 ? Theme.danger : modelData.pct >= 70 ? Theme.warn : Theme.ok
                                }
                            }

                            Text {
                                width: Theme.s(26)
                                anchors.verticalCenter: parent.verticalCenter
                                horizontalAlignment: Text.AlignRight
                                text: modelData.pct + "%"
                                font.family: Theme.mono
                                font.pixelSize: Theme.s(9)
                                font.bold: true
                                color: Theme.text
                            }

                            Text {
                                width: Theme.s(62)
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.reset || ""
                                font.family: Theme.mono
                                font.pixelSize: Theme.s(8)
                                color: Theme.muted
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
