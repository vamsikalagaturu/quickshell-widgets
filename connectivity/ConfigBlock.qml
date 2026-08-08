import QtQuick
import Quickshell
import Quickshell.Io

// Inline, per-connection field editor. This is ConfigPane's old "edit mode"
// factored out so WifiPane can embed one under an expanded network row and
// WiredPane can embed one permanently under the wired device -- nothing
// hands off to another tab anymore. EAP settings are rendered read-only and
// are never part of the apply flag list.
//
// Caller drives it with a *local* index (0..focusCount-1); it never touches
// the shell's global focusIdx itself.
Item {
    id: block

    property var shellRoot
    property var loaded: null        // net.py show <uuid> result
    property var draft: null         // mutable copy being edited
    property bool reactivate: false
    property var editItems: []
    property string applyError: ""
    property string applyOk: ""

    readonly property bool ready: loaded !== null
    readonly property int focusCount: editItems.length
    // Owning pane sets this to the block-local index that currently holds
    // the shell's global focus ring position, or -1 when none of this
    // block's rows are focused.
    property int focusedLocalIndex: -1

    function open(uuid) {
        applyError = ""
        applyOk = ""
        loaded = null
        draft = null
        editItems = []
        showProc.command = ["python3", Quickshell.shellPath("net.py"), "show", uuid]
        showProc.running = true
    }

    function reload() {
        if (loaded) open(loaded.uuid)
    }

    // ---- ring dispatch (local indices) ----
    function itemAt(i) {
        var row = fieldRepeater.itemAt(i)
        return row || null
    }

    function activateAt(i) {
        var item = editItems[i]
        if (!item) return
        if (item.kind === "field") {
            // only enter insert once the field actually resolved -- otherwise
            // insert stays true with nothing focused and the router's guard
            // swallows every key, Esc included.
            var f = fieldFor(i)
            if (f) {
                shellRoot.insert = true
                f.beginInsert()
            }
        } else {
            runItemAction(item)
        }
    }

    function toggleAt(i) {
        var item = editItems[i]
        if (!item || item.kind === "field") return
        runItemAction(item)
    }

    function yankAt(i) {
        var item = editItems[i]
        if (item) { Quickshell.clipboardText = String(getDraft(item)); shellRoot.flash("copied") }
    }

    function runItemAction(item) {
        if (item.kind === "toggle") {
            setDraft(item, !getDraft(item))
        } else if (item.kind === "seg") {
            var opts = item.options
            var i = opts.indexOf(String(getDraft(item)))
            i = (i + 1 + opts.length) % opts.length
            setDraft(item, opts[i])
        } else if (item.kind === "button" && item.key === "apply") {
            doApply()
        }
    }

    function getDraft(item) {
        if (!draft) return ""
        if (item.group === "reactivate") return block.reactivate
        // "action" (the apply button) has no group in the net.py payload --
        // its row's Toggle/Seg/Field are all `visible: false` but QML still
        // evaluates their bindings, so this must resolve harmlessly rather
        // than index into an undefined group.
        var g = draft[item.group]
        return g ? g[item.key] : ""
    }
    function setDraft(item, val) {
        if (item.group === "reactivate") { block.reactivate = val; return }
        var d = draft
        d[item.group][item.key] = val
        draft = Object.assign({}, d)
    }

    function fieldFor(i) {
        var row = fieldRepeater.itemAt(i)
        return row ? row.fieldItem : null
    }

    // Human-readable group heading. "" means the group gets no heading --
    // `reactivate` and `action` are not config groups, they're the trailing
    // controls, and labelling them "REACTIVATE" / "ACTION" read as noise.
    function groupLabel(g) {
        switch (g) {
            case "conn": return "CONNECTION"
            case "ipv4": return "IPv4"
            case "ipv6": return "IPv6"
            case "link": return "LINK"
            case "wifi": return "WI-FI"
            default: return ""
        }
    }

    function doApply() {
        if (!loaded) return
        applyError = ""
        applyOk = ""
        var args = ["apply", loaded.uuid].concat(buildApplyArgs())
        applyProc.command = ["python3", Quickshell.shellPath("net.py")].concat(args)
        applyProc.running = true
    }

    function buildApplyArgs() {
        var d = draft
        var args = []
        function push(flag, val) { if (val !== undefined && val !== null && String(val) !== "") args.push(flag, String(val)) }
        function pushBool(flag, val) { args.push(flag, val ? "true" : "false") }

        push("--ipv4-method", d.ipv4.method)
        push("--ipv4-addresses", d.ipv4.addresses)
        push("--ipv4-gateway", d.ipv4.gateway)
        push("--ipv4-dns", d.ipv4.dns)
        push("--ipv4-dns-search", d.ipv4.dns_search)
        pushBool("--ipv4-ignore-auto-dns", d.ipv4.ignore_auto_dns)
        push("--ipv4-route-metric", d.ipv4.route_metric)
        pushBool("--ipv4-never-default", d.ipv4.never_default)

        push("--ipv6-method", d.ipv6.method)
        push("--ipv6-addresses", d.ipv6.addresses)
        push("--ipv6-gateway", d.ipv6.gateway)
        push("--ipv6-dns", d.ipv6.dns)
        push("--ipv6-addr-gen-mode", d.ipv6.addr_gen_mode)
        push("--ipv6-privacy", d.ipv6.ip6_privacy)

        pushBool("--autoconnect", d.conn.autoconnect)
        push("--priority", d.conn.priority)
        push("--metered", d.conn.metered)
        push("--zone", d.conn.zone)

        push("--mtu", d.link.mtu)
        push("--cloned-mac", d.link.cloned_mac)

        if (loaded.type === "wifi" && d.wifi) {
            pushBool("--hidden", d.wifi.hidden)
            push("--bssid", d.wifi.bssid)
            push("--band", d.wifi.band)
            push("--channel", d.wifi.channel)
            push("--powersave", d.wifi.powersave)
        }

        if (block.reactivate) args.push("--reactivate")
        return args
    }

    function rebuildEditItems() {
        if (!draft) { editItems = []; return }
        var items = []
        items.push({ group: "conn", key: "autoconnect", kind: "toggle", label: "Autoconnect" })
        items.push({ group: "conn", key: "priority", kind: "field", label: "Priority", numeric: true })
        items.push({ group: "conn", key: "metered", kind: "seg", label: "Metered", options: ["auto", "yes", "no"] })
        items.push({ group: "conn", key: "zone", kind: "field", label: "Firewall zone" })

        items.push({ group: "ipv4", key: "method", kind: "seg", label: "IPv4 method", options: ["auto", "manual", "link-local", "shared", "disabled"] })
        items.push({ group: "ipv4", key: "addresses", kind: "field", label: "IPv4 addresses" })
        items.push({ group: "ipv4", key: "gateway", kind: "field", label: "IPv4 gateway" })
        items.push({ group: "ipv4", key: "dns", kind: "field", label: "IPv4 DNS" })
        items.push({ group: "ipv4", key: "dns_search", kind: "field", label: "IPv4 DNS search" })
        items.push({ group: "ipv4", key: "ignore_auto_dns", kind: "toggle", label: "Ignore auto DNS" })
        items.push({ group: "ipv4", key: "route_metric", kind: "field", label: "Route metric", numeric: true })
        items.push({ group: "ipv4", key: "never_default", kind: "toggle", label: "Never default route" })

        items.push({ group: "ipv6", key: "method", kind: "seg", label: "IPv6 method", options: ["auto", "manual", "link-local", "ignore", "disabled"] })
        items.push({ group: "ipv6", key: "addresses", kind: "field", label: "IPv6 addresses" })
        items.push({ group: "ipv6", key: "gateway", kind: "field", label: "IPv6 gateway" })
        items.push({ group: "ipv6", key: "dns", kind: "field", label: "IPv6 DNS" })
        items.push({ group: "ipv6", key: "addr_gen_mode", kind: "seg", label: "IPv6 addr-gen", options: ["default", "stable-privacy", "eui64"] })
        items.push({ group: "ipv6", key: "ip6_privacy", kind: "seg", label: "IPv6 privacy", options: ["-1", "0", "1", "2"], labels: ["default", "disabled", "enabled", "prefer"] })

        items.push({ group: "link", key: "mtu", kind: "field", label: "MTU", numeric: true })
        items.push({ group: "link", key: "cloned_mac", kind: "field", label: "Cloned MAC" })

        if (loaded && loaded.type === "wifi") {
            items.push({ group: "wifi", key: "hidden", kind: "toggle", label: "Hidden SSID" })
            items.push({ group: "wifi", key: "bssid", kind: "field", label: "BSSID" })
            items.push({ group: "wifi", key: "band", kind: "seg", label: "Band", options: ["", "a", "bg"], labels: ["auto", "5GHz", "2.4GHz"] })
            items.push({ group: "wifi", key: "channel", kind: "field", label: "Channel", numeric: true })
            items.push({ group: "wifi", key: "powersave", kind: "seg", label: "Powersave", options: ["default", "enable", "disable", "ignore"] })
        }

        items.push({ group: "reactivate", key: "reactivate", kind: "toggle", label: "Reactivate after apply" })
        items.push({ group: "action", key: "apply", kind: "button", label: "Apply" })

        editItems = items
    }

    Process {
        id: showProc
        stdout: StdioCollector { id: showOut }
        stderr: StdioCollector { id: showErr }
        onExited: code => {
            if (code === 0) {
                try {
                    var obj = JSON.parse(showOut.text.trim())
                    block.loaded = obj
                    block.draft = JSON.parse(JSON.stringify(obj))
                    block.reactivate = false
                    block.rebuildEditItems()
                } catch (e) {
                    shellRoot.flash("bad response from net.py")
                }
            } else {
                shellRoot.flash(showErr.text.trim() || "failed to load connection")
            }
        }
    }

    Process {
        id: applyProc
        stdout: StdioCollector { id: applyOut }
        stderr: StdioCollector { id: applyErr }
        onExited: code => {
            if (code === 0) {
                block.applyOk = "applied"
                block.applyError = ""
            } else {
                block.applyError = applyErr.text.trim() || "apply failed"
            }
        }
    }

    implicitHeight: col.implicitHeight

    Column {
        id: col
        width: parent.width
        spacing: Theme.s(6)

        Text {
            visible: !block.ready
            text: "loading…"
            font.pixelSize: Theme.s(11)
            color: Theme.muted
        }

        Text {
            visible: !!(block.loaded && block.loaded.eap)
            width: parent.width
            wrapMode: Text.WordWrap
            text: "802.1x / WPA-Enterprise — EAP settings are read-only and are never modified by this panel."
            font.pixelSize: Theme.s(10)
            color: Theme.warn
        }

        // read-only EAP block, never focusable, never in editItems
        Rectangle {
            visible: !!(block.loaded && block.loaded.eap && block.loaded.eap_info)
            width: parent.width
            implicitHeight: eapCol.implicitHeight + Theme.s(12)
            radius: Theme.s(8)
            color: Theme.surface
            opacity: 0.6

            Column {
                id: eapCol
                anchors.top: parent.top
                anchors.topMargin: Theme.s(6)
                anchors.left: parent.left
                anchors.leftMargin: Theme.s(10)
                spacing: Theme.s(2)
                Text { text: "EAP (read-only)"; font.pixelSize: Theme.s(10); color: Theme.muted }
                Text {
                    text: block.loaded && block.loaded.eap_info ? ("type: " + block.loaded.eap_info.eap) : ""
                    font.family: Theme.mono; font.pixelSize: Theme.s(11); color: Theme.dim
                }
                Text {
                    text: block.loaded && block.loaded.eap_info ? ("identity: " + block.loaded.eap_info.identity) : ""
                    font.family: Theme.mono; font.pixelSize: Theme.s(11); color: Theme.dim
                }
                Text {
                    text: block.loaded && block.loaded.eap_info ? ("phase2: " + block.loaded.eap_info.phase2) : ""
                    font.family: Theme.mono; font.pixelSize: Theme.s(11); color: Theme.dim
                }
            }
        }

        Text {
            visible: block.applyError !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            text: block.applyError
            font.pixelSize: Theme.s(11)
            color: Theme.danger
        }
        Text {
            visible: block.applyOk !== ""
            text: block.applyOk
            font.pixelSize: Theme.s(11)
            color: Theme.accent
        }

        Repeater {
            id: fieldRepeater
            model: block.editItems

            delegate: ListRow {
                id: erow
                required property var modelData
                required property int index
                width: parent ? parent.width : Theme.s(300)
                focused: block.focusedLocalIndex === index

                readonly property var item: modelData
                readonly property alias fieldItem: fld

                readonly property bool groupStart: erow.index === 0
                    || block.editItems[erow.index - 1].group !== erow.item.group
                readonly property string groupText: block.groupLabel(erow.item.group)
                // Heading space is RESERVED INSIDE the row's own height. The
                // previous version drew it at topMargin:-16, i.e. outside the
                // row, so every heading landed on top of the row above it.
                readonly property int headSpace: erow.groupStart
                    ? (erow.groupText !== "" ? Theme.s(22) : Theme.s(12)) : 0

                implicitHeight: headSpace + Theme.s(34)

                Text {
                    visible: erow.groupStart && erow.groupText !== ""
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.topMargin: Theme.s(3)
                    text: erow.groupText
                    font.pixelSize: Theme.s(10)
                    font.bold: true
                    font.letterSpacing: 1
                    color: Theme.muted
                }

                // separator above the trailing unlabelled controls
                Rectangle {
                    visible: erow.groupStart && erow.groupText === "" && erow.index > 0
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.topMargin: Theme.s(5)
                    height: 1
                    color: Theme.line
                }

                // Everything below the heading. Children center in HERE, not
                // in the whole row, so the heading can never be sat on.
                Item {
                    id: body
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.topMargin: erow.headSpace
                    anchors.bottom: parent.bottom

                    Text {
                        visible: erow.item.kind !== "button"
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: Theme.s(150)
                        text: erow.item.label
                        font.pixelSize: Theme.s(12)
                        color: Theme.text
                        elide: Text.ElideRight
                    }

                    Toggle {
                        visible: erow.item.kind === "toggle"
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.s(156)
                        anchors.verticalCenter: parent.verticalCenter
                        checked: !!block.getDraft(erow.item)
                        focused: erow.focused
                        onToggled: block.setDraft(erow.item, !block.getDraft(erow.item))
                    }

                    Seg {
                        visible: erow.item.kind === "seg"
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.s(156)
                        anchors.verticalCenter: parent.verticalCenter
                        focused: erow.focused
                        options: erow.item.options || []
                        labels: erow.item.labels || []
                        value: String(block.getDraft(erow.item))
                        onChanged: val => block.setDraft(erow.item, val)
                    }

                    Field {
                        id: fld
                        visible: erow.item.kind === "field"
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.s(156)
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        focused: erow.focused
                        numeric: !!erow.item.numeric
                        text: block.draft ? String(block.getDraft(erow.item)) : ""
                        onAccepted: { block.setDraft(erow.item, text); shellRoot.exitInsert() }
                        onCancelled: { text = block.draft ? String(block.getDraft(erow.item)) : ""; shellRoot.exitInsert() }
                    }

                    Rectangle {
                        visible: erow.item.kind === "button"
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: Theme.s(140)
                        height: Theme.s(26)
                        radius: Theme.s(8)
                        color: erow.item.key === "apply" ? Theme.accentDim : Theme.surfaceAlt
                        border.width: erow.focused ? 1 : 0
                        border.color: Theme.accent

                        Text {
                            anchors.centerIn: parent
                            text: erow.item.label
                            font.pixelSize: Theme.s(12)
                            font.bold: erow.item.key === "apply"
                            color: Theme.text
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: block.runItemAction(erow.item)
                        }
                    }
                }
            }
        }
    }
}
