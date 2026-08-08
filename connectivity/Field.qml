import QtQuick

// Labeled text input. The ONLY component in this widget that ever takes
// real Qt focus, and only while `insert` mode is active for it -- driven
// entirely by the owning pane, never by Tab-chains.
Item {
    id: field

    property string label: ""
    property alias text: input.text
    property string placeholder: ""
    property bool focused: false    // this field is the pane's current ring item
    property bool password: false
    property bool numeric: false
    // validator hook: function(string) -> bool. null = always valid.
    property var validator: null
    readonly property bool valid: !validator || validator(input.text)

    signal accepted()   // Enter while editing -> caller applies + exits insert
    signal cancelled()  // Esc while editing -> caller discards + exits insert

    function beginInsert() {
        input.forceActiveFocus()
        input.selectAll()
    }

    // Label space is reserved INSIDE the item. Drawing it at a negative top
    // margin put it outside our own bounds, on top of whatever sat above.
    readonly property int labelSpace: label !== "" ? Theme.s(15) : 0

    implicitHeight: labelSpace + Theme.s(34)
    width: parent ? parent.width : Theme.s(200)

    Text {
        id: labelText
        visible: field.label !== ""
        anchors.left: parent.left
        anchors.leftMargin: Theme.s(2)
        anchors.top: parent.top
        text: field.label
        font.pixelSize: Theme.s(10)
        color: Theme.muted
    }

    Rectangle {
        id: box
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: field.labelSpace
        anchors.bottom: parent.bottom
        radius: Theme.s(8)
        color: Theme.surfaceAlt
        border.width: (field.focused || input.activeFocus) ? 1 : 0
        border.color: !field.valid ? Theme.danger : Theme.accent
    }

    Text {
        anchors.left: box.left
        anchors.leftMargin: Theme.s(10)
        anchors.verticalCenter: box.verticalCenter
        visible: input.text === "" && !input.activeFocus && field.placeholder !== ""
        text: field.placeholder
        font.pixelSize: Theme.s(12)
        color: Theme.muted
    }

    TextInput {
        id: input
        anchors.left: box.left
        anchors.right: box.right
        anchors.leftMargin: Theme.s(10)
        anchors.rightMargin: Theme.s(10)
        anchors.verticalCenter: box.verticalCenter
        echoMode: field.password ? TextInput.Password : TextInput.Normal
        validator: field.numeric ? intValidator : null
        activeFocusOnTab: false
        font.pixelSize: Theme.s(12)
        font.family: Theme.mono
        color: Theme.text
        selectionColor: Theme.accentDim
        clip: true

        IntValidator {
            id: intValidator
            bottom: -1
            top: 999999
        }

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) {
                field.cancelled()
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                field.accepted()
                event.accepted = true
            }
            // every other key is normal text editing -- global bindings are
            // suspended simply because this TextInput, not the shell item,
            // owns activeFocus right now.
        }
    }
}
