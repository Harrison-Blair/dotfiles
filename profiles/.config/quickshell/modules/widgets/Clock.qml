import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.services
import qs.components

// Two clocks (UTC + local) on the bar face, matching waybar's clock#utc /
// clock#local. Hover opens a rich tooltip: hero time/date, world clocks, a mini
// month calendar, and ISO week / day-of-year / uptime.
Item {
    id: root
    implicitWidth: row.implicitWidth
    implicitHeight: row.implicitHeight
    Layout.alignment: Qt.AlignVCenter

    property var now: new Date()
    Timer {
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.now = new Date()
    }

    // Tooltip palette (harmonizes with Theme's pink/dark scheme; from Memory.qml).
    readonly property color dimFg: Qt.rgba(1, 1, 1, 0.75)
    readonly property color faintFg: Qt.rgba(1, 1, 1, 0.5)

    // World clocks. Local + UTC need no subprocess; the rest are filled from
    // tzOffsets once the batched `date` Process returns (fallback: those rows hide).
    readonly property var zones: [
        { label: "Local",       key: "" },
        { label: "UTC",         key: "UTC" },
        { label: "Los Angeles", key: "America/Los_Angeles" },
        { label: "New York",    key: "America/New_York" },
        { label: "London",      key: "Europe/London" },
        { label: "Tokyo",       key: "Asia/Tokyo" },
        { label: "New Delhi",   key: "Asia/Kolkata" }
    ]
    // { "America/New_York": -240, ... } minutes east of UTC. Empty until fetched.
    property var tzOffsets: ({})
    property real uptimeSecs: 0

    function pad(n) { return n < 10 ? "0" + n : "" + n }
    function utcTime() {
        const d = root.now
        return "UTC " + pad(d.getUTCHours()) + ":" + pad(d.getUTCMinutes()) + ":" + pad(d.getUTCSeconds())
    }
    function localTime() {
        return Qt.formatDateTime(root.now, "t") + " " + Qt.formatDateTime(root.now, "HH:mm:ss")
    }

    // Offset (minutes east of UTC) for a zone key, or undefined if not yet known.
    function offsetFor(key) {
        if (key === "") return -root.now.getTimezoneOffset()
        if (key === "UTC") return 0
        return root.tzOffsets[key]
    }
    // Wall-clock parts for a given offset, read via UTC fields after shifting.
    function zoneParts(offsetMin) {
        const d = new Date(root.now.getTime() + offsetMin * 60000)
        return { h: d.getUTCHours(), m: d.getUTCMinutes(),
                 key: Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()) }
    }
    function zoneTime(offsetMin) {
        const p = zoneParts(offsetMin)
        return pad(p.h) + ":" + pad(p.m)
    }
    // "+1d" / "-1d" when the zone's calendar day differs from local.
    function zoneMarker(offsetMin) {
        const localKey = zoneParts(-root.now.getTimezoneOffset()).key
        const delta = Math.round((zoneParts(offsetMin).key - localKey) / 86400000)
        return delta > 0 ? "+" + delta + "d" : delta < 0 ? delta + "d" : ""
    }

    // ISO-8601 week number (weeks start Monday; week 1 contains the first Thursday).
    function isoWeek(d) {
        const dt = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()))
        dt.setUTCDate(dt.getUTCDate() - ((dt.getUTCDay() + 6) % 7) + 3)  // this week's Thursday
        const firstThu = new Date(Date.UTC(dt.getUTCFullYear(), 0, 4))
        firstThu.setUTCDate(firstThu.getUTCDate() - ((firstThu.getUTCDay() + 6) % 7) + 3)
        return 1 + Math.round((dt - firstThu) / 604800000)
    }
    function dayOfYear(d) {
        return Math.floor((d - new Date(d.getFullYear(), 0, 0)) / 86400000)
    }
    function fmtUptime(secs) {
        const s = Math.floor(secs)
        const dd = Math.floor(s / 86400)
        const hh = Math.floor((s % 86400) / 3600)
        const mm = Math.floor((s % 3600) / 60)
        return (dd > 0 ? dd + "d " : "") + hh + "h " + mm + "m"
    }

    // Month grid as a flat array: leading blanks (0), 1..daysInMonth, trailing
    // blanks to complete the last week. Monday-first to match ISO week numbers.
    readonly property var calModel: {
        const y = root.now.getFullYear(), m = root.now.getMonth()
        const lead = (new Date(y, m, 1).getDay() + 6) % 7
        const dim = new Date(y, m + 1, 0).getDate()
        const a = []
        for (let i = 0; i < lead; i++) a.push(0)
        for (let d = 1; d <= dim; d++) a.push(d)
        while (a.length % 7 !== 0) a.push(0)
        return a
    }

    // Batched offset fetch: one Process for all named zones, only while open.
    Process {
        id: tzProc
        command: ["sh", "-c",
            "for z in America/Los_Angeles America/New_York Europe/London Asia/Tokyo Asia/Kolkata; do printf '%s %s\\n' \"$z\" \"$(TZ=$z date +%z)\"; done"]
        stdout: StdioCollector {
            onStreamFinished: {
                const map = {}
                for (const line of this.text.split("\n")) {
                    const m = line.match(/^(\S+)\s+([+-]\d{4})$/)
                    if (m) {
                        const sign = m[2][0] === "-" ? -1 : 1
                        map[m[1]] = sign * (parseInt(m[2].substr(1, 2)) * 60 + parseInt(m[2].substr(3, 2)))
                    }
                }
                root.tzOffsets = map
            }
        }
    }
    Timer {
        interval: 300000   // re-fetch occasionally so a mid-session DST flip is caught
        running: menu.visible
        repeat: true
        triggeredOnStart: true
        onTriggered: tzProc.running = true
    }

    FileView {
        id: uptimeFile
        path: "/proc/uptime"
        onLoaded: root.uptimeSecs = parseFloat(text().trim().split(/\s+/)[0])
    }
    Timer {
        interval: 60000
        running: menu.visible
        repeat: true
        triggeredOnStart: true
        onTriggered: uptimeFile.reload()
    }

    // Reserve the world-clock time column so rows never jitter as seconds tick.
    TextMetrics {
        id: timeMetrics
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 1
        text: "00:00"
    }

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 16
        Text {
            text: root.utcTime()
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }
        Text {
            text: root.localTime()
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: menu.anchorHovered = true
        onExited: menu.anchorHovered = false
    }

    // --- Tooltip building blocks (copied from Memory.qml's conventions) ---

    // Section header: pink label left, dimmed detail right.
    component SectionHeader: RowLayout {
        property string label
        property string detail
        Layout.preferredWidth: 290
        Layout.fillWidth: true
        Text {
            text: parent.label
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }
        Item { Layout.fillWidth: true }
        Text {
            text: parent.detail
            color: root.dimFg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
        }
    }

    component Separator: Rectangle {
        Layout.fillWidth: true
        Layout.topMargin: 4
        Layout.bottomMargin: 4
        implicitHeight: 1
        color: Qt.alpha(Theme.sep, 0.35)
    }

    // World-clock row: zone label left, day marker + right-aligned time.
    component ClockRow: RowLayout {
        property string label
        property int offsetMin: 0
        Layout.fillWidth: true
        spacing: 8
        Text {
            text: parent.label
            color: root.dimFg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 1
        }
        Item { Layout.fillWidth: true }
        Text {
            text: root.zoneMarker(parent.offsetMin)
            color: root.faintFg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 3
            Layout.alignment: Qt.AlignVCenter
        }
        Text {
            Layout.preferredWidth: timeMetrics.width
            text: root.zoneTime(parent.offsetMin)
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 1
            horizontalAlignment: Text.AlignRight
        }
    }

    // Single calendar cell: centered day number, accent pill behind today.
    component CalCell: Item {
        property int day: 0
        property bool today: false
        implicitWidth: 30
        implicitHeight: 26
        Rectangle {
            anchors.centerIn: parent
            width: 24
            height: 22
            radius: 4
            color: Qt.alpha(Theme.accent, 0.5)
            visible: parent.today
        }
        Text {
            anchors.centerIn: parent
            visible: parent.day > 0
            text: parent.day
            color: parent.today ? Theme.fg : root.dimFg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
        }
    }

    PopupMenu {
        id: menu
        anchorItem: root

        // Whole tooltip body in one wrapper so the subtle fade/rise-in is
        // contained here (PopupMenu stays untouched, other widgets unaffected).
        ColumnLayout {
            id: body
            spacing: 6
            opacity: menu.visible ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }
            transform: Translate {
                y: menu.visible ? 0 : 8
                Behavior on y { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            }

            // Hero: large local time over the full date.
            ColumnLayout {
                spacing: 0
                Layout.alignment: Qt.AlignHCenter
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: Qt.formatDateTime(root.now, "HH:mm:ss")
                    color: Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize + 12
                    font.bold: true
                }
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: Qt.formatDateTime(root.now, "dddd, MMMM d, yyyy")
                    color: root.dimFg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
                }
            }

            Separator {}

            SectionHeader { label: "Clocks" }
            Repeater {
                model: root.zones
                ClockRow {
                    visible: root.offsetFor(modelData.key) !== undefined
                    label: modelData.label
                    offsetMin: root.offsetFor(modelData.key) || 0
                }
            }

            Separator {}

            SectionHeader { label: Qt.formatDateTime(root.now, "MMMM yyyy") }
            Grid {
                columns: 7
                Layout.alignment: Qt.AlignHCenter
                Repeater {
                    model: ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
                    Item {
                        implicitWidth: 30
                        implicitHeight: 16
                        Text {
                            anchors.centerIn: parent
                            text: modelData
                            color: root.faintFg
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 4
                        }
                    }
                }
            }
            Grid {
                columns: 7
                Layout.alignment: Qt.AlignHCenter
                Repeater {
                    model: root.calModel
                    CalCell {
                        day: modelData
                        today: modelData === root.now.getDate()
                    }
                }
            }

            Separator {}

            Text {
                Layout.fillWidth: true
                text: "Week " + root.isoWeek(root.now) + "  ·  Day " + root.dayOfYear(root.now) + " / 365"
                color: root.dimFg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
            }
            Text {
                Layout.fillWidth: true
                text: "Up " + root.fmtUptime(root.uptimeSecs)
                color: root.dimFg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
            }
        }
    }
}
