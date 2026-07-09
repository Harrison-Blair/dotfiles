pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Discrete-GPU poller, shared by the Gpu usage widget and the Temperature widget
// so vendor/slot detection and (crucially) the GPU-waking polling happen exactly
// once instead of per-widget.
//
// Vendor-adaptive: the dGPU driver + PCI slot are detected from sysfs at startup,
// then either amdgpu (sysfs busy% + `amdgpu_top`) or NVIDIA (`nvidia-smi`) fills a
// common set of reactive properties. The render side is vendor-agnostic — it just
// draws `busy`, `engines[]`, clocks, VRAM, `power`, `temp`, and `procs[]`.
//
// Battery/RTD3: laptop dGPUs enter D3cold when idle. Polling `nvidia-smi` would
// force-wake them, so every tick first reads power/runtime_status and, while the
// GPU is suspended, reports an idle state without spawning anything.
Singleton {
    id: root

    // --- Detected once at startup ---
    property string vendor: ""       // "nvidia" | "amd" | "none"
    property string pci: ""          // canonical slot, e.g. "0000:01:00.0"
    property string name: "GPU"      // marketing name for the header label
    readonly property bool present: vendor === "nvidia" || vendor === "amd"
    readonly property string sysfs: pci ? "/sys/bus/pci/devices/" + pci : ""

    // --- Reactive state (common shape across vendors) ---
    property bool suspended: false   // dGPU in runtime-PM D3; reported as idle
    property real busy: 0            // overall GPU busy fraction 0..1
    property var hist: []            // overall busy ring buffer (0..1)
    property real vramUsed: 0        // MiB
    property real vramTotal: 0       // MiB
    property var engines: []         // [{label, val 0..1}] per-domain activity
    property var engHist: []         // per-engine history ring buffers
    property int sclk: 0             // shader / SM clock (MHz)
    property int mclk: 0             // memory clock (MHz)
    property var power: null         // board power (W) or null
    property var temp: null          // edge temperature (°C) or null
    property var procs: []           // top GPU processes [{pct, comm}]

    // Set true by the usage widget while its tooltip is open; gates the expensive
    // per-process poll (amdgpu_top / nvidia-smi pmon) to only run when visible.
    property bool detailWanted: false

    // --- Detection: find the dGPU driver + canonical slot from sysfs. Prefer
    //     nvidia over amdgpu if (improbably) both are bound. ---
    Process {
        id: detect
        command: ["sh", "-c",
            "for drv in nvidia amdgpu; do for d in /sys/bus/pci/drivers/$drv/0000:*; do " +
            "[ -e \"$d\" ] && { echo \"$drv $(basename $d)\"; exit 0; }; done; done"]
        stdout: StdioCollector {
            onStreamFinished: {
                const parts = this.text.trim().split(/\s+/)
                if (parts.length === 2) {
                    root.vendor = (parts[0] === "nvidia") ? "nvidia" : "amd"
                    root.pci = parts[1]
                    if (root.vendor === "nvidia") nvName.running = true
                    poll.running = true
                }
            }
        }
    }
    Component.onCompleted: detect.running = true

    // One-shot NVIDIA marketing name for the header label.
    Process {
        id: nvName
        command: ["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"]
        stdout: StdioCollector { onStreamFinished: { const s = this.text.trim(); if (s) root.name = s } }
    }

    // --- Suspend gate: read runtime_status each tick; drives active vs idle. ---
    FileView {
        id: rtStatus
        path: root.sysfs ? root.sysfs + "/power/runtime_status" : ""
        onLoaded: root.onStatus(this.text().trim())
        onLoadFailed: root.onStatus("active")   // no runtime PM → always poll
    }

    function onStatus(s) {
        if (s === "suspended") {
            root.markIdle()
        } else {
            root.suspended = false
            if (root.vendor === "nvidia") {
                if (!nvQuery.running) nvQuery.running = true
            } else {
                busyFile.reload(); vramUsedFile.reload(); vramTotalFile.reload()
            }
        }
    }

    // Report a powered-down dGPU: flat sparkline, zeroed meters, no clocks/temp.
    function markIdle() {
        root.suspended = true
        root.busy = 0
        root.hist = root.hist.concat(0).slice(-24)
        root.sclk = 0; root.mclk = 0; root.power = null; root.temp = null
        root.vramUsed = 0
        root.procs = []
        if (root.engines.length) {
            const z = root.engines.map(e => ({ label: e.label, val: 0 }))
            root.engines = z
            root.pushEngHist(z.map(e => 0))
        }
    }

    function pushEngHist(vals) {
        const eh = root.engHist.slice()
        if (eh.length !== vals.length) { eh.length = 0; for (let i = 0; i < vals.length; i++) eh.push([]) }
        for (let i = 0; i < vals.length; i++) eh[i] = eh[i].concat(vals[i]).slice(-10)
        root.engHist = eh
    }

    Timer {
        id: poll
        interval: 1000
        running: false
        repeat: true
        triggeredOnStart: true
        onTriggered: rtStatus.reload()
    }

    // ======================= NVIDIA backend =======================
    // One query returns everything cheaply, so headline + tooltip stats all
    // refresh each tick (no cheap/expensive split needed like amdgpu).
    Process {
        id: nvQuery
        command: ["nvidia-smi",
            "--query-gpu=utilization.gpu,utilization.memory,utilization.encoder,utilization.decoder," +
            "memory.used,memory.total,temperature.gpu,clocks.sm,clocks.mem,power.draw",
            "--format=csv,noheader,nounits"]
        stdout: StdioCollector { onStreamFinished: root.parseNvidia(this.text) }
    }

    function parseNvidia(t) {
        const f = t.trim().split(",").map(x => parseFloat(x.trim()))
        if (f.length < 10 || isNaN(f[0])) return
        root.busy = f[0] / 100
        root.hist = root.hist.concat(root.busy).slice(-24)

        // Memory (f[1], utilization.memory) is intentionally omitted: it reads a
        // stuck 100% on NVIDIA laptop GPUs and would show a permanent red bar.
        // VRAM capacity is covered by its own meter.
        const eng = [
            { label: "GPU",     val: f[0] / 100 },
            { label: "Encoder", val: f[2] / 100 },
            { label: "Decoder", val: f[3] / 100 }
        ]
        root.engines = eng
        root.pushEngHist(eng.map(e => e.val))

        root.vramUsed = f[4]
        root.vramTotal = f[5]
        root.temp = isNaN(f[6]) ? null : f[6]
        root.sclk = isNaN(f[7]) ? 0 : Math.round(f[7])
        root.mclk = isNaN(f[8]) ? 0 : Math.round(f[8])
        root.power = isNaN(f[9]) ? null : Math.round(f[9] * 10) / 10
    }

    // Per-process (tooltip only). pmon lists graphics + compute apps, unlike
    // --query-compute-apps which omits graphics (games/browsers).
    Process {
        id: nvMon
        command: ["nvidia-smi", "pmon", "-c", "1"]
        stdout: StdioCollector { onStreamFinished: root.parsePmon(this.text) }
    }

    function parsePmon(t) {
        const rows = []
        for (const line of t.split("\n")) {
            if (!line.trim() || line.trim()[0] === "#") continue
            const p = line.trim().split(/\s+/)
            if (p.length < 4 || !/^\d+$/.test(p[1])) continue   // no pid → idle row
            const sm = parseInt(p[3]); if (isNaN(sm)) continue
            rows.push({ pct: sm, comm: p[p.length - 1] })
        }
        rows.sort((a, b) => b.pct - a.pct)
        root.procs = rows.slice(0, 6)
    }

    // ======================= amdgpu backend =======================
    // Cheap always-on data from PCI-stable sysfs (busy% + VRAM).
    // Paths gated on vendor so NVIDIA machines don't auto-read absent amdgpu files.
    readonly property string amdSysfs: root.vendor === "amd" ? root.sysfs : ""
    FileView {
        id: busyFile
        path: root.amdSysfs ? root.amdSysfs + "/gpu_busy_percent" : ""
        onLoaded: {
            root.busy = (parseInt(text()) || 0) / 100
            root.hist = root.hist.concat(root.busy).slice(-24)
        }
    }
    FileView {
        id: vramUsedFile
        path: root.amdSysfs ? root.amdSysfs + "/mem_info_vram_used" : ""
        onLoaded: root.vramUsed = (parseInt(text()) || 0) / 1048576
    }
    FileView {
        id: vramTotalFile
        path: root.amdSysfs ? root.amdSysfs + "/mem_info_vram_total" : ""
        onLoaded: root.vramTotal = (parseInt(text()) || 0) / 1048576
    }

    // Richer per-engine / per-process breakdown from amdgpu_top (~1s sample);
    // only run while the tooltip wants detail.
    Process {
        id: amdTop
        command: ["amdgpu_top", "--pci", root.pci, "-J", "-n", "1"]
        stdout: StdioCollector { onStreamFinished: root.parseAmd(this.text) }
    }

    function parseAmd(t) {
        let d
        try { d = JSON.parse(t) } catch (e) { return }
        if (!d.devices || d.devices.length === 0) return
        const dev = d.devices[0]
        if (dev.Info && dev.Info.DeviceName) root.name = dev.Info.DeviceName
        const grbm = dev.GRBM || {}
        const grbm2 = dev.GRBM2 || {}
        function g(sec, k) { const o = sec[k]; return (o && o.value != null) ? o.value / 100 : 0 }

        const defs = [
            ["GFX",      grbm,  "Graphics Pipe"],
            ["Shader",   grbm,  "Shader Processor Interpolator"],
            ["Texture",  grbm,  "Texture Pipe"],
            ["Color",    grbm,  "Color Block"],
            ["Depth",    grbm,  "Depth Block"],
            ["Geometry", grbm,  "Geometry Engine"],
            ["Compute",  grbm2, "Command Processor -  Compute"],
            ["Copy",     grbm2, "SDMA"]
        ]
        const eng = defs.map(x => ({ label: x[0], val: g(x[1], x[2]) }))
        root.engines = eng
        root.pushEngHist(eng.map(e => e.val))

        const s = dev.Sensors || {}
        function sv(k) { const o = s[k]; return (o && o.value != null) ? o.value : null }
        root.sclk = sv("GFX_SCLK") || 0
        root.mclk = sv("GFX_MCLK") || 0
        root.power = sv("GFX Power")

        const fd = dev.fdinfo || {}
        const rows = []
        for (const pid in fd) {
            const u = (fd[pid].usage && fd[pid].usage.usage) || {}
            function pv(k) { const o = u[k]; return (o && o.value != null) ? o.value : 0 }
            rows.push({ pct: pv("GFX") + pv("Compute") + pv("Media"), comm: fd[pid].name, vram: pv("VRAM") })
        }
        rows.sort((a, b) => (b.pct - a.pct) || (b.vram - a.vram))
        root.procs = rows.slice(0, 6)
    }

    // Per-process poll while the tooltip is open (both vendors, when awake).
    Timer {
        interval: 1500
        running: root.detailWanted && !root.suspended && root.present
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (root.vendor === "nvidia") { if (!nvMon.running) nvMon.running = true }
            else if (root.vendor === "amd") { if (!amdTop.running) amdTop.running = true }
        }
    }
}
