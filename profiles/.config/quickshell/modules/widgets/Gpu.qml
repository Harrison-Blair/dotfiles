import Quickshell
import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.services
import qs.components

// Discrete GPU usage (AMD Radeon RX 9070 XT). Mirrors the Cpu widget: the panel
// shows a block-glyph sparkline of overall GPU busy%; the hover tooltip breaks it
// down into clocks, VRAM, per-engine meters with trend sparklines, and the top
// GPU processes.
//
// Cheap always-on data comes from PCI-stable sysfs (busy% + VRAM). The richer
// per-engine / per-process breakdown comes from `amdgpu_top` and, like the CPU
// tooltip's `ps` poll, only runs while the tooltip is open.
Item {
    id: root
    implicitWidth: row.implicitWidth
    implicitHeight: Theme.groupHeight
    Layout.alignment: Qt.AlignVCenter

    // dGPU PCI slot — stable across card0/card1 renumbering (see Info.DevicePath.pci).
    readonly property string pci: "0000:03:00.0"
    readonly property string sysfs: "/sys/bus/pci/devices/" + pci

    property real busy: 0           // overall GPU busy fraction 0..1
    property var hist: []           // overall busy history ring buffer (0..1)
    property real vramUsed: 0       // MiB
    property real vramTotal: 0      // MiB
    property var engines: []        // [{label, val 0..1}] per-engine activity
    property var engHist: []        // per-engine history ring buffers
    property int sclk: 0            // GFX shader clock (MHz)
    property int mclk: 0            // memory clock (MHz)
    property var power: null        // GFX power (W) or null
    property var procs: []          // top GPU processes [{pct, comm}]

    readonly property real vramPct: vramTotal > 0 ? vramUsed / vramTotal : 0

    // Threshold color, reusing the waybar cpu levels (orange @87.5%, red @100%).
    function engColor(v) {
        return v >= 0.875 ? Theme.crit : (v >= 0.75 ? Theme.warn : Theme.fg)
    }

    // Render a 0..1 history buffer as block glyphs ▁▂▃▄▅▆▇█.
    function spark(buf) {
        if (!buf || buf.length === 0) return ""
        let s = ""
        for (const v of buf) s += Theme.cpuBlocks[Math.min(7, Math.floor(v * 8))]
        return s
    }

    // Panel bar: overall busy history as a fixed-width colored glyph strip.
    function barGlyphs() {
        const N = 10
        let buf = root.hist.slice(-N)
        while (buf.length < N) buf.unshift(0)
        let s = ""
        for (const v of buf) {
            const idx = Math.min(7, Math.floor(v * 8))
            const ch = Theme.cpuBlocks[idx]
            if (idx === 7) s += '<span style="color:' + Theme.crit + '">' + ch + '</span>'
            else if (idx === 6) s += '<span style="color:' + Theme.warn + '">' + ch + '</span>'
            else s += ch
        }
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

    function parseGpu(t) {
        let d
        try { d = JSON.parse(t) } catch (e) { return }
        if (!d.devices || d.devices.length === 0) return
        const dev = d.devices[0]
        const grbm = dev.GRBM || {}
        const grbm2 = dev.GRBM2 || {}
        function g(sec, k) { const o = sec[k]; return (o && o.value != null) ? o.value / 100 : 0 }

        // Curated engine breakdown (8 units, mirrors CPU per-core meters).
        const defs = [
            ["GFX",      grbm,  "Graphics Pipe"],
            ["Shader",   grbm,  "Shader Processor Interpolator"],
            ["Texture",  grbm,  "Texture Pipe"],
            ["Color",    grbm,  "Color Block"],
            ["Depth",    grbm,  "Depth Block"],
            ["Geometry", grbm,  "Geometry Engine"],
            ["Compute",  grbm2, "Command Processor -  Compute"],
            ["Copy",     grbm2, "SDMA"]
        ]
        const eng = defs.map(x => ({ label: x[0], val: g(x[1], x[2]) }))
        root.engines = eng

        const eh = root.engHist.slice()
        if (eh.length !== eng.length) {
            eh.length = 0
            for (let i = 0; i < eng.length; i++) eh.push([])
        }
        for (let i = 0; i < eng.length; i++)
            eh[i] = eh[i].concat(eng[i].val).slice(-10)
        root.engHist = eh

        const s = dev.Sensors || {}
        function sv(k) { const o = s[k]; return (o && o.value != null) ? o.value : null }
        root.sclk = sv("GFX_SCLK") || 0
        root.mclk = sv("GFX_MCLK") || 0
        root.power = sv("GFX Power")

        const fd = dev.fdinfo || {}
        const rows = []
        for (const pid in fd) {
            const u = (fd[pid].usage && fd[pid].usage.usage) || {}
            function pv(k) { const o = u[k]; return (o && o.value != null) ? o.value : 0 }
            rows.push({ pct: pv("GFX") + pv("Compute") + pv("Media"), comm: fd[pid].name, vram: pv("VRAM") })
        }
        rows.sort((a, b) => (b.pct - a.pct) || (b.vram - a.vram))
        root.procs = rows.slice(0, 6)
    }

    FileView {
        id: busyFile
        path: root.sysfs + "/gpu_busy_percent"
        onLoaded: {
            root.busy = (parseInt(text()) || 0) / 100
            root.hist = root.hist.concat(root.busy).slice(-24)
        }
    }
    FileView {
        id: vramUsedFile
        path: root.sysfs + "/mem_info_vram_used"
        onLoaded: root.vramUsed = (parseInt(text()) || 0) / 1048576
    }
    FileView {
        id: vramTotalFile
        path: root.sysfs + "/mem_info_vram_total"
        onLoaded: root.vramTotal = (parseInt(text()) || 0) / 1048576
    }
    Timer {
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: { busyFile.reload(); vramUsedFile.reload(); vramTotalFile.reload() }
    }

    // Per-engine + per-process breakdown: only poll amdgpu_top while the tooltip
    // is open (each run samples for ~1s, so a 1500ms interval never overlaps).
    Process {
        id: gpuProc
        command: ["amdgpu_top", "--pci", root.pci, "-J", "-n", "1"]
        stdout: StdioCollector {
            onStreamFinished: root.parseGpu(this.text)
        }
    }
    Timer {
        interval: 1500
        running: menu.visible
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!gpuProc.running) gpuProc.running = true
    }

    // Reserve width for the widest percentage ("100%") so engine rows stay aligned.
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
            text: Theme.icoSensDgpu
            Layout.leftMargin: 2
            Layout.rightMargin: 2
        }
        Text {
            textFormat: Text.RichText
            text: root.barGlyphs()
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: Quickshell.execDetached(["kitty", "-e", "amdgpu_top"])
        onEntered: menu.anchorHovered = true
        onExited: menu.anchorHovered = false
    }

    PopupMenu {
        id: menu
        anchorItem: root

        // --- Header: icon + title + overall busy % + model + sparkline ---
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Icon {
                text: Theme.icoSensDgpu
                color: Theme.fg
                size: Theme.iconSizeSmall
            }
            Text {
                text: "GPU"
                color: Theme.fg
                font.bold: true
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
            }
            Text {
                text: Math.round(root.busy * 100) + "%"
                color: root.engColor(root.busy)
                font.bold: true
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
            }
            Text {
                text: "· RX 9070 XT"
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

        // --- Clocks + power, units stacked under values (mirrors CPU load avg) ---
        RowLayout {
            spacing: 10
            Text {
                text: "Clocks"
                color: Theme.sep
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
            }
            Repeater {
                model: [
                    { v: root.sclk ? root.sclk : "—", u: "sclk" },
                    { v: root.mclk ? root.mclk : "—", u: "mclk" },
                    { v: root.power != null ? root.power + "W" : "—", u: "power" }
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

        // --- VRAM meter (GPU-specific, from cheap sysfs) ---
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Text {
                text: "VRAM"
                color: Theme.sep
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
            }
            Rectangle {
                Layout.fillWidth: true
                implicitWidth: 160
                implicitHeight: 8
                radius: 4
                color: Qt.rgba(1, 1, 1, 0.08)
                Rectangle {
                    width: parent.width * Math.max(0, Math.min(1, root.vramPct))
                    height: parent.height
                    radius: 4
                    color: root.engColor(root.vramPct)
                    Behavior on width { NumberAnimation { duration: 300 } }
                }
            }
            Text {
                text: Math.round(root.vramPct * 100) + "%"
                color: root.engColor(root.vramPct)
                horizontalAlignment: Text.AlignRight
                Layout.preferredWidth: pctMetrics.width
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
            }
            Text {
                text: (root.vramUsed / 1024).toFixed(1) + "/" + (root.vramTotal / 1024).toFixed(1) + "G"
                color: Theme.sep
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
            }
        }

        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.sep }

        // --- Per-engine meters: label · bar · % · trend sparkline ---
        Repeater {
            model: root.engines.length
            RowLayout {
                id: engRow
                required property int index
                readonly property var eng: root.engines[index]
                Layout.fillWidth: true
                spacing: 8

                Text {
                    text: engRow.eng.label
                    color: Theme.sep
                    Layout.preferredWidth: engLabelMetrics.width
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
                        width: parent.width * Math.max(0, Math.min(1, engRow.eng.val))
                        height: parent.height
                        radius: 4
                        color: root.engColor(engRow.eng.val)
                        Behavior on width { NumberAnimation { duration: 300 } }
                    }
                }
                Text {
                    text: Math.round(engRow.eng.val * 100) + "%"
                    color: root.engColor(engRow.eng.val)
                    horizontalAlignment: Text.AlignRight
                    Layout.preferredWidth: pctMetrics.width
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }
                Text {
                    text: root.spark(root.engHist[engRow.index])
                    color: Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }
            }
        }
        // Fixed label column width for the engine rows.
        TextMetrics {
            id: engLabelMetrics
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
            text: "Geometry"
        }
        Text {
            visible: root.engines.length === 0
            text: "sampling…"
            color: Theme.sep
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
        }

        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.sep }

        // --- Top GPU processes ---
        Text {
            text: "%GPU  COMMAND"
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
            label: "Open amdgpu_top"
            icon: Theme.icoSensDgpu
            command: ["kitty", "-e", "amdgpu_top"]
        }
    }
}
