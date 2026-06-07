import Quickshell
import QtQuick
import QtQuick.Layouts
import qs.services

// Reusable hover-activated tooltip/menu. A module sets `anchorItem` to its own
// root Item and drives `anchorHovered` from its MouseArea's onEntered/onExited.
// The popup stays open while the cursor is over the widget OR the popup itself
// (tracked via HoverHandler), so action buttons inside remain clickable. A short
// close delay bridges the gap between the bar widget and the popup.
PopupWindow {
    id: popup
    property Item anchorItem
    property bool anchorHovered: false
    default property alias content: inner.data

    // Open while hovering either the source widget or the popup body.
    readonly property bool keepOpen: anchorHovered || frameHover.hovered
    onKeepOpenChanged: {
        if (keepOpen) {
            closeTimer.stop()
            visible = true
        } else {
            closeTimer.restart()
        }
    }

    anchor.item: anchorItem
    anchor.edges: Edges.Bottom
    anchor.gravity: Edges.Bottom
    anchor.margins.top: 6

    implicitWidth: frame.implicitWidth
    implicitHeight: frame.implicitHeight
    color: "transparent"
    visible: false

    Timer {
        id: closeTimer
        interval: 250
        onTriggered: if (!popup.keepOpen) popup.visible = false
    }

    Rectangle {
        id: frame
        anchors.fill: parent
        implicitWidth: inner.implicitWidth + 28
        implicitHeight: inner.implicitHeight + 22
        color: Theme.menuBg
        border.width: 1
        border.color: Theme.border
        radius: 10

        // Tracks hover over the popup body without intercepting button clicks.
        HoverHandler { id: frameHover }

        ColumnLayout {
            id: inner
            anchors.centerIn: parent
            spacing: 6
        }
    }
}
