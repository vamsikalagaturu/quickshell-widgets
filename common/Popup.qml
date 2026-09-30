import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland._GlobalShortcuts
import Quickshell.Hyprland._FocusGrab

// Focusable popup toggled by a global shortcut; widgets override open()/close() to reset their own state.
// No anchors: layer-shell centres it on the focused output; Normal exclusion centres it below waybar.
PanelWindow {
    id: popup

    required property string shortcut
    property string shortcutDescription

    visible: false
    color: "transparent"
    exclusionMode: ExclusionMode.Normal
    aboveWindows: true
    focusable: true

    function open() { visible = true }
    function close() { visible = false }

    GlobalShortcut {
        appid: "quickshell"
        name: popup.shortcut
        description: popup.shortcutDescription
        onPressed: popup.visible ? popup.close() : popup.open()
    }

    HyprlandFocusGrab {
        active: popup.visible
        windows: [popup]
    }
}
