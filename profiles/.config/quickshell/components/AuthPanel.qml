import QtQuick
import QtQuick.Effects
import Quickshell.Io
import qs.services
import qs.components

// Shared visual + input surface for the greeter and the lock screen. Owns the
// blurred wallpaper, frosted card, clock, animated password dots, reveal toggle,
// caps-lock indicator and shake-on-fail. It knows nothing about Greetd vs PAM:
// it only emits submitted() and exposes slots the host drives. See
// components-hosts: greeter.qml / services/Lock.qml.
Item {
    id: panel

    // --- Inputs (host -> panel) ---
    property real uiScale: 1.0          // greeter passes 1.5, lock passes 1.0
    property bool showUser: false       // greeter: true (editable username)
    property string userText: "penguin" // initial username
    property url wallpaperSource: ""    // background image; blurred at runtime
    property string errorMsg: ""        // host writes; drives the error line
    property bool busy: false           // host sets between submit and result
    property bool showCard: true        // secondary lock monitors: bg + clock only
    property bool showStatus: false     // lock: battery + now-playing

    // Status feeds (lock only; kept as plain props so the greeter never pulls
    // session-only UPower/Mpris services).
    property int batteryPct: -1         // <0 hides the battery chip
    property bool batteryCharging: false
    property string mediaTitle: ""
    property string mediaArtist: ""

    // --- Output (panel -> host) ---
    signal submitted(string username, string password)

    // --- Slots the host calls ---
    function focusInput() { pw.forceActiveFocus() }
    function clearPassword() { pw.text = "" }
    function reportFailure() { pw.text = ""; shakeAnim.restart(); pw.forceActiveFocus() }

    // --- internal state ---
    property bool revealed: false
    property bool capsOn: false
    property var now: new Date()

    // Integer device pixels for a scaled logical size (crisp text/borders).
    function px(v) { return Math.round(v * panel.uiScale) }

    function trySubmit() {
        if (panel.busy)
            return
        panel.submitted(panel.showUser ? userInput.text : "", pw.text)
    }

    function battGlyph() {
        if (panel.batteryCharging) return Theme.icoBatCharging
        const p = panel.batteryPct
        if (p < 10) return Theme.icoBat[0]
        if (p < 25) return Theme.icoBat[1]
        if (p < 50) return Theme.icoBat[2]
        if (p < 75) return Theme.icoBat[3]
        return Theme.icoBat[4]
    }

    Timer {
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: panel.now = new Date()
    }

    // Caps Lock state, polled from the authoritative sysfs LED (world-readable,
    // works for both `greeter` and the user). Only while a field is focused.
    // Best-effort: if no LED node exists the read yields 0 and the warning stays
    // hidden.
    Process {
        id: capsProc
        command: ["sh", "-c", "cat /sys/class/leds/*::capslock/brightness 2>/dev/null | grep -m1 . || echo 0"]
        stdout: StdioCollector {
            onStreamFinished: panel.capsOn = this.text.trim() === "1"
        }
    }
    Timer {
        interval: 400
        running: pw.activeFocus || userInput.activeFocus
        repeat: true
        triggeredOnStart: true
        onTriggered: capsProc.running = true
    }

    // --- Background: opaque base, blurred wallpaper, dim overlay ---
    Rectangle {
        anchors.fill: parent
        color: "#1e1e1e"
    }
    Image {
        id: wp
        anchors.fill: parent
        source: panel.wallpaperSource
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        visible: false          // sampled by the effect, not drawn directly
    }
    MultiEffect {
        anchors.fill: parent
        source: wp
        blurEnabled: true
        blur: 1.0
        blurMax: 64
        brightness: -0.35
        saturation: -0.1
        visible: wp.status === Image.Ready
    }
    // Extra darkening for text contrast over bright wallpapers.
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.28)
    }

    // --- Foreground: clock over the frosted card ---
    Column {
        anchors.centerIn: parent
        spacing: panel.px(28)

        // Clock + date
        Column {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: panel.px(2)
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Qt.formatDateTime(panel.now, "HH:mm")
                color: "white"
                font.family: Theme.fontFamily
                font.pixelSize: panel.px(Theme.authTimeSize)
                font.bold: true
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Qt.formatDateTime(panel.now, "dddd, MMMM d")
                color: Theme.dimFg
                font.family: Theme.fontFamily
                font.pixelSize: panel.px(Theme.fontSize)
            }
        }

        // Card wrapper — the shake target. Kept separate from the background so
        // the blur effect never re-renders when the card animates.
        Item {
            id: cardWrap
            visible: panel.showCard
            anchors.horizontalCenter: parent.horizontalCenter
            width: card.width
            height: card.height
            property real shakeX: 0

            // Soft drop shadow (samples a hidden clone, never the live input).
            Rectangle {
                id: cardShadowSrc
                anchors.fill: card
                radius: card.radius
                color: "black"
                visible: false
            }
            MultiEffect {
                anchors.fill: card
                source: cardShadowSrc
                shadowEnabled: true
                shadowColor: Qt.rgba(0, 0, 0, 0.55)
                shadowBlur: 1.0
                shadowVerticalOffset: panel.px(8)
                blurMax: 32
                autoPaddingEnabled: true
                z: -1
            }

            Rectangle {
                id: card
                x: cardWrap.shakeX
                width: panel.px(360)
                height: cardCol.implicitHeight + panel.px(36)
                radius: Theme.radius
                color: Theme.glassBg
                border.width: 1
                border.color: Theme.glassBorder

                // Click anywhere on the card refocuses the password field. Sits
                // below the content so the eye toggle / inputs get events first.
                MouseArea {
                    anchors.fill: parent
                    onClicked: pw.forceActiveFocus()
                }

                Column {
                    id: cardCol
                    anchors.centerIn: parent
                    width: card.width - panel.px(40)
                    spacing: panel.px(14)

                    Icon {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: Theme.icoLock
                        color: Theme.fg
                        size: panel.px(30)
                    }

                    // Username (greeter only). Always instantiated so its id is
                    // valid; hidden on the lock.
                    Rectangle {
                        visible: panel.showUser
                        width: parent.width
                        height: panel.px(44)
                        radius: Theme.radius
                        color: Qt.rgba(1, 1, 1, 0.06)
                        border.width: 1
                        border.color: userInput.activeFocus ? Theme.accent : Theme.border

                        TextInput {
                            id: userInput
                            anchors.fill: parent
                            anchors.leftMargin: panel.px(16)
                            anchors.rightMargin: panel.px(16)
                            verticalAlignment: TextInput.AlignVCenter
                            text: panel.userText
                            color: Theme.fg
                            font.family: Theme.fontFamily
                            font.pixelSize: panel.px(Theme.fontSize)
                            clip: true
                            enabled: !panel.busy
                            onAccepted: pw.forceActiveFocus()
                            KeyNavigation.tab: pw
                        }
                    }

                    // Password field: always-present TextInput (never toggle its
                    // visibility — that drops Wayland focus). When masked, its
                    // glyphs are hidden and the animated dots overlay stands in.
                    Rectangle {
                        id: pwBox
                        width: parent.width
                        height: panel.px(44)
                        radius: Theme.radius
                        color: Qt.rgba(1, 1, 1, 0.06)
                        border.width: 1
                        border.color: pw.activeFocus ? Theme.accent : Theme.border

                        TextInput {
                            id: pw
                            anchors.fill: parent
                            anchors.leftMargin: panel.px(16)
                            anchors.rightMargin: panel.px(44)   // room for the eye
                            verticalAlignment: TextInput.AlignVCenter
                            echoMode: panel.revealed ? TextInput.Normal : TextInput.Password
                            passwordCharacter: " "               // invisible mask; dots stand in
                            color: panel.revealed ? Theme.fg : "transparent"
                            cursorVisible: panel.revealed && activeFocus
                            font.family: Theme.fontFamily
                            font.pixelSize: panel.px(Theme.fontSize)
                            clip: true
                            focus: true
                            enabled: !panel.busy
                            onAccepted: panel.trySubmit()
                            KeyNavigation.backtab: userInput
                        }

                        // Animated dots: a fixed pool whose per-dot visibility
                        // tracks the length. Only the newly-shown dot animates
                        // in; existing dots are never recreated, so typing
                        // doesn't flash the whole row.
                        Row {
                            id: dots
                            anchors.left: pwBox.left
                            anchors.leftMargin: panel.px(16)
                            anchors.verticalCenter: pwBox.verticalCenter
                            spacing: panel.px(6)
                            visible: !panel.revealed && pw.text.length > 0
                            Repeater {
                                model: 64
                                Rectangle {
                                    visible: index < pw.text.length
                                    width: panel.px(9)
                                    height: panel.px(9)
                                    radius: width / 2
                                    color: Theme.fg
                                    anchors.verticalCenter: parent.verticalCenter
                                    scale: visible ? 1 : 0
                                    Behavior on scale {
                                        NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
                                    }
                                }
                            }
                        }

                        // Reveal toggle.
                        Icon {
                            anchors.right: pwBox.right
                            anchors.rightMargin: panel.px(12)
                            anchors.verticalCenter: pwBox.verticalCenter
                            text: panel.revealed ? Theme.icoEyeOff : Theme.icoEye
                            color: eyeArea.containsMouse ? Theme.fg : Theme.dimFg
                            size: panel.px(Theme.iconSizeSmall)
                            MouseArea {
                                id: eyeArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    panel.revealed = !panel.revealed
                                    pw.forceActiveFocus()
                                }
                            }
                        }
                    }

                    // Caps Lock warning.
                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: panel.px(6)
                        visible: panel.capsOn
                        Icon {
                            text: Theme.icoCapsLock
                            color: Theme.warn
                            size: panel.px(Theme.iconSizeSmall)
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            text: "Caps Lock is on"
                            color: Theme.warn
                            font.family: Theme.fontFamily
                            font.pixelSize: panel.px(Theme.fontSize - 2)
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    // Error line.
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: panel.errorMsg !== ""
                        text: panel.errorMsg
                        color: Theme.crit
                        font.family: Theme.fontFamily
                        font.pixelSize: panel.px(Theme.fontSize - 1)
                    }

                    // Status (lock only): battery + now-playing.
                    Column {
                        width: parent.width
                        spacing: panel.px(10)
                        visible: panel.showStatus
                                 && (panel.batteryPct >= 0 || panel.mediaTitle !== "")

                        Rectangle {
                            width: parent.width
                            height: 1
                            color: Theme.sep
                            opacity: 0.4
                        }

                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: panel.px(8)
                            visible: panel.batteryPct >= 0
                            Icon {
                                text: panel.battGlyph()
                                color: Theme.dimFg
                                size: panel.px(Theme.iconSizeSmall)
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                text: panel.batteryPct + "%"
                                color: Theme.dimFg
                                font.family: Theme.fontFamily
                                font.pixelSize: panel.px(Theme.fontSize - 1)
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        Text {
                            width: parent.width
                            visible: panel.mediaTitle !== ""
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                            text: "♪  " + panel.mediaTitle
                                  + (panel.mediaArtist !== "" ? "  —  " + panel.mediaArtist : "")
                            color: Theme.dimFg
                            font.family: Theme.fontFamily
                            font.pixelSize: panel.px(Theme.fontSize - 2)
                        }
                    }
                }
            }
        }
    }

    // Shake: horizontal wobble on the card wrapper, decaying to rest.
    SequentialAnimation {
        id: shakeAnim
        NumberAnimation { target: cardWrap; property: "shakeX"; to: panel.px(12);  duration: 40 }
        NumberAnimation { target: cardWrap; property: "shakeX"; to: panel.px(-10); duration: 40 }
        NumberAnimation { target: cardWrap; property: "shakeX"; to: panel.px(7);   duration: 40 }
        NumberAnimation { target: cardWrap; property: "shakeX"; to: panel.px(-4);  duration: 40 }
        NumberAnimation { target: cardWrap; property: "shakeX"; to: 0;             duration: 40 }
    }
}
