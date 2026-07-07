import Quickshell
import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.services
import qs.components

// Hardware temperatures (waybar custom/sensors). Classification logic ported to
// QML; raw data comes from `sensors -j` (+ nvidia-smi) like the old script.
// Bar shows CPU / GPU / SSD headline temps; menu lists every sensor per chip.
Item {
    id: root
    implicitWidth: row.implicitWidth
    implicitHeight: Theme.groupHeight
    Layout.alignment: Qt.AlignVCenter

    property string sensorsText: ""
    property string nvidiaText: ""
    property var groups: []          // [{header, icon, rows:[{label,val,crit,icon}]}]
    property var headline: []        // [{icon, temp, crit}]
    property bool anyCritical: false
    property bool hasNvidia: false   // detected once; avoids polling a missing binary

    function rebuild() {
        let data = {}
        try { data = JSON.parse(root.sensorsText || "{}") } catch (e) { data = {} }

        const groups = []
        let cpuMax = null, cpuCrit = false
        let ssdMax = null, ssdCrit = false
        let gpuTemp = null, gpuCrit = false, gpuIcon = Theme.icoSensIgpu, gpuPriority = 99
        let anyCrit = false

        for (const chipKey in data) {
            const chip = chipKey.split("-")[0]
            const obj = data[chipKey]
            if (typeof obj !== "object") continue

            const isCpu = (chip === "k10temp" || chip === "coretemp" || chip === "zenpower")
            const isAmd = (chip === "amdgpu")
            const isI915 = (chip === "i915")
            const isNvme = (chip === "nvme")
            if (!(isCpu || isAmd || isI915 || isNvme)) continue

            let amdHasMem = false
            if (isAmd) for (const f in obj) if (f.toLowerCase().indexOf("mem") >= 0) amdHasMem = true

            let chipIcon = "", header = chip, tag = chip
            if (isCpu) { chipIcon = Theme.icoSensCpu; header = "CPU" }
            else if (isAmd) { chipIcon = amdHasMem ? Theme.icoSensDgpu : Theme.icoSensIgpu
                              header = amdHasMem ? "Discrete GPU" : "Integrated GPU" }
            else if (isI915) { chipIcon = Theme.icoSensIgpu; header = "Integrated GPU" }
            else if (isNvme) { chipIcon = Theme.icoSensNvme; header = "NVMe SSD" }

            const rows = []
            let edgeMax = null
            for (const feat in obj) {
                const fv = obj[feat]
                if (typeof fv !== "object") continue
                let val = null, n = null
                for (const k in fv) { const m = /^temp(\d+)_input$/.exec(k); if (m) { val = fv[k]; n = m[1]; break } }
                if (val === null) continue

                const isMem = feat.toLowerCase().indexOf("mem") >= 0
                let thr = 0
                if (isCpu) thr = Theme.critCpu
                else if (isAmd) thr = isMem ? Theme.critVram : Theme.critDgpu
                else if (isI915) thr = Theme.critIgpu
                else if (isNvme) thr = Theme.critNvme
                const crit = thr > 0 && val >= thr           // headline: conservative Theme level
                if (crit) anyCrit = true

                // tooltip tier: prefer the hardware's own reported crit/max
                const rawCrit = fv["temp" + n + "_crit"], rawMax = fv["temp" + n + "_max"]
                const critLimit = root.sane(rawCrit) ? rawCrit : thr
                const warnLimit = root.sane(rawMax) ? rawMax : (critLimit > 0 ? 0.85 * critLimit : 0)
                const alarm = fv["temp" + n + "_crit_alarm"] === 1
                const tier = (alarm || (critLimit > 0 && val >= critLimit)) ? "crit"
                           : (warnLimit > 0 && val >= warnLimit) ? "warn" : "nominal"
                const ratio = critLimit > 0 ? Math.max(0, Math.min(1, val / critLimit)) : null
                rows.push({ kind: "temp", label: root.friendlyLabel(feat), val: val, unit: "°C",
                            critLimit: critLimit, tier: tier, ratio: ratio })

                if (isCpu) { cpuMax = (cpuMax === null) ? val : Math.max(cpuMax, val); if (crit) cpuCrit = true }
                else if (isNvme) { ssdMax = (ssdMax === null) ? val : Math.max(ssdMax, val); if (crit) ssdCrit = true }
                else if ((isAmd || isI915) && !isMem) edgeMax = (edgeMax === null) ? val : Math.max(edgeMax, val)
            }

            // dGPU context rows: fan RPM and power draw (always nominal, skip if absent).
            // Only the discrete GPU has a fan / meaningful power; the iGPU reads ~0 W.
            if (isAmd && amdHasMem) {
                for (const feat in obj) {
                    const fv = obj[feat]
                    if (typeof fv !== "object") continue
                    if ("fan1_input" in fv) {
                        const fmax = fv["fan1_max"]
                        rows.push({ kind: "fan", label: "Fan", val: fv["fan1_input"], unit: "rpm",
                                    critLimit: 0, tier: "nominal",
                                    ratio: root.sane(fmax) ? Math.min(1, fv["fan1_input"] / fmax) : null })
                    }
                    const pw = fv["power1_average"] !== undefined ? fv["power1_average"] : fv["power1_input"]
                    if (pw !== undefined) {
                        const cap = fv["power1_cap"]
                        rows.push({ kind: "power", label: "Power", val: pw, unit: "W",
                                    critLimit: (cap > 0) ? cap : 0, tier: "nominal",
                                    ratio: (cap > 0) ? Math.min(1, pw / cap) : null })
                    }
                }
            }

            if ((isAmd || isI915) && edgeMax !== null) {
                const pr = (isAmd && amdHasMem) ? 1 : 2
                if (pr < gpuPriority) {
                    gpuPriority = pr; gpuTemp = edgeMax
                    gpuIcon = (pr === 1) ? Theme.icoSensDgpu : Theme.icoSensIgpu
                    gpuCrit = edgeMax >= Theme.critDgpu
                }
            }
            if (rows.length) groups.push({ header: header, tag: tag, icon: chipIcon, rows: rows })
        }

        // NVIDIA via nvidia-smi
        const nv = parseInt((root.nvidiaText || "").trim())
        if (!isNaN(nv)) {
            const crit = nv >= Theme.critDgpu
            if (crit) anyCrit = true
            const tier = nv >= Theme.critDgpu ? "crit" : (nv >= 0.85 * Theme.critDgpu ? "warn" : "nominal")
            groups.push({ header: "GPU", tag: "nvidia", icon: Theme.icoSensDgpu,
                          rows: [{ kind: "temp", label: "GPU", val: nv, unit: "°C",
                                   critLimit: Theme.critDgpu, tier: tier,
                                   ratio: Math.max(0, Math.min(1, nv / Theme.critDgpu)) }] })
            if (1 < gpuPriority) { gpuPriority = 1; gpuTemp = nv; gpuIcon = Theme.icoSensDgpu; gpuCrit = crit }
        }

        const head = []
        if (cpuMax !== null) head.push({ icon: Theme.icoSensCpu, temp: Math.round(cpuMax), crit: cpuCrit, color: "#d93a3a" })
        if (gpuTemp !== null) head.push({ icon: gpuIcon, temp: Math.round(gpuTemp), crit: gpuCrit, color: "#d93a3a" })
        if (ssdMax !== null) head.push({ icon: Theme.icoSensNvme, temp: Math.round(ssdMax), crit: ssdCrit, color: Theme.fg })

        root.groups = groups
        root.headline = head
        root.anyCritical = anyCrit
    }

    // Reject threshold garbage: NVMe reports 65261.85 for unused sensors and
    // -273.15 as an "unset" sentinel; real limits sit in (0, 200).
    function sane(x) { return x !== undefined && x !== null && x > 0 && x < 200 }

    function friendlyLabel(feat) {
        const map = { "Tctl": "Tctl", "Tccd1": "CCD1", "edge": "Edge", "junction": "Junction",
                      "mem": "Memory", "Composite": "Composite", "GPU": "GPU" }
        if (map[feat]) return map[feat]
        if (/^Sensor \d+$/.test(feat)) return feat
        return feat.charAt(0).toUpperCase() + feat.slice(1)
    }

    function fmtVal(r) {
        if (r.kind === "temp") return r.val.toFixed(1) + "°C"
        return Math.round(r.val) + " " + r.unit
    }

    // 10-cell unicode gauge; blank when there's no meaningful limit.
    function barStr(ratio) {
        if (ratio === null || ratio === undefined) return "          "
        const f = Math.max(0, Math.min(10, Math.round(ratio * 10)))
        return "█".repeat(f) + "░".repeat(10 - f)
    }

    function tierColor(tier) {
        return tier === "crit" ? Theme.crit : (tier === "warn" ? Theme.warn : Theme.fg)
    }

    // "Junction     87.0°C  /110°   ██████░░░░" — monospace-aligned columns.
    function rowText(r) {
        const limitCol = (r.critLimit > 0)
            ? ("  /" + Math.round(r.critLimit) + (r.kind === "temp" ? "°" : "")) : ""
        return r.label.padEnd(11) + fmtVal(r).padStart(8)
            + limitCol.padEnd(6) + "  " + barStr(r.ratio)
    }

    Process {
        id: sensorsProc
        command: ["sensors", "-j"]
        stdout: StdioCollector {
            onStreamFinished: { root.sensorsText = this.text; root.rebuild() }
        }
    }
    Process {
        id: nvidiaProc
        command: ["nvidia-smi", "--query-gpu=temperature.gpu", "--format=csv,noheader,nounits"]
        stdout: StdioCollector {
            onStreamFinished: { root.nvidiaText = this.text; root.rebuild() }
        }
    }
    // One-time probe so we only poll nvidia-smi on machines that have it.
    Process {
        id: nvidiaProbe
        command: ["sh", "-c", "command -v nvidia-smi"]
        onExited: (code, status) => { root.hasNvidia = (code === 0) }
    }
    Component.onCompleted: nvidiaProbe.running = true

    Timer {
        interval: 2000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: { sensorsProc.running = true; if (root.hasNvidia) nvidiaProc.running = true }
    }

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 10

        // placeholder when nothing detected yet
        Icon {
            visible: root.headline.length === 0
            text: Theme.icoSensCpu
        }

        Repeater {
            model: root.headline
            RowLayout {
                required property var modelData
                spacing: 5
                Icon {
                    text: modelData.icon
                    color: modelData.crit ? Theme.crit : modelData.color
                }
                Text {
                    text: modelData.temp + "°"
                    color: modelData.crit ? Theme.crit : Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                }
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: Quickshell.execDetached(["kitty", "-e", "btop"])
        onEntered: menu.anchorHovered = true
        onExited: menu.anchorHovered = false
    }

    PopupMenu {
        id: menu
        anchorItem: root

        // One section per chip: colored title + dimmed tag, a dimmed column
        // header, then one Text per sensor row (each row carries its own tier
        // color, so rows can't share a single aligned RichText block).
        Repeater {
            model: root.groups

            ColumnLayout {
                id: section
                required property var modelData
                required property int index
                spacing: 4

                Rectangle {
                    visible: section.index > 0
                    Layout.fillWidth: true
                    Layout.topMargin: 4
                    Layout.bottomMargin: 2
                    implicitHeight: 1
                    color: Theme.sep
                }
                RowLayout {
                    spacing: 6
                    Icon {
                        text: section.modelData.icon
                        color: Theme.fg
                        size: Theme.iconSizeSmall
                    }
                    Text {
                        textFormat: Text.RichText
                        text: section.modelData.header
                            + ' <span style="color:' + Theme.sep + '">· ' + section.modelData.tag + "</span>"
                        color: Theme.fg
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize
                        font.bold: true
                    }
                }
                Text {
                    text: "sensor".padEnd(11) + "value".padStart(8) + "".padEnd(6) + "  " + "gauge"
                    color: Theme.sep
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }
                Repeater {
                    model: section.modelData.rows
                    Text {
                        required property var modelData
                        text: root.rowText(modelData)
                        color: root.tierColor(modelData.tier)
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                    }
                }
            }
        }
        Text {
            visible: root.groups.length === 0
            text: "no sensors detected"
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }
        MenuButton {
            label: "Open btop"
            onTriggered: Quickshell.execDetached(["kitty", "-e", "btop"])
        }
    }
}
