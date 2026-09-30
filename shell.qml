import Quickshell
import "usage" as Usage
import "launcher" as Launcher
import "clipboard" as Clipboard
import "connectivity" as Connectivity
import "github" as Github
import "powermenu" as Powermenu
import "volume" as Volume
import "osd" as Osd
import "ports" as Ports
import "calendar" as Calendar
import "keybinds" as Keybinds
import "calc" as Calc
import "wallpaper" as Wallpaper

// All widgets in one quickshell process: one QML engine instead of one per widget.
// Each folder still runs alone for testing: quickshell -p <folder>
ShellRoot {
    Usage.Usage {}
    Launcher.Launcher {}
    Clipboard.Clipboard {}
    Connectivity.Connectivity {}
    Github.Github {}
    Powermenu.Powermenu {}
    Volume.Volume {}
    Osd.Osd {}
    Ports.Ports {}
    Calendar.Calendar {}
    Keybinds.Keybinds {}
    Calc.Calc {}
    Wallpaper.Wallpaper {}
}
