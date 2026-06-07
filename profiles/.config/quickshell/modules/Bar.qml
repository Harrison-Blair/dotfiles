import Quickshell
import QtQuick
import QtQuick.Layouts
import qs.services
import qs.components
import qs.modules.widgets

PanelWindow {
    id: bar

    anchors {
        top: true
        left: true
        right: true
    }
    implicitHeight: Theme.barHeight
    exclusiveZone: Theme.barHeight
    color: "transparent"

    // One compact, centered group holding every widget.
    Group {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter

        Workspaces {}
        Separator {}
        Clock {}
        Separator {}
        Audio {}
        Separator {}
        Network {}
        Memory {}
        Cpu {}
        Separator {}
        Temperature {}
        Separator { visible: battery.present }
        Battery { id: battery }
    }
}
