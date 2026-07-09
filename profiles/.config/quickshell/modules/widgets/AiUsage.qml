import QtQuick
import QtQuick.Layouts
import qs.services
import qs.services as Services
import qs.components

// AI usage at a glance (Claude Code / OpenCode / Cursor). The shared
// services/AiUsage.qml singleton runs scripts/ai-usage.py every 60s (API
// calls throttled to 5min inside the script) and feeds all bar instances.
// Bar shows one segment per provider: icon in the provider's color, then
// session% / weekly% / monthly% + 30-day cost in the default fg; hover
// popup has limits/resets and day/week/month cost + token breakdowns.
Item {
    id: root
    implicitWidth: row.implicitWidth
    implicitHeight: Theme.groupHeight
    Layout.alignment: Qt.AlignVCenter

    readonly property var stats: Services.AiUsage.stats

    function fmtUsd(v) {
        return (v === undefined || v === null) ? "$--" : "$" + v.toFixed(2)
    }
    // Bar-only $: comma-grouped, fixed width for $9,999.99 (4 integer
    // digits + 2 decimals). The "$" hugs the number; padding sits to the
    // left of the "$" so the segment doesn't jiggle as values change.
    function fmtUsdBar(v) {
        let s
        if (v === undefined || v === null) {
            s = "--"
        } else {
            const f = v.toFixed(2)
            const dot = f.indexOf(".")
            const grouped = f.slice(0, dot).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
            s = grouped + f.slice(dot)
        }
        return ("$" + s).padStart(9," ")
    }
    function fmtTok(v) {
        if (v === undefined || v === null) return "--"
        if (v >= 1e6) return (v / 1e6).toFixed(1) + "M"
        if (v >= 1e3) return Math.round(v / 1e3) + "K"
        return "" + v
    }
    // ISO timestamp -> local "HH:mm" (today) or "ddd HH:mm"
    function fmtReset(iso) {
        if (!iso) return "--"
        const d = new Date(iso)
        const hm = d.toLocaleTimeString(Qt.locale(), "HH:mm")
        return d.toDateString() === new Date().toDateString()
            ? hm : d.toLocaleDateString(Qt.locale(), "ddd") + " " + hm
    }
    // ISO timestamp -> "in 2h 14m" / "in 3d 5h" countdown from now.
    function fmtCountdown(iso) {
        if (!iso) return "--"
        let ms = new Date(iso).getTime() - Date.now()
        if (ms <= 0) return "now"
        const m = Math.floor(ms / 60000)
        if (m < 60) return "in " + m + "m"
        const h = Math.floor(m / 60)
        if (h < 24) return "in " + h + "h " + (m % 60) + "m"
        return "in " + Math.floor(h / 24) + "d " + (h % 24) + "h"
    }

    // One percentage, warn/crit-colored; dimmed when the provider is stale.
    function pctSpan(v, dim, warn = 70, crit = 90) {
        // Fixed width for 3 digits + "%" (e.g. "100%"), right-aligned with
        // non-breaking spaces so the segment doesn't jiggle as values change.
        const num = (v === undefined || v === null ? "--" : "" + v).padStart(3, " ")
        if (v === undefined || v === null) return num + "%"
        let color = null
        if (dim) color = Theme.sep
        else if (v >= crit) color = Theme.crit
        else if (v >= warn) color = Theme.warn
        return color ? '<span style="color:' + color + '">' + num + "%</span>" : num + "%"
    }
    // Bar segment: "session% / weekly% [/ monthly%] $monthly-cost".
    // weekThresholds ([warn, crit]) lets Claude's weekly slot match the ntfy
    // alert policy while the other slots keep the defaults.
    function segText(prov, showMonth, weekThresholds) {
        const l = prov && prov.limits
        const dim = prov ? prov.status !== "ok" : false
        const wt = weekThresholds || []
        let s = pctSpan(l ? l.session_pct : null, dim)
            + " / " + pctSpan(l ? l.week_pct : null, dim, wt[0], wt[1])
        if (showMonth !== false) s += " / " + pctSpan(l ? l.month_pct : null, dim)
        const cost = prov && prov.usage ? prov.usage.month.cost : null
        return s + " " + fmtUsdBar(cost)
    }
    // "limits: statusline · 12s ago" — which source supplied the displayed
    // 5h/weekly figures and how old that reading is.
    function limitsFooter(lim) {
        if (!lim || !lim.source) return ""
        let s = "limits: " + lim.source
        if (lim.source_at) {
            const sec = Math.max(0, Math.round(Date.now() / 1000 - lim.source_at))
            const age = sec < 60 ? sec + "s"
                : sec < 3600 ? Math.floor(sec / 60) + "m"
                : Math.floor(sec / 3600) + "h"
            s += " · " + age + " ago"
        }
        return s
    }

    function usageRow(label, w) {
        return label.padEnd(9) + fmtUsd(w.cost).padStart(8) + "  "
            + (fmtTok(w.input) + " / " + fmtTok(w.output)).padStart(15)
    }
    function usageBlock(u) {
        return " ".repeat(9) + "cost".padStart(8) + "  " + "in / out".padStart(15) + "\n"
            + usageRow("Today", u.day) + "\n"
            + usageRow("7 days", u.week) + "\n"
            + usageRow("30 days", u.month)
    }
    // Comma-grouped $ with no fixed padding (for the per-model tables).
    function fmtUsdG(v) {
        if (v === undefined || v === null) return "$--"
        const f = v.toFixed(2), dot = f.indexOf(".")
        return "$" + f.slice(0, dot).replace(/\B(?=(\d{3})+(?!\d))/g, ",") + f.slice(dot)
    }
    // Model id -> compact label: drop the "claude-" prefix and a trailing
    // "-YYYYMMDD" date; truncate anything still too wide for the name column.
    function shortModel(name) {
        let s = name.replace(/^claude-/, "").replace(/-\d{8}$/, "")
        return s.length > 15 ? s.slice(0, 14) + "…" : s
    }
    function hasModels(p) { return !!(p && p.models && p.models.length > 0) }

    // --- Per-model cost table (allTime adds the "all" column, Claude only) ---
    function costCols(allTime) { return allTime ? ["day", "week", "month", "all"] : ["day", "week", "month"] }
    function costHeader(allTime) {
        const h = allTime ? ["today", "7d", "30d", "all"] : ["today", "7d", "30d"]
        return "by model".padEnd(15) + h.map(x => x.padStart(10)).join("")
    }
    function costRows(models, allTime) {
        if (!root.hasModels({models: models})) return ""
        return models.map(m => root.shortModel(m.name).padEnd(15)
            + root.costCols(allTime).map(c => root.fmtUsdG(m.cost[c]).padStart(10)).join("")).join("\n")
    }
    function costTotal(models, allTime) {
        if (!root.hasModels({models: models})) return ""
        const sum = c => models.reduce((a, m) => a + (m.cost[c] || 0), 0)
        return "Total".padEnd(15) + root.costCols(allTime).map(c => root.fmtUsdG(sum(c)).padStart(10)).join("")
    }

    // --- Per-model token table (in/out over day/7d/30d) ---
    function tokPair(inTok, outTok) { return fmtTok(inTok) + "/" + fmtTok(outTok) }
    function tokHeader() {
        return "tokens in/out".padEnd(15) + ["today", "7d", "30d"].map(x => x.padStart(11)).join("")
    }
    function tokRows(models) {
        if (!root.hasModels({models: models})) return ""
        return models.map(m => root.shortModel(m.name).padEnd(15)
            + ["day", "week", "month"].map(c => root.tokPair(m.in[c], m.out[c]).padStart(11)).join("")).join("\n")
    }
    function tokTotal(models) {
        if (!root.hasModels({models: models})) return ""
        const sum = (k, c) => models.reduce((a, m) => a + (m[k][c] || 0), 0)
        return "Total".padEnd(15) + ["day", "week", "month"].map(c =>
            root.tokPair(sum("in", c), sum("out", c)).padStart(11)).join("")
    }
    function claudeLimitsBlock() {
        const lim = root.stats.claude.limits
        if (!lim) return "no limit data"
        let s = "Session " + ((lim.session_pct === null ? "--" : lim.session_pct) + "%").padStart(4)
            + "   resets " + fmtReset(lim.session_resets_at)
        s += "\nWeek    " + ((lim.week_pct === null ? "--" : lim.week_pct) + "%").padStart(4)
            + "   resets " + fmtReset(lim.week_resets_at)
        if (lim.week_opus_pct !== null && lim.week_opus_pct !== undefined)
            s += "\nOpus wk " + (lim.week_opus_pct + "%").padStart(4)
        if (lim.month_pct !== null && lim.month_pct !== undefined)
            s += "\nExtra   " + (lim.month_pct + "%").padStart(4)
        return s
    }
    function opencodeLimitsBlock() {
        const lim = root.stats.opencode.limits
        if (!lim) return "no limit data"
        return "5h      " + (lim.session_pct + "%").padStart(4) + "   " + fmtUsd(lim.session_usd) + " / $12"
            + "   resets " + fmtCountdown(lim.session_resets_at)
            + "\nWeek    " + (lim.week_pct + "%").padStart(4) + "   " + fmtUsd(lim.week_usd) + " / $30"
            + "   resets " + fmtCountdown(lim.week_resets_at)
            + "\nMonth   " + (lim.month_pct + "%").padStart(4) + "   " + fmtUsd(lim.month_usd) + " / $60"
            + "   resets " + fmtCountdown(lim.month_resets_at)
    }
    function cursorLimitsBlock() {
        const lim = root.stats.cursor.limits
        if (!lim) return "no plan data"
        let s = "Plan    " + (lim.plan_pct + "%").padStart(6)
        if (lim.plan_limit_usd > 0)
            s += "   " + fmtUsd(lim.plan_used_usd) + " / " + fmtUsd(lim.plan_limit_usd)
        s += "   renews " + fmtReset(lim.cycle_end)
        return s
    }

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 6

        Icon {
            text: Theme.icoAi
            color: Theme.aiClaude
            Layout.leftMargin: 2
        }
        Text {
            textFormat: Text.RichText
            text: root.segText(root.stats ? root.stats.claude : null, false, [60, 85])
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }
        Text {
            text: "|"
            color: Theme.sep
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }
        Icon {
            text: Theme.icoOpencode
            color: Theme.fg
        }
        Text {
            textFormat: Text.RichText
            text: root.segText(root.stats ? root.stats.opencode : null)
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            Layout.rightMargin: 2
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

        // One section per provider: colored title, optional error line,
        // monospace limits + day/week/month rows.
        Repeater {
            model: root.stats ? [
                {
                    title: "Claude Code",
                    icon: Theme.icoAi,
                    tag: (root.stats.claude.limits && root.stats.claude.limits.plan) || "",
                    color: Theme.aiClaude,
                    p: root.stats.claude,
                    limits: root.stats.claude.status === "error" ? "" : root.claudeLimitsBlock(),
                    footer: root.limitsFooter(root.stats.claude.limits)
                },
                {
                    title: "OpenCode",
                    icon: Theme.icoOpencode,
                    tag: "opencode-go",
                    color: Theme.fg,
                    p: root.stats.opencode,
                    limits: root.stats.opencode.status === "error" ? "" : root.opencodeLimitsBlock()
                },
                {
                    title: "Cursor",
                    icon: Theme.icoCursor,
                    tag: (root.stats.cursor.limits && root.stats.cursor.limits.membership) || "",
                    color: Theme.aiCursor,
                    p: root.stats.cursor,
                    limits: root.stats.cursor.status === "error" ? "" : root.cursorLimitsBlock()
                }
            ] : []

            ColumnLayout {
                id: section
                required property var modelData
                required property int index
                readonly property var p: modelData.p
                readonly property bool allTime: modelData.title === "Claude Code"
                readonly property bool showModels: root.hasModels(p) && p.status !== "error"
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
                        color: section.modelData.color
                        size: Theme.iconSizeSmall
                    }
                    Text {
                        textFormat: Text.RichText
                        text: section.modelData.title
                            + (section.modelData.tag
                               ? ' <span style="color:' + Theme.sep + '">· ' + section.modelData.tag + "</span>" : "")
                        color: section.modelData.color
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize
                        font.bold: true
                    }
                }
                Text {
                    visible: section.modelData.p.error !== null
                    text: "⚠ " + section.modelData.p.error
                    color: Theme.warn
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }
                Text {
                    visible: section.modelData.p.status === "idle"
                    text: "idle — app not running, showing cached limits"
                    color: Theme.sep
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }
                Text {
                    visible: section.modelData.limits !== ""
                    text: section.modelData.limits
                    color: Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }
                Text {
                    visible: (section.modelData.footer || "") !== ""
                    text: section.modelData.footer || ""
                    color: Theme.sep
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }
                // Providers without a model breakdown (Cursor): the combined
                // cost + token totals block.
                Text {
                    visible: section.p.status !== "error" && !root.hasModels(section.p)
                    text: root.usageBlock(section.p.usage)
                    color: Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }

                // --- Per-model cost table: dimmed header, rows, rule, Total ---
                Text {
                    visible: section.showModels
                    text: root.costHeader(section.allTime)
                    color: Theme.sep
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }
                Text {
                    visible: section.showModels
                    text: root.costRows(section.p.models, section.allTime)
                    color: Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }
                Rectangle {
                    visible: section.showModels
                    Layout.fillWidth: true
                    Layout.topMargin: 2
                    Layout.bottomMargin: 2
                    implicitHeight: 1
                    color: Theme.sep
                }
                Text {
                    visible: section.showModels
                    text: root.costTotal(section.p.models, section.allTime)
                    color: Theme.fg
                    font.bold: true
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }

                // --- Per-model token table: dimmed header, rows, rule, Total ---
                Text {
                    visible: section.showModels
                    Layout.topMargin: 2
                    text: root.tokHeader()
                    color: Theme.sep
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }
                Text {
                    visible: section.showModels
                    text: root.tokRows(section.p.models)
                    color: Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }
                Rectangle {
                    visible: section.showModels
                    Layout.fillWidth: true
                    Layout.topMargin: 2
                    Layout.bottomMargin: 2
                    implicitHeight: 1
                    color: Theme.sep
                }
                Text {
                    visible: section.showModels
                    text: root.tokTotal(section.p.models)
                    color: Theme.fg
                    font.bold: true
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }
}
        }
        Text {
            visible: !root.stats
            text: "loading…"
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }
        MenuButton {
            label: "Refresh now"
            onTriggered: Services.AiUsage.refresh()
        }
    }
}
