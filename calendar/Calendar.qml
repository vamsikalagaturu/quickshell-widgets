import QtQuick
import Quickshell
import "../common"

// Month calendar above waybar's clock: ‹ › / h l change month, t jumps to today, Esc closes.
Popup {
    id: win
    shortcut: "toggle-calendar"
    shortcutDescription: "Toggle calendar"

    anchors.bottom: true
    margins.bottom: Theme.s(6)

    property date now: new Date()
    property int viewYear: now.getFullYear()
    property int viewMonth: now.getMonth()

    readonly property real cell: Theme.s(26)

    implicitWidth: 8 * cell + Theme.s(32)
    implicitHeight: body.implicitHeight + Theme.s(28)

    function open() {
        now = new Date()
        showToday()
        visible = true
        panelBg.forceActiveFocus()
    }

    function showToday() {
        viewYear = now.getFullYear()
        viewMonth = now.getMonth()
    }

    function shiftMonth(delta) {
        var d = new Date(viewYear, viewMonth + delta, 1)
        viewYear = d.getFullYear()
        viewMonth = d.getMonth()
    }

    function isoWeek(d) {
        var t = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()))
        var day = t.getUTCDay() || 7
        t.setUTCDate(t.getUTCDate() + 4 - day)
        var yearStart = new Date(Date.UTC(t.getUTCFullYear(), 0, 1))
        return Math.ceil(((t - yearStart) / 86400000 + 1) / 7)
    }

    // six Monday-first weeks covering the viewed month
    readonly property var weeks: {
        var first = new Date(viewYear, viewMonth, 1)
        var offset = (first.getDay() + 6) % 7
        var rows = []
        for (var w = 0; w < 6; w++) {
            var days = []
            for (var i = 0; i < 7; i++)
                days.push(new Date(viewYear, viewMonth, 1 - offset + w * 7 + i))
            rows.push(days)
        }
        return rows
    }

    component NavButton: Rectangle {
        property string glyph
        signal clicked()
        width: win.cell; height: win.cell
        radius: width / 2
        color: navMouse.containsMouse ? Theme.surfaceAlt : "transparent"
        Text {
            anchors.centerIn: parent
            text: parent.glyph
            font.pixelSize: Theme.s(12)
            color: Theme.dim
        }
        MouseArea {
            id: navMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: parent.clicked()
        }
    }

    Card {
        id: panelBg
        anchors.fill: parent
        focus: true

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) win.close()
            else if (event.key === Qt.Key_H || event.key === Qt.Key_Left) win.shiftMonth(-1)
            else if (event.key === Qt.Key_L || event.key === Qt.Key_Right) win.shiftMonth(1)
            else if (event.key === Qt.Key_K || event.key === Qt.Key_Up) win.shiftMonth(-12)
            else if (event.key === Qt.Key_J || event.key === Qt.Key_Down) win.shiftMonth(12)
            else if (event.key === Qt.Key_T) win.showToday()
            else return
            event.accepted = true
        }

        Column {
            id: body
            anchors.centerIn: parent
            spacing: Theme.s(6)

            Item {
                width: 8 * win.cell
                height: win.cell

                NavButton {
                    anchors.left: parent.left
                    glyph: "‹"
                    onClicked: win.shiftMonth(-1)
                }
                Text {
                    anchors.centerIn: parent
                    text: Qt.locale().standaloneMonthName(win.viewMonth) + " " + win.viewYear
                    font.pixelSize: Theme.s(11)
                    font.bold: true
                    color: titleMouse.containsMouse ? Theme.accent : Theme.text
                    MouseArea {
                        id: titleMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: win.showToday()
                    }
                }
                NavButton {
                    anchors.right: parent.right
                    glyph: "›"
                    onClicked: win.shiftMonth(1)
                }
            }

            Row {
                Item { width: win.cell; height: win.cell * 0.8 }
                Repeater {
                    // Monday first
                    model: [1, 2, 3, 4, 5, 6, 0]
                    Text {
                        width: win.cell
                        height: win.cell * 0.8
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        text: Qt.locale().dayName(modelData, Locale.ShortFormat).slice(0, 2)
                        font.pixelSize: Theme.s(8)
                        color: Theme.info
                    }
                }
            }

            Repeater {
                model: win.weeks
                Row {
                    required property var modelData

                    Text {
                        width: win.cell; height: win.cell
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        text: win.isoWeek(modelData[0])
                        font.family: Theme.mono
                        font.pixelSize: Theme.s(7)
                        color: Qt.alpha(Theme.muted, 0.55)
                    }

                    Repeater {
                        model: modelData
                        Rectangle {
                            required property var modelData
                            readonly property bool inMonth: modelData.getMonth() === win.viewMonth
                            readonly property bool isToday: modelData.toDateString() === win.now.toDateString()
                            width: win.cell; height: win.cell
                            radius: width / 2
                            color: isToday ? Theme.surfaceAlt : "transparent"
                            border.width: isToday ? 1 : 0
                            border.color: Theme.accent

                            Text {
                                anchors.centerIn: parent
                                text: parent.modelData.getDate()
                                font.family: Theme.mono
                                font.pixelSize: Theme.s(9)
                                font.bold: parent.isToday
                                color: parent.isToday ? Theme.accent : parent.inMonth ? Theme.text : Qt.alpha(Theme.muted, 0.55)
                            }
                        }
                    }
                }
            }
        }
    }

    // keeps "today" right across midnight while the popup is open
    Timer {
        interval: 60000
        repeat: true
        running: win.visible
        onTriggered: win.now = new Date()
    }
}
