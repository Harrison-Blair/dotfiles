import Quickshell
import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.services
import qs.components

// RAM usage (waybar memory). Reads /proc/meminfo each second.
Item {
    id: root
    implicitWidth: row.implicitWidth
    implicitHeight: Theme.groupHeight
    Layout.alignment: Qt.AlignVCenter

    property real usedGb: 0
    property real totalGb: 0
    property int percent: 0
    property real swapUsedGb: 0
    property real swapTotalGb: 0
    property int swapPercent: 0
    // Tooltip breakdown (GiB). appsGb + cacheGb + sharedGb + freeGb ≈ totalGb;
    // the small remainder (Unevictable etc.) is absorbed by the bar track.
    property real appsGb: 0
    property real cacheGb: 0
    property real sharedGb: 0
    property real freeGb: 0
    property real availGb: 0
    // [{name, gb}] top programs by RSS, aggregated per command name.
    property var topProcs: []

    // Tooltip palette (harmonizes with Theme's pink/dark scheme).
    readonly property color appsColor: root.percent >= 90 ? Theme.crit
                                     : root.percent >= 80 ? Theme.warn : Theme.fg
    readonly property color sharedColor: "#c9a6ff"
    readonly property color cacheColor: Qt.alpha(Theme.accent, 0.55)
    readonly property color trackColor: Qt.rgba(1, 1, 1, 0.09)
    readonly property color dimFg: Qt.rgba(1, 1, 1, 0.75)
    readonly property color faintFg: Qt.rgba(1, 1, 1, 0.5)

    // Reserve width for the widest value ("00.00G") so the widget — and thus the
    // whole centered bar — doesn't shift when used RAM crosses 10 GB.
    TextMetrics {
        id: memMetrics
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize
        text: "00.00G"
    }
    // Fixed tooltip columns so rows never jitter as values change.
    TextMetrics {
        id: valMetrics
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 2
        text: "00.00 G"
    }
    TextMetrics {
        id: pctMetrics
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 2
        text: "100 %"
    }

    function parse(t) {
        function get(k) {
            const m = t.match(new RegExp("^" + k + ":\\s+(\\d+)", "m"))
            return m ? parseInt(m[1]) : 0   // kB
        }
        const total = get("MemTotal")
        const avail = get("MemAvailable")
        const free = get("MemFree")
        const buffers = get("Buffers")
        const cached = get("Cached")
        const sreclaim = get("SReclaimable")
        const shmem = get("Shmem")
        const swapT = get("SwapTotal")
        const swapF = get("SwapFree")
        const used = total - avail
        root.usedGb = used / 1048576
        root.totalGb = total / 1048576
        root.percent = total > 0 ? Math.round(used * 100 / total) : 0
        root.appsGb = (total - free - buffers - cached - sreclaim) / 1048576
        root.cacheGb = (buffers + cached + sreclaim - shmem) / 1048576
        root.sharedGb = shmem / 1048576
        root.freeGb = free / 1048576
        root.availGb = avail / 1048576
        root.swapUsedGb = (swapT - swapF) / 1048576
        root.swapTotalGb = swapT / 1048576
        root.swapPercent = swapT > 0 ? Math.round((swapT - swapF) * 100 / swapT) : 0
    }

    FileView {
        id: meminfo
        path: "/proc/meminfo"
        onLoaded: root.parse(text())
    }
    Timer {
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: meminfo.reload()
    }

    // Top programs by RSS, aggregated per command name so multi-process apps
    // (browsers, electron) show as one row. Only polled while the popup is open.
    Process {
        id: psProc
        command: ["sh", "-c",
            "ps axo rss=,comm= | awk '{a[$2]+=$1} END {for (k in a) printf \"%d %s\\n\", a[k], k}' | sort -rn | head -10"]
        stdout: StdioCollector {
            onStreamFinished: {
                const procs = []
                for (const line of this.text.split("\n")) {
                    const m = line.match(/^(\d+)\s+(.+)$/)
                    if (m) procs.push({ name: m[2], gb: parseInt(m[1]) / 1048576 })
                }
                if (procs.length > 0) root.topProcs = procs
            }
        }
    }
    Timer {
        interval: 2000
        running: menu.visible
        repeat: true
        triggeredOnStart: true
        onTriggered: psProc.running = true
    }

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 6
        Icon {
            text: Theme.icoMem
            Layout.leftMargin: 2
            Layout.rightMargin: 2
        }
        // Fixed-width box so the label ("6.42G" → "12.34G") never changes the
        // module's width. RowLayout honors this Item's implicitWidth.
        Item {
            implicitWidth: memMetrics.width
            implicitHeight: memText.implicitHeight
            Layout.alignment: Qt.AlignVCenter
            Text {
                id: memText
                anchors.fill: parent
                text: root.usedGb.toFixed(2) + "G"
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
                horizontalAlignment: Text.AlignRight
                verticalAlignment: Text.AlignVCenter
            }
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

    // Section header: pink label left, dimmed total right.
    component SectionHeader: RowLayout {
        property string label
        property string detail
        Layout.preferredWidth: 290
        Layout.fillWidth: true
        Text {
            text: parent.label
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }
        Item { Layout.fillWidth: true }
        Text {
            text: parent.detail
            color: root.dimFg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
        }
    }

    // Legend row: color dot, label, right-aligned value + percent columns.
    component LegendRow: RowLayout {
        property string label
        property real gb
        property real ofTotal: 0
        property color dotColor: "transparent"
        property bool dot: true
        property color textColor: root.dimFg
        Layout.fillWidth: true
        spacing: 8
        Rectangle {
            implicitWidth: 8
            implicitHeight: 8
            radius: 4
            color: parent.dotColor
            opacity: parent.dot ? 1 : 0
        }
        Text {
            text: parent.label
            color: parent.textColor
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
        }
        Item { Layout.fillWidth: true }
        Text {
            Layout.preferredWidth: valMetrics.width
            text: parent.gb.toFixed(2) + " G"
            color: parent.textColor
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
            horizontalAlignment: Text.AlignRight
        }
        Text {
            Layout.preferredWidth: pctMetrics.width
            text: (parent.ofTotal > 0 ? Math.round(parent.gb * 100 / parent.ofTotal) : 0) + " %"
            color: parent.textColor
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
            horizontalAlignment: Text.AlignRight
        }
    }

    component Separator: Rectangle {
        Layout.fillWidth: true
        Layout.topMargin: 4
        Layout.bottomMargin: 4
        implicitHeight: 1
        color: Qt.alpha(Theme.sep, 0.35)
    }

    PopupMenu {
        id: menu
        anchorItem: root

        SectionHeader { label: "Memory"; detail: root.totalGb.toFixed(1) + " GiB" }

        // Segmented usage bar: in use / shared / cache; remainder (free) is track.
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 8
            radius: 4
            color: root.trackColor
            clip: true
            Row {
                anchors.fill: parent
                Rectangle {
                    width: root.totalGb > 0 ? parent.width * root.appsGb / root.totalGb : 0
                    height: parent.height
                    color: root.appsColor
                }
                Rectangle {
                    width: root.totalGb > 0 ? parent.width * root.sharedGb / root.totalGb : 0
                    height: parent.height
                    color: root.sharedColor
                }
                Rectangle {
                    width: root.totalGb > 0 ? parent.width * root.cacheGb / root.totalGb : 0
                    height: parent.height
                    color: root.cacheColor
                }
            }
        }

        LegendRow { label: "In use"; gb: root.appsGb; ofTotal: root.totalGb; dotColor: root.appsColor }
        LegendRow { label: "Cache"; gb: root.cacheGb; ofTotal: root.totalGb; dotColor: root.cacheColor }
        LegendRow { label: "Shared"; gb: root.sharedGb; ofTotal: root.totalGb; dotColor: root.sharedColor }
        LegendRow { label: "Free"; gb: root.freeGb; ofTotal: root.totalGb; dotColor: root.trackColor }
        LegendRow { label: "Available"; gb: root.availGb; ofTotal: root.totalGb; dot: false; textColor: root.faintFg }

        Separator { visible: root.swapTotalGb > 0 }

        SectionHeader {
            visible: root.swapTotalGb > 0
            label: "Swap"
            detail: root.swapTotalGb.toFixed(1) + " GiB"
        }
        Rectangle {
            visible: root.swapTotalGb > 0
            Layout.fillWidth: true
            implicitHeight: 8
            radius: 4
            color: root.trackColor
            clip: true
            Rectangle {
                width: root.swapTotalGb > 0 ? parent.width * root.swapUsedGb / root.swapTotalGb : 0
                height: parent.height
                color: root.swapPercent >= 80 ? Theme.crit
                     : root.swapPercent >= 50 ? Theme.warn : Theme.fg
            }
        }
        LegendRow {
            visible: root.swapTotalGb > 0
            label: "Used"
            gb: root.swapUsedGb
            ofTotal: root.swapTotalGb
            dotColor: root.swapPercent >= 80 ? Theme.crit
                    : root.swapPercent >= 50 ? Theme.warn : Theme.fg
        }

        Separator { visible: root.topProcs.length > 0 }

        Text {
            visible: root.topProcs.length > 0
            text: "Top programs"
            color: root.dimFg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
        }
        Repeater {
            model: root.topProcs
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Text {
                    Layout.fillWidth: true
                    text: modelData.name
                    elide: Text.ElideRight
                    color: root.dimFg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }
                Text {
                    Layout.preferredWidth: valMetrics.width
                    text: modelData.gb.toFixed(2) + " G"
                    color: root.dimFg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                    horizontalAlignment: Text.AlignRight
                }
            }
        }
    }
}
