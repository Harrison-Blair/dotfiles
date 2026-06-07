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
        }
        Text {
            text: root.usedGb.toFixed(2) + "G"
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: menu.visible = !menu.visible
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
        MenuButton {
            label: "Open htop"
            command: ["kitty", "-e", "htop"]
            onTriggered: menu.visible = false
        }
    }
}
