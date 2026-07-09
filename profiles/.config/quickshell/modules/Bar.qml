import Quickshell
import QtQuick
import QtQuick.Layouts
import qs.services
import qs.components
import qs.modules.widgets

PanelWindow {
    id: bar

    // Portrait screens (rotated monitors) are too narrow for the full widget row.
    readonly property bool portrait: screen.height > screen.width

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

        Scratchpad { id: scratchpad; visible: present && !bar.portrait }
        Separator { visible: scratchpad.present && !bar.portrait }
        Workspaces { screen: bar.screen }
        Separator { visible: !bar.portrait }
        Network { visible: !bar.portrait }
        Separator { visible: !bar.portrait }
        Memory { visible: !bar.portrait }
        Separator { visible: !bar.portrait }
        Cpu { visible: !bar.portrait }
        Separator { visible: !bar.portrait }
        Gpu { visible: !bar.portrait }
        Separator { visible: !bar.portrait }
        Temperature { visible: !bar.portrait }
        Separator { visible: !bar.portrait }
        AiUsage { visible: !bar.portrait }
        Separator {}
        Clock {}
        Separator {}
        Audio {}
        Separator { visible: battery.present && !bar.portrait }
        Battery { id: battery; visible: present && !bar.portrait }
        Separator { visible: !bar.portrait }
        Screenshot { visible: !bar.portrait }
        Separator {}
        Notification {}
        Separator {}
        PowerMenu {}
    }
}
