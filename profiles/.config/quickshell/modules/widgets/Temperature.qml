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

            let chipIcon = "", header = chip
            if (isCpu) chipIcon = Theme.icoSensCpu
            else if (isAmd) { chipIcon = amdHasMem ? Theme.icoSensDgpu : Theme.icoSensIgpu
                              header = amdHasMem ? "amdgpu (dGPU)" : "amdgpu (iGPU)" }
            else if (isI915) chipIcon = Theme.icoSensIgpu
            else if (isNvme) chipIcon = Theme.icoSensNvme

            const rows = []
            let edgeMax = null
            for (const feat in obj) {
                const fv = obj[feat]
                if (typeof fv !== "object") continue
                let val = null
                for (const k in fv) if (/^temp\d+_input$/.test(k)) { val = fv[k]; break }
                if (val === null) continue

                const isMem = feat.toLowerCase().indexOf("mem") >= 0
                let thr = 0
                if (isCpu) thr = Theme.critCpu
                else if (isAmd) thr = isMem ? Theme.critVram : Theme.critDgpu
                else if (isI915) thr = Theme.critIgpu
                else if (isNvme) thr = Theme.critNvme
                const crit = thr > 0 && val >= thr
                if (crit) anyCrit = true

                rows.push({ label: feat, val: val, crit: crit,
                            icon: (isAmd && isMem) ? Theme.icoSensGpuMem : "" })

                if (isCpu) { cpuMax = (cpuMax === null) ? val : Math.max(cpuMax, val); if (crit) cpuCrit = true }
                else if (isNvme) { ssdMax = (ssdMax === null) ? val : Math.max(ssdMax, val); if (crit) ssdCrit = true }
                else if ((isAmd || isI915) && !isMem) edgeMax = (edgeMax === null) ? val : Math.max(edgeMax, val)
            }

            if ((isAmd || isI915) && edgeMax !== null) {
                const pr = (isAmd && amdHasMem) ? 1 : 2
                if (pr < gpuPriority) {
                    gpuPriority = pr; gpuTemp = edgeMax
                    gpuIcon = (pr === 1) ? Theme.icoSensDgpu : Theme.icoSensIgpu
                    gpuCrit = edgeMax >= Theme.critDgpu
                }
            }
            if (rows.length) groups.push({ header: header, icon: chipIcon, rows: rows })
        }

        // NVIDIA via nvidia-smi
        const nv = parseInt((root.nvidiaText || "").trim())
        if (!isNaN(nv)) {
            const crit = nv >= Theme.critDgpu
            if (crit) anyCrit = true
            groups.push({ header: "nvidia", icon: Theme.icoSensDgpu,
                          rows: [{ label: "GPU", val: nv, crit: crit, icon: "" }] })
            if (1 < gpuPriority) { gpuPriority = 1; gpuTemp = nv; gpuIcon = Theme.icoSensDgpu; gpuCrit = crit }
        }

        const head = []
        if (cpuMax !== null) head.push({ icon: Theme.icoSensCpu, temp: Math.round(cpuMax), crit: cpuCrit })
        if (gpuTemp !== null) head.push({ icon: gpuIcon, temp: Math.round(gpuTemp), crit: gpuCrit })
        if (ssdMax !== null) head.push({ icon: Theme.icoSensNvme, temp: Math.round(ssdMax), crit: ssdCrit })

        root.groups = groups
        root.headline = head
        root.anyCritical = anyCrit
    }

    function menuHtml() {
        let s = ""
        for (const g of root.groups) {
            if (s) s += "<br/>"
            s += (g.icon ? g.icon + "  " : "") + g.header
            for (const r of g.rows) {
                const prefix = r.icon ? r.icon + " " : "&nbsp;&nbsp;"
                const valStr = r.val.toFixed(1) + "°C"
                const v = r.crit ? '<span style="color:' + Theme.crit + '">' + valStr + '</span>' : valStr
                s += "<br/>" + prefix + r.label + "&nbsp;&nbsp;" + v
            }
        }
        return s || "no sensors detected"
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
                    color: modelData.crit ? Theme.crit : Theme.fg
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
        onEntered: menu.anchorHovered = true
        onExited: menu.anchorHovered = false
    }

    PopupMenu {
        id: menu
        anchorItem: root
        Text {
            textFormat: Text.RichText
            text: root.menuHtml()
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 1
            lineHeight: 1.15
        }
        MenuButton {
            label: "Open sensors"
            command: ["kitty", "-e", "watch", "-n", "1", "sensors"]
            onTriggered: menu.visible = false
        }
    }
}
