import Quickshell
import QtQuick
import QtQuick.Layouts
import qs.services
import qs.components

// Discrete GPU usage. Mirrors the Cpu widget: the panel shows a block-glyph
// sparkline of overall GPU busy%; the hover tooltip breaks it down into clocks,
// VRAM, per-domain meters with trend sparklines, and the top GPU processes.
//
// All data (and the vendor/slot detection + battery-friendly suspend gating)
// lives in the shared GpuInfo singleton — this file is just the view. On NVIDIA
// the meters are the four utilization domains (GPU/Memory/Encoder/Decoder); on
// amdgpu they are the eight GRBM engines. The widget hides on machines with no
// discrete GPU.
Item {
    id: root
    visible: GpuInfo.present
    implicitWidth: row.implicitWidth
    implicitHeight: Theme.groupHeight
    Layout.alignment: Qt.AlignVCenter

    // Feed the singleton's expensive per-process poll only while hovering.
    Binding { target: GpuInfo; property: "detailWanted"; value: menu.visible }

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
        let buf = GpuInfo.hist.slice(-N)
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
        const procs = GpuInfo.procs
        let s = ""
        for (let i = 0; i < procs.length; i++) {
            s += pad(Math.round(procs[i].pct), 3) + "%  " + procs[i].comm
            if (i < procs.length - 1) s += "\n"
        }
        return s
    }

    readonly property real vramPct: GpuInfo.vramTotal > 0 ? GpuInfo.vramUsed / GpuInfo.vramTotal : 0

    // Launch target: amdgpu_top on AMD, nvidia-smi live loop on NVIDIA (nvtop
    // isn't a guaranteed dependency).
    readonly property var launchCmd: GpuInfo.vendor === "amd"
        ? ["kitty", "-e", "amdgpu_top"]
        : ["kitty", "-e", "nvidia-smi", "-l", "1"]

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
            opacity: GpuInfo.suspended ? 0.4 : 1.0
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: Quickshell.execDetached(root.launchCmd)
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
                text: GpuInfo.suspended ? "suspended" : (Math.round(GpuInfo.busy * 100) + "%")
                color: GpuInfo.suspended ? Theme.sep : root.engColor(GpuInfo.busy)
                font.bold: true
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
            }
            Text {
                text: "· " + GpuInfo.name
                color: Theme.sep
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
            }
            Item { Layout.fillWidth: true }             // push sparkline to the right
            Text {
                text: root.spark(GpuInfo.hist)
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
                    { v: GpuInfo.sclk ? GpuInfo.sclk : "—", u: "sclk" },
                    { v: GpuInfo.mclk ? GpuInfo.mclk : "—", u: "mclk" },
                    { v: GpuInfo.power != null ? GpuInfo.power + "W" : "—", u: "power" }
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

        // --- VRAM meter (GPU-specific, from cheap sysfs / nvidia-smi) ---
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
                text: (GpuInfo.vramUsed / 1024).toFixed(1) + "/" + (GpuInfo.vramTotal / 1024).toFixed(1) + "G"
                color: Theme.sep
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
            }
        }

        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.sep }

        // --- Per-engine / per-domain meters: label · bar · % · trend sparkline ---
        Repeater {
            model: GpuInfo.engines.length
            RowLayout {
                id: engRow
                required property int index
                readonly property var eng: GpuInfo.engines[index]
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
                    text: root.spark(GpuInfo.engHist[engRow.index])
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
            visible: GpuInfo.engines.length === 0
            text: GpuInfo.suspended ? "suspended (idle)" : "sampling…"
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
            visible: GpuInfo.procs.length > 0
            text: root.procRows()
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
        }

        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.sep }

        MenuButton {
            label: GpuInfo.vendor === "amd" ? "Open amdgpu_top" : "Open nvidia-smi"
            icon: Theme.icoSensDgpu
            command: root.launchCmd
        }
    }
}
