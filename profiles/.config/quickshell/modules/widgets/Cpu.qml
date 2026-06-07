import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.services
import qs.components

// Per-core CPU load bars (waybar cpu). Reads /proc/stat each second and renders
// one block glyph per core; orange at >=87.5%, red at 100% (waybar thresholds).
Item {
    id: root
    implicitWidth: row.implicitWidth
    implicitHeight: Theme.groupHeight
    Layout.alignment: Qt.AlignVCenter

    property var cores: []          // per-core load fraction 0..1
    property var prevTotal: []
    property var prevIdle: []

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
        }
        root.prevTotal = total
        root.prevIdle = idle
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
    Timer {
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: stat.reload()
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
        onEntered: menu.anchorHovered = true
        onExited: menu.anchorHovered = false
    }

    PopupMenu {
        id: menu
        anchorItem: root
        Text {
            text: "CPU load — " + root.cores.length + " cores"
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }
        Text {
            text: {
                let s = ""
                for (let i = 0; i < root.cores.length; i++) {
                    const p = Math.round(root.cores[i] * 100)
                    s += "Core " + (i < 10 ? " " : "") + i + "   " + (p < 10 ? "  " : (p < 100 ? " " : "")) + p + "%"
                    if (i < root.cores.length - 1) s += "\n"
                }
                return s
            }
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
        }
        MenuButton {
            label: "Open htop"
            command: ["kitty", "-e", "htop"]
            onTriggered: menu.visible = false
        }
    }
}
