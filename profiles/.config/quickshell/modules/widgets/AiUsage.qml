import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.services
import qs.components

// AI usage at a glance (Claude Code / OpenCode / Cursor). scripts/ai-usage.py
// aggregates local transcripts, the OpenCode db and vendor APIs into one JSON
// blob every 60s (API calls throttled to 5min inside the script). Bar shows
// one segment per provider: session% / weekly% / monthly% + 30-day cost, in
// the provider's base color; hover popup has limits/resets and day/week/month
// cost + token breakdowns.
Item {
    id: root
    implicitWidth: row.implicitWidth
    implicitHeight: Theme.groupHeight
    Layout.alignment: Qt.AlignVCenter

    property var stats: null

    function fmtUsd(v) {
        return (v === undefined || v === null) ? "$--" : "$" + v.toFixed(2)
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

    // One percentage, warn/crit-colored; dimmed when the provider is stale.
    function pctSpan(v, dim) {
        if (v === undefined || v === null) return "--%"
        let color = null
        if (dim) color = Theme.sep
        else if (v >= 90) color = Theme.crit
        else if (v >= 70) color = Theme.warn
        return color ? '<span style="color:' + color + '">' + v + "%</span>" : v + "%"
    }
    // Bar segment: "session% / weekly% [/ monthly%] $monthly-cost"
    function segText(prov, showMonth) {
        const l = prov && prov.limits
        const dim = prov ? prov.status !== "ok" : false
        const pcts = [l ? l.session_pct : null, l ? l.week_pct : null]
        if (showMonth !== false) pcts.push(l ? l.month_pct : null)
        const cost = prov && prov.usage ? prov.usage.month.cost : null
        return pcts.map(v => pctSpan(v, dim)).join(" / ") + " " + fmtUsd(cost)
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
            + "\nWeek    " + (lim.week_pct + "%").padStart(4) + "   " + fmtUsd(lim.week_usd) + " / $30"
            + "\nMonth   " + (lim.month_pct + "%").padStart(4) + "   " + fmtUsd(lim.month_usd) + " / $60"
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

    Process {
        id: proc
        command: ["python3", Quickshell.env("HOME") + "/.config/quickshell/scripts/ai-usage.py"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.stats = JSON.parse(this.text) } catch (e) {}
            }
        }
    }
    Timer {
        interval: 60000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!proc.running) proc.running = true
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
            text: root.segText(root.stats ? root.stats.claude : null, false)
            color: Theme.aiClaude
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
                    tag: (root.stats.claude.limits && root.stats.claude.limits.plan) || "",
                    color: Theme.aiClaude,
                    p: root.stats.claude,
                    limits: root.stats.claude.status === "error" ? "" : root.claudeLimitsBlock()
                },
                {
                    title: "OpenCode",
                    tag: "opencode-go",
                    color: Theme.fg,
                    p: root.stats.opencode,
                    limits: root.stats.opencode.status === "error" ? "" : root.opencodeLimitsBlock()
                },
                {
                    title: "Cursor",
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
                spacing: 4

                Rectangle {
                    visible: section.index > 0
                    Layout.fillWidth: true
                    Layout.topMargin: 4
                    Layout.bottomMargin: 2
                    implicitHeight: 1
                    color: Theme.sep
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
                Text {
                    visible: section.modelData.p.error !== null
                    text: "⚠ " + section.modelData.p.error
                    color: Theme.warn
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
                    visible: section.modelData.p.status !== "error"
                    text: root.usageBlock(section.modelData.p.usage)
                    color: Theme.fg
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
    }
}
