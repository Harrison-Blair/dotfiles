import QtQuick
import QtQuick.Layouts
import qs.services
import qs.components

// Power menu: lock / logout / reboot / shutdown. Reboot and shutdown require a
// second confirming click (easy to misfire). Lock engages the in-process
// WlSessionLock via the Lock singleton; the rest shell out via MenuButton.
Item {
    id: root
    implicitWidth: icon.implicitWidth
    implicitHeight: Theme.groupHeight
    Layout.alignment: Qt.AlignVCenter

    // "", "reboot" or "shutdown" — when set, the menu shows a confirm prompt.
    property string pendingAction: ""

    Icon {
        id: icon
        anchors.centerIn: parent
        text: Theme.icoPower
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: menu.anchorHovered = true
        onExited: menu.anchorHovered = false
    }

    PopupMenu {
        id: menu
        anchorItem: root
        // Drop any half-finished confirm whenever the menu closes.
        onVisibleChanged: if (!visible) root.pendingAction = ""

        // --- action list (hidden while confirming) ---
        MenuButton {
            visible: root.pendingAction === ""
            icon: Theme.icoLock
            label: "Lock"
            onTriggered: { Lock.lock(); menu.visible = false }
        }
        MenuButton {
            visible: root.pendingAction === ""
            icon: Theme.icoLogout
            label: "Logout"
            // $XDG_SESSION_ID is inherited from quickshell's session environment.
            command: ["sh", "-c", "loginctl terminate-session \"$XDG_SESSION_ID\""]
            onTriggered: menu.visible = false
        }
        MenuButton {
            visible: root.pendingAction === ""
            icon: Theme.icoReboot
            label: "Reboot"
            onTriggered: root.pendingAction = "reboot"
        }
        MenuButton {
            visible: root.pendingAction === ""
            icon: Theme.icoShutdown
            label: "Shutdown"
            onTriggered: root.pendingAction = "shutdown"
        }

        // --- confirmation (shown only once an action is pending) ---
        Text {
            visible: root.pendingAction !== ""
            Layout.alignment: Qt.AlignHCenter
            text: "Confirm " + root.pendingAction + "?"
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 1
        }
        MenuButton {
            visible: root.pendingAction !== ""
            label: "Yes"
            command: root.pendingAction === "reboot"
                     ? ["systemctl", "reboot"]
                     : ["systemctl", "poweroff"]
            onTriggered: menu.visible = false
        }
        MenuButton {
            visible: root.pendingAction !== ""
            label: "Cancel"
            onTriggered: root.pendingAction = ""
        }
    }
}
