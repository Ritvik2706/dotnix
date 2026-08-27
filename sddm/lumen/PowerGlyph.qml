// A power / reboot mark drawn as a stroked path rather than set as a font
// glyph. Two reasons, both LUMEN: form here is drawn by the same 1px luminous
// line as the password rim, and a drawn mark can never degrade into a
// missing-codepoint box on a greeter that runs before any of the user's
// fontconfig applies.

import QtQuick
import QtQuick.Shapes

Item {
    id: g
    required property string action        // "poweroff" | "reboot"
    property color baseColor: Qt.rgba(0.965, 0.973, 0.988, 0.55)
    property color liveColor: Qt.rgba(0.965, 0.973, 0.988, 0.92)

    width: 18
    height: 18
    visible: enabled

    property color stroke: hit.containsMouse ? liveColor : baseColor
    Behavior on stroke { ColorAnimation { duration: 220 } }

    readonly property real cx: 9
    readonly property real cy: 9.5
    readonly property real r:  6.6

    // ── POWEROFF ── the IEC mark: a ring broken at the top, plus a stem.
    Shape {
        anchors.fill: parent
        visible: g.action === "poweroff"
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: g.stroke
            strokeWidth: 1.3
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: g.cx; centerY: g.cy
                radiusX: g.r;  radiusY: g.r
                startAngle: -62; sweepAngle: 304
            }
        }
        ShapePath {
            strokeColor: g.stroke
            strokeWidth: 1.3
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            startX: g.cx; startY: 1.2
            PathLine { x: g.cx; y: 8.6 }
        }
    }

    // ── REBOOT ── the same ring, closed by an arrowhead on the arc's terminus
    // so the mark reads as motion rather than as a broken circle.
    Shape {
        id: rb
        anchors.fill: parent
        visible: g.action === "reboot"
        preferredRendererType: Shape.CurveRenderer

        // Arc start angle, and the point + tangent there — the arrowhead is
        // built from the tangent so the barbs always sit true to the curve.
        readonly property real a0: -58
        readonly property real px: g.cx + g.r * Math.cos(a0 * Math.PI / 180)
        readonly property real py: g.cy + g.r * Math.sin(a0 * Math.PI / 180)
        // Clockwise tangent at a0, reversed: the head points back along the
        // direction of travel, which is what makes it read as "return".
        readonly property real tx:  Math.sin(a0 * Math.PI / 180)
        readonly property real ty: -Math.cos(a0 * Math.PI / 180)

        function barbX(deg) {
            var a = Math.atan2(ty, tx) + deg * Math.PI / 180;
            return px + 4.2 * Math.cos(a);
        }
        function barbY(deg) {
            var a = Math.atan2(ty, tx) + deg * Math.PI / 180;
            return py + 4.2 * Math.sin(a);
        }

        ShapePath {
            strokeColor: g.stroke
            strokeWidth: 1.3
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: g.cx; centerY: g.cy
                radiusX: g.r;  radiusY: g.r
                startAngle: rb.a0; sweepAngle: 300
            }
        }
        ShapePath {
            strokeColor: g.stroke
            strokeWidth: 1.3
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            startX: rb.barbX(142);  startY: rb.barbY(142)
            PathLine { x: rb.px;         y: rb.py }
            PathLine { x: rb.barbX(-142); y: rb.barbY(-142) }
        }
    }

    MouseArea {
        id: hit
        anchors.fill: parent
        anchors.margins: -10
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: g.action === "poweroff" ? sddm.powerOff() : sddm.reboot()
    }
}
