import Quickshell
import qs.modules

// Entry point. One bar per monitor (all screens).
ShellRoot {
    Variants {
        model: Quickshell.screens
        Bar {
            required property var modelData
            screen: modelData
        }
    }
}
