// SDDM — "LUMEN"
// The ONLY authentication surface in this setup. It began as the login-screen
// sibling of hypr/hyprlock.conf; hyprlock has since been removed, so this
// screen is now the whole of LUMEN's auth design — and the only place the
// machine ever asks who you are.
//
//   · LIGHT IS THE MATERIAL — fills approach zero; form is drawn by a luminous
//     rim and a chromatic dispersion across it (cool violet at one edge, warm
//     peach at the other). That prism is the signature.
//   · QUIET BY DEFAULT — chrome nearly dissolves into the wallpaper; nothing
//     is painted until it matters.
//   · CONCENTRIC, LIQUID GEOMETRY — nothing is boxed; everything is lit.
//
// COMPOSITION. The screen is ONE optically-centred column of light —
// greeting, time, date, entry, identity — read top to bottom in a single
// breath. Earlier drafts kept the old lock screen's split (time at the middle,
// a control stranded 420px below), which left a dead zone through the centre
// and gave the eye two competing poles. A column has one gravitational centre.
//
// THE ENTRY IS NOT A FIELD. There is no box, no capsule, no plate — only
// the dots of what you have typed, floating on the wallpaper. An earlier
// draft grew a glass capsule out of the screen on the first keypress; it was
// a good piece of material, but it was chrome wrapped around the one thing
// that actually carries information. Deleting it is the most LUMEN move
// available: at rest the screen is wallpaper, greeting, time and date, and
// typing adds nothing but light.
//
// Everything the entry needs to say, it says with those dots and nothing
// else:
//   · each character lands as a dot that springs in past its size and settles
//   · while PAM works a crest of light travels along the row
//   · caps lock and failure retint them; failure also recoils the row
// Each dot carries its own soft shadow, which is what lets it hold over a
// bright cloud with no surface beneath it.
//
// THE MACHINERY LIVES IN ONE CORNER. Which user, which session, and how to
// power down are all bottom-right, stacked; the centre column is left to the
// time and to what you are typing.
//
// SELECTION UNFOLDS, it does not drop down. See LightSelector.qml.

import QtQuick
import QtQuick.Effects
import SddmComponents 2.0

