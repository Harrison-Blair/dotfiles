import QtQuick
import QtQuick.Layouts
import qs.services

// A Nerd Font glyph, sized via Theme.iconSize and vertically centered on the
// bar's line (Nerd glyph metrics otherwise sit off-center next to text).
Text {
    color: Theme.fg
    font.family: Theme.fontFamily
    font.pixelSize: Theme.iconSize
    verticalAlignment: Text.AlignVCenter
    horizontalAlignment: Text.AlignHCenter
    Layout.alignment: Qt.AlignVCenter
}
