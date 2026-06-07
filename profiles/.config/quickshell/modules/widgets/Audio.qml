import Quickshell.Services.Pipewire
import QtQuick
import QtQuick.Layouts
import qs.services
import qs.components

// Default sink volume (waybar pulseaudio).
RowLayout {
    id: root
    Layout.alignment: Qt.AlignVCenter
    spacing: 6

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
