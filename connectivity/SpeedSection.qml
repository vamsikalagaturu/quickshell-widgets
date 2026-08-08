import QtQuick
import Quickshell

// Dumb view over the SpeedTest singleton. Wi-Fi and Wired tabs each embed
// one of these at the bottom of their pane; both read/drive the same
// singleton so the run is shared. The owning pane offsets its focus ring by
// `baseIdx` and forwards activate()/toggleItem()/yank() for the two local
// slots (0: duration seg, 1: upload toggle) into durationFocused/
// uploadFocused + the functions below.
Item {
    id: section

    property int baseIdx: 0          // ring index of the duration seg
    property bool durationFocused: false
    property bool uploadFocused: false

    readonly property int focusCount: 2
    readonly property alias durationItem: durationRow
    readonly property alias uploadItem: uploadRow

    function cycleDuration() { durationSeg.next() }
    function toggleUpload() { SpeedTest.uploadEnabled = !SpeedTest.uploadEnabled }

    implicitHeight: col.implicitHeight

    Column {
        id: col
        width: parent.width
        spacing: Theme.s(8)

        Rectangle {
            width: parent.width
            height: 1
            color: Theme.line
        }

        Text {
            text: "Speed test"
            font.pixelSize: Theme.s(11)
            font.bold: true
            color: Theme.dim
        }

        Row {
            width: parent.width
            spacing: Theme.s(24)

            Column {
                spacing: Theme.s(2)
                Text { text: "DOWN"; font.pixelSize: Theme.s(9); color: Theme.muted }
                Text {
                    text: SpeedTest.down.toFixed(1)
                    font.family: Theme.mono
                    font.pixelSize: Theme.s(22)
                    font.bold: true
                    color: SpeedTest.phase === "down" ? Theme.accent : Theme.text
                }
            }
            Column {
                spacing: Theme.s(2)
                Text { text: "UP"; font.pixelSize: Theme.s(9); color: Theme.muted }
                Text {
                    text: SpeedTest.up.toFixed(1)
                    font.family: Theme.mono
                    font.pixelSize: Theme.s(22)
                    font.bold: true
                    color: SpeedTest.phase === "up" ? Theme.accent : Theme.text
                }
            }
            Column {
                spacing: Theme.s(2)
                Text { text: "PING"; font.pixelSize: Theme.s(9); color: Theme.muted }
                Text {
                    text: SpeedTest.ping.toFixed(1) + " / " + SpeedTest.jitter.toFixed(1) + " ms"
                    font.family: Theme.mono
                    font.pixelSize: Theme.s(12)
                    color: Theme.text
                }
            }
            Column {
                spacing: Theme.s(2)
                Text { text: "COLO"; font.pixelSize: Theme.s(9); color: Theme.muted }
                Text {
                    text: SpeedTest.colo || "—"
                    font.family: Theme.mono
                    font.pixelSize: Theme.s(12)
                    color: Theme.text
                }
            }

            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.s(16)

                ListRow {
                    id: durationRow
                    width: implicitWidth
                    implicitHeight: Theme.s(24)
                    focused: section.durationFocused
                    leftContent: [
                        Seg {
                            id: durationSeg
                            focused: section.durationFocused
                            options: ["5", "10", "20"]
                            labels: ["5s", "10s", "20s"]
                            value: String(SpeedTest.duration)
                            onChanged: val => { SpeedTest.duration = parseInt(val) }
                        }
                    ]
                }

                ListRow {
                    id: uploadRow
                    width: implicitWidth
                    implicitHeight: Theme.s(24)
                    focused: section.uploadFocused
                    leftContent: [
                        Toggle {
                            checked: SpeedTest.uploadEnabled
                            focused: section.uploadFocused
                            onToggled: section.toggleUpload()
                        },
                        Text {
                            text: "upload"
                            font.pixelSize: Theme.s(12)
                            color: Theme.text
                        }
                    ]
                }
            }
        }

        Rectangle {
            width: parent.width
            height: Theme.s(4)
            radius: Theme.s(2)
            color: Theme.line
            visible: SpeedTest.running

            Rectangle {
                height: parent.height
                radius: parent.radius
                color: Theme.accent
                width: parent.width * Math.max(0, Math.min(1, SpeedTest.pct))
                Behavior on width { NumberAnimation { duration: 120 } }
            }
        }

        Text {
            visible: SpeedTest.running
            text: "phase: " + SpeedTest.phase + "   ·  x to abort"
            font.pixelSize: Theme.s(10)
            color: Theme.dim
        }

        Text {
            visible: !SpeedTest.running && SpeedTest.errorMsg === ""
            text: "s to start"
            font.pixelSize: Theme.s(10)
            color: Theme.muted
        }

        Text {
            visible: SpeedTest.errorMsg !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            text: SpeedTest.errorMsg
            font.pixelSize: Theme.s(11)
            color: Theme.danger
        }
    }
}
