pragma Singleton
import Quickshell
import QtQuick

Singleton {
    id: theme

    // --- Layout ---
    readonly property int barHeight: 54
    readonly property int groupHeight: 46
    readonly property int radius: 23
    readonly property int pad: 18          // horizontal padding inside a group
    readonly property int gap: 8           // gap between groups / bar side margins
    readonly property int itemSpacing: 8   // spacing between items within a group

    // --- Typography ---
    // Single family + fontconfig fallback to the Nerd Font, exactly as the
    // old waybar setup relied on (Noto Sans Mono falls back for glyphs).
    readonly property string fontFamily: "Noto Sans Mono"
    readonly property int fontSize: 16
    readonly property int iconSize: 38     // enlarged Nerd Font glyphs

    // --- Palette (lifted from waybar style.css / scripts) ---
    readonly property color fg: "#ff7cff"                       // rgb(255,124,255)
    readonly property color groupBg: Qt.rgba(30/255, 30/255, 30/255, 0.66)
    readonly property color menuBg: Qt.rgba(30/255, 30/255, 30/255, 0.92)
    readonly property color border: "#666666"
    readonly property color sep: "#666666"
    readonly property color warn: "#ff9977"                     // cpu orange @ 87.5%
    readonly property color crit: "#dd532e"                     // critical red
    readonly property color wifiWeak: "#ffffa5"                 // weak signal yellow
    readonly property color wifiBad: "#dd532e"                  // bad signal red
    readonly property color accent: Qt.rgba(175/255, 75/255, 175/255, 1.0)
    readonly property color accentActive: Qt.rgba(175/255, 75/255, 175/255, 0.75)

    // --- Sensor critical thresholds (°C), from scripts/sensors.sh ---
    readonly property int critCpu: 85
    readonly property int critDgpu: 90
    readonly property int critIgpu: 90
    readonly property int critVram: 95
    readonly property int critNvme: 75

    // --- Nerd Font glyphs (codepoints extracted from the waybar config/scripts
    //     so they match exactly; referenced by codepoint to avoid PUA bytes) ---
    readonly property string icoVolMute: String.fromCodePoint(0xF0E08)
    readonly property string icoVolLow:  String.fromCodePoint(0xF057F)
    readonly property string icoVolMid:  String.fromCodePoint(0xF027)
    readonly property string icoVolHigh: String.fromCodePoint(0xF028)

    readonly property string icoNetDown: String.fromCodePoint(0xF063)
    readonly property string icoNetUp:   String.fromCodePoint(0xF062)
    readonly property string icoNetDisc: String.fromCodePoint(0xF0BE1)
    readonly property string icoEthernet: String.fromCodePoint(0xF0200)
    // wifi signal strength, weakest → strongest (waybar format-icons)
    readonly property var icoWifi: [
        String.fromCodePoint(0xF092F),  // bad    (red)
        String.fromCodePoint(0xF091F),  // weak   (yellow)
        String.fromCodePoint(0xF0922),
        String.fromCodePoint(0xF0925),
        String.fromCodePoint(0xF0928)
    ]

    readonly property string icoMem: String.fromCodePoint(0xEFC5)
    readonly property string icoCpu: String.fromCodePoint(0xF4BC)
    readonly property string icoReload: String.fromCodePoint(0xF00E2)

    // sensors (scripts/sensors.sh)
    readonly property string icoSensCpu:    String.fromCodePoint(0xF4BC)
    readonly property string icoSensDgpu:   String.fromCodePoint(0xF08AE)
    readonly property string icoSensIgpu:   String.fromCodePoint(0xF035B)
    readonly property string icoSensGpuMem: String.fromCodePoint(0xF09F6)
    readonly property string icoSensNvme:   String.fromCodePoint(0xF02CA)

    // battery (scripts/battery.sh): charging, then <10 <25 <50 <75 >=75
    readonly property string icoBatCharging: String.fromCodePoint(0xF0084)
    readonly property var icoBat: [
        String.fromCodePoint(0xF008E),  // <10
        String.fromCodePoint(0xF007B),  // <25
        String.fromCodePoint(0xF007E),  // <50
        String.fromCodePoint(0xF0080),  // <75
        String.fromCodePoint(0xF0082)   // >=75
    ]

    // cpu per-core load blocks ▁▂▃▄▅▆▇█
    readonly property var cpuBlocks: ["▁","▂","▃","▄","▅","▆","▇","█"]
}
