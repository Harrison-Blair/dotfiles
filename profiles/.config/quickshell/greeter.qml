import Quickshell
import Quickshell.Services.Greetd
import QtQuick
import qs.services
import qs.components

// greetd graphical greeter. Run under cage before login:
//   cage -s -- qs -p /home/penguin/.config/quickshell/greeter.qml
// cage fullscreens this single xdg-toplevel. On successful PAM auth greetd
// launches the session and quickshell exits (launch() quits by default).
// The visuals live in the shared components/AuthPanel.qml (also used by the
// lock screen); this file only wires it to the Greetd backend.
ShellRoot {
    id: app

    property string errorMsg: ""
    property string pendingPassword: ""
    property bool busy: false          // true between submit and result; gates re-submit

    // Pin the greeter to DP-1 (cage exposes wlroots connector names). Fall back
    // to the first output if DP-1 isn't present.
    readonly property var targetScreen: {
        const list = Quickshell.screens
        for (let i = 0; i < list.length; i++)
            if (list[i].name === "DP-1")
                return list[i]
        return list.length > 0 ? list[0] : null
    }
    readonly property real s: 1.5   // global UI scale

    function submit(username, password) {
        if (app.busy || username.length === 0)
            return
        app.errorMsg = ""
        app.busy = true
        app.pendingPassword = password
        Greetd.createSession(username)
    }

    // Reset after a failed/aborted attempt: clear state, unlock input, shake.
    function fail(message) {
        app.errorMsg = (message && message.length) ? message : "Authentication failed"
        app.pendingPassword = ""
        app.busy = false
        panel.reportFailure()
    }

    Connections {
        target: Greetd

        // PAM prompt — hand over the stored password when one is requested.
        function onAuthMessage(message, error, responseRequired, echoResponse) {
            if (error)
                app.errorMsg = message
            if (responseRequired)
                Greetd.respond(app.pendingPassword)
        }

        function onReadyToLaunch() {
            Greetd.launch(["/usr/bin/start-hyprland"])
        }

        function onAuthFailure(message) {
            app.fail(message)
        }

        function onError(message) {
            app.fail(message)
        }
    }

    FloatingWindow {
        color: "black"
        screen: app.targetScreen
        fullscreen: true

        Component.onCompleted: panel.focusInput()

        AuthPanel {
            id: panel
            anchors.fill: parent
            uiScale: app.s
            showUser: true
            userText: "penguin"
            wallpaperSource: Theme.wallpaper
            errorMsg: app.errorMsg
            busy: app.busy
            onSubmitted: (username, password) => app.submit(username, password)
        }
    }
}
