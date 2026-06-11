import Quickshell
import QtQuick
import QtQuick.Layouts
import qs.services

// Action button used inside menus (e.g. "Open htop"). Launches `command`
// detached so the menu can close without killing the spawned app.
Rectangle {
    id: btn
    property string label: ""
    property string icon: ""        // optional leading glyph (Theme.iconFont)
    property var command: []
    signal triggered()

    Layout.fillWidth: true
    implicitHeight: 26
    implicitWidth: row.implicitWidth + 24   // content + horizontal padding
    radius: 8
    color: ma.containsMouse ? Theme.accent : Qt.rgba(1, 1, 1, 0.06)
    border.width: 1
    border.color: Theme.border

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 8

        Text {
            visible: btn.icon !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: btn.icon
            color: Theme.fg
            font.family: Theme.iconFont
            font.pixelSize: Theme.fontSize
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: btn.label
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 1
        }
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
