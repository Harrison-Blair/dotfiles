import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.services
import qs.components

// Network (waybar network): live up/down bandwidth + wifi signal icon.
// Bandwidth from sysfs byte counters; SSID/signal/freq/IP/gateway from nmcli.
Item {
    id: root
    implicitWidth: row.implicitWidth
    implicitHeight: Theme.groupHeight
    Layout.alignment: Qt.AlignVCenter

    property string iface: ""
    property string ifaceType: ""     // "wifi" | "ethernet" | ""
    property bool connected: false

    property real downRate: 0          // bytes/sec
    property real upRate: 0
    property int rxPrev: -1
    property int txPrev: -1

    // wifi / connection details (for the menu + signal icon)
    property string ssid: ""
    property int signal: 0             // 0..100
    property real freqGhz: 0
    property string ipaddr: ""
    property string gateway: ""

    function human(bps) {
        if (bps < 1024) return bps.toFixed(0) + "B"
        const k = bps / 1024
        if (k < 1024) return (k < 10 ? k.toFixed(1) : k.toFixed(0)) + "K"
        const m = k / 1024
        if (m < 1024) return (m < 10 ? m.toFixed(1) : m.toFixed(0)) + "M"
        return (m / 1024).toFixed(1) + "G"
    }

    // signal 0..100 -> icon index 0..4
    function wifiIdx() {
        if (root.signal < 20) return 0
        if (root.signal < 40) return 1
        if (root.signal < 60) return 2
        if (root.signal < 80) return 3
        return 4
    }
    function netIcon() {
        if (!root.connected) return Theme.icoNetDisc
        if (root.ifaceType === "ethernet") return Theme.icoEthernet
        return Theme.icoWifi[wifiIdx()]
    }
    function netIconColor() {
        if (!root.connected) return Theme.fg
        if (root.ifaceType === "wifi") {
            const i = wifiIdx()
            if (i === 0) return Theme.wifiBad
            if (i === 1) return Theme.wifiWeak
        }
        return Theme.fg
    }

    // --- bandwidth counters ---
    FileView { id: rxFile; path: root.iface ? "/sys/class/net/" + root.iface + "/statistics/rx_bytes" : ""
        onLoaded: { const v = parseInt(text()); if (root.rxPrev >= 0) root.downRate = Math.max(0, v - root.rxPrev); root.rxPrev = v } }
    FileView { id: txFile; path: root.iface ? "/sys/class/net/" + root.iface + "/statistics/tx_bytes" : ""
        onLoaded: { const v = parseInt(text()); if (root.txPrev >= 0) root.upRate = Math.max(0, v - root.txPrev); root.txPrev = v } }
    Timer {
        interval: 1000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: { if (root.iface) { rxFile.reload(); txFile.reload() } }
    }

    // --- pick the active interface ---
    Process {
        id: statusProc
        command: ["nmcli", "-t", "-f", "DEVICE,TYPE,STATE", "device", "status"]
        stdout: StdioCollector {
            onStreamFinished: {
                let dev = "", type = "", conn = false
                for (const line of this.text.split("\n")) {
                    const f = line.split(":")
                    if (f.length < 3) continue
                    if (f[1] === "loopback") continue
                    if (f[2].indexOf("connected") === 0 && f[2] !== "disconnected") {
                        dev = f[0]; type = (f[1] === "wifi") ? "wifi" : "ethernet"; conn = true
                        break
                    }
                }
                if (dev !== root.iface) { root.rxPrev = -1; root.txPrev = -1 }
                root.iface = dev; root.ifaceType = type; root.connected = conn
            }
        }
    }

    // --- wifi AP details ---
    Process {
        id: wifiProc
        command: ["nmcli", "-t", "-f", "IN-USE,SIGNAL,SSID,FREQ", "device", "wifi"]
        stdout: StdioCollector {
            onStreamFinished: {
                for (const line of this.text.split("\n")) {
                    if (line.indexOf("*") !== 0) continue
                    const f = line.split(":")
                    root.signal = parseInt(f[1]) || 0
                    root.ssid = f[2] || ""
                    root.freqGhz = (parseInt(f[3]) || 0) / 1000
                    break
                }
            }
        }
    }

    // --- IP + gateway ---
    Process {
        id: ipProc
        command: root.iface ? ["nmcli", "-t", "-g", "IP4.ADDRESS,IP4.GATEWAY", "device", "show", root.iface] : ["true"]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = this.text.split("\n").filter(l => l.length > 0)
                root.ipaddr = lines.length > 0 ? lines[0].split("/")[0] : ""
                root.gateway = lines.length > 1 ? lines[1] : ""
            }
        }
    }

    Timer {
        interval: 3000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: {
            statusProc.running = true
            if (root.ifaceType === "wifi") wifiProc.running = true
            if (root.iface) ipProc.running = true
        }
    }

    // Fixed width for a rate value so changing digit counts never resize the bar
    // (widest output is e.g. "1023B" / "1023M" — 5 monospace chars).
    TextMetrics {
        id: rateMetrics
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize
        text: "1023M"
    }

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 6
        Icon {
            text: root.netIcon()
            color: root.netIconColor()
        }
        Text {
            visible: root.connected
            text: root.human(root.downRate)
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            Layout.preferredWidth: rateMetrics.width
            horizontalAlignment: Text.AlignRight
        }
        Icon {
            visible: root.connected
            text: Theme.icoNetDown
            size: Theme.iconSizeSmall
        }
        Text {
            visible: root.connected
            text: root.human(root.upRate)
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            Layout.preferredWidth: rateMetrics.width
            horizontalAlignment: Text.AlignRight
        }
        Icon {
            visible: root.connected
            text: Theme.icoNetUp
            size: Theme.iconSizeSmall
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
            text: root.connected ? (root.iface + "  (" + root.ifaceType + ")") : "Disconnected"
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }
        Text {
            visible: root.ifaceType === "wifi" && root.connected
            text: "SSID:    " + root.ssid + "\n"
                + "Freq:    " + root.freqGhz.toFixed(3) + " GHz\n"
                + "Signal:  " + root.signal + "%"
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 1
        }
        Text {
            visible: root.connected
            text: "Gateway: " + root.gateway + "\n"
                + "IPv4:    " + root.ipaddr
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 1
        }
        MenuButton {
            label: "Open nmtui"
            command: ["kitty", "-e", "nmtui"]
            onTriggered: menu.visible = false
        }
    }
}
