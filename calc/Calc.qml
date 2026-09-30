import QtQuick
import Quickshell
import Quickshell.Io
import "../common"

// Calculator on qalc: results update as you type, Enter copies the result and keeps it in the history, Esc closes.
Popup {
    id: win
    shortcut: "toggle-calc"
    shortcutDescription: "Calculator"

    implicitWidth: Theme.s(480)
    implicitHeight: body.implicitHeight + Theme.s(32)

    property string result: ""
    property var history: []

    function open() {
        visible = true
        input.forceActiveFocus()
        input.selectAll()
    }

    function evaluate() {
        if (input.text.trim() === "") { result = ""; return }
        qalc.exec(["qalc", "-t", input.text])
    }

    function commit() {
        if (result === "") return
        Quickshell.clipboardText = result
        history = [{ expr: input.text, value: result }].concat(history).slice(0, 6)
        input.text = ""
    }

    Process {
        id: qalc
        stdout: StdioCollector { id: out }
        onExited: win.result = out.text.trim()
    }

    Timer {
        id: debounce
        interval: 120
        onTriggered: win.evaluate()
    }

    Card {
        id: panelBg
        anchors.fill: parent

        Column {
            id: body
            anchors.top: parent.top; anchors.topMargin: Theme.s(16)
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            spacing: Theme.s(10)

            Rectangle {
                width: parent.width
                height: Theme.s(40)
                radius: Theme.s(10)
                color: Theme.surface
                border.width: 1
                border.color: input.activeFocus ? Qt.alpha(Theme.accent, 0.6) : Theme.line

                Text {
                    anchors.left: parent.left; anchors.leftMargin: Theme.s(14)
                    anchors.verticalCenter: parent.verticalCenter
                    visible: input.text.length === 0
                    text: "2^10, 5 km to mi, sqrt(2)…"
                    font.pixelSize: Theme.s(13)
                    color: Theme.muted
                }

                TextInput {
                    id: input
                    anchors.left: parent.left; anchors.leftMargin: Theme.s(14)
                    anchors.right: parent.right; anchors.rightMargin: Theme.s(14)
                    anchors.verticalCenter: parent.verticalCenter
                    font.family: Theme.mono
                    font.pixelSize: Theme.s(13)
                    color: Theme.text
                    selectionColor: Theme.accentDim
                    clip: true
                    onTextChanged: debounce.restart()
                    Keys.onEscapePressed: win.close()
                    Keys.onReturnPressed: win.commit()
                    Keys.onEnterPressed: win.commit()
                }
            }

            Text {
                width: parent.width
                visible: win.result !== ""
                text: "= " + win.result
                wrapMode: Text.WrapAnywhere
                font.family: Theme.mono
                font.pixelSize: Theme.s(18)
                font.bold: true
                color: Theme.accent
            }

            Repeater {
                model: win.history
                Row {
                    required property var modelData
                    width: body.width
                    spacing: Theme.s(8)
                    Text {
                        width: parent.width * 0.6
                        elide: Text.ElideRight
                        text: parent.modelData.expr
                        font.family: Theme.mono
                        font.pixelSize: Theme.s(10)
                        color: Theme.muted
                    }
                    Text {
                        width: parent.width * 0.4 - Theme.s(8)
                        horizontalAlignment: Text.AlignRight
                        elide: Text.ElideLeft
                        text: parent.modelData.value
                        font.family: Theme.mono
                        font.pixelSize: Theme.s(10)
                        color: Theme.dim
                    }
                }
            }

            Text {
                text: "Enter copy · Esc close"
                font.pixelSize: Theme.s(9)
                color: Theme.muted
            }
        }
    }
}
