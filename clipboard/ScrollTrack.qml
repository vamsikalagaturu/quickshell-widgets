import QtQuick

// Thin scroll indicator for a Flickable.
//
// Deliberately NOT QtQuick.Controls' ScrollBar: we don't import Controls
// anywhere in this widget and pulling it in drags a style backend along for
// what is a track plus a thumb. Named ScrollTrack rather than ScrollBar /
// ScrollIndicator so it can't shadow a Controls type if one is ever imported
// -- the Row-vs-QtQuick.Row collision already cost us a layout bug once.
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

        // heightRatio/yPosition are fractions of the whole content; clamp the
        // thumb so it stays grabbable on very long lists and never overruns
        // the bottom of the track.
        height: track.needed
            ? Math.max(Theme.s(24), track.height * track.flick.visibleArea.heightRatio)
            : 0
        y: track.needed
            ? Math.max(0, Math.min(track.height - height,
                                   track.height * track.flick.visibleArea.yPosition))
            : 0
    }
}
