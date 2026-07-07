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
    property real rxPrev: -1
    property real txPrev: -1

    // wifi / connection details (for the menu + signal icon)
    property string ssid: ""
    property int signal: 0             // 0..100
    property real freqGhz: 0
    property string ipaddr: ""
    property string gateway: ""

    // extended breakdown details (for the tooltip)
    property int chan: 0               // wifi channel
    property string rate: ""           // wifi negotiated rate, e.g. "1170 Mbit/s"
    property string security: ""       // wifi security, e.g. "WPA2" ("" = open)
    property string dns: ""
    property string mac: ""
    property int linkSpeed: 0          // ethernet link Mbps from sysfs (0 = n/a)
    property string duplex: ""         // ethernet duplex, e.g. "full"

    // session byte totals: base counter captured at connect
    property real rxBase: -1
    property real txBase: -1

    // rolling history of recent rates (bytes/sec) for the sparklines
    property var downHist: []
    property var upHist: []

    function human(bps) {
        if (bps < 1024) return bps.toFixed(0) + "B"
        const k = bps / 1024
        if (k < 1024) return (k < 10 ? k.toFixed(1) : k.toFixed(0)) + "K"
        const m = k / 1024
        if (m < 1024) return (m < 10 ? m.toFixed(1) : m.toFixed(0)) + "M"
        return (m / 1024).toFixed(1) + "G"
    }

    // "1170 Mbit/s" -> "1170 Mbps"
    function fmtBits(s) { return s ? s.replace("Mbit/s", "Mbps") : "" }

    // Bytes since connect, or "" if not yet baselined.
    function sessionTotal(prev, base) {
        return (base >= 0 && prev >= base) ? human(prev - base) : "0B"
    }

    // Block-glyph trend line, auto-scaled to the window's own max so the
    // shape stays readable regardless of magnitude. Idle -> flat baseline.
    function sparkline(hist) {
        if (!hist || hist.length === 0) return ""
        const maxV = Math.max.apply(null, hist)
        let s = ""
        for (const v of hist) {
            const idx = maxV <= 0 ? 0 : Math.min(7, Math.round(v / maxV * 7))
            s += Theme.cpuBlocks[idx]
        }
        return s
    }

    // 10-cell filled/empty meter for the wifi signal %.
    function signalMeter() {
        const n = Math.max(0, Math.min(10, Math.round(root.signal / 10)))
        return "█".repeat(n) + "░".repeat(10 - n)
    }
    // Threshold color for the signal meter + %, matching the bar icon.
    function signalColor() {
        if (root.signal < 20) return Theme.wifiBad
        if (root.signal < 40) return Theme.wifiWeak
        return Theme.fg
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
        onLoaded: { const v = parseInt(text())
            if (root.rxPrev >= 0) { root.downRate = Math.max(0, v - root.rxPrev); root.downHist = root.downHist.concat(root.downRate).slice(-20) }
            root.rxPrev = v; if (root.rxBase < 0) root.rxBase = v } }
    FileView { id: txFile; path: root.iface ? "/sys/class/net/" + root.iface + "/statistics/tx_bytes" : ""
        onLoaded: { const v = parseInt(text())
            if (root.txPrev >= 0) { root.upRate = Math.max(0, v - root.txPrev); root.upHist = root.upHist.concat(root.upRate).slice(-20) }
            root.txPrev = v; if (root.txBase < 0) root.txBase = v } }
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
                if (dev !== root.iface) {
                    root.rxPrev = -1; root.txPrev = -1
                    root.rxBase = -1; root.txBase = -1
                    root.downHist = []; root.upHist = []
                }
                root.iface = dev; root.ifaceType = type; root.connected = conn
            }
        }
    }

    // --- wifi AP details ---
    Process {
        id: wifiProc
        command: ["nmcli", "-t", "-f", "IN-USE,SIGNAL,SSID,FREQ,CHAN,RATE,SECURITY", "device", "wifi"]
        stdout: StdioCollector {
            onStreamFinished: {
                for (const line of this.text.split("\n")) {
                    if (line.indexOf("*") !== 0) continue   // active AP row
                    const f = line.split(":")
                    root.signal = parseInt(f[1]) || 0
                    root.ssid = f[2] || ""
                    root.freqGhz = (parseInt(f[3]) || 0) / 1000
                    root.chan = parseInt(f[4]) || 0
                    root.rate = f[5] || ""
                    root.security = f[6] || ""
                    break
                }
            }
        }
    }

    // --- IP + gateway ---
    Process {
        id: ipProc
        command: root.iface ? ["nmcli", "-t", "-g", "IP4.ADDRESS,IP4.GATEWAY,IP4.DNS,GENERAL.HWADDR", "device", "show", root.iface] : ["true"]
        stdout: StdioCollector {
            onStreamFinished: {
                // -g emits one line per field (empty line if unset), so index
                // positionally rather than dropping blanks (keeps alignment).
                const lines = this.text.split("\n")
                root.ipaddr = lines[0] ? lines[0].split("/")[0] : ""
                root.gateway = lines[1] || ""
                root.dns = lines[2] || ""
                root.mac = lines[3] ? lines[3].replace(/\\:/g, ":") : ""   // -t escapes MAC colons
            }
        }
    }

    // --- ethernet link speed / duplex (wifi drivers return -1 / error) ---
    FileView { id: speedFile
        path: (root.connected && root.ifaceType === "ethernet") ? "/sys/class/net/" + root.iface + "/speed" : ""
        onLoaded: { const v = parseInt(text()); root.linkSpeed = v > 0 ? v : 0 } }
    FileView { id: duplexFile
        path: (root.connected && root.ifaceType === "ethernet") ? "/sys/class/net/" + root.iface + "/duplex" : ""
        onLoaded: root.duplex = text().trim() }

    Timer {
        interval: 3000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: {
            statusProc.running = true
            if (root.ifaceType === "wifi") wifiProc.running = true
            if (root.iface) ipProc.running = true
            if (root.ifaceType === "ethernet") { speedFile.reload(); duplexFile.reload() }
        }
    }

    // Fixed width for a rate value so changing digit counts never resize the bar.
    // Widest output is the "G" branch, which always carries a decimal: e.g.
    // "120.0G" — wider than "1023M". Size for the worst case so the right-aligned
    // text never overflows its box and collides with the wifi icon.
    TextMetrics {
        id: rateMetrics
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize
        text: "1023.9G"
    }

    // Fixed width for tooltip key/value label column, sized to the widest
    // label ("security") so labels and values line up across all sections.
    TextMetrics {
        id: labelMetrics
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 2
        text: "security"
    }

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 6
        Icon {
            text: root.netIcon()
            color: root.netIconColor()
            Layout.rightMargin: 4
        }
        Text {
            visible: root.connected
            text: root.human(root.downRate)
            color: Theme.netDown
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            Layout.preferredWidth: rateMetrics.width
            horizontalAlignment: Text.AlignRight
        }
        Icon {
            visible: root.connected
            text: Theme.icoNetDown
            color: Theme.netDown
            size: Theme.iconSizeSmall
            Layout.leftMargin: 2
            Layout.rightMargin: 2
        }
        Text {
            visible: root.connected
            text: root.human(root.upRate)
            color: Theme.netUp
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            Layout.preferredWidth: rateMetrics.width
            horizontalAlignment: Text.AlignRight
        }
        Icon {
            visible: root.connected
            text: Theme.icoNetUp
            color: Theme.netUp
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

    // Reusable 1px section separator (AiUsage idiom).
    component Rule: Rectangle {
        Layout.fillWidth: true
        implicitHeight: 1
        color: Theme.sep
        Layout.topMargin: 4
        Layout.bottomMargin: 2
    }
    // Dimmed key label, fixed-width so values align across sections.
    component KeyLabel: Text {
        color: Theme.sep
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 2
        Layout.minimumWidth: labelMetrics.width
    }

    PopupMenu {
        id: menu
        anchorItem: root

        // --- Header: net icon + title + dimmed iface tag ---
        RowLayout {
            spacing: 6
            Icon {
                text: root.netIcon()
                color: root.netIconColor()
                size: Theme.iconSizeSmall
            }
            Text {
                textFormat: Text.RichText
                text: root.connected
                    ? ((root.ifaceType === "wifi" && root.ssid ? root.ssid
                        : (root.ifaceType === "ethernet" ? "Ethernet" : root.iface))
                       + ' <span style="color:' + Theme.sep + '">· ' + root.iface + '</span>')
                    : "Disconnected"
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
                font.bold: true
            }
        }
        Text {
            visible: !root.connected
            text: "No active connection"
            color: Theme.sep
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
        }

        Rule { visible: root.connected }

        // --- Hero throughput: down (red) / up (green) rate + sparkline ---
        ColumnLayout {
            visible: root.connected
            spacing: 4
            RowLayout {
                spacing: 6
                Icon { text: Theme.icoNetDown; color: Theme.netDown; size: Theme.iconSizeSmall }
                Text {
                    text: root.human(root.downRate); color: Theme.netDown
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize; font.bold: true
                    Layout.preferredWidth: rateMetrics.width; horizontalAlignment: Text.AlignRight
                }
                Text {
                    text: root.sparkline(root.downHist); color: Theme.netDown
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize
                    Layout.leftMargin: 4
                }
            }
            RowLayout {
                spacing: 6
                Icon { text: Theme.icoNetUp; color: Theme.netUp; size: Theme.iconSizeSmall }
                Text {
                    text: root.human(root.upRate); color: Theme.netUp
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize; font.bold: true
                    Layout.preferredWidth: rateMetrics.width; horizontalAlignment: Text.AlignRight
                }
                Text {
                    text: root.sparkline(root.upHist); color: Theme.netUp
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize
                    Layout.leftMargin: 4
                }
            }
        }

        Rule { visible: root.connected && (root.ifaceType === "wifi" || (root.ifaceType === "ethernet" && root.linkSpeed > 0)) }

        // --- Signal (wifi): meter + % and radio detail line ---
        ColumnLayout {
            visible: root.connected && root.ifaceType === "wifi"
            spacing: 2
            RowLayout {
                spacing: 6
                KeyLabel { text: "signal" }
                Text {
                    text: root.signalMeter(); color: root.signalColor()
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize
                }
                Text {
                    text: root.signal + "%"; color: root.signalColor()
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                }
            }
            RowLayout {
                spacing: 6
                KeyLabel { text: "radio" }
                Text {
                    text: {
                        let parts = []
                        if (root.freqGhz > 0) parts.push((root.freqGhz >= 5 ? "5" : "2.4") + " GHz")
                        if (root.chan > 0) parts.push("ch " + root.chan)
                        if (root.rate) parts.push(root.fmtBits(root.rate))
                        return parts.join(" · ")
                    }
                    color: Theme.sep
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                }
            }
        }

        // --- Link (ethernet): negotiated speed + duplex ---
        RowLayout {
            visible: root.connected && root.ifaceType === "ethernet" && root.linkSpeed > 0
            spacing: 6
            KeyLabel { text: "link" }
            Text {
                text: root.linkSpeed + " Mbps" + (root.duplex ? " · " + root.duplex : "")
                color: Theme.fg
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
            }
        }

        Rule { visible: root.connected }

        // --- Connection details: dimmed label / fg value rows ---
        ColumnLayout {
            visible: root.connected
            spacing: 2
            Repeater {
                model: root.connected ? [
                    { l: "security", v: root.ifaceType === "wifi" ? root.security : "" },
                    { l: "IPv4",     v: root.ipaddr },
                    { l: "gateway",  v: root.gateway },
                    { l: "DNS",      v: root.dns },
                    { l: "MAC",      v: root.mac }
                ] : []
                RowLayout {
                    required property var modelData
                    visible: !!modelData.v
                    spacing: 6
                    KeyLabel { text: modelData.l }
                    Text {
                        text: modelData.v; color: Theme.fg
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                    }
                }
            }
        }

        Rule { visible: root.connected }

        // --- Session totals since connect ---
        RowLayout {
            visible: root.connected
            spacing: 6
            KeyLabel { text: "session" }
            Text {
                text: "↓ " + root.sessionTotal(root.rxPrev, root.rxBase)
                    + "   ↑ " + root.sessionTotal(root.txPrev, root.txBase)
                color: Theme.sep
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
            }
        }

        MenuButton {
            label: "Open nmtui"
            command: ["kitty", "-e", "nmtui"]
            onTriggered: menu.visible = false
        }
    }
}
