import QtQuick

// Read-only text view with vim normal/visual motions, so a fragment of a
// clipboard entry can be selected and yanked with the keyboard.
//
// This is a deliberate subset of vim, not an emulator: motions, counts and
// the two visual modes. No registers, macros, ex commands, operators other
// than y, or text objects. Everything is computed against `text` plus
// TextEdit's positionAt()/positionToRectangle(), which is all QtQuick gives
// us for line geometry.
//
// Supported:
//   h j k l          char / line
//   w b e            word forward / back / end
//   0 ^ $            line start / first non-blank / line end
//   gg G             buffer start / end
//   { }              paragraph back / forward
//   Ctrl+d Ctrl+u    half page
//   v V              visual char / visual line
//   y                yank selection (in visual), or the whole line
//   Esc              leave visual, else exit()
//   <count> prefix   e.g. 5j, 3w
FocusScope {
    id: view

    property alias text: edit.text
    property color textColor: Theme.dim
    property int fontSize: Theme.s(11)

    // "" = normal, "char" = v, "line" = V
    property string visual: ""
    property int anchor: 0
    property int count: 0        // pending numeric prefix, 0 = none
    property bool pendingG: false

    // Our own cursor, deliberately NOT TextEdit.cursorPosition. Assigning
    // cursorPosition clears any selection, so driving motions through it
    // meant visual mode selected nothing at all. TextEdit.select() owns the
    // highlight; this owns where the next motion starts from.
    property int cursor: 0
    readonly property int cursorPos: view.cursor

    // Caret geometry. positionToRectangle() is a function, not a bindable
    // property, so this can't be a binding -- updateCaret() is called from
    // every motion and whenever the text or width changes.
    property real caretX: 0
    property real caretY: 0
    property real caretH: 0

    function updateCaret() {
        var r = edit.positionToRectangle(Math.max(0, Math.min(edit.length, view.cursor)))
        view.caretX = r.x
        view.caretY = r.y
        view.caretH = r.height
    }

    readonly property string modeLabel: visual === "char" ? "VISUAL"
        : visual === "line" ? "V-LINE" : "NORMAL"
    readonly property string selection: edit.selectedText

    signal yanked(string content)
    signal exited()

    function reset() {
        view.visual = ""
        view.count = 0
        view.pendingG = false
        view.cursor = 0
        edit.select(0, 0)
        edit.cursorPosition = 0
        flick.contentY = 0
        updateCaret()
    }

    function takeCount(def) {
        var c = view.count > 0 ? view.count : def
        view.count = 0
        return c
    }

    // ---- selection bookkeeping -------------------------------------------
    // In visual mode every motion re-derives the selection from the anchor,
    // so motions themselves never need to know about selecting.
    function applyMotion(pos) {
        pos = Math.max(0, Math.min(edit.length, pos))
        view.cursor = pos
        if (view.visual === "char") {
            // vim's charwise visual is INCLUSIVE of the char under the cursor
            if (pos >= view.anchor) edit.select(view.anchor, Math.min(edit.length, pos + 1))
            else edit.select(pos, Math.min(edit.length, view.anchor + 1))
        } else if (view.visual === "line") {
            var a = lineStart(view.anchor)
            var b = lineEnd(pos)
            if (pos < view.anchor) { a = lineStart(pos); b = lineEnd(view.anchor) }
            edit.select(a, b)
        } else {
            // normal mode: no selection, just move the caret
            edit.cursorPosition = pos
        }
        updateCaret()
        ensureCursorVisible()
    }

    function ensureCursorVisible() {
        var r = edit.positionToRectangle(view.cursor)
        if (r.y < flick.contentY)
            flick.contentY = Math.max(0, r.y)
        else if (r.y + r.height > flick.contentY + flick.height)
            flick.contentY = Math.min(Math.max(0, flick.contentHeight - flick.height),
                                      r.y + r.height - flick.height)
    }

    // ---- text helpers ------------------------------------------------------
    function lineStart(pos) {
        var i = view.text.lastIndexOf("\n", Math.max(0, pos - 1))
        return i < 0 ? 0 : i + 1
    }
    function lineEnd(pos) {
        var i = view.text.indexOf("\n", pos)
        return i < 0 ? view.text.length : i
    }
    function firstNonBlank(pos) {
        var s = lineStart(pos), e = lineEnd(pos), t = view.text
        var i = s
        while (i < e && /\s/.test(t.charAt(i))) i++
        return i
    }

    function isWordChar(c) { return /[A-Za-z0-9_]/.test(c) }
    function isSpace(c) { return /\s/.test(c) }

    function wordForward(pos) {
        var t = view.text, n = t.length, i = pos
        if (i >= n) return n
        if (isWordChar(t.charAt(i)))       while (i < n && isWordChar(t.charAt(i))) i++
        else if (!isSpace(t.charAt(i)))    while (i < n && !isWordChar(t.charAt(i)) && !isSpace(t.charAt(i))) i++
        while (i < n && isSpace(t.charAt(i))) i++
        return i
    }
    function wordBack(pos) {
        var t = view.text, i = pos - 1
        while (i >= 0 && isSpace(t.charAt(i))) i--
        if (i < 0) return 0
        if (isWordChar(t.charAt(i)))    while (i >= 0 && isWordChar(t.charAt(i))) i--
        else                            while (i >= 0 && !isWordChar(t.charAt(i)) && !isSpace(t.charAt(i))) i--
        return i + 1
    }
    function wordEnd(pos) {
        var t = view.text, n = t.length, i = pos + 1
        while (i < n && isSpace(t.charAt(i))) i++
        if (i >= n) return n
        if (isWordChar(t.charAt(i)))    while (i + 1 < n && isWordChar(t.charAt(i + 1))) i++
        else                            while (i + 1 < n && !isWordChar(t.charAt(i + 1)) && !isSpace(t.charAt(i + 1))) i++
        return i
    }

    function paragraphForward(pos) {
        var i = view.text.indexOf("\n\n", pos)
        return i < 0 ? view.text.length : i + 1
    }
    function paragraphBack(pos) {
        var i = view.text.lastIndexOf("\n\n", Math.max(0, pos - 2))
        return i < 0 ? 0 : i + 1
    }

    // vertical motion needs real line geometry -- wrapped lines mean text
    // offsets alone can't tell us where "one line down" lands
    function verticalMove(pos, lines) {
        var r = edit.positionToRectangle(pos)
        var y = r.y + (lines * r.height) + r.height / 2
        if (y < 0) return 0
        return edit.positionAt(r.x, y)
    }

    function yank() {
        var content
        if (view.visual !== "") content = edit.selectedText
        else content = view.text.substring(lineStart(view.cursor), lineEnd(view.cursor))
        if (content.length === 0) return
        view.yanked(content)
    }

    // ---- key handling ------------------------------------------------------
    function handleKey(event) {
        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
        var k = event.key
        var txt = event.text
        var cur = view.cursor

        if (k === Qt.Key_Escape) {
            if (view.visual !== "") { view.visual = ""; edit.select(cur, cur); edit.cursorPosition = cur }
            else view.exited()
            view.count = 0
            view.pendingG = false
            return true
        }

        if (ctrl && (k === Qt.Key_D || k === Qt.Key_U)) {
            var half = Math.max(1, Math.floor(flick.height / Math.max(1, edit.positionToRectangle(view.cursor).height) / 2))
            applyMotion(verticalMove(cur, k === Qt.Key_D ? half : -half))
            return true
        }
        if (ctrl) return false

        // numeric prefix; a leading 0 is the line-start motion, not a count
        if (txt >= "0" && txt <= "9" && !(txt === "0" && view.count === 0)) {
            view.count = view.count * 10 + parseInt(txt)
            return true
        }

        // gg needs two keystrokes
        if (view.pendingG) {
            view.pendingG = false
            if (txt === "g") { applyMotion(0); view.count = 0; return true }
            return true
        }

        switch (txt) {
        case "h": applyMotion(cur - takeCount(1)); return true
        case "l": applyMotion(cur + takeCount(1)); return true
        case "j": applyMotion(verticalMove(cur, takeCount(1))); return true
        case "k": applyMotion(verticalMove(cur, -takeCount(1))); return true
        case "w": { var n = takeCount(1), p = cur; for (var i = 0; i < n; i++) p = wordForward(p); applyMotion(p); return true }
        case "b": { var n2 = takeCount(1), p2 = cur; for (var j = 0; j < n2; j++) p2 = wordBack(p2); applyMotion(p2); return true }
        case "e": { var n3 = takeCount(1), p3 = cur; for (var m = 0; m < n3; m++) p3 = wordEnd(p3); applyMotion(p3); return true }
        case "0": applyMotion(lineStart(cur)); return true
        case "^": applyMotion(firstNonBlank(cur)); return true
        // vim's $ sits on the LAST CHARACTER of the line, not on the newline,
        // so an inclusive visual selection stops before the line break
        case "$": applyMotion(Math.max(lineStart(cur), lineEnd(cur) - 1)); return true
        case "{": applyMotion(paragraphBack(cur)); return true
        case "}": applyMotion(paragraphForward(cur)); return true
        case "G": {
            // G with a count is "go to line N"
            if (view.count > 0) {
                var want = view.count - 1, idx = 0, at = 0
                while (idx < want) { var nl = view.text.indexOf("\n", at); if (nl < 0) break; at = nl + 1; idx++ }
                view.count = 0
                applyMotion(at)
            } else applyMotion(edit.length)
            return true
        }
        case "g": view.pendingG = true; return true
        case "v":
            if (view.visual === "char") { view.visual = ""; edit.select(cur, cur); edit.cursorPosition = cur }
            else { view.visual = "char"; view.anchor = cur; applyMotion(cur) }
            return true
        case "V":
            if (view.visual === "line") { view.visual = ""; edit.select(cur, cur); edit.cursorPosition = cur }
            else { view.visual = "line"; view.anchor = cur; applyMotion(cur) }
            return true
        case "y": yank(); return true
        }
        return false
    }

    Keys.onPressed: event => { if (handleKey(event)) event.accepted = true }

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Item {
            id: content
            width: flick.width
            height: edit.implicitHeight

            // Block caret drawn BEHIND the text (declared first) so the
            // character under the cursor stays readable. TextEdit's own
            // cursorDelegate is no use here: `edit` never takes activeFocus
            // (the FocusScope does), and in visual mode its cursor sits
            // wherever select() left it rather than at the vim cursor.
            Rectangle {
                visible: view.activeFocus
                x: view.caretX
                y: view.caretY
                width: charWidth.advanceWidth > 0 ? charWidth.advanceWidth : Math.max(2, view.caretH * 0.5)
                height: view.caretH
                radius: 1
                color: Theme.accent
                opacity: view.visual !== "" ? 0.85 : 0.45
            }

            TextEdit {
                id: edit
                width: content.width
                readOnly: true
                selectByMouse: true
                persistentSelection: true
                activeFocusOnPress: false   // the router owns focus; clicks must not steal it
                cursorVisible: false        // we draw our own, at the vim cursor
                wrapMode: TextEdit.Wrap
                font.family: Theme.mono
                font.pixelSize: view.fontSize
                color: view.textColor
                selectionColor: Theme.accentDim
                selectedTextColor: Theme.text

                onTextChanged: Qt.callLater(view.updateCaret)
                onWidthChanged: Qt.callLater(view.updateCaret)
            }

            // monospace, so one glyph's advance is the block width
            TextMetrics {
                id: charWidth
                font: edit.font
                text: "M"
            }
        }
    }

    ScrollTrack {
        flick: flick
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
    }
}
