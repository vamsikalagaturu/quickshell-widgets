pragma Singleton
import QtQuick

// Duplicated from connectivity/Theme.qml -- see launcher/Theme.qml for why.

QtObject {
    readonly property color bg: "#0c0e11"
    readonly property color surface: "#14181d"
    readonly property color surfaceAlt: "#1a1f25"
    readonly property color line: "#242a31"
    readonly property color text: "#e6e6e6"
    readonly property color dim: "#8f949b"
    readonly property color muted: "#6f7378"
    readonly property color accent: "#57d5a8"
    readonly property color accentDim: "#2e7d5b"
    readonly property color warn: "#ffb454"
    readonly property color danger: "#ff6b6b"
    readonly property color info: "#5773c7"

    readonly property string mono: Qt.fontFamilies().indexOf("JetBrainsMono Nerd Font Mono") !== -1
        ? "JetBrainsMono Nerd Font Mono" : "monospace"

    // Single scaling knob. Every font size / row height / margin / radius in
    // the widget routes through s(px). Change this one number (e.g. to 1.25)
    // to rescale the whole UI -- nothing else should need editing.
    readonly property real scale: 1.5
    function s(px) { return Math.round(px * scale) }
}
