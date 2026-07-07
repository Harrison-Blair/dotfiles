import Quickshell
import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.services
import qs.components

// Per-core CPU load bars (waybar cpu). Reads /proc/stat each second and renders
// one block glyph per core; orange at >=87.5%, red at 100% (waybar thresholds).
// Hover tooltip: overall summary + sparkline, load average, per-core meters with
// per-core trend sparklines, and a top-process table.
Item {
    id: root
    implicitWidth: row.implicitWidth
    implicitHeight: Theme.groupHeight
    Layout.alignment: Qt.AlignVCenter

    property var cores: []          // per-core load fraction 0..1
    property var prevTotal: []
    property var prevIdle: []

    property real overall: 0        // mean busy fraction 0..1
    property var hist: []           // overall history ring buffer (0..1)
    property var coreHist: []       // per-core history ring buffers (array of arrays)
    property var load: []           // /proc/loadavg 1m/5m/15m as strings
    property var procs: []          // top processes [{pct, comm}]

    function parse(t) {
        const lines = t.split("\n")
        const total = []
        const idle = []
        for (const line of lines) {
            if (!/^cpu[0-9]+ /.test(line)) continue
            const nums = line.trim().split(/\s+/).slice(1).map(Number)
            idle.push(nums[3] + (nums[4] || 0))            // idle + iowait
            total.push(nums.reduce((a, b) => a + b, 0))
        }
        if (root.prevTotal.length === total.length && total.length > 0) {
            const out = []
            for (let c = 0; c < total.length; c++) {
                const dt = total[c] - root.prevTotal[c]
                const di = idle[c] - root.prevIdle[c]
                out.push(dt > 0 ? (dt - di) / dt : 0)
            }
            root.cores = out

            // Aggregate + history buffers (reassigned so bindings refresh).
            root.overall = out.reduce((a, b) => a + b, 0) / out.length
            root.hist = root.hist.concat(root.overall).slice(-24)

            const ch = root.coreHist.slice()
            if (ch.length !== out.length) {
                ch.length = 0
                for (let i = 0; i < out.length; i++) ch.push([])
            }
            for (let i = 0; i < out.length; i++)
                ch[i] = ch[i].concat(out[i]).slice(-10)
            root.coreHist = ch
        }
        root.prevTotal = total
        root.prevIdle = idle
    }

    function parseProcs(t) {
        const lines = t.trim().split("\n")
        const out = []
        for (let i = 1; i < lines.length; i++) {           // skip ps header row
            const m = lines[i].trim().match(/^([\d.]+)\s+(.+)$/)
            if (m) out.push({ pct: parseFloat(m[1]), comm: m[2] })
        }
        root.procs = out
    }

    // Threshold color, reusing the waybar cpu levels (orange @87.5%, red @100%).
    function coreColor(v) {
        return v >= 0.875 ? Theme.crit : (v >= 0.75 ? Theme.warn : Theme.fg)
    }

    // Render a 0..1 history buffer as block glyphs ▁▂▃▄▅▆▇█.
    function spark(buf) {
        if (!buf || buf.length === 0) return ""
        let s = ""
        for (const v of buf) s += Theme.cpuBlocks[Math.min(7, Math.floor(v * 8))]
        return s
    }

    // Right-aligned monospace process table body.
    function procRows() {
        function pad(s, n) { s = String(s); return " ".repeat(Math.max(0, n - s.length)) + s }
        let s = ""
        for (let i = 0; i < root.procs.length; i++) {
            s += pad(Math.round(root.procs[i].pct), 3) + "%  " + root.procs[i].comm
            if (i < root.procs.length - 1) s += "\n"
        }
        return s
    }

    // Build rich-text block string with per-core color for the hot levels.
    function glyphs() {
        let s = ""
        for (const load of root.cores) {
            const idx = Math.min(7, Math.floor(load * 8))
            const ch = Theme.cpuBlocks[idx]
            if (idx === 7) s += '<span style="color:' + Theme.crit + '">' + ch + '</span>'
            else if (idx === 6) s += '<span style="color:' + Theme.warn + '">' + ch + '</span>'
            else s += ch
        }
        return s
    }

    FileView {
        id: stat
        path: "/proc/stat"
        onLoaded: root.parse(text())
    }
    FileView {
        id: loadavg
        path: "/proc/loadavg"
        onLoaded: root.load = text().trim().split(/\s+/).slice(0, 3)
    }
    Timer {
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: { stat.reload(); loadavg.reload() }
    }

    // Top processes: only poll `ps` while the tooltip is open.
    Process {
        id: psProc
        command: ["sh", "-c", "ps -eo pcpu,comm --sort=-pcpu | head -n 7"]
        stdout: StdioCollector {
            onStreamFinished: root.parseProcs(this.text)
        }
    }
    Timer {
        interval: 2000
        running: menu.visible
        repeat: true
        triggeredOnStart: true
        onTriggered: psProc.running = true
    }

    // Reserve width for the widest percentage ("100%") so core rows stay aligned.
    TextMetrics {
        id: pctMetrics
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 2
        text: "100%"
    }

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 6
        Icon {
            text: Theme.icoCpu
            Layout.leftMargin: 2
            Layout.rightMargin: 2
        }
        Text {
            textFormat: Text.RichText
            text: root.glyphs()
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: Quickshell.execDetached(["kitty", "-e", "btop"])
        onEntered: menu.anchorHovered = true
        onExited: menu.anchorHovered = false
    }

    PopupMenu {
        id: menu
        anchorItem: root

        // --- Header: icon + title + overall % + core count + sparkline ---
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Icon {
                text: Theme.icoCpu
                color: Theme.fg
                size: Theme.iconSizeSmall
            }
            Text {
                text: "CPU"
                color: Theme.fg
                font.bold: true
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
            }
            Text {
                text: Math.round(root.overall * 100) + "%"
                color: root.coreColor(root.overall)
                font.bold: true
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
            }
            Text {
                text: "· " + root.cores.length + " cores"
                color: Theme.sep
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
            }
            Item { Layout.fillWidth: true }             // push sparkline to the right
            Text {
                text: root.spark(root.hist)
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
            }
        }

        // --- Load average, units stacked under values ---
        RowLayout {
            spacing: 10
            Text {
                text: "Load"
                color: Theme.sep
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
            }
            Repeater {
                model: [
                    { v: root.load[0] || "—", u: "1m" },
                    { v: root.load[1] || "—", u: "5m" },
                    { v: root.load[2] || "—", u: "15m" }
                ]
                ColumnLayout {
                    required property var modelData
                    spacing: 0
                    Text {
                        text: modelData.v
                        color: Theme.fg
                        horizontalAlignment: Text.AlignHCenter
                        Layout.alignment: Qt.AlignHCenter
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                    }
                    Text {
                        text: modelData.u
                        color: Theme.sep
                        horizontalAlignment: Text.AlignHCenter
                        Layout.alignment: Qt.AlignHCenter
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 4
                    }
                }
            }
        }

        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.sep }

        // --- Per-core meters: label · bar · % · trend sparkline ---
        Repeater {
            model: root.cores.length
            RowLayout {
                id: coreRow
                required property int index
                readonly property real val: root.cores[index] || 0
                Layout.fillWidth: true
                spacing: 8

                Text {
                    text: "Core " + (coreRow.index < 10 ? "0" : "") + coreRow.index
                    color: Theme.sep
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }
                Rectangle {                             // track
                    Layout.fillWidth: true
                    implicitWidth: 160
                    implicitHeight: 8
                    radius: 4
                    color: Qt.rgba(1, 1, 1, 0.08)
                    Rectangle {                         // fill
                        width: parent.width * Math.max(0, Math.min(1, coreRow.val))
                        height: parent.height
                        radius: 4
                        color: root.coreColor(coreRow.val)
                        Behavior on width { NumberAnimation { duration: 300 } }
                    }
                }
                Text {
                    text: Math.round(coreRow.val * 100) + "%"
                    color: root.coreColor(coreRow.val)
                    horizontalAlignment: Text.AlignRight
                    Layout.preferredWidth: pctMetrics.width
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }
                Text {
                    text: root.spark(root.coreHist[coreRow.index])
                    color: Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }
            }
        }

        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.sep }

        // --- Top processes by CPU ---
        Text {
            text: "%CPU  COMMAND"
            color: Theme.sep
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
        }
        Text {
            visible: root.procs.length > 0
            text: root.procRows()
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
        }

        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.sep }

        MenuButton {
            label: "Open btop"
            icon: Theme.icoCpu
            command: ["kitty", "-e", "btop"]
        }
    }
}
