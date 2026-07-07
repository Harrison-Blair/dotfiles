import QtQuick
import QtQuick.Layouts
import qs.services

// Horizontal level bar for a volume value. The fill spans a 0-150% range so
// over-unity (>100%) boost is visible rather than clipped, and recolors to
// warn/crit past unity. A 1px tick marks the 100% unity-gain point.
Rectangle {
    id: meter
    property int volume: 0
    property bool muted: false

    Layout.fillWidth: true
    implicitWidth: 200
    implicitHeight: 6
    radius: 3
    color: Qt.rgba(1, 1, 1, 0.10)   // subtle groove

    Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        radius: parent.radius
        width: parent.width * Math.min(meter.volume, 150) / 150
        color: meter.muted ? Theme.border
             : meter.volume <= 100 ? Theme.fg
             : meter.volume <= 125 ? Theme.warn : Theme.crit
    }

    Rectangle {   // 100% unity tick
        width: 1
        height: parent.height
        color: Theme.border
        x: parent.width * 100 / 150
    }
}
