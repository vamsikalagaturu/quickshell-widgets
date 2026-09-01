import QtQuick

// Thin scroll indicator for a Flickable. Duplicated from connectivity/ScrollTrack.qml.
Rectangle {
    id: track

    property var flick: null

    readonly property bool needed: !!flick && flick.contentHeight > flick.height + 1

    width: Theme.s(4)
    radius: width / 2
    color: Theme.line
    opacity: needed ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: 120 } }

    Rectangle {
        width: parent.width
        radius: parent.radius
        color: Theme.accentDim

        height: track.needed
            ? Math.max(Theme.s(24), track.height * track.flick.visibleArea.heightRatio)
            : 0
        y: track.needed
            ? Math.max(0, Math.min(track.height - height,
                                   track.height * track.flick.visibleArea.yPosition))
            : 0
    }
}
