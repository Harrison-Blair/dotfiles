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

    // Reserve width for the widest value ("00.00G") so the widget — and thus the
    // whole centered bar — doesn't shift when used RAM crosses 10 GB.
    TextMetrics {
        id: memMetrics
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize
        text: "00.00G"
    }

    function parse(t) {
        function get(k) {
            const m = t.match(new RegExp("^" + k + ":\\s+(\\d+)", "m"))
            return m ? parseInt(m[1]) : 0   // kB
        }
        const total = get("MemTotal")
        const avail = get("MemAvailable")
        const swapT = get("SwapTotal")
        const swapF = get("SwapFree")
        const used = total - avail
        root.usedGb = used / 1048576
        root.totalGb = total / 1048576
        root.percent = total > 0 ? Math.round(used * 100 / total) : 0
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

    PopupMenu {
        id: menu
        anchorItem: root
        Text {
            text: "Memory:  " + root.usedGb.toFixed(2) + " / " + root.totalGb.toFixed(2)
                  + " GB  |  " + root.percent + "%"
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }
        Text {
            text: "Swap:    " + root.swapUsedGb.toFixed(2) + " / " + root.swapTotalGb.toFixed(2)
                  + " GB  |  " + root.swapPercent + "%"
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }
    }
}
