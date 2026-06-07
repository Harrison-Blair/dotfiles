import Quickshell
import QtQuick
import QtQuick.Layouts
import qs.services

// Action button used inside menus (e.g. "Open htop"). Launches `command`
// detached so the menu can close without killing the spawned app.
Rectangle {
    id: btn
    property string label: ""
    property var command: []
    signal triggered()

    Layout.fillWidth: true
    implicitHeight: 26
    radius: 8
    color: ma.containsMouse ? Theme.accent : Qt.rgba(1, 1, 1, 0.06)
    border.width: 1
    border.color: Theme.border

    Text {
        anchors.centerIn: parent
        text: btn.label
        color: Theme.fg
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 1
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            if (btn.command.length > 0)
                Quickshell.execDetached(btn.command)
            btn.triggered()
        }
    }
}
