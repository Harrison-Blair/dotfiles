import Quickshell.Services.Pipewire
import QtQuick
import QtQuick.Layouts
import qs.services
import qs.components

// Default sink volume (waybar pulseaudio). Click opens a menu with a button to
// launch pavucontrol.
Item {
    id: root
    implicitWidth: row.implicitWidth
    implicitHeight: Theme.groupHeight
    Layout.alignment: Qt.AlignVCenter

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property bool ready: sink && sink.audio
    readonly property bool muted: ready ? sink.audio.muted : false
    readonly property int volume: ready ? Math.round(sink.audio.volume * 100) : 0

    // Required for sink.audio.{volume,muted} to stay live.
    PwObjectTracker { objects: [Pipewire.defaultAudioSink] }

    // Reserve width for the widest label ("100%"/"Mute") so the widget — and
    // thus the whole centered bar — doesn't shift as the volume changes.
    TextMetrics {
        id: volMetrics
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize
        text: "100%"
    }

    function volIcon() {
        if (root.muted) return Theme.icoVolMute
        if (root.volume <= 0) return Theme.icoVolLow
        if (root.volume < 50) return Theme.icoVolMid
        return Theme.icoVolHigh
    }

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 6
        // Fixed-width box so the label ("5%" → "100%" → "Mute") never changes
        // the module's width. RowLayout honors this Item's implicitWidth.
        Item {
            implicitWidth: volMetrics.width
            implicitHeight: volText.implicitHeight
            Layout.alignment: Qt.AlignVCenter
            Text {
                id: volText
                anchors.fill: parent
                text: root.muted ? "Mute" : (root.volume + "%")
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
                horizontalAlignment: Text.AlignRight
                verticalAlignment: Text.AlignVCenter
            }
        }
        Icon {
            text: root.volIcon()
        }
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
        Text {
            text: (root.ready && root.sink.description ? root.sink.description : "Audio")
                  + ": " + (root.muted ? "Muted" : root.volume + "%")
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 1
        }
        MenuButton {
            label: "Open pavucontrol"
            command: ["pavucontrol"]
            onTriggered: menu.visible = false
        }
    }
}
