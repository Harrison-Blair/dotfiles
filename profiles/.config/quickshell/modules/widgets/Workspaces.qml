import Quickshell.Hyprland
import QtQuick
import QtQuick.Layouts
import qs.services

// Hyprland workspace buttons (waybar hyprland/workspaces).
// Shows only workspaces that hold windows (plus each monitor's active one, so
// a freshly created empty workspace stays visible), followed by a gray "+"
// that jumps to this monitor's next free workspace. Special (scratchpad)
// workspaces are excluded — the Scratchpad widget covers those. Styled by
// text instead of a background highlight: active = bold + foreground,
// inactive = divider-gray.
Item {
    id: root
    property var screen  // this bar's ShellScreen, set by Bar.qml
    property int slotW: 24
    property int gap: 4

    readonly property var monitor: Hyprland.monitorFor(screen)

    // Mirrors the workspace→monitor rules in
    // ~/.config/hypr/modules/display/workspaces.lua:
    // DP-2 gets 1,4,7…; DP-1 gets 2,5,8…; DP-3 gets 3,6,9…
    readonly property var monitorRem: ({ "DP-2": 1, "DP-1": 2, "DP-3": 0 })

    readonly property var shown: Hyprland.workspaces.values
        .filter(w => w.id > 0
                && ((w.lastIpcObject && w.lastIpcObject.windows > 0) || w.active))
        .sort((a, b) => a.id - b.id)

    Layout.alignment: Qt.AlignVCenter
    implicitHeight: Theme.groupHeight
    implicitWidth: content.implicitWidth

    // Window counts (lastIpcObject.windows) only update when quickshell
    // re-queries workspaces; nudge it on every compositor event so
    // open/close/move are reflected immediately.
    Connections {
        target: Hyprland
        function onRawEvent() { Hyprland.refreshWorkspaces() }
    }

    // Smallest workspace id belonging to this monitor with no windows in it
    // (existing-but-empty counts, so the persistent 1-6 get reused first).
    function nextFreeId() {
        const rem = monitorRem[monitor.name]
        const occupied = Hyprland.workspaces.values
            .filter(w => w.lastIpcObject && w.lastIpcObject.windows > 0)
            .map(w => w.id)
        if (rem === undefined)  // monitor without a rule: just take a fresh id
            return Math.max(0, ...occupied) + 1
        let id = rem === 0 ? 3 : rem
        while (occupied.indexOf(id) !== -1) id += 3
        return id
    }

    RowLayout {
        id: content
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: root.gap

        Repeater {
            model: root.shown

            Item {
                id: ws
                required property var modelData
                implicitWidth: root.slotW
                implicitHeight: Theme.groupHeight

                Text {
                    anchors.centerIn: parent
                    text: ws.modelData.name
                    color: ws.modelData.active ? Theme.fg : Theme.sep
                    font.bold: ws.modelData.active
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    // This Hyprland uses a Lua config: dispatch payloads are
                    // evaluated as Lua, so mirror the keybinds' hl.dsp.focus call.
                    onClicked: Hyprland.dispatch("hl.dsp.focus({workspace=" + ws.modelData.id + "})")
                }
            }
        }

        // Deactivated "+": creates/focuses the next free workspace here.
        Item {
            implicitWidth: root.slotW
            implicitHeight: Theme.groupHeight

            Text {
                anchors.centerIn: parent
                text: "+"
                color: Theme.sep
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    // Focus the monitor first so unruled ids (>9) land here.
                    Hyprland.dispatch("hl.dsp.focus({monitor='" + root.monitor.name + "'})")
                    Hyprland.dispatch("hl.dsp.focus({workspace=" + root.nextFreeId() + "})")
                }
            }
        }
    }
}
