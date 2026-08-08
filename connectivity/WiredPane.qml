import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Networking

// Uniform pane interface, see WifiPane.qml for the general pattern. Wired
// has exactly one device and one profile, so its config is always inline
// (no 'e' gate) -- shown even with no carrier, since interface/MAC/link
// state and the IPv4/IPv6 config are all useful without a cable plugged in.
//
// Focus ring: 0 autoconnect, 1 nmManaged, 2 connect/disconnect,
// 3..3+N config fields, last 2 speed section.
Item {
    id: pane

    property var shellRoot

    readonly property var device: {
        var ds = Networking.devices.values
        for (var i = 0; i < ds.length; i++)
            if (ds[i].type === DeviceType.Wired) return ds[i]
        return null
    }

    // ---- resolve the wired connection profile via net.py, so the config
    // block is populated even when there's no active link (no device.network
    // to read a name/uuid off). Prefer the profile bound to this interface,
    // fall back to the only ethernet profile that exists (the common case). ----
    property var connList: []

    function refreshConns() {
        connsProc.command = ["python3", Quickshell.shellPath("net.py"), "conns"]
        connsProc.running = true
    }

    Process {
        id: connsProc
        stdout: StdioCollector { id: connsOut }
        onExited: code => {
            if (code !== 0) return
            try { pane.connList = JSON.parse(connsOut.text.trim() || "[]") } catch (e) { /* keep previous */ }
        }
    }

    // ---- live IP/gateway/DNS (not on NetworkDevice's DBus surface --
    // device.address is the MAC) ----
    property var activeInfo: ({})

    function refreshActive() {
        activeProc.command = ["python3", Quickshell.shellPath("net.py"), "active"]
        activeProc.running = true
    }

    readonly property var myInfo: pane.device && pane.activeInfo[pane.device.name]
        ? pane.activeInfo[pane.device.name] : null

    Process {
        id: activeProc
        stdout: StdioCollector { id: activeOut }
        onExited: code => {
            if (code !== 0) return
            try { pane.activeInfo = JSON.parse(activeOut.text.trim() || "{}") } catch (e) { /* keep previous */ }
        }
    }

    Connections {
        target: pane.device
        function onConnectedChanged() { Qt.callLater(pane.refreshActive) }
        function onStateChanged() { Qt.callLater(pane.refreshActive) }
    }

    Connections {
        target: shellRoot
        function onVisibleChanged() {
            if (shellRoot.visible) { pane.refreshConns(); pane.refreshActive() }
        }
    }
    Component.onCompleted: { refreshConns(); refreshActive() }

    readonly property var ethConn: {
        var list = pane.connList.filter(c => c.type === "ethernet")
        if (list.length === 0) return null
        if (pane.device) {
            for (var i = 0; i < list.length; i++)
                if (list[i].device === pane.device.name) return list[i]
        }
        for (var j = 0; j < list.length; j++) if (list[j].active) return list[j]
        return list[0]
    }
    onEthConnChanged: if (pane.ethConn) configBlock.open(pane.ethConn.uuid)

    // ---- flat ring resolver ----
    function resolveRing(idx) {
        if (idx === 0) return { kind: "autoconnect" }
        if (idx === 1) return { kind: "nmManaged" }
        if (idx === 2) return { kind: "connect" }
        var pos = 3
        var n = configBlock.ready ? configBlock.focusCount : 0
        if (idx < pos + n) return { kind: "field", localIdx: idx - pos }
        pos += n
        var s = idx - pos
        if (s === 0) return { kind: "speedDuration" }
        if (s === 1) return { kind: "speedUpload" }
        return null
    }

    readonly property var currentRing: pane.device ? resolveRing(focusIdx) : null

    // ---- uniform pane interface ----
    property int focusIdx: 0
    readonly property int focusCount: pane.device
        ? (3 + (configBlock.ready ? configBlock.focusCount : 0) + 2) : 0
    readonly property string hints: "j/k move · Enter connect/disconnect/edit · Space toggle · y copy MAC · r refresh · s/x speed"
    readonly property string deleteLabel: (device && device.network && device.network.known)
        ? ("forget “" + device.network.name + "”") : ""

    onFocusCountChanged: if (focusIdx >= focusCount) focusIdx = Math.max(0, focusCount - 1)

    function activate() {
        var r = pane.currentRing
        if (!r || !pane.device) return
        if (r.kind === "autoconnect") { pane.device.autoconnect = !pane.device.autoconnect; return }
        if (r.kind === "nmManaged") { pane.device.nmManaged = !pane.device.nmManaged; return }
        if (r.kind === "connect") {
            if (pane.device.network) {
                if (pane.device.network.connected) pane.device.network.disconnect()
                else pane.device.network.connect()
            }
            return
        }
        if (r.kind === "field") { configBlock.activateAt(r.localIdx); return }
        if (r.kind === "speedDuration") { speedSection.cycleDuration(); return }
        if (r.kind === "speedUpload") { speedSection.toggleUpload(); return }
    }

    function toggleItem() {
        var r = pane.currentRing
        if (r && r.kind === "field") { configBlock.toggleAt(r.localIdx); return }
        activate()
    }

    function yank() {
        var r = pane.currentRing
        if (r && r.kind === "field") { configBlock.yankAt(r.localIdx); return }
        if (device) { Quickshell.clipboardText = device.address; shellRoot.flash("copied MAC") }
    }

    function refresh() { refreshConns(); refreshActive() }

    function deleteFocused() {
        if (device && device.network && device.network.known) device.network.forget()
    }

    // scroll-follow
    function currentFocusItem() {
        var r = pane.currentRing
        if (!r) return null
        if (r.kind === "autoconnect") return autoRow
        if (r.kind === "nmManaged") return nmRow
        if (r.kind === "connect") return connectRow
        if (r.kind === "field") return configBlock.itemAt(r.localIdx)
        // speed section is pinned outside the Flickable -- never scrolled to
        return null
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

    Flickable {
        id: flick
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.rightMargin: Theme.s(10)   // room for the scroll track
        anchors.bottom: speedSection.top
        anchors.bottomMargin: Theme.s(10)
        contentWidth: width
        contentHeight: mainCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: mainCol
            width: flick.width
            spacing: Theme.s(10)

            Text { text: "Wired"; font.pixelSize: Theme.s(13); font.bold: true; color: Theme.text }

            Rectangle {
                visible: !pane.device
                width: parent.width
                implicitHeight: Theme.s(60)
                radius: Theme.s(10)
                color: Theme.surface
                Text {
                    anchors.centerIn: parent
                    text: "no wired device found"
                    font.pixelSize: Theme.s(12)
                    color: Theme.muted
                }
            }

            Column {
                visible: !!pane.device
                width: parent.width
                spacing: Theme.s(10)

                // Two independent ring items, but they're short toggles --
                // stacking them wasted a whole row of vertical space.
                Item {
                    width: parent.width
                    height: Math.max(autoRow.implicitHeight, nmRow.implicitHeight)

                    ListRow {
                        id: autoRow
                        anchors.left: parent.left
                        width: (parent.width - Theme.s(10)) / 2
                        focused: pane.currentRing && pane.currentRing.kind === "autoconnect"
                        leftContent: [
                            Toggle {
                                checked: pane.device ? pane.device.autoconnect : false
                                focused: pane.currentRing && pane.currentRing.kind === "autoconnect"
                                onToggled: pane.device.autoconnect = !pane.device.autoconnect
                            },
                            Text { text: "Autoconnect"; font.pixelSize: Theme.s(12); color: Theme.text }
                        ]
                        MouseArea {
                            anchors.fill: parent
                            onClicked: pane.focusIdx = 0
                            onDoubleClicked: { pane.focusIdx = 0; pane.activate() }
                        }
                    }

                    ListRow {
                        id: nmRow
                        anchors.right: parent.right
                        width: (parent.width - Theme.s(10)) / 2
                        focused: pane.currentRing && pane.currentRing.kind === "nmManaged"
                        leftContent: [
                            Toggle {
                                checked: pane.device ? pane.device.nmManaged : false
                                focused: pane.currentRing && pane.currentRing.kind === "nmManaged"
                                onToggled: pane.device.nmManaged = !pane.device.nmManaged
                            },
                            Text { text: "NM managed"; font.pixelSize: Theme.s(12); color: Theme.text }
                        ]
                        MouseArea {
                            anchors.fill: parent
                            onClicked: pane.focusIdx = 1
                            onDoubleClicked: { pane.focusIdx = 1; pane.activate() }
                        }
                    }
                }

                // ---- info card: interface, MAC, link state -- always
                // shown, carrier or not ----
                Rectangle {
                    width: parent.width
                    implicitHeight: infoCol.implicitHeight + Theme.s(20)
                    radius: Theme.s(10)
                    color: Theme.surface

                    Column {
                        id: infoCol
                        anchors.top: parent.top; anchors.topMargin: Theme.s(10)
                        anchors.left: parent.left; anchors.leftMargin: Theme.s(14)
                        anchors.right: parent.right; anchors.rightMargin: Theme.s(14)
                        spacing: Theme.s(4)

                        Row {
                            spacing: Theme.s(8)
                            Rectangle {
                                width: Theme.s(8); height: Theme.s(8); radius: Theme.s(4)
                                anchors.verticalCenter: parent.verticalCenter
                                color: pane.device && pane.device.connected ? Theme.accent : Theme.muted
                            }
                            Text {
                                text: pane.device && pane.device.connected ? "connected" : "no link"
                                font.pixelSize: Theme.s(12)
                                color: pane.device && pane.device.connected ? Theme.accent : Theme.dim
                            }
                            Text {
                                visible: !!(pane.device && pane.device.hasLink && pane.device.linkSpeed > 0)
                                text: pane.device ? pane.device.linkSpeed + " Mb/s" : ""
                                font.family: Theme.mono
                                font.pixelSize: Theme.s(12)
                                color: Theme.dim
                            }
                        }
                        Text {
                            text: pane.device ? ("interface  " + pane.device.name) : ""
                            font.family: Theme.mono
                            font.pixelSize: Theme.s(11)
                            color: Theme.muted
                        }
                        Text {
                            text: pane.device ? ("MAC        " + pane.device.address) : ""
                            font.family: Theme.mono
                            font.pixelSize: Theme.s(11)
                            color: Theme.muted
                        }
                        Text {
                            visible: !!(pane.device && pane.device.network)
                            text: pane.device && pane.device.network ? ("profile    " + pane.device.network.name) : ""
                            font.family: Theme.mono
                            font.pixelSize: Theme.s(11)
                            color: Theme.muted
                        }
                        Text {
                            visible: !!(pane.myInfo && pane.myInfo.ip4.length > 0)
                            text: pane.myInfo && pane.myInfo.ip4.length ? ("IPv4       " + pane.myInfo.ip4.join(", ")) : ""
                            font.family: Theme.mono; font.pixelSize: Theme.s(11); color: Theme.dim
                        }
                        Text {
                            visible: !!(pane.myInfo && pane.myInfo.gw4)
                            text: pane.myInfo ? ("gateway    " + pane.myInfo.gw4) : ""
                            font.family: Theme.mono; font.pixelSize: Theme.s(11); color: Theme.muted
                        }
                        Text {
                            visible: !!(pane.myInfo && pane.myInfo.dns.length > 0)
                            text: pane.myInfo && pane.myInfo.dns.length ? ("DNS        " + pane.myInfo.dns.join(", ")) : ""
                            font.family: Theme.mono; font.pixelSize: Theme.s(11); color: Theme.muted
                        }
                    }
                }

                ListRow {
                    id: connectRow
                    width: parent.width
                    focused: pane.currentRing && pane.currentRing.kind === "connect"
                    activeState: pane.device && pane.device.connected
                    dim: !pane.device || !pane.device.network

                    MouseArea {
                        anchors.fill: parent
                        onClicked: pane.focusIdx = 2
                        onDoubleClicked: { pane.focusIdx = 2; pane.activate() }
                    }

                    leftContent: [
                        Text {
                            text: pane.device && pane.device.network
                                ? (pane.device.network.connected ? "Disconnect" : "Connect")
                                : "No profile bound to this interface"
                            font.pixelSize: Theme.s(12)
                            color: Theme.text
                        }
                    ]
                }

                Text {
                    visible: !pane.ethConn
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: "no ethernet connection profile found via net.py — nothing to edit"
                    font.pixelSize: Theme.s(11)
                    color: Theme.muted
                }

                ConfigBlock {
                    id: configBlock
                    width: parent.width
                    visible: !!pane.ethConn
                    shellRoot: pane.shellRoot
                    focusedLocalIndex: pane.currentRing && pane.currentRing.kind === "field" ? pane.currentRing.localIdx : -1
                }
            }
        }
    }

    ScrollTrack {
        flick: flick
        anchors.right: parent.right
        anchors.top: flick.top
        anchors.bottom: flick.bottom
    }

    // Pinned outside the Flickable so it's visible without scrolling.
    SpeedSection {
        id: speedSection
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        durationFocused: pane.currentRing && pane.currentRing.kind === "speedDuration"
        uploadFocused: pane.currentRing && pane.currentRing.kind === "speedUpload"
    }
}
