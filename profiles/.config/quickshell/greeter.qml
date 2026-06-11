import Quickshell
import Quickshell.Services.Greetd
import QtQuick
import qs.services

// greetd graphical greeter. Run under cage before login:
//   cage -s -- qs -p /home/penguin/.config/quickshell/greeter.qml
// cage fullscreens this single xdg-toplevel. On successful PAM auth greetd
// launches the session and quickshell exits (launch() quits by default).
ShellRoot {
    id: app

    property string errorMsg: ""
    property string pendingPassword: ""

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
        if (username.length === 0)
            return
        app.errorMsg = ""
        app.pendingPassword = password
        Greetd.createSession(username)
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
            app.errorMsg = (message && message.length) ? message : "Authentication failed"
            app.pendingPassword = ""
        }

        function onError(message) {
            app.errorMsg = message
            app.pendingPassword = ""
        }
    }

    FloatingWindow {
        color: "#1e1e1e"
        screen: app.targetScreen
        fullscreen: true

        Component.onCompleted: userInput.forceActiveFocus()

        Column {
            anchors.centerIn: parent
            spacing: 20 * app.s

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Theme.icoLock
                color: Theme.fg
                font.family: Theme.iconFont
                font.pixelSize: 72 * app.s
            }

            // Username
            Rectangle {
                width: 320 * app.s
                height: 42 * app.s
                radius: Theme.radius
                color: Qt.rgba(1, 1, 1, 0.06)
                border.width: 1
                border.color: userInput.activeFocus ? Theme.accent : Theme.border

                TextInput {
                    id: userInput
                    anchors.fill: parent
                    anchors.leftMargin: 16 * app.s
                    anchors.rightMargin: 16 * app.s
                    verticalAlignment: TextInput.AlignVCenter
                    text: "penguin"
                    color: Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize * app.s
                    clip: true
                    onAccepted: passInput.forceActiveFocus()
                    KeyNavigation.tab: passInput
                }
            }

            // Password
            Rectangle {
                width: 320 * app.s
                height: 42 * app.s
                radius: Theme.radius
                color: Qt.rgba(1, 1, 1, 0.06)
                border.width: 1
                border.color: passInput.activeFocus ? Theme.accent : Theme.border

                TextInput {
                    id: passInput
                    anchors.fill: parent
                    anchors.leftMargin: 16 * app.s
                    anchors.rightMargin: 16 * app.s
                    verticalAlignment: TextInput.AlignVCenter
                    echoMode: TextInput.Password
                    passwordCharacter: "•"
                    color: Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize * app.s
                    clip: true
                    onAccepted: {
                        app.submit(userInput.text, text)
                        text = ""
                    }
                    KeyNavigation.backtab: userInput
                }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: app.errorMsg !== ""
                text: app.errorMsg
                color: Theme.crit
                font.family: Theme.fontFamily
                font.pixelSize: (Theme.fontSize - 1) * app.s
            }
        }
    }
}
