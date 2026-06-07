import QtQuick
import QtQuick.Layouts
import qs.services

// Thin vertical divider between module groupings (waybar custom/sep).
Rectangle {
    implicitWidth: 2
    Layout.preferredHeight: Theme.groupHeight * 0.6
    Layout.alignment: Qt.AlignVCenter
    color: Theme.sep
    radius: 1
}
