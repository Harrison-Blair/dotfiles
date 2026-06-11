import Quickshell
import qs.modules
import qs.services

// Entry point. One bar per monitor (all screens).
ShellRoot {
    // Force the Lock singleton to load at startup so its "lock" IPC handler
    // registers (it holds the WlSessionLock + PAM auth; engaged by the power
    // menu or `qs ipc call lock lock`).
    readonly property var _lock: Lock

    Variants {
        model: Quickshell.screens
        Bar {
            required property var modelData
            screen: modelData
        }
    }
}
