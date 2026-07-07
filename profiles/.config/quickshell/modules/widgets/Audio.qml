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

    readonly property var source: Pipewire.defaultAudioSource
    readonly property bool srcReady: source && source.audio
    readonly property bool srcMuted: srcReady ? source.audio.muted : false
    readonly property int srcVolume: srcReady ? Math.round(source.audio.volume * 100) : 0

    // Required for {sink,source}.audio.{volume,muted} to stay live. Binds to the
    // Pipewire.default* properties, so it re-targets when the default device changes.
    PwObjectTracker { objects: [Pipewire.defaultAudioSink, Pipewire.defaultAudioSource] }

    // Reserve width for the widest label ("100%"/"Mute") so the widget — and
    // thus the whole centered bar — doesn't shift as the volume changes.
    TextMetrics {
        id: volMetrics
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize
        text: "100%"
    }

    // Fixed width for the tooltip's right-aligned percentage column (widest
    // token) so the output/input rows line up and the popup doesn't jitter.
    TextMetrics {
        id: muteMetrics
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 1
        text: "Muted"
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
        // Output device: icon + description + level, then a drawn meter.
        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            opacity: root.muted ? 0.5 : 1.0
            Icon {
                text: root.volIcon()
                size: Theme.iconSizeSmall
            }
            Text {
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: root.ready && root.sink.description ? root.sink.description : "Audio"
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 1
            }
            Text {
                Layout.preferredWidth: muteMetrics.width
                horizontalAlignment: Text.AlignRight
                text: root.muted ? "Muted" : root.volume + "%"
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 1
            }
        }
        VolumeMeter {
            volume: root.volume
            muted: root.muted
        }

        // Default input (mic) — hidden when there is no default source.
        RowLayout {
            visible: root.srcReady
            Layout.fillWidth: true
            spacing: 6
            opacity: root.srcMuted ? 0.5 : 1.0
            Icon {
                text: root.srcMuted ? Theme.icoMicMute : Theme.icoMicHigh
                size: Theme.iconSizeSmall
            }
            Text {
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: root.srcReady && root.source.description ? root.source.description : "Microphone"
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 1
            }
            Text {
                Layout.preferredWidth: muteMetrics.width
                horizontalAlignment: Text.AlignRight
                text: root.srcMuted ? "Muted" : root.srcVolume + "%"
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 1
            }
        }
        VolumeMeter {
            visible: root.srcReady
            volume: root.srcVolume
            muted: root.srcMuted
        }
        MenuButton {
            label: "Open pavucontrol"
            command: ["pavucontrol"]
            onTriggered: menu.visible = false
        }
    }
}
