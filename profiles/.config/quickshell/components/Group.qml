import QtQuick
import QtQuick.Layouts
import qs.services

// Rounded, translucent, bordered container — the waybar "module group" box.
// Children placed inside a Group are laid out in a horizontal row.
Rectangle {
    id: root
    default property alias content: row.data
    property real hpad: Theme.pad
    property real spacing: Theme.itemSpacing

    implicitWidth: row.implicitWidth + hpad * 2
    implicitHeight: Theme.groupHeight
    radius: Theme.radius
    color: Theme.groupBg
    border.width: 1
    border.color: Theme.border

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: root.spacing
    }
}
