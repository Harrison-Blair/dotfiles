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
        Text {
            text: root.muted ? "Mute" : (root.volume + "%")
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }
        Icon {
            text: root.volIcon()
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: menu.visible = !menu.visible
    }

    PopupMenu {
        id: menu
        anchorItem: root
        Text {
            text: (root.ready && root.sink.description ? root.sink.description : "Audio")
                  + "\n" + (root.muted ? "Muted" : root.volume + "%")
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
