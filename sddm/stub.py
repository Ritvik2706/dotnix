#!/usr/bin/env python3
"""Turn the theme into a standalone QML app that `qml` can run.

sddm-greeter-qt6 --test-mode renders in a FIXED 1600x900 window, which makes
anything positioned in the lower third look jammed against the bottom edge —
it has misjudged this theme's layout twice. The greeter supplies `sddm`,
`config`, `userModel`, `sessionModel` and `keyboard` as C++ context
properties, which the plain `qml` runtime cannot inject. So we inject them as
ids instead: QML resolves unqualified names against ids anywhere in the same
file, so a QtObject with `id: sddm` stands in for the context property exactly.
"""
import re
import sys, pathlib, shutil

d, W, H, text = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]

STUBS = '''
    // ── preview stubs (see stub.py) ───────────────────────────────────────
    QtObject {
        id: sddm
        property string hostName: "razer"
        property bool canPowerOff: true
        property bool canReboot: true
        signal loginSucceeded()
        signal loginFailed()
        function login(u, p, s) {}
    }
    QtObject { id: keyboard; property bool capsLock: false }
    QtObject {
        id: config
        property string fontDisplay: "SF Pro Display"
        property string fontText: "SF Pro Text"
        property string fadeOnEmpty: "true"
        property string background: "background.png"
    }
    QtObject {
        id: userModel
        property int count: 1
        property int lastIndex: 0
        property string lastUser: "ritvik"
        function index(i, c) { return i }
        function data(i, role) {
            if (role === 257) return "ritvik";
            if (role === 258) return "Ritvik";
            return undefined;
        }
    }
    QtObject {
        id: sessionModel
        property int count: 2
        property int lastIndex: 0
        function index(i, c) { return i }
        function data(i, role) {
            var n = ["Hyprland (uwsm-managed)", "Hyprland"];
            return role === 260 ? n[i] : undefined;
        }
    }
'''

m = (d / "Main.qml").read_text()
m = m.replace("import SddmComponents 2.0\n", "")
# Drop the stubs in immediately after the root object opens.
anchor = '    color: "#0b0a10"\n'
# Size the root directly rather than wrapping it in a Preview component: a
# same-directory type reference resolves under sddm-greeter but not under the
# bare `qml` runtime, and the wrapper is not worth the import-path fight.
m = m.replace(anchor, anchor + "    width: %s\n    height: %s\n" % (W, H) + STUBS, 1)
if text:
    # Indent-agnostic: the entry has been re-nested more than once, and an
    # exact-indent match silently did nothing rather than failing loudly.
    m = re.sub(r"( *)focus: true\n( *)onAccepted:",
               lambda mo: '%sfocus: true\n%stext: "%s"\n%sonAccepted:'
                          % (mo.group(1), mo.group(2), text, mo.group(2)),
               m, count=1)
    if 'text: "' not in m:
        sys.exit("stub: could not inject typed text into the TextInput")
(d / "Main.qml").write_text(m)

# PowerGlyph lives in its own file, so the id above is out of scope there.
p = d / "PowerGlyph.qml"
g = p.read_text()
g = g.replace("    width: 18\n",
              "    property var sddm: ({ powerOff: function () {}, reboot: function () {} })\n\n    width: 18\n")
p.write_text(g)

