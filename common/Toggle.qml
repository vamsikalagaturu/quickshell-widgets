import QtQuick

// On/off pill. Purely visual + mouse bonus; the keyboard path drives
// `checked` via the owning pane's activate()/toggleItem(), never Qt focus.
Rectangle {
    id: toggle

    property bool checked: false
    property bool focused: false
    signal toggled()

    width: Theme.s(38)
    height: Theme.s(21)
    radius: height / 2
    color: checked ? Theme.accentDim : Theme.line
    border.width: focused ? 1 : 0
    border.color: Theme.accent

    Rectangle {
        width: Theme.s(17)
        height: Theme.s(17)
        radius: width / 2
        color: Theme.text
        anchors.verticalCenter: parent.verticalCenter
        x: toggle.checked ? parent.width - width - Theme.s(2) : Theme.s(2)
        Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: toggle.toggled()
    }
}
