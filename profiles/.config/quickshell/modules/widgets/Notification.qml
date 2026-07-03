import Quickshell
import QtQuick
import QtQuick.Layouts
import qs.services
import qs.components

// Notification bell. Click toggles the swaync control center (`swaync-client -t`).
// `-sw` skips waiting for the reply so the click returns immediately.
Item {
    id: root
    implicitWidth: Theme.groupHeight
    implicitHeight: Theme.groupHeight
    Layout.alignment: Qt.AlignVCenter

    Icon {
        anchors.centerIn: parent
        text: Theme.icoNotification
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: Quickshell.execDetached(["swaync-client", "-t", "-sw"])
    }
}
