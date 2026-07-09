pragma Singleton
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pam
import Quickshell.Services.UPower
import Quickshell.Services.Mpris
import Quickshell.Io
import QtQuick
import qs.services
import qs.components

// In-process screen lock. Engaged via Lock.lock() (power menu) or the "lock"
// IPC target (`qs ipc call lock lock`). Authenticates against the
// `quickshell-lock` PAM service and only releases once PAM reports success.
// If quickshell dies while locked, a conformant compositor keeps the screen
// locked and solid — failure is secure, not exposed.
//
// The visuals live in the shared components/AuthPanel.qml (also used by the
// greeter); this singleton wires it to PAM and feeds it live status.
Singleton {
    id: root

    // Wipe of every surface's input field after a failed attempt.
    signal cleared()
    property string errorMsg: ""

    // Wallpaper for the lock: the live `awww` wallpaper, resolved at lock time,
    // falling back to the bundled asset.
    property url wallpaperUrl: Theme.wallpaper

    function lock() {
        if (sessionLock.locked)
            return
        root.errorMsg = ""
        wpProc.running = true      // refresh the live wallpaper for this lock
        sessionLock.locked = true
        pam.start()
    }

    // Submit the typed password to the waiting PAM conversation.
    function submit(pw) {
        if (pam.responseRequired)
            pam.respond(pw)
    }

    // Resolve the current awww wallpaper: `awww query` prints
    //   ": <output>: ..., currently displaying: image: /path/to.jpg"
    Process {
        id: wpProc
        command: ["sh", "-c", "awww query 2>/dev/null | sed -n 's/.*image: //p' | head -1"]
        stdout: StdioCollector {
            onStreamFinished: {
                const p = this.text.trim()
                if (p.length > 0)
                    root.wallpaperUrl = "file://" + p
            }
        }
    }

    // --- Battery (UPower; same source as the bar's Battery widget) ---
    readonly property var batteryDev: UPower.displayDevice
    readonly property int batteryPct: {
        if (!batteryDev || !batteryDev.isLaptopBattery)
            return -1
        const r = batteryDev.percentage
        return Math.round(r <= 1.0 ? r * 100 : r)
    }
    readonly property bool batteryCharging: batteryDev
        && (batteryDev.state === UPowerDeviceState.Charging
            || batteryDev.state === UPowerDeviceState.FullyCharged)

    // --- Now-playing (Mpris): the first playing player, else the first present ---
    readonly property var mediaPlayer: {
        const model = Mpris.players
        const ps = (model && model.values) ? model.values : []
        for (let i = 0; i < ps.length; i++)
            if (ps[i] && ps[i].isPlaying)
                return ps[i]
        return ps.length > 0 ? ps[0] : null
    }
    readonly property string mediaTitle: (mediaPlayer && mediaPlayer.trackTitle) ? mediaPlayer.trackTitle : ""
    readonly property string mediaArtist: (mediaPlayer && mediaPlayer.trackArtist) ? mediaPlayer.trackArtist : ""

    WlSessionLock {
        id: sessionLock
        locked: false

        // One surface per screen. Drawn opaque (transparent lock surfaces are
        // buggy per the v0.3.0 docs); the wallpaper image covers it.
        surface: WlSessionLockSurface {
            id: surface
            color: "black"

            // Only one Wayland surface can hold keyboard focus, so the full
            // card + status + focus live on the primary screen; other monitors
            // show just the blurred wallpaper + clock.
            readonly property bool primary: Quickshell.screens.length > 0
                && surface.screen === Quickshell.screens[0]

            Component.onCompleted: if (surface.primary) panel.focusInput()

            AuthPanel {
                id: panel
                anchors.fill: parent
                uiScale: 1.0
                showUser: false
                showCard: surface.primary
                showStatus: surface.primary
                wallpaperSource: root.wallpaperUrl
                errorMsg: root.errorMsg
                batteryPct: root.batteryPct
                batteryCharging: root.batteryCharging
                mediaTitle: root.mediaTitle
                mediaArtist: root.mediaArtist
                onSubmitted: (username, password) => root.submit(password)
            }

            Connections {
                target: root
                function onCleared() {
                    if (surface.primary)
                        panel.reportFailure()   // wipe + shake + refocus
                    else
                        panel.clearPassword()
                }
            }
        }
    }

    PamContext {
        id: pam
        config: "quickshell-lock"

        onCompleted: (result) => {
            if (result === PamResult.Success) {
                sessionLock.locked = false
                root.errorMsg = ""
                root.cleared()
            } else {
                root.errorMsg = "Authentication failed"
                root.cleared()
                pam.start()   // re-arm for the next attempt
            }
        }

        onError: (error) => {
            root.errorMsg = "PAM error"
            root.cleared()
        }
    }

    IpcHandler {
        target: "lock"
        function lock(): void { root.lock() }
    }
}
