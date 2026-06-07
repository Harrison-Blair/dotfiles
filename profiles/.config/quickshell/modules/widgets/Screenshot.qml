import Quickshell
import QtQuick
import QtQuick.Layouts
import qs.services
import qs.components

// Region screenshot. Click runs `grim -g "$(slurp)" - | swappy -f -`, letting
// the user select a region and edit/save it in swappy. Launched via `sh -c`
// because the command relies on a pipe and command substitution.
Item {
    id: root
    implicitWidth: Theme.groupHeight
    implicitHeight: Theme.groupHeight
    Layout.alignment: Qt.AlignVCenter

    Icon {
        anchors.centerIn: parent
        text: Theme.icoScreenshot
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: Quickshell.execDetached(["sh", "-c", "grim -g \"$(slurp)\" - | swappy -f -"])
    }
}
