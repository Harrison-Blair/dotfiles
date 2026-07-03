pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Shared AI-usage poller: one ai-usage.py process feeds every bar instance
// (one per monitor) instead of each widget polling on its own.
Singleton {
    id: root

    property var stats: null

    Process {
        id: proc
        command: ["python3", Quickshell.env("HOME") + "/.config/quickshell/scripts/ai-usage.py"]
        stdout: StdioCollector {
            onStreamFinished: {
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
