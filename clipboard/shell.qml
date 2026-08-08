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
// MODAL, vim-style. Three modes:
//
//   list     (default)  j/k move, l enter preview, / search, y copy entry,
//                       d delete, Esc close
//   search   ('/')      typing filters, Esc cancels, Enter accepts
//   preview  ('l')      vim normal/visual motions inside VimTextView;
//                       y yanks the selection, Esc returns to list
//
// Focus follows the mode: panelBg owns keys in list mode, the search
// TextInput only in search mode, VimTextView only in preview mode. Single-
// letter bindings are safe because the text field only holds focus while
// mode === "search".
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

    readonly property real listFrac: 0.44

    property var entries: []      // [{id, preview, image}]
    property var filtered: []
    property int selection: 0
    property bool confirmDelete: false
    property bool confirmWipe: false
    property string flashMsg: ""
    property string filterText: ""

    // "list" | "search" | "preview"
    property string mode: "list"

    readonly property int rowHeight: Theme.s(40)
    readonly property var current: filtered[selection] || null

    function flash(m) { win.flashMsg = m; flashTimer.restart() }
    Timer { id: flashTimer; interval: 1800; onTriggered: win.flashMsg = "" }

    // Hold the panel open briefly after a yank so the confirmation is
    // actually readable, instead of the window vanishing the same frame.
    Timer { id: closeTimer; interval: 1000; onTriggered: win.close() }

    function flashThenClose(m) {
        win.flashMsg = m
        flashTimer.stop()      // let the close, not the flash timeout, end it
        closeTimer.restart()
    }

    // ---- modes ----
    function enterList() {
        win.mode = "list"
        panelBg.forceActiveFocus()
    }

    function enterSearch() {
        win.mode = "search"
        query.forceActiveFocus()
    }

    function enterPreview() {
        if (win.previewText === "") { win.flash("nothing to select here"); return }
        win.mode = "preview"
        previewView.reset()
        previewView.forceActiveFocus()
    }

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
        var q = win.filterText.trim().toLowerCase()
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

    function jump(toLast) {
        if (filtered.length === 0) return
        selection = toLast ? filtered.length - 1 : 0
        list.positionViewAtIndex(selection, ListView.Contain)
    }

    // ---- actions ----
    //
    // `cliphist decode` takes the list line on STDIN, not as an argument --
    // a positional id fails with "input not prefixed with id". The id must
    // be tab-terminated, which is enough; no need to re-list every entry.
    function decodeCmd(id) { return "printf '" + id + "\\t' | cliphist decode" }

    function copyCurrent() {
        var e = win.current
        if (!e) return
        copyProc.command = ["sh", "-c", win.decodeCmd(e.id) + " | wl-copy"]
        copyProc.running = true
        win.flashThenClose(e.image ? "yanked image" : "yanked entry")
    }

    // Yank of a vim selection. Goes through Quickshell.clipboardText rather
    // than `sh -c "... | wl-copy"` on purpose: the text is arbitrary user
    // content and must never be interpolated into a shell command.
    function yankFragment(content) {
        if (!content || content.length === 0) { win.flash("nothing selected"); return }
        Quickshell.clipboardText = content
        var lines = content.split("\n").length
        win.flashThenClose("yanked " + content.length + " chars"
                           + (lines > 1 ? " · " + lines + " lines" : ""))
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

    function wipeAll() { wipeProc.running = true }

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

    // ---- preview of the selected entry ----
    property string previewPath: ""
    property string previewText: ""
    property bool previewTruncated: false

    // Debounced: holding j would otherwise spawn a decode per row.
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
            // don't strand the mode on a now-hidden text view
            if (win.mode === "preview") win.enterList()
            var p = "/tmp/qs-clip-preview-" + e.id
            imgProc.command = ["sh", "-c", win.decodeCmd(e.id) + " > " + p]
            imgProc.pendingPath = p
            imgProc.running = true
        } else {
            // cap it -- an entry can be megabytes, the pane shows a screenful
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
        win.filterText = ""
        query.text = ""
        win.confirmDelete = false
        win.confirmWipe = false
        win.flashMsg = ""
        win.previewPath = ""
        win.previewText = ""
        win.reload()
        win.enterList()
    }

    function close() {
        closeTimer.stop()      // Esc during the post-yank pause closes now
        win.visible = false
        win.filterText = ""
        query.text = ""
        win.confirmDelete = false
        win.confirmWipe = false
        win.flashMsg = ""
        win.mode = "list"
    }

    Rectangle {
        id: panelBg
        anchors.fill: parent
        radius: Theme.s(18)
        color: "#f20c0e11"
        border.width: 1
        border.color: "#1e2228"
        focus: true

        // ---- list-mode key router ----
        Keys.onPressed: event => {
            var txt = event.text
            var k = event.key

            if (win.confirmDelete || win.confirmWipe) {
                if (txt.toLowerCase() === "y") {
                    if (win.confirmDelete) win.deleteCurrent()
                    else win.wipeAll()
                } // anything else cancels
                win.confirmDelete = false
                win.confirmWipe = false
                event.accepted = true
                return
            }

            if (k === Qt.Key_Escape) { win.close(); event.accepted = true; return }

            if (txt === "j" || k === Qt.Key_Down) { win.move(1); event.accepted = true }
            else if (txt === "k" || k === Qt.Key_Up) { win.move(-1); event.accepted = true }
            else if (txt === "l" || k === Qt.Key_Right) { win.enterPreview(); event.accepted = true }
            else if (txt === "h" || k === Qt.Key_Left) { /* already leftmost */ event.accepted = true }
            else if (txt === "g") { win.jump(false); event.accepted = true }
            else if (txt === "G") { win.jump(true); event.accepted = true }
            else if (k === Qt.Key_PageDown) { win.move(8); event.accepted = true }
            else if (k === Qt.Key_PageUp) { win.move(-8); event.accepted = true }
            else if (txt === "/") { win.enterSearch(); event.accepted = true }
            else if (txt === "y" || k === Qt.Key_Return || k === Qt.Key_Enter) {
                win.copyCurrent(); event.accepted = true
            }
            else if (txt === "d") {
                if (win.current) win.confirmDelete = true
                event.accepted = true
            }
            else if (txt === "D") { win.confirmWipe = true; event.accepted = true }
        }

        // ---- search ----
        Rectangle {
            id: searchBox
            anchors.top: parent.top; anchors.topMargin: Theme.s(16)
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            height: Theme.s(44)
            radius: Theme.s(10)
            color: Theme.surfaceAlt
            border.width: win.mode === "search" ? 1 : 0
            border.color: Theme.accent

            Text {
                anchors.left: parent.left; anchors.leftMargin: Theme.s(14)
                anchors.verticalCenter: parent.verticalCenter
                visible: win.filterText.length === 0
                text: win.mode === "search" ? "type to filter…" : "press / to search"
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
                activeFocusOnTab: false
                onTextChanged: { win.filterText = text; win.applyFilter() }

                Keys.onPressed: event => {
                    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
                    if (event.key === Qt.Key_Escape) {
                        // cancel the search outright
                        query.text = ""
                        win.filterText = ""
                        win.applyFilter()
                        win.enterList()
                        event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        // keep the filter, hand keys back to list mode
                        win.enterList()
                        event.accepted = true
                    } else if (event.key === Qt.Key_Down
                               || (ctrl && (event.key === Qt.Key_N || event.key === Qt.Key_J))) {
                        win.move(1); event.accepted = true
                    } else if (event.key === Qt.Key_Up
                               || (ctrl && (event.key === Qt.Key_P || event.key === Qt.Key_K))) {
                        win.move(-1); event.accepted = true
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
                border.color: win.mode === "preview" ? Theme.line : Theme.accent

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
                : "no matches for “" + win.filterText.trim() + "”"
            font.pixelSize: Theme.s(12)
            color: Theme.muted
        }

        // ---- preview (right pane) ----
        Rectangle {
            id: preview
            anchors.top: list.top
            anchors.bottom: list.bottom
            anchors.left: list.right; anchors.leftMargin: Theme.s(18)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            radius: Theme.s(10)
            color: Theme.surface
            border.width: win.mode === "preview" ? 1 : 0
            border.color: Theme.accent
            clip: true

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

            // text entries -- full content with vim motions for selecting
            VimTextView {
                id: previewView
                visible: win.previewText !== ""
                anchors.fill: parent
                anchors.margins: Theme.s(12)
                focus: win.mode === "preview"
                textColor: win.mode === "preview" ? Theme.text : Theme.dim
                text: win.previewText + (win.previewTruncated ? "\n\n… truncated" : "")

                onYanked: content => win.yankFragment(content)
                onExited: win.enterList()
            }

            Rectangle {
                visible: win.mode === "preview"
                anchors.top: parent.top; anchors.topMargin: Theme.s(6)
                anchors.right: parent.right; anchors.rightMargin: Theme.s(8)
                width: modeText.implicitWidth + Theme.s(12)
                height: Theme.s(16)
                radius: Theme.s(4)
                color: previewView.visual !== "" ? Theme.accentDim : Theme.line

                Text {
                    id: modeText
                    anchors.centerIn: parent
                    text: previewView.modeLabel
                    font.family: Theme.mono
                    font.pixelSize: Theme.s(9)
                    font.bold: true
                    color: Theme.text
                }
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
                visible: win.confirmDelete || win.confirmWipe
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                text: win.confirmWipe ? "wipe entire clipboard history?  y/n"
                                      : "delete this entry?  y/n"
                font.pixelSize: Theme.s(13)
                color: Theme.warn
            }
            Text {
                visible: !win.confirmDelete && !win.confirmWipe && win.flashMsg !== ""
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                text: win.flashMsg
                font.pixelSize: Theme.s(13)
                color: Theme.accent
            }
            Text {
                visible: !win.confirmDelete && !win.confirmWipe && win.flashMsg === ""
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                font.pixelSize: Theme.s(12)
                color: Theme.dim
                text: win.mode === "preview"
                    ? "h j k l  w b e  0 ^ $  gg G  { }  ·  v / V visual  ·  y yank  ·  Esc back"
                    : win.mode === "search"
                    ? "type to filter  ·  ↑↓ move  ·  Enter accept  ·  Esc cancel search"
                    : "j/k move  ·  l preview  ·  / search  ·  y copy  ·  d delete  ·  D wipe  ·  Esc close"
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