Rectangle {
    id: root
    color: "#0b0a10"

    // ── palette ───────────────────────────────────────────────────────────
    readonly property color cText:      Qt.rgba(0.965, 0.973, 0.988, 0.96)
    readonly property color cDim:       Qt.rgba(0.965, 0.973, 0.988, 0.50)
    readonly property color cGreet:     Qt.rgba(0.965, 0.973, 0.988, 0.72)
    readonly property color cFaint:     Qt.rgba(0.965, 0.973, 0.988, 0.42)
    readonly property color cPrismCool: Qt.rgba(0.671, 0.612, 1.000, 0.50)
    readonly property color cPrismWarm: Qt.rgba(1.000, 0.702, 0.549, 0.46)
    readonly property color cCheck:     Qt.rgba(0.463, 1.000, 0.345, 0.75)
    readonly property color cFail:      Qt.rgba(1.000, 0.478, 0.549, 0.85)
    readonly property color cCaps:      Qt.rgba(1.000, 0.808, 0.431, 0.85)

    readonly property string fDisplay: config.fontDisplay || "SF Pro Display"
    readonly property string fText:    config.fontText    || "SF Pro Text"

    property int  failCount: 0
    property bool busy: false

    readonly property bool engaged: pw.text.length > 0 || busy

    // ── BACKGROUND ────────────────────────────────────────────────────────
    // Blur, dim and vignette are baked offline (render-bg.sh) to match
    // the old lock screen's background block. Baking rather than running it
    // here keeps the greeter's first frame instant on a cold boot.
    Image {
        anchors.fill: parent
        source: config.background || "background.png"
        fillMode: Image.PreserveAspectCrop
        asynchronous: false
        cache: true
        smooth: true
    }

    // ── ARRIVAL ── the composition fades up rather than snapping in, so boot
    // resolves into the screen instead of cutting to it.
    Item {
        id: stage
        anchors.fill: parent
        opacity: 0
        Component.onCompleted: stage.opacity = 1
        Behavior on opacity { NumberAnimation { duration: 700; easing.type: Easing.OutCubic } }

        // ── GREETING ── a small contextual line ABOVE the time. Content, not
        // chrome, and the only place the name is spoken.
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            y: parent.height / 2 - 300 - height / 2
            color: root.cGreet
            font.family: root.fDisplay
            font.weight: Font.Medium
            font.pixelSize: 17
            renderType: Text.NativeRendering
            text: {
                var h = clock.now.getHours();
                var part = h < 12 ? "morning" : (h < 18 ? "afternoon" : "evening");
                return "Good " + part + (session.firstName ? ", " + session.firstName : "");
            }
        }

        // ── TIME ── largest type on screen; hierarchy is size, not colour.
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            y: parent.height / 2 - 152 - height / 2
            color: root.cText
            font.family: root.fDisplay
            font.bold: true
            font.pixelSize: 118
            renderType: Text.NativeRendering
            text: Qt.formatDateTime(clock.now, "H:mm")
        }

        // ── DATE ── quiet, dimmed, closing the upper block.
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            y: parent.height / 2 - 42 - height / 2
            color: root.cDim
            font.family: root.fText
            font.pixelSize: 19
            renderType: Text.NativeRendering
            text: Qt.formatDateTime(clock.now, "dddd, MMMM d")
        }

        // ── ENTRY ── there is no field. What you type IS the control.
        //
        // Earlier drafts wrapped the dots in a glass capsule that opened on
        // the first keypress. It was a nice piece of material, but it was
        // furniture around the only thing that carries information: the
        // count of characters you have entered. Removing it costs nothing —
        // the dots already say "password", they already say how far along
        // you are, and with the capsule gone they say it against the
        // wallpaper itself, which is as far as "quiet by default" goes.
        //
        // What the rim used to say, the dots now say, using the same colours
        // (see rimState): failure and caps lock retint them, and while PAM
        // works a wave of light travels along the row in place of the rim's
        // sweep. One element, several things to say.
        Item {
            id: entry
            width: 320
            height: 26
            anchors.horizontalCenter: parent.horizontalCenter
            y: parent.height / 2 + 78

            // ── DOTS ── drawn rather than typeset, so each character can
            // land with its own spring. A TextInput's echoMode cannot do
            // this: it repaints the whole run at once, which is precisely
            // the dead, mechanical feel we are designing away from.
            Row {
                id: dots
                anchors.centerIn: parent
                spacing: 15
                Repeater {
                    model: pw.text.length
                    delegate: Item {
                        id: slot
                        required property int index
                        width: 9; height: 9
                        // Set after construction so the spring runs on the
                        // Behaviors rather than being the initial value.
                        property bool born: false
                        Component.onCompleted: born = true

                        Rectangle {
                            anchors.fill: parent
                            radius: width / 2
                            color: root.dotColor

                            // The authenticating wave: a crest travelling
                            // along the row, driven by the same `sweep` that
                            // used to walk the rim's dispersion.
                            readonly property real crest: {
                                var v = Math.cos(sweep.value * Math.PI / 180
                                                 - slot.index * 0.55);
                                return v > 0 ? v * v : 0;
                            }

                            // Overshoot, then settle — the dot arrives with
                            // weight instead of blinking into existence.
                            scale: slot.born ? 1 : 0
                            opacity: !slot.born ? 0
                                   : root.busy  ? 0.34 + 0.66 * crest
                                                : 1
                            Behavior on scale {
                                NumberAnimation { duration: 340; easing.type: Easing.OutBack; easing.overshoot: 2.6 }
                            }
                            // Off during the wave: the crest is already a
                            // continuous curve, and animating toward each of
                            // its frames would only smear it.
                            Behavior on opacity {
                                enabled: !root.busy
                                NumberAnimation { duration: 180 }
                            }
                            Behavior on color { ColorAnimation { duration: 320 } }
                        }
                    }
                }
            }

            // Legibility with no plate to sit on. A blurred, blackened copy
            // of the row rides behind it, so each dot carries its own soft
            // shadow and holds against the bright pink cloud it may land on.
            // (Source and effect both draw — that IS the drop shadow.)
            MultiEffect {
                anchors.fill: dots
                source: dots
                z: -1
                autoPaddingEnabled: true
                blurEnabled: true
                blur: 1.0
                blurMax: 16
                colorization: 1.0
                colorizationColor: "#000000"
                opacity: 0.5
                // No scale: enlarging the blurred copy slides its ends past
                // the row, which reads as two dark smudges bracketing the
                // dots rather than as a halo under each one. At 1:1 every
                // dot sits exactly over its own shadow.
            }

            // The real input. Invisible, but focused and taking every key —
            // the dots above are its display.
            TextInput {
                id: pw
                anchors.fill: parent
                opacity: 0
                echoMode: TextInput.Password
                enabled: !root.busy
                focus: true
                onAccepted: root.attempt()
                Keys.onEscapePressed: pw.text = ""
            }
        }

        // ── NOTICE ── the one place words appear on failure.
        Text {
            id: notice
            property bool showing: failFade.running || keyboard.capsLock
            anchors.horizontalCenter: parent.horizontalCenter
            y: parent.height / 2 + 128
            color: keyboard.capsLock ? root.cCaps : root.cFail
            font.family: root.fText
            font.pixelSize: 13
            renderType: Text.NativeRendering
            opacity: showing ? 1.0 : 0.0
            Behavior on opacity { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
            text: keyboard.capsLock ? "Caps Lock is on"
                                    : "Incorrect password (" + root.failCount + ")"
        }

        // ── IDENTITY ── who, and into what. Parked bottom-right, directly
        // above the power glyphs, so the whole of the screen's machinery —
        // which user, which session, and how to leave — sits in one corner
        // cluster and the centre column is left to say only the time and
        // what you are typing.
        //
        // Right-aligned by computed x rather than an anchor: a selector
        // GROWS when it unfolds, and this way it grows leftward into the
        // empty screen instead of pushing itself off the edge.
        Row {
            id: identity
            x: parent.width - width - 32
            y: power.y - height - 16
            spacing: 0

            LightSelector {
                id: userSel
                visible: session.userLabels.length > 1
                anchors.verticalCenter: parent.verticalCenter
                labels: session.userLabels
                currentIndex: session.userIdx
                dimColor: root.cFaint
                prismCool: root.cPrismCool
                prismWarm: root.cPrismWarm
                fontFamily: root.fText
                onPicked: (i) => { session.userIdx = i; pw.text = ""; pw.forceActiveFocus(); }
            }

            // Aligned to the labels, not to the Row: a selector reserves a
            // gutter below its text for the travelling light, which would drag
            // a vertically-centred separator off the shared baseline.
            Item {
                width: 6
                height: sessionSel.height
                visible: userSel.visible && sessionSel.visible
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: (sessionSel.height - 9 - height) / 2
                    text: "·"
                    color: Qt.rgba(0.965, 0.973, 0.988, 0.28)
                    font.family: root.fText
                    font.pixelSize: 13
                    renderType: Text.NativeRendering
                }
            }

            LightSelector {
                id: sessionSel
                anchors.verticalCenter: parent.verticalCenter
                labels: session.sessionLabels
                currentIndex: session.idx
                dimColor: root.cFaint
                prismCool: root.cPrismCool
                prismWarm: root.cPrismWarm
                fontFamily: root.fText
                onPicked: (i) => { session.idx = i; pw.forceActiveFocus(); }
            }
        }

        // ── POWER ── bottom-right, the only thing left in a corner. Same
        // quiet, drawn not typeset (see PowerGlyph.qml).
        Row {
            id: power
            spacing: 20
            x: parent.width - width - 32
            y: parent.height - height - 30
            PowerGlyph { action: "poweroff"; enabled: sddm.canPowerOff }
            PowerGlyph { action: "reboot";   enabled: sddm.canReboot   }
        }
    }

    // ── state colour ── success, failure and caps all speak through the
    // dots themselves rather than adding elements.
    readonly property color rimState: busy                ? cCheck
                                     : failFade.running    ? cFail
                                     : keyboard.capsLock   ? cCaps
                                     : Qt.rgba(0, 0, 0, 0)
    readonly property bool  stated:   rimState.a > 0
    readonly property color dotColor: stated ? rimState
                                             : Qt.rgba(0.965, 0.973, 0.988, 0.94)

    // ── plumbing ──────────────────────────────────────────────────────────
    QtObject {
        id: clock
        property date now: new Date()
    }
    Timer { interval: 1000; running: true; repeat: true
            onTriggered: clock.now = new Date() }

    // The authenticating sweep: light turning through the glass, in place of
    // a spinner.
    QtObject { id: sweep; property real value: 0 }
    NumberAnimation {
        target: sweep; property: "value"
        from: 0; to: 360; duration: 1400
        loops: Animation.Infinite
        running: root.busy
        onRunningChanged: if (!running) sweep.value = 0
    }

    Timer { id: failFade; interval: 2400; repeat: false }

    QtObject {
        id: session
        property int idx: sessionModel.lastIndex
        property int userIdx: userModel.lastIndex

        // SDDM's UserModel roles: +1 name, +2 realName. SessionModel exposes
        // nothing on DisplayRole — the human-readable name is on +4. Both
        // verified against sddm 0.21's models rather than assumed.
        function userName(i) {
            return userModel.data(userModel.index(i, 0), Qt.UserRole + 1) || "";
        }
        function userReal(i) {
            return userModel.data(userModel.index(i, 0), Qt.UserRole + 2) || "";
        }

        readonly property var userLabels: {
            var out = [];
            for (var i = 0; i < userModel.count; i++)
                out.push(userReal(i) || userName(i));
            return out;
        }
        readonly property var sessionLabels: {
            var out = [];
            for (var i = 0; i < sessionModel.count; i++)
                out.push(sessionModel.data(sessionModel.index(i, 0),
                                           Qt.UserRole + 4) || "Session");
            return out;
        }

        readonly property string user: userName(userIdx) || userModel.lastUser || ""
        readonly property string firstName: {
            var s = userReal(userIdx) || user;
            if (!s) return "";
            s = s.split(" ")[0];                    // personal, not clerical
            return s.charAt(0).toUpperCase() + s.slice(1);
        }
    }

    function attempt() {
        if (root.busy || pw.text.length === 0) return;
        root.busy = true;
        sddm.login(session.user, pw.text, session.idx);
    }

    Connections {
        target: sddm
        function onLoginSucceeded() { root.busy = false; }
        function onLoginFailed() {
            root.busy = false;
            root.failCount += 1;
            pw.text = "";
            failFade.restart();
            recoil.restart();
        }
    }

    // LUMEN GLIDE — long, fluid arrival (the old fail_transition = 420).
    SequentialAnimation {
        id: recoil
        NumberAnimation { target: entry; property: "anchors.horizontalCenterOffset"
                          to:  9; duration:  70; easing.type: Easing.OutCubic }
        NumberAnimation { target: entry; property: "anchors.horizontalCenterOffset"
                          to: -8; duration:  90; easing.type: Easing.InOutCubic }
        NumberAnimation { target: entry; property: "anchors.horizontalCenterOffset"
                          to:  0; duration: 260; easing.type: Easing.OutCubic }
    }

    Component.onCompleted: pw.forceActiveFocus()
}
