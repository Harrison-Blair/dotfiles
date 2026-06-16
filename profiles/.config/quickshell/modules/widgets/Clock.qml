import QtQuick
import QtQuick.Layouts
import qs.services
import qs.components

// Two clocks (UTC + local), matching waybar's clock#utc / clock#local.
// Click opens a menu with the full date.
Item {
    id: root
    implicitWidth: row.implicitWidth
    implicitHeight: row.implicitHeight
    Layout.alignment: Qt.AlignVCenter

    property var now: new Date()
    Timer {
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.now = new Date()
    }

    function pad(n) { return n < 10 ? "0" + n : "" + n }
    function utcTime() {
        const d = root.now
        return "UTC " + pad(d.getUTCHours()) + ":" + pad(d.getUTCMinutes()) + ":" + pad(d.getUTCSeconds())
    }
    function localTime() {
        return "EST " + Qt.formatDateTime(root.now, "HH:mm:ss")
    }
    function utcDateStr() {
        const days = ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"]
        const months = ["January","February","March","April","May","June","July",
                        "August","September","October","November","December"]
        const d = root.now
        return days[d.getUTCDay()] + ", " + months[d.getUTCMonth()] + " " + d.getUTCDate() + ", " + d.getUTCFullYear()
    }

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 16
        Text {
            text: root.utcTime()
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }
        Text {
            text: root.localTime()
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
            text: Qt.formatDateTime(root.now, "dddd, MMMM d, yyyy")
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }
        Text {
            text: "UTC  " + root.utcDateStr()
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 1
            opacity: 0.8
        }
    }
}
