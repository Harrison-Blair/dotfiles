import Quickshell.Hyprland
import QtQuick
import QtQuick.Layouts
import qs.services

// Hyprland workspace buttons (waybar hyprland/workspaces).
// Reserves room for `slots` items so the bar width stays stable, and styles by
// text instead of a background highlight: active = bold + foreground, inactive =
// divider-gray.
Item {
    id: root
    property int slots: 6
    property int slotW: 24
    property int gap: 4

    Layout.alignment: Qt.AlignVCenter
    implicitHeight: Theme.groupHeight
    implicitWidth: Math.max(slots * slotW + (slots - 1) * gap, content.implicitWidth)

    RowLayout {
        id: content
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: root.gap

        Repeater {
            model: Hyprland.workspaces

            Item {
                id: ws
                required property var modelData
                implicitWidth: root.slotW
                implicitHeight: Theme.groupHeight

                Text {
                    anchors.centerIn: parent
                    text: ws.modelData.name
                    color: ws.modelData.active ? Theme.fg : Theme.sep
                    font.bold: ws.modelData.active
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Hyprland.dispatch("workspace " + ws.modelData.id)
                }
            }
        }
    }
}
