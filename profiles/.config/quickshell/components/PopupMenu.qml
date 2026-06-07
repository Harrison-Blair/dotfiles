import Quickshell
import QtQuick
import QtQuick.Layouts
import qs.services

// Reusable click-activated menu (replaces waybar hover tooltips). A module sets
// `anchorItem` to its own root Item and toggles `visible`. Clicking outside
// dismisses it via grabFocus.
PopupWindow {
    id: popup
    property Item anchorItem
    default property alias content: inner.data

    anchor.item: anchorItem
    anchor.edges: Edges.Bottom
    anchor.gravity: Edges.Bottom
    anchor.margins.top: 6

    implicitWidth: frame.implicitWidth
    implicitHeight: frame.implicitHeight
    color: "transparent"
    visible: false
    grabFocus: visible

    Rectangle {
        id: frame
        anchors.fill: parent
        implicitWidth: inner.implicitWidth + 28
        implicitHeight: inner.implicitHeight + 22
        color: Theme.menuBg
        border.width: 1
        border.color: Theme.border
        radius: 10

        ColumnLayout {
            id: inner
            anchors.centerIn: parent
            spacing: 6
        }
    }
}
