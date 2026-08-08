import QtQuick

// Generic focusable list row (accent bar + border per focus rules).
//
// NOT a layout -- `content` dumps children into a plain Item with no
// positioning, and a plain Item leaves any child that forgets a horizontal
// anchor sitting at x=0. That bug already happened once (autoconnect toggle
// and its label both only set anchors.verticalCenter and landed on top of
// each other). To make the common case hard to get wrong, use the
// leftContent/rightContent slots below -- each is wrapped in a real Row
// positioner, so children just need spacing, not per-child anchors. Only
// reach for the bare `content` default slot when leftContent/rightContent
// don't fit the shape (e.g. a full-width detail block) and anchor every
// child explicitly when you do.
Rectangle {
    id: row

    property bool focused: false
    property bool activeState: false // connected/active green fill when not focused
    property bool dim: false         // read-only / disabled styling
    default property alias content: inner.data
    property alias leftContent: leftRow.data
    property alias rightContent: rightRow.data

    width: parent ? parent.width : Theme.s(300)
    implicitHeight: Theme.s(42)
    height: implicitHeight
    radius: Theme.s(8)
    color: focused ? Theme.surfaceAlt : (activeState ? "#2e7d5b26" : "transparent")
    border.width: focused ? 1 : 0
    border.color: Theme.accent
    opacity: dim ? 0.55 : 1

    // No left accent bar: the border + surface fill already mark focus, and
    // a focus-dependent left margin made every row's text jump sideways as
    // the ring moved. Margin is constant now.
    Item {
        id: inner
        anchors.fill: parent
        anchors.leftMargin: Theme.s(10)
        anchors.rightMargin: Theme.s(10)

        Row {
            id: leftRow
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.s(8)
        }

        Row {
            id: rightRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.s(8)
        }
    }
}
