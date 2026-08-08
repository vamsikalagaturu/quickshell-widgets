import QtQuick

// Segmented multiple-choice control (ipv4 method, band, powersave, ...).
// activate()/toggleItem() on the owning pane calls next()/prev() or clicks
// drive `changed`; this never takes Qt focus.
Row {
    id: seg

    property var options: []      // list of value strings
    property var labels: []       // display labels; falls back to options[i]
    property string value: ""
    property bool focused: false
    signal changed(string val)

    function labelFor(i) {
        return (labels && labels[i] !== undefined) ? labels[i] : options[i]
    }

    function indexOfValue() {
        return options.indexOf(seg.value)
    }

    function next() {
        if (options.length === 0) return
        var i = indexOfValue()
        i = (i + 1 + options.length) % options.length
        seg.changed(options[i])
    }

    spacing: Theme.s(6)
    height: Theme.s(24)

    Repeater {
        model: seg.options
        delegate: Rectangle {
            required property string modelData
            required property int index
            width: Math.max(Theme.s(44), txt.implicitWidth + Theme.s(16))
            height: Theme.s(24)
            radius: Theme.s(7)
            color: modelData === seg.value ? Theme.accentDim : Theme.surfaceAlt
            border.width: seg.focused && modelData === seg.value ? 1 : 0
            border.color: Theme.accent

            Text {
                id: txt
                anchors.centerIn: parent
                text: seg.labelFor(index)
                font.pixelSize: Theme.s(11)
                color: modelData === seg.value ? Theme.text : Theme.dim
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: seg.changed(modelData)
            }
        }
    }
}
