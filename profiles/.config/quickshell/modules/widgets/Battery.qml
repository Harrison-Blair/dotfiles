import Quickshell.Services.UPower
import QtQuick
import QtQuick.Layouts
import qs.services
import qs.components

// Battery (waybar custom/battery). Hidden entirely on machines with no battery
// (the desktop), replacing the script's class="empty" collapse trick.
Item {
    id: root
    implicitWidth: row.implicitWidth
    implicitHeight: Theme.groupHeight
    Layout.alignment: Qt.AlignVCenter

    readonly property var dev: UPower.displayDevice
    readonly property bool present: dev && dev.isLaptopBattery
    readonly property real rawPct: dev ? dev.percentage : 0
    // UPower percentage is a 0..1 ratio; guard in case a build reports 0..100.
    readonly property int pct: Math.round(rawPct <= 1.0 ? rawPct * 100 : rawPct)
    readonly property bool charging: dev && (dev.state === UPowerDeviceState.Charging
                                          || dev.state === UPowerDeviceState.FullyCharged)
    readonly property bool critical: present && pct < 15 && !charging

    visible: present

    function battIcon() {
        if (root.charging) return Theme.icoBatCharging
        if (root.pct < 10) return Theme.icoBat[0]
        if (root.pct < 25) return Theme.icoBat[1]
        if (root.pct < 50) return Theme.icoBat[2]
        if (root.pct < 75) return Theme.icoBat[3]
        return Theme.icoBat[4]
    }

    function stateLabel() {
        if (!root.dev) return ""
        switch (root.dev.state) {
            case UPowerDeviceState.Charging: return "Charging"
            case UPowerDeviceState.Discharging: return "Discharging"
            case UPowerDeviceState.FullyCharged: return "Full"
            case UPowerDeviceState.PendingCharge: return "Pending charge"
            case UPowerDeviceState.PendingDischarge: return "Pending discharge"
            case UPowerDeviceState.Empty: return "Empty"
            default: return "Unknown"
        }
    }

    // Seconds -> "Xh Ym" (or "Ym" under an hour). 0 -> "" (not yet estimated).
    function fmtTime(secs) {
        if (!secs || secs <= 0) return ""
        const mins = Math.round(secs / 60)
        const h = Math.floor(mins / 60)
        const m = mins % 60
        return h > 0 ? (h + "h " + m + "m") : (m + "m")
    }

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 6
        Icon {
            text: root.battIcon()
            color: root.critical ? Theme.crit : Theme.fg
        }
        Text {
            text: root.pct + "%"
            color: root.critical ? Theme.crit : Theme.fg
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

    // Fixed-width label column so tooltip rows line up ("remaining" is widest).
    TextMetrics {
        id: labelMetrics
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 2
        text: "remaining"
    }

    // Reusable 1px section separator (Network/Memory idiom).
    component Rule: Rectangle {
        Layout.fillWidth: true
        implicitHeight: 1
        color: Theme.sep
        Layout.topMargin: 4
        Layout.bottomMargin: 2
    }
    // Dimmed key label, fixed-width so values align across rows.
    component KeyLabel: Text {
        color: Theme.sep
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 2
        Layout.minimumWidth: labelMetrics.width
    }

    PopupMenu {
        id: menu
        anchorItem: root

        RowLayout {
            spacing: 6
            Icon {
                text: root.battIcon()
                color: root.critical ? Theme.crit : Theme.fg
                size: Theme.iconSizeSmall
            }
            Text {
                text: root.stateLabel() + " · " + root.pct + "%"
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
                font.bold: true
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 8
            radius: 4
            color: Qt.rgba(1, 1, 1, 0.09)
            clip: true
            Rectangle {
                width: parent.width * root.pct / 100
                height: parent.height
                color: root.critical ? Theme.crit : (root.pct < 25 ? Theme.warn : Theme.fg)
            }
        }

        Rule {}

        RowLayout {
            visible: root.dev && (root.charging ? root.dev.timeToFull > 0 : root.dev.timeToEmpty > 0)
            spacing: 6
            KeyLabel { text: "remaining" }
            Text {
                text: root.fmtTime(root.charging ? root.dev.timeToFull : root.dev.timeToEmpty)
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
            }
        }

        RowLayout {
            visible: root.dev && root.dev.healthSupported
            spacing: 6
            KeyLabel { text: "health" }
            Text {
                text: root.dev ? Math.round(root.dev.healthPercentage) + "%" : ""
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
            }
        }

        RowLayout {
            visible: root.dev && root.dev.energyCapacity > 0
            spacing: 6
            KeyLabel { text: "energy" }
            Text {
                text: root.dev
                    ? root.dev.energy.toFixed(1) + " / " + root.dev.energyCapacity.toFixed(1) + " Wh"
                        + (root.dev.changeRate !== 0 ? "  " + (root.charging ? "↑" : "↓") + " " + Math.abs(root.dev.changeRate).toFixed(1) + " W" : "")
                    : ""
                color: Theme.sep
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
            }
        }

        RowLayout {
            visible: root.dev && !!root.dev.model
            spacing: 6
            KeyLabel { text: "model" }
            Text {
                text: root.dev ? root.dev.model : ""
                color: Theme.sep
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
            }
        }
    }
}
