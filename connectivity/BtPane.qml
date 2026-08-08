import QtQuick
import Quickshell
import Quickshell.Bluetooth

Item {
    id: pane

    property var shellRoot

    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property var devices: adapter ? adapter.devices.values : []
    property string filterText: ""
    readonly property var filteredDevices: filterText === "" ? devices
        : devices.filter(d => (d.name || d.deviceName || "").toLowerCase().indexOf(filterText.toLowerCase()) !== -1)

    // row 0: adapter enabled, row 1: discovering, rows 2..: devices
    property int focusIdx: 0
    readonly property int focusCount: adapter ? (2 + filteredDevices.length) : 0
    readonly property string hints: "j/k move · Enter connect/pair · Space toggle · / filter · y copy address · r scan · d,y forget"
    readonly property var focusedDevice: (focusIdx > 1 && focusIdx - 2 < filteredDevices.length)
        ? filteredDevices[focusIdx - 2] : null
    readonly property string deleteLabel: (focusedDevice && (focusedDevice.paired || focusedDevice.bonded))
        ? ("forget “" + (focusedDevice.name || focusedDevice.deviceName) + "”") : ""

    onFocusCountChanged: if (focusIdx >= focusCount) focusIdx = Math.max(0, focusCount - 1)

    function startFilter() {
        shellRoot.insert = true
        filterField.beginInsert()
    }
    function clearFilter() { pane.filterText = "" }

    function activate() {
        if (!adapter) return
        if (focusIdx === 0) { adapter.enabled = !adapter.enabled; return }
        if (focusIdx === 1) { adapter.discovering = !adapter.discovering; return }
        var d = focusedDevice
        if (!d) return
        if (d.connected) d.disconnect()
        else if (d.paired || d.bonded) d.connect()
        else d.pair()
    }

    function toggleItem() { activate() }

    function yank() {
        var d = focusedDevice
        Quickshell.clipboardText = d ? d.address : (adapter ? adapter.name : "")
        shellRoot.flash(d ? "copied address" : "copied")
    }

    function refresh() {
        if (adapter) adapter.discovering = true
        shellRoot.flash("scanning…")
    }

    function deleteFocused() {
        if (focusedDevice) focusedDevice.forget()
    }

    // scroll-follow
    function currentFocusItem() {
        if (focusIdx === 0) return powerRow
        if (focusIdx === 1) return scanRow
        var d = devRepeater.itemAt(focusIdx - 2)
        return d || null
    }

    function ensureVisible(item) {
        if (!item) return
        var pos = item.mapToItem(flick.contentItem, 0, 0)
        var top = pos.y
        var bottom = pos.y + item.height
        var pad = Theme.s(8)
        if (top < flick.contentY) flick.contentY = Math.max(0, top - pad)
        else if (bottom > flick.contentY + flick.height)
            flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, bottom - flick.height + pad))
    }

    onFocusIdxChanged: Qt.callLater(() => ensureVisible(currentFocusItem()))

    ScrollTrack {
        flick: flick
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
    }

    Flickable {
        id: flick
        anchors.fill: parent
        anchors.rightMargin: Theme.s(10)   // room for the scroll track
        contentWidth: width
        contentHeight: mainCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: mainCol
            width: flick.width
            spacing: Theme.s(10)

            Text { text: "Bluetooth"; font.pixelSize: Theme.s(13); font.bold: true; color: Theme.text }

            Rectangle {
                visible: !pane.adapter
                width: parent.width
                implicitHeight: Theme.s(60)
                radius: Theme.s(10)
                color: Theme.surface
                Text {
                    anchors.centerIn: parent
                    text: "no bluetooth adapter found"
                    font.pixelSize: Theme.s(12)
                    color: Theme.muted
                }
            }

            Rectangle {
                visible: !!pane.adapter
                width: parent.width
                implicitHeight: adapterCol.implicitHeight + Theme.s(16)
                radius: Theme.s(10)
                color: Theme.surface

                Column {
                    id: adapterCol
                    anchors.top: parent.top; anchors.topMargin: Theme.s(8)
                    anchors.left: parent.left; anchors.leftMargin: Theme.s(12)
                    anchors.right: parent.right; anchors.rightMargin: Theme.s(12)
                    spacing: Theme.s(6)

                    // Two short toggles side by side rather than stacked --
                    // still two independent ring items.
                    Item {
                        width: parent.width
                        height: Math.max(powerRow.implicitHeight, scanRow.implicitHeight)

                        ListRow {
                            id: powerRow
                            anchors.left: parent.left
                            width: (parent.width - Theme.s(10)) / 2
                            focused: pane.focusIdx === 0
                            leftContent: [
                                Toggle {
                                    checked: pane.adapter ? pane.adapter.enabled : false
                                    focused: pane.focusIdx === 0
                                    onToggled: pane.adapter.enabled = !pane.adapter.enabled
                                },
                                Text { text: "Bluetooth"; font.pixelSize: Theme.s(12); color: Theme.text }
                            ]
                            MouseArea {
                                anchors.fill: parent
                                onClicked: pane.focusIdx = 0
                                onDoubleClicked: { pane.focusIdx = 0; pane.activate() }
                            }
                        }

                        ListRow {
                            id: scanRow
                            anchors.right: parent.right
                            width: (parent.width - Theme.s(10)) / 2
                            focused: pane.focusIdx === 1
                            leftContent: [
                                Toggle {
                                    checked: pane.adapter ? pane.adapter.discovering : false
                                    focused: pane.focusIdx === 1
                                    onToggled: pane.adapter.discovering = !pane.adapter.discovering
                                },
                                Text {
                                    text: "Scanning" + (pane.adapter && pane.adapter.discovering ? "…" : "")
                                    font.pixelSize: Theme.s(12)
                                    color: Theme.text
                                }
                            ]
                            MouseArea {
                                anchors.fill: parent
                                onClicked: pane.focusIdx = 1
                                onDoubleClicked: { pane.focusIdx = 1; pane.activate() }
                            }
                        }
                    }
                }
            }

            Field {
                id: filterField
                visible: !!pane.adapter
                width: parent.width
                placeholder: "/ to filter devices…"
                text: pane.filterText
                onTextChanged: pane.filterText = text
                onAccepted: shellRoot.exitInsert()
                onCancelled: { pane.filterText = ""; text = ""; shellRoot.exitInsert() }
            }

            Column {
                width: parent.width
                spacing: Theme.s(4)
                visible: !!pane.adapter

                Repeater {
                    id: devRepeater
                    model: pane.filteredDevices

                    delegate: ListRow {
                        id: devRow
                        required property var modelData
                        required property int index
                        width: parent ? parent.width : Theme.s(300)
                        focused: pane.focusIdx === index + 2
                        activeState: modelData.connected

                        MouseArea {
                            anchors.fill: parent
                            onClicked: pane.focusIdx = devRow.index + 2
                            onDoubleClicked: { pane.focusIdx = devRow.index + 2; pane.activate() }
                        }

                        leftContent: [
                            Text {
                                width: Theme.s(220)
                                text: devRow.modelData.name || devRow.modelData.deviceName
                                elide: Text.ElideRight
                                font.pixelSize: Theme.s(13)
                                color: devRow.modelData.connected ? Theme.accent : Theme.text
                            },
                            Text {
                                visible: devRow.modelData.paired || devRow.modelData.bonded
                                text: devRow.modelData.connected ? "connected" : "paired"
                                font.pixelSize: Theme.s(10)
                                color: Theme.dim
                            }
                        ]
                        rightContent: [
                            Text {
                                visible: devRow.modelData.batteryAvailable
                                text: Math.round(devRow.modelData.battery * 100) + "%"
                                font.family: Theme.mono
                                font.pixelSize: Theme.s(11)
                                color: Theme.dim
                            }
                        ]
                    }
                }

                Text {
                    visible: !!pane.adapter && pane.filteredDevices.length === 0
                    text: pane.filterText !== "" ? "no matches" : "no devices"
                    font.pixelSize: Theme.s(12)
                    color: Theme.muted
                }
            }
        }
    }
}
