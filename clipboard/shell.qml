import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland._GlobalShortcuts
import Quickshell.Hyprland._FocusGrab

// Clipboard history, styled to match the network panel and launcher.
// Backed by cliphist, whose wl-paste watchers already run from
// hypr/startup.conf -- this is only a picker over `cliphist list`.
//
// Search-first like the launcher: the TextInput owns focus throughout, so
// navigation is arrows plus readline-style Ctrl+N/P and Ctrl+J/K.
PanelWindow {
    id: win
    visible: false
    color: "transparent"
    anchors.top: true
    anchors.left: true
    margins.top: Math.max(0, (win.screen.height - implicitHeight) / 2)
    margins.left: Math.max(0, (win.screen.width - implicitWidth) / 2)
    exclusionMode: ExclusionMode.Ignore
    aboveWindows: true
    focusable: true

    implicitWidth: Theme.s(940)
    implicitHeight: Theme.s(580)

    // list / preview split
    readonly property real listFrac: 0.44

    property var entries: []      // [{id, preview, image}]
    property var filtered: []
    property int selection: 0
    property bool confirmWipe: false
    property string flashMsg: ""

    readonly property int rowHeight: Theme.s(40)
    readonly property var current: filtered[selection] || null

    function flash(m) { win.flashMsg = m; flashTimer.restart() }
    Timer { id: flashTimer; interval: 1800; onTriggered: win.flashMsg = "" }

    // ---- load ----
    function reload() {
        listProc.running = false
        listProc.running = true
    }

    Process {
        id: listProc
        command: ["cliphist", "list"]
        stdout: StdioCollector { id: listOut }
        onExited: code => {
            if (code !== 0) { win.entries = []; win.applyFilter(); return }
            var rows = []
            var lines = listOut.text.split("\n")
            for (var i = 0; i < lines.length; i++) {
                var line = lines[i]
                if (line === "") continue
                // cliphist emits "<id>\t<one-line preview>"; split on the
                // FIRST tab only, the preview may contain further tabs.
                var t = line.indexOf("\t")
                if (t < 0) continue
                var id = line.substring(0, t)
                if (!/^[0-9]+$/.test(id)) continue   // guard: id goes into a shell command
                var prev = line.substring(t + 1)
                rows.push({
                    id: id,
                    preview: prev,
                    image: prev.indexOf("binary data image/") === 0
                })
            }
            win.entries = rows
            win.applyFilter()
        }
    }

    function applyFilter() {
        var q = query.text.trim().toLowerCase()
        if (q === "") {
            filtered = entries
        } else {
            var out = []
            for (var i = 0; i < entries.length; i++)
                if (entries[i].preview.toLowerCase().indexOf(q) >= 0) out.push(entries[i])
            filtered = out
        }
        selection = 0
        list.positionViewAtBeginning()
    }

    function move(delta) {
        if (filtered.length === 0) return
        selection = (selection + delta + filtered.length) % filtered.length
        list.positionViewAtIndex(selection, ListView.Contain)
    }

    // ---- actions ----
    // `cliphist decode` takes the list line on STDIN, not as an argument --
    // a positional id fails with "input not prefixed with id". The id must
    // be tab-terminated, which is enough; no need to re-list every entry.
    function decodeCmd(id) { return "printf '" + id + "\\t' | cliphist decode" }

    function copyCurrent() {
        var e = win.current
        if (!e) return
        copyProc.command = ["sh", "-c", win.decodeCmd(e.id) + " | wl-copy"]
        copyProc.running = true
        win.close()
    }

    function deleteCurrent() {
        var e = win.current
        if (!e) return
        // `cliphist delete` reads the exact list line from stdin; re-select it
        // by anchored id rather than trying to re-escape the preview text.
        delProc.command = ["sh", "-c",
            "cliphist list | grep -m1 -P '^" + e.id + "\\t' | cliphist delete"]
        delProc.running = true
    }

    function wipeAll() {
        wipeProc.running = true
    }

    Process { id: copyProc }
    Process {
        id: delProc
        onExited: { win.flash("deleted"); win.reload() }
    }
    Process {
        id: wipeProc
        command: ["cliphist", "wipe"]
        onExited: { win.flash("history cleared"); win.reload() }
    }

    // ---- preview of the selected entry. Images decode to a temp file and
    // render as a thumbnail; text decodes to stdout so the pane can show the
    // FULL content, not just the one-line summary cliphist puts in `list`. ----
    property string previewPath: ""
    property string previewText: ""
    property bool previewTruncated: false

    // Debounced: holding j/k would otherwise spawn a decode per row.
    Timer {
        id: previewDebounce
        interval: 110
        onTriggered: win.refreshPreview()
    }

    function refreshPreview() {
        var e = win.current
        win.previewPath = ""
        win.previewText = ""
        win.previewTruncated = false
        if (!e) return
        if (e.image) {
            var p = "/tmp/qs-clip-preview-" + e.id
            imgProc.command = ["sh", "-c", win.decodeCmd(e.id) + " > " + p]
            imgProc.pendingPath = p
            imgProc.running = true
        } else {
            // cap it -- a clipboard entry can be megabytes and the pane only
            // ever shows a screenful
            txtProc.command = ["sh", "-c", win.decodeCmd(e.id) + " | head -c 20000"]
            txtProc.running = true
        }
    }

    Process {
        id: imgProc
        property string pendingPath: ""
        onExited: code => { win.previewPath = code === 0 ? pendingPath : "" }
    }

    Process {
        id: txtProc
        stdout: StdioCollector { id: txtOut }
        onExited: code => {
            if (code !== 0) { win.previewText = ""; return }
            win.previewText = txtOut.text
            win.previewTruncated = txtOut.text.length >= 20000
        }
    }

    onSelectionChanged: previewDebounce.restart()
    onFilteredChanged: previewDebounce.restart()

    function open() {
        win.visible = true
        query.text = ""
        win.confirmWipe = false
        win.flashMsg = ""
        win.previewPath = ""
        win.reload()
        query.forceActiveFocus()
    }

    function close() {
        win.visible = false
        query.text = ""
        win.confirmWipe = false
    }

    Rectangle {
        id: panelBg
        anchors.fill: parent
        radius: Theme.s(18)
        color: "#f20c0e11"
        border.width: 1
        border.color: "#1e2228"

        // ---- search ----
        Rectangle {
            id: searchBox
            anchors.top: parent.top; anchors.topMargin: Theme.s(16)
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            height: Theme.s(44)
            radius: Theme.s(10)
            color: Theme.surfaceAlt
            border.width: 1
            border.color: query.activeFocus ? Theme.accent : Theme.line

            Text {
                anchors.left: parent.left; anchors.leftMargin: Theme.s(14)
                anchors.verticalCenter: parent.verticalCenter
                visible: query.text.length === 0
                text: "Search clipboard history"
                font.pixelSize: Theme.s(14)
                color: Theme.muted
            }

            TextInput {
                id: query
                anchors.left: parent.left
                anchors.right: countLabel.left
                anchors.leftMargin: Theme.s(14)
                anchors.rightMargin: Theme.s(10)
                anchors.verticalCenter: parent.verticalCenter
                font.pixelSize: Theme.s(14)
                color: Theme.text
                selectionColor: Theme.accentDim
                clip: true
                onTextChanged: win.applyFilter()

                Keys.onPressed: event => {
                    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0

                    if (win.confirmWipe) {
                        if (event.text.toLowerCase() === "y") { win.wipeAll(); win.confirmWipe = false }
                        else win.confirmWipe = false
                        event.accepted = true
                        return
                    }

                    if (event.key === Qt.Key_Escape) {
                        win.close(); event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        win.copyCurrent(); event.accepted = true
                    } else if (event.key === Qt.Key_Down
                               || (ctrl && (event.key === Qt.Key_N || event.key === Qt.Key_J))) {
                        win.move(1); event.accepted = true
                    } else if (event.key === Qt.Key_Up
                               || (ctrl && (event.key === Qt.Key_P || event.key === Qt.Key_K))) {
                        win.move(-1); event.accepted = true
                    } else if (event.key === Qt.Key_PageDown) {
                        win.move(8); event.accepted = true
                    } else if (event.key === Qt.Key_PageUp) {
                        win.move(-8); event.accepted = true
                    } else if (ctrl && event.key === Qt.Key_D) {
                        win.deleteCurrent(); event.accepted = true
                    } else if (ctrl && event.key === Qt.Key_W) {
                        win.confirmWipe = true; event.accepted = true
                    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                        event.accepted = true
                    }
                }
            }

            Text {
                id: countLabel
                anchors.right: parent.right; anchors.rightMargin: Theme.s(14)
                anchors.verticalCenter: parent.verticalCenter
                text: win.filtered.length + " / " + win.entries.length
                font.family: Theme.mono
                font.pixelSize: Theme.s(11)
                color: Theme.muted
            }
        }

        // ---- history list (left pane) ----
        ListView {
            id: list
            anchors.top: searchBox.bottom; anchors.topMargin: Theme.s(10)
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.bottom: hintSep.top; anchors.bottomMargin: Theme.s(8)
            width: (parent.width - Theme.s(16) * 2 - Theme.s(10)) * win.listFrac - Theme.s(10)
            model: win.filtered
            currentIndex: win.selection
            clip: true
            spacing: Theme.s(2)
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
                required property var modelData
                required property int index

                width: list.width
                height: win.rowHeight
                radius: Theme.s(8)
                color: index === win.selection ? Theme.surfaceAlt : "transparent"
                border.width: index === win.selection ? 1 : 0
                border.color: Theme.accent

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: win.selection = index
                    onDoubleClicked: { win.selection = index; win.copyCurrent() }
                }

                Rectangle {
                    id: badge
                    anchors.left: parent.left; anchors.leftMargin: Theme.s(10)
                    anchors.verticalCenter: parent.verticalCenter
                    visible: modelData.image
                    width: Theme.s(38); height: Theme.s(18)
                    radius: Theme.s(4)
                    color: Theme.accentDim
                    Text {
                        anchors.centerIn: parent
                        text: "IMG"
                        font.family: Theme.mono
                        font.pixelSize: Theme.s(9)
                        font.bold: true
                        color: Theme.text
                    }
                }

                Text {
                    anchors.left: modelData.image ? badge.right : parent.left
                    anchors.leftMargin: Theme.s(10)
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.s(12)
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    text: modelData.image ? "image" : modelData.preview
                    font.family: Theme.mono
                    font.pixelSize: Theme.s(12)
                    color: index === win.selection ? Theme.text : Theme.dim
                }
            }
        }

        ScrollTrack {
            flick: list
            anchors.left: list.right; anchors.leftMargin: Theme.s(4)
            anchors.top: list.top
            anchors.bottom: list.bottom
        }

        Text {
            visible: win.filtered.length === 0
            anchors.centerIn: list
            width: list.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: win.entries.length === 0
                ? "clipboard history is empty"
                : "no matches for “" + query.text.trim() + "”"
            font.pixelSize: Theme.s(12)
            color: Theme.muted
        }

        // ---- preview (right pane), full height so images get real room ----
        Rectangle {
            id: preview
            anchors.top: list.top
            anchors.bottom: list.bottom
            anchors.left: list.right; anchors.leftMargin: Theme.s(18)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            radius: Theme.s(10)
            color: Theme.surface
            clip: true

            // image entries
            Image {
                id: previewImage
                visible: win.previewPath !== ""
                anchors.fill: parent
                anchors.margins: Theme.s(10)
                anchors.bottomMargin: Theme.s(28)
                source: win.previewPath !== "" ? "file://" + win.previewPath : ""
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                cache: false
            }

            Text {
                visible: previewImage.visible && previewImage.status === Image.Ready
                anchors.bottom: parent.bottom; anchors.bottomMargin: Theme.s(8)
                anchors.horizontalCenter: parent.horizontalCenter
                text: previewImage.sourceSize.width + " × " + previewImage.sourceSize.height
                font.family: Theme.mono
                font.pixelSize: Theme.s(10)
                color: Theme.muted
            }

            // text entries -- full content, scrollable
            Flickable {
                id: textFlick
                visible: win.previewText !== ""
                anchors.fill: parent
                anchors.margins: Theme.s(12)
                contentWidth: width
                contentHeight: previewLabel.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Text {
                    id: previewLabel
                    width: textFlick.width
                    text: win.previewText + (win.previewTruncated ? "\n\n… truncated" : "")
                    wrapMode: Text.Wrap
                    font.family: Theme.mono
                    font.pixelSize: Theme.s(11)
                    color: Theme.dim
                }
            }

            ScrollTrack {
                flick: textFlick
                visible: textFlick.visible && needed
                anchors.right: parent.right; anchors.rightMargin: Theme.s(4)
                anchors.top: parent.top; anchors.topMargin: Theme.s(10)
                anchors.bottom: parent.bottom; anchors.bottomMargin: Theme.s(10)
            }

            Text {
                visible: win.previewText === "" && win.previewPath === ""
                anchors.centerIn: parent
                text: win.current ? "loading…" : "nothing selected"
                font.pixelSize: Theme.s(12)
                color: Theme.muted
            }
        }

        // ---- footnote ----
        Rectangle {
            id: hintSep
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            anchors.bottom: hintBar.top; anchors.bottomMargin: Theme.s(10)
            height: 1
            color: Theme.line
        }

        Item {
            id: hintBar
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            anchors.bottom: parent.bottom; anchors.bottomMargin: Theme.s(14)
            height: Theme.s(18)

            Text {
                visible: win.confirmWipe
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                text: "wipe entire clipboard history?  y/n"
                font.pixelSize: Theme.s(13)
                color: Theme.warn
            }
            Text {
                visible: !win.confirmWipe && win.flashMsg !== ""
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                text: win.flashMsg
                font.pixelSize: Theme.s(13)
                color: Theme.accent
            }
            Text {
                visible: !win.confirmWipe && win.flashMsg === ""
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                text: "↑↓ or Ctrl+n/p move  ·  Enter copy  ·  Ctrl+d delete  ·  Ctrl+w wipe  ·  Esc close"
                font.pixelSize: Theme.s(12)
                color: Theme.dim
            }
        }
    }

    GlobalShortcut {
        appid: "quickshell"
        name: "toggle-clipboard"
        description: "Toggle clipboard history"
        onPressed: {
            if (win.visible) win.close()
            else win.open()
        }
    }

    HyprlandFocusGrab {
        active: win.visible
        windows: [win]
    }
}
