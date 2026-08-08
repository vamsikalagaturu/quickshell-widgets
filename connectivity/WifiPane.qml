import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Networking

// Uniform pane interface driven entirely by shell.qml's key router:
// focusIdx / focusCount / activate() / toggleItem() / yank() / refresh() / hints.
// This pane never takes Qt focus -- only `pwdField` and the fields inside an
// expanded ConfigBlock take it, and only while shellRoot.insert is true.
//
// Focus ring layout (flat index -> meaning), computed by resolveRing():
//   0                                   header (wifi radio toggle)
//   1..filteredNetworks.length          one entry per network row
//     if that network is expanded (via 'e'), its ConfigBlock's fields are
//     spliced in immediately after that row's ring slot
//   last 2 slots                        speed section (duration, upload)
Item {
    id: pane

    property var shellRoot

    // ---- device (never cached -- Networking.devices populates async over
    // DBus, so this must stay a live re-evaluating binding) ----
    readonly property var device: {
        var ds = Networking.devices.values
        for (var i = 0; i < ds.length; i++)
            if (ds[i].type === DeviceType.Wifi) return ds[i]
        return null
    }

    // Scanner must run while the panel is visible or the device only ever
    // reports the single active AP (measured: scannerEnabled=false keeps
    // networks.length at 1 indefinitely; true reaches the real AP count
    // within ~4s). A live Binding -- not an imperative one-shot set -- so it
    // re-asserts whenever `device` resolves to a new instance or the panel
    // is hidden again (radio off when hidden: don't burn power / keep the
    // radio busy for a closed panel).
    Binding {
        target: pane.device
        property: "scannerEnabled"
        value: pane.shellRoot ? pane.shellRoot.visible : false
        when: pane.device !== null
    }

    readonly property var networks: device
        ? device.networks.values.slice().sort((a, b) => (b.connected - a.connected) || (b.signalStrength - a.signalStrength))
        : []
    readonly property var filteredNetworks: filterText === "" ? networks
        : networks.filter(n => n.name.toLowerCase().indexOf(filterText.toLowerCase()) !== -1)

    // ---- per-SSID detail from `net.py scan` (nmcli has bssid/chan/freq/
    // rate that WifiNetwork's DBus surface doesn't). Keyed by SSID so it can
    // be matched against the reactive WifiNetwork list while keeping that
    // list's connect()/disconnect() actions. Refreshed on visibility and 'r'
    // so simply focusing a row shows info immediately -- no keypress needed. ----
    property var scanBySsid: ({})

    function refreshScan() {
        scanProc.command = ["python3", Quickshell.shellPath("net.py"), "scan"]
        scanProc.running = true
    }

    Process {
        id: scanProc
        stdout: StdioCollector { id: scanOut }
        onExited: code => {
            if (code !== 0) return
            try {
                var arr = JSON.parse(scanOut.text.trim() || "[]")
                var map = {}
                for (var i = 0; i < arr.length; i++) map[arr[i].ssid] = arr[i]
                pane.scanBySsid = map
            } catch (e) { /* leave previous scan data in place */ }
        }
    }

    // ---- live connection info for the header card (IP/gateway/DNS aren't
    // on WifiNetwork's or NetworkDevice's DBus surface -- device.address is
    // the MAC). Keyed by interface name. ----
    property var activeInfo: ({})

    function refreshActive() {
        activeProc.command = ["python3", Quickshell.shellPath("net.py"), "active"]
        activeProc.running = true
    }

    readonly property var myInfo: pane.device && pane.activeInfo[pane.device.name]
        ? pane.activeInfo[pane.device.name] : null

    // the currently-connected AP, and its richer scan row (band/chan/rate)
    readonly property var connectedNet: {
        var ns = pane.networks
        for (var i = 0; i < ns.length; i++) if (ns[i].connected) return ns[i]
        return null
    }
    readonly property var connectedScan: pane.connectedNet
        ? (pane.scanBySsid[pane.connectedNet.name] || null) : null

    Process {
        id: activeProc
        stdout: StdioCollector { id: activeOut }
        onExited: code => {
            if (code !== 0) return
            try { pane.activeInfo = JSON.parse(activeOut.text.trim() || "{}") } catch (e) { /* keep previous */ }
        }
    }

    // reflect connect/disconnect promptly without polling on a timer
    Connections {
        target: pane.device
        function onConnectedChanged() { Qt.callLater(pane.refreshActive) }
        function onStateChanged() { Qt.callLater(pane.refreshActive) }
    }

    Connections {
        target: shellRoot
        function onVisibleChanged() {
            if (shellRoot.visible) { pane.refreshScan(); pane.refreshActive() }
        }
    }
    Component.onCompleted: { refreshScan(); refreshActive() }

    // ---- filter ('/' stays on this page) ----
    property string filterText: ""
    function startFilter() {
        shellRoot.insert = true
        filterField.beginInsert()
    }
    function clearFilter() { pane.filterText = "" }

    // ---- inline config expansion ('e' -- never switches tab) ----
    property int expandedIndex: -1       // network index currently expanded, -1 = none
    property var expandedBlock: null     // the ConfigBlock instance for expandedIndex

    function hasExpansion() { return pane.expandedIndex >= 0 }

    function ringIndexOfNetwork(netIndex) {
        var pos = 1
        for (var i = 0; i < netIndex; i++) {
            pos++
            if (pane.expandedIndex === i && pane.expandedBlock) pos += pane.expandedBlock.focusCount
        }
        return pos
    }

    function collapseExpansion() {
        var netIdx = pane.expandedIndex
        pane.expandedIndex = -1
        pane.expandedBlock = null
        if (netIdx >= 0) pane.focusIdx = pane.ringIndexOfNetwork(netIdx)
    }

    function edit() {
        var r = pane.currentRing
        if (!r) return
        if (r.kind === "network") {
            if (pane.expandedIndex === r.netIndex) { collapseExpansion(); return }
            var info = pane.scanBySsid[r.net.name]
            if (!info || !info.uuid) {
                shellRoot.flash("no saved profile — connect once first to enable editing")
                return
            }
            pane.expandedIndex = r.netIndex
        } else if (r.kind === "field") {
            collapseExpansion()
        }
    }

    // ---- flat ring resolver ----
    function resolveRing(idx) {
        if (idx === 0) return { kind: "header" }
        var pos = 1
        var nets = pane.filteredNetworks
        for (var i = 0; i < nets.length; i++) {
            if (idx === pos) return { kind: "network", netIndex: i, net: nets[i] }
            pos++
            if (pane.expandedIndex === i && pane.expandedBlock) {
                var n = pane.expandedBlock.focusCount
                if (idx < pos + n) return { kind: "field", netIndex: i, localIdx: idx - pos }
                pos += n
            }
        }
        var s = idx - pos
        if (s === 0) return { kind: "speedDuration" }
        if (s === 1) return { kind: "speedUpload" }
        return null
    }

    readonly property var currentRing: resolveRing(focusIdx)
    readonly property int focusedNetIndex: currentRing && (currentRing.kind === "network" || currentRing.kind === "field")
        ? currentRing.netIndex : -1

    // ---- uniform pane interface ----
    property int focusIdx: 0
    readonly property int focusCount: {
        var n = 1 + filteredNetworks.length + 2
        if (pane.expandedIndex >= 0 && pane.expandedBlock) n += pane.expandedBlock.focusCount
        return n
    }
    readonly property string hints: pwdMode
        ? "Enter connect · Esc cancel"
        : "j/k move · Enter connect · Space toggle radio · / filter · e edit config · y copy · r rescan · d,y forget · s/x speed"
    readonly property string deleteLabel: (currentRing && currentRing.kind === "network" && currentRing.net.known)
        ? ("forget “" + currentRing.net.name + "”") : ""

    onFocusCountChanged: if (focusIdx >= focusCount) focusIdx = Math.max(0, focusCount - 1)

    property bool pwdMode: false
    property var pwdNetwork: null

    function needsPsk(n) {
        return n.security !== WifiSecurityType.Open && !n.known
    }

    function activate() {
        var r = pane.currentRing
        if (!r) return
        if (r.kind === "header") { Networking.wifiEnabled = !Networking.wifiEnabled; return }
        if (r.kind === "network") {
            var n = r.net
            if (n.connected) { n.disconnect(); return }
            if (needsPsk(n)) {
                pwdField.text = ""
                pane.pwdMode = true
                pane.pwdNetwork = n
                shellRoot.insert = true
                Qt.callLater(() => pwdField.beginInsert())
            } else {
                n.connect()
            }
            return
        }
        if (r.kind === "field") { if (pane.expandedBlock) pane.expandedBlock.activateAt(r.localIdx); return }
        if (r.kind === "speedDuration") { speedSection.cycleDuration(); return }
        if (r.kind === "speedUpload") { speedSection.toggleUpload(); return }
    }

    function toggleItem() {
        var r = pane.currentRing
        if (r && r.kind === "field") { pane.expandedBlock.toggleAt(r.localIdx); return }
        activate()
    }

    function yank() {
        var r = pane.currentRing
        if (!r) return
        if (r.kind === "network") {
            Quickshell.clipboardText = r.net.name
            shellRoot.flash("copied “" + r.net.name + "”")
        } else if (r.kind === "field") {
            if (pane.expandedBlock) pane.expandedBlock.yankAt(r.localIdx)
        } else if (r.kind === "header") {
            Quickshell.clipboardText = device ? device.address : ""
            shellRoot.flash("copied")
        }
    }

    function refresh() {
        if (device) {
            device.scannerEnabled = false
            Qt.callLater(() => { device.scannerEnabled = true })
        }
        refreshScan()
        refreshActive()
        shellRoot.flash("rescanning…")
    }

    function deleteFocused() {
        if (currentRing && currentRing.kind === "network" && currentRing.net.known) currentRing.net.forget()
    }

    function submitPsk() {
        if (pane.pwdNetwork) pane.pwdNetwork.connectWithPsk(pwdField.text)
        pwdField.text = ""
        pane.pwdMode = false
        pane.pwdNetwork = null
        shellRoot.exitInsert()
    }

    function cancelPsk() {
        pwdField.text = ""
        pane.pwdMode = false
        pane.pwdNetwork = null
        shellRoot.exitInsert()
    }

    // scroll-follow: bring the item at the current ring position into view.
    // The speed section is pinned outside the Flickable (always visible), so
    // it never needs scrolling to -- and mapping it into the flickable's
    // content coords would produce a bogus jump.
    function currentFocusItem() {
        var r = pane.currentRing
        if (!r) return null
        if (r.kind === "header") return headerRow
        if (r.kind === "speedDuration" || r.kind === "speedUpload") return null
        var d = netRepeater.itemAt(r.netIndex)
        if (!d) return null
        if (r.kind === "network") return d.rowItem
        if (r.kind === "field" && pane.expandedBlock) return pane.expandedBlock.itemAt(r.localIdx)
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
    onExpandedIndexChanged: Qt.callLater(() => ensureVisible(currentFocusItem()))

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

            ListRow {
                id: headerRow
                width: parent.width
                focused: pane.focusIdx === 0
                leftContent: [
                    Toggle {
                        checked: Networking.wifiEnabled
                        focused: pane.focusIdx === 0
                        onToggled: Networking.wifiEnabled = !Networking.wifiEnabled
                    },
                    Text {
                        text: "Wi-Fi"
                        font.pixelSize: Theme.s(13)
                        font.bold: true
                        color: pane.focusIdx === 0 ? Theme.accent : Theme.text
                    }
                ]
                rightContent: [
                    Text {
                        visible: !Networking.wifiHardwareEnabled
                        text: "hardware disabled (rfkill)"
                        font.pixelSize: Theme.s(11)
                        color: Theme.warn
                    }
                ]
            }

            // ---- connection info card, mirroring the Wired tab's ----
            Rectangle {
                width: parent.width
                implicitHeight: wifiInfoCol.implicitHeight + Theme.s(20)
                radius: Theme.s(10)
                color: Theme.surface

                Column {
                    id: wifiInfoCol
                    anchors.top: parent.top; anchors.topMargin: Theme.s(10)
                    anchors.left: parent.left; anchors.leftMargin: Theme.s(14)
                    anchors.right: parent.right; anchors.rightMargin: Theme.s(14)
                    spacing: Theme.s(4)

                    Row {
                        spacing: Theme.s(8)
                        Rectangle {
                            width: Theme.s(8); height: Theme.s(8); radius: Theme.s(4)
                            anchors.verticalCenter: parent.verticalCenter
                            color: pane.connectedNet ? Theme.accent : Theme.muted
                        }
                        Text {
                            text: pane.connectedNet ? pane.connectedNet.name : "not connected"
                            font.pixelSize: Theme.s(13)
                            font.bold: true
                            color: pane.connectedNet ? Theme.accent : Theme.dim
                        }
                        Text {
                            visible: !!pane.connectedNet
                            anchors.verticalCenter: parent.verticalCenter
                            text: pane.connectedNet ? Math.round(pane.connectedNet.signalStrength) + "%" : ""
                            font.family: Theme.mono
                            font.pixelSize: Theme.s(12)
                            color: Theme.dim
                        }
                        Text {
                            visible: !!pane.connectedScan
                            anchors.verticalCenter: parent.verticalCenter
                            text: pane.connectedScan
                                ? (pane.connectedScan.band + " · ch " + pane.connectedScan.chan
                                   + " · " + pane.connectedScan.rate)
                                : ""
                            font.family: Theme.mono
                            font.pixelSize: Theme.s(11)
                            color: Theme.muted
                        }
                    }

                    Text {
                        text: pane.device ? ("interface  " + pane.device.name) : "no wifi device"
                        font.family: Theme.mono; font.pixelSize: Theme.s(11); color: Theme.muted
                    }
                    Text {
                        visible: !!pane.device
                        text: pane.device ? ("MAC        " + pane.device.address) : ""
                        font.family: Theme.mono; font.pixelSize: Theme.s(11); color: Theme.muted
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
                    Text {
                        visible: !!(pane.myInfo && pane.myInfo.ip6.length > 0)
                        text: pane.myInfo && pane.myInfo.ip6.length ? ("IPv6       " + pane.myInfo.ip6[0]) : ""
                        font.family: Theme.mono; font.pixelSize: Theme.s(11); color: Theme.muted
                    }
                }
            }

            Field {
                id: filterField
                width: parent.width
                placeholder: "/ to filter networks…"
                text: pane.filterText
                onTextChanged: pane.filterText = text
                onAccepted: shellRoot.exitInsert()
                onCancelled: { pane.filterText = ""; text = ""; shellRoot.exitInsert() }
            }

            Text {
                visible: !Networking.wifiEnabled
                text: "Wi-Fi is off"
                font.pixelSize: Theme.s(12)
                color: Theme.muted
            }

            Column {
                id: networksCol
                width: parent.width
                spacing: Theme.s(6)
                visible: Networking.wifiEnabled

                Repeater {
                    id: netRepeater
                    model: pane.filteredNetworks

                    delegate: Column {
                        id: netDelegate
                        required property var modelData
                        required property int index
                        width: networksCol.width
                        spacing: Theme.s(4)
                        readonly property alias rowItem: netRow

                        ListRow {
                            id: netRow
                            width: parent.width
                            focused: pane.focusedNetIndex === netDelegate.index
                            activeState: netDelegate.modelData.connected

                            Connections {
                                target: netDelegate.modelData
                                function onConnectionFailed(reason) {
                                    shellRoot.flash("failed: " + ConnectionFailReason.toString(reason))
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: pane.focusIdx = pane.ringIndexOfNetwork(netDelegate.index)
                                onDoubleClicked: {
                                    pane.focusIdx = pane.ringIndexOfNetwork(netDelegate.index)
                                    pane.activate()
                                }
                            }

                            leftContent: [
                                Text {
                                    width: Theme.s(220)
                                    text: netDelegate.modelData.name
                                    elide: Text.ElideRight
                                    font.pixelSize: Theme.s(13)
                                    color: netDelegate.modelData.connected ? Theme.accent : Theme.text
                                }
                            ]
                            rightContent: [
                                Text {
                                    text: Math.round(netDelegate.modelData.signalStrength) + "%"
                                    font.family: Theme.mono
                                    font.pixelSize: Theme.s(12)
                                    color: Theme.dim
                                }
                            ]
                        }

                        // Instant detail: shown the moment this row is
                        // focused, no keypress required. WifiNetwork's DBus
                        // surface has no bssid/channel/freq/rate -- this
                        // comes from `net.py scan`, matched by SSID.
                        Text {
                            visible: netDelegate.index === pane.focusedNetIndex
                            width: parent.width
                            wrapMode: Text.WordWrap
                            leftPadding: Theme.s(14)
                            topPadding: Theme.s(2)
                            bottomPadding: Theme.s(4)
                            lineHeight: 1.25
                            font.family: Theme.mono
                            font.pixelSize: Theme.s(11)
                            color: Theme.dim
                            text: {
                                var info = pane.scanBySsid[netDelegate.modelData.name]
                                if (!info) return "no scan data yet — press r to rescan"
                                var bits = [info.security, info.band, "ch " + info.chan, info.freq,
                                            info.rate, info.bssid, info.saved ? "saved" : "not saved"]
                                if (info.active) bits.push("active")
                                return bits.join("  ·  ")
                            }
                        }

                        Loader {
                            id: expLoader
                            width: parent.width
                            active: pane.expandedIndex === netDelegate.index
                            sourceComponent: cbComponent

                            Component {
                                id: cbComponent
                                ConfigBlock {
                                    shellRoot: pane.shellRoot
                                    focusedLocalIndex: pane.currentRing && pane.currentRing.kind === "field"
                                        && pane.currentRing.netIndex === netDelegate.index ? pane.currentRing.localIdx : -1
                                    Component.onCompleted: {
                                        pane.expandedBlock = this
                                        var info = pane.scanBySsid[netDelegate.modelData.name]
                                        if (info && info.uuid) open(info.uuid)
                                    }
                                }
                            }
                        }
                    }
                }

                Text {
                    visible: pane.filteredNetworks.length === 0
                    text: pane.filterText !== "" ? "no matches" : "no networks found"
                    font.pixelSize: Theme.s(12)
                    color: Theme.muted
                }
            }

            Field {
                id: pwdField
                visible: pane.pwdMode
                width: parent.width
                label: "password for " + (pane.pwdNetwork ? pane.pwdNetwork.name : "")
                password: true
                placeholder: "psk"
                onAccepted: pane.submitPsk()
                onCancelled: pane.cancelPsk()
            }
        }
    }

    ScrollTrack {
        flick: flick
        anchors.right: parent.right
        anchors.top: flick.top
        anchors.bottom: flick.bottom
    }

    // Pinned to the bottom of the pane, OUTSIDE the Flickable -- previously
    // it was the last item in the scrolling column, so it was invisible
    // until you scrolled all the way down and nobody knew it existed.
    SpeedSection {
        id: speedSection
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        durationFocused: pane.currentRing && pane.currentRing.kind === "speedDuration"
        uploadFocused: pane.currentRing && pane.currentRing.kind === "speedUpload"
    }
}
