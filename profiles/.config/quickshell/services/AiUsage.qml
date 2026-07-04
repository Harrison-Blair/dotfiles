pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Shared AI-usage poller: one ai-usage.py process feeds every bar instance
// (one per monitor) instead of each widget polling on its own.
Singleton {
    id: root

    property var stats: null
    // Next run bypasses the script's API cache: set at startup and by refresh().
    property bool freshNext: true

    function refresh() {
        root.freshNext = true
        if (!proc.running) proc.running = true
    }

    Process {
        id: proc
        command: {
            const cmd = ["python3", Quickshell.env("HOME") + "/.config/quickshell/scripts/ai-usage.py"]
            if (root.freshNext) cmd.push("--fresh")
            return cmd
        }
        stdout: StdioCollector {
            onStreamFinished: {
                root.freshNext = false
                try { root.stats = JSON.parse(this.text) } catch (e) {}
            }
        }
    }
    Timer {
        interval: 60000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!proc.running) proc.running = true
    }
}
