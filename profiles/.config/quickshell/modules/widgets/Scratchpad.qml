import Quickshell.Hyprland
import QtQuick
import QtQuick.Layouts
import qs.services
import qs.components

// Indicator for the "magic" special workspace (the Super+S scratchpad).
// Special workspaces only exist while they hold windows, so this is visible
// exactly when something (e.g. Spotify) is parked there. Click toggles it.
Item {
    id: root
    readonly property bool present:
        Hyprland.workspaces.values.some(w => w.name === "special:magic")

    visible: present
    implicitWidth: Theme.groupHeight
    implicitHeight: Theme.groupHeight
    Layout.alignment: Qt.AlignVCenter

    Icon {
        anchors.centerIn: parent
        text: Theme.icoScratchpad
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: Hyprland.dispatch("hl.dsp.workspace.toggle_special('magic')")
    }
}
