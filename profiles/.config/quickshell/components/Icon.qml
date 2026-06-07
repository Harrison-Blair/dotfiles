import QtQuick
import QtQuick.Layouts
import qs.services

// A Nerd Font glyph rendered directly in the dedicated symbol font (not via
// fontconfig fallback), so it scales and centers correctly. Drawn inside a
// fixed square box and centered both ways for deterministic alignment.
Item {
    id: root
    property alias text: glyph.text
    property color color: Theme.fg
    property int size: Theme.iconSize

    implicitWidth: size
    implicitHeight: size
    Layout.alignment: Qt.AlignVCenter

    Text {
        id: glyph
        anchors.centerIn: parent
        color: root.color
        font.family: Theme.iconFont
        font.pixelSize: root.size
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
}
