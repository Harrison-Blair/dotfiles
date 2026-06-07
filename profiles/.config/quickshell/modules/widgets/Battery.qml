import Quickshell.Services.UPower
import QtQuick
import QtQuick.Layouts
import qs.services
import qs.components

// Battery (waybar custom/battery). Hidden entirely on machines with no battery
// (the desktop), replacing the script's class="empty" collapse trick.
RowLayout {
    id: root
    Layout.alignment: Qt.AlignVCenter
    spacing: 6

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
