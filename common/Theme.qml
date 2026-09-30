pragma Singleton
import QtQuick

QtObject {
    // Nord (nordtheme.com) Polar Night: nord0 bg, nord1 elevated, nord2 selection, nord3 lines
    readonly property color bg: "#2e3440"
    readonly property color surface: "#3b4252"
    readonly property color surfaceAlt: "#434c5e"
    readonly property color line: "#4c566a"
    readonly property color text: "#eceff4"
    readonly property color dim: "#d8dee9"
    // between nord3 and nord4: secondary text that stays readable on bg (~5:1)
    readonly property color muted: "#a0a8b6"
    readonly property color accent: "#88c0d0"
    readonly property color accentDim: "#5e81ac"
    readonly property color ok: "#a3be8c"
    readonly property color warn: "#ebcb8b"
    readonly property color danger: "#bf616a"
    readonly property color info: "#81a1c1"

    readonly property string mono: Qt.fontFamilies().indexOf("JetBrainsMono Nerd Font Mono") !== -1
        ? "JetBrainsMono Nerd Font Mono" : "monospace"

    // Single scaling knob. Every font size / row height / margin / radius in
    // the widget routes through s(px). Change this one number (e.g. to 1.25)
    // to rescale the whole UI -- nothing else should need editing.
    readonly property real scale: 1.5
    function s(px) { return Math.round(px * scale) }
}
