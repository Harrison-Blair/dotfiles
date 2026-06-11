pragma Singleton
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pam
import Quickshell.Io
import QtQuick
import qs.services

// In-process screen lock. Engaged via Lock.lock() (power menu) or the "lock"
// IPC target (`qs ipc call lock lock`). Authenticates against the
// `quickshell-lock` PAM service and only releases once PAM reports success.
// If quickshell dies while locked, a conformant compositor keeps the screen
// locked and solid — failure is secure, not exposed.
Singleton {
    id: root

    // Wipe of every surface's input field after a failed attempt.
    signal cleared()
    property string errorMsg: ""

    function lock() {
        if (sessionLock.locked)
            return
        root.errorMsg = ""
        sessionLock.locked = true
        pam.start()
    }

    // Submit the typed password to the waiting PAM conversation.
    function submit(pw) {
        if (pam.responseRequired)
            pam.respond(pw)
    }

    WlSessionLock {
        id: sessionLock
        locked: false

        // One surface per screen. Drawn opaque (transparent lock surfaces are
        // buggy per the v0.3.0 docs).
        surface: WlSessionLockSurface {
            id: surface
            color: "#1e1e1e"

            Component.onCompleted: pwInput.forceActiveFocus()

            Column {
                anchors.centerIn: parent
                spacing: 18

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Theme.icoLock
                    color: Theme.fg
                    font.family: Theme.iconFont
                    font.pixelSize: 64
                }

                // Password box.
                Rectangle {
                    width: 280
                    height: 40
                    radius: Theme.radius
                    color: Qt.rgba(1, 1, 1, 0.06)
                    border.width: 1
                    border.color: Theme.border

                    TextInput {
                        id: pwInput
                        anchors.fill: parent
                        anchors.leftMargin: 14
                        anchors.rightMargin: 14
                        verticalAlignment: TextInput.AlignVCenter
                        echoMode: TextInput.Password
                        passwordCharacter: "•"
                        color: Theme.fg
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize
                        clip: true
                        focus: true
                        onAccepted: root.submit(text)

                        Connections {
                            target: root
                            function onCleared() { pwInput.text = "" }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: pwInput.forceActiveFocus()
                    }
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: root.errorMsg !== ""
                    text: root.errorMsg
                    color: Theme.crit
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
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
