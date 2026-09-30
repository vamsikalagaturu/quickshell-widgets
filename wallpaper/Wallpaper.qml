import QtQuick
import Quickshell
import Quickshell.Io
import "../common"

// Wallpaper grid from ~/Pictures/wallpapers: type to filter, arrows move, Enter applies via swww, Ctrl+R picks one at random.
Popup {
    id: win
    shortcut: "toggle-wallpaper"
    shortcutDescription: "Select wallpaper"

    readonly property string dir: Quickshell.env("HOME") + "/Pictures/wallpapers"
    readonly property int columns: 4
    readonly property real cellW: Theme.s(200)
    readonly property real cellH: Theme.s(128)

    implicitWidth: columns * cellW + Theme.s(40)
    implicitHeight: Theme.s(600)

    property var files: []
    property string filterText: ""
    readonly property var shown: {
        var q = filterText.toLowerCase()
        return files.filter(f => !q || f.toLowerCase().indexOf(q) >= 0)
    }

    function open() {
        visible = true
        query.text = ""
        filterText = ""
        grid.currentIndex = 0
        lister.exec(["find", "-L", dir, "-type", "f", "-iregex", ".*\\.\\(jpe?g\\|png\\|webp\\|gif\\)$"])
        query.forceActiveFocus()
    }

    function apply(path) {
        if (!path) return
        setter.exec(["swww", "img", path, "--transition-type", "any", "--transition-fps", "60",
                     "--transition-duration", "2", "--transition-bezier", ".43,1.19,1,.4"])
        close()
    }

    function nameOf(path) { return path.substring(path.lastIndexOf("/") + 1) }

    Process {
        id: lister
        stdout: StdioCollector { id: listed }
        onExited: win.files = listed.text.split("\n").filter(l => l !== "").sort((a, b) => win.nameOf(a).localeCompare(win.nameOf(b)))
    }

    Process { id: setter }

    Card {
        id: panelBg
        anchors.fill: parent

        Rectangle {
            id: searchBox
            anchors.top: parent.top; anchors.topMargin: Theme.s(16)
            anchors.left: parent.left; anchors.leftMargin: Theme.s(16)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(16)
            height: Theme.s(40)
            radius: Theme.s(10)
            color: Theme.surface
            border.width: 1
            border.color: query.activeFocus ? Qt.alpha(Theme.accent, 0.6) : Theme.line

            Text {
                anchors.left: parent.left; anchors.leftMargin: Theme.s(14)
                anchors.verticalCenter: parent.verticalCenter
                visible: query.text.length === 0
                text: "type to filter wallpapers…"
                font.pixelSize: Theme.s(13)
                color: Theme.muted
            }

            TextInput {
                id: query
                anchors.left: parent.left; anchors.leftMargin: Theme.s(14)
                anchors.right: countLabel.left; anchors.rightMargin: Theme.s(10)
                anchors.verticalCenter: parent.verticalCenter
                font.pixelSize: Theme.s(13)
                color: Theme.text
                selectionColor: Theme.accentDim
                clip: true
                onTextChanged: { win.filterText = text; grid.currentIndex = 0 }
                Keys.onEscapePressed: win.close()
                Keys.onReturnPressed: win.apply(win.shown[grid.currentIndex])
                Keys.onEnterPressed: win.apply(win.shown[grid.currentIndex])
                Keys.onPressed: event => {
                    var n = win.shown.length
                    if (n === 0) return
                    var i = grid.currentIndex
                    if (event.key === Qt.Key_Right) i = Math.min(n - 1, i + 1)
                    else if (event.key === Qt.Key_Left) i = Math.max(0, i - 1)
                    else if (event.key === Qt.Key_Down) i = Math.min(n - 1, i + win.columns)
                    else if (event.key === Qt.Key_Up) i = Math.max(0, i - win.columns)
                    else if (event.key === Qt.Key_R && (event.modifiers & Qt.ControlModifier)) i = Math.floor(Math.random() * n)
                    else return
                    grid.currentIndex = i
                    event.accepted = true
                }
            }

            Text {
                id: countLabel
                anchors.right: parent.right; anchors.rightMargin: Theme.s(14)
                anchors.verticalCenter: parent.verticalCenter
                text: win.shown.length + " wallpapers"
                font.family: Theme.mono
                font.pixelSize: Theme.s(10)
                color: Theme.muted
            }
        }

        GridView {
            id: grid
            anchors.top: searchBox.bottom; anchors.topMargin: Theme.s(12)
            anchors.left: parent.left; anchors.leftMargin: Theme.s(20)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(20)
            anchors.bottom: nameLabel.top; anchors.bottomMargin: Theme.s(8)
            clip: true
            cellWidth: win.cellW
            cellHeight: win.cellH
            model: win.shown
            boundsBehavior: Flickable.StopAtBounds
            highlightFollowsCurrentItem: false

            delegate: Item {
                id: cell
                required property var modelData
                required property int index
                width: grid.cellWidth
                height: grid.cellHeight

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: Theme.s(5)
                    radius: Theme.s(8)
                    color: Theme.surface
                    border.width: cell.index === grid.currentIndex ? 2 : 0
                    border.color: Theme.accent

                    Image {
                        anchors.fill: parent
                        anchors.margins: cell.index === grid.currentIndex ? 2 : 0
                        source: "file://" + cell.modelData
                        sourceSize.width: Theme.s(200)
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: true
                        smooth: true
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: grid.currentIndex = cell.index
                        onDoubleClicked: win.apply(cell.modelData)
                    }
                }
            }
        }

        Text {
            id: nameLabel
            anchors.left: parent.left; anchors.leftMargin: Theme.s(20)
            anchors.right: parent.right; anchors.rightMargin: Theme.s(20)
            anchors.bottom: parent.bottom; anchors.bottomMargin: Theme.s(14)
            elide: Text.ElideMiddle
            text: (win.shown.length ? win.nameOf(win.shown[grid.currentIndex] || "") + "   ·   " : "")
                + "arrows move · Enter apply · Ctrl+R random · Esc close"
            font.pixelSize: Theme.s(10)
            color: Theme.muted
        }
    }
}
