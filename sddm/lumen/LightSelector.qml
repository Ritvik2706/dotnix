// A selector with no chrome at all — no dropdown, no popup, no panel, no fill.
//
// Collapsed, it is one dim word. Click it and the alternatives UNFOLD sideways
// out of that word, and a 1px bar of prism light slides along to sit beneath
// whichever is current. Pick one and it folds back up. Nothing is ever
// occluded, nothing floats above anything, and the only moving part is light
// travelling along a line — which is the whole LUMEN thesis applied to a
// control rather than to a surface.
//
// Degrades honestly: with only one option there is nothing to choose, so it
// renders as plain quiet text and never invites a click.

import QtQuick

Item {
    id: sel

    property var    labels: []
    property int    currentIndex: 0
    property color  dimColor:   Qt.rgba(0.965, 0.973, 0.988, 0.42)
    property color  liveColor:  Qt.rgba(0.965, 0.973, 0.988, 0.90)
    property color  prismCool:  Qt.rgba(0.671, 0.612, 1.000, 0.40)
    property color  prismWarm:  Qt.rgba(1.000, 0.702, 0.549, 0.36)
    property real   fontSize:   13
    property string fontFamily: "SF Pro Text"

    property bool expanded: false
    readonly property bool interactive: labels.length > 1

    signal picked(int index)

    // Half the inter-item gap, and the inset the underline pulls back to.
    readonly property real pad: 15

    implicitWidth:  row.width
    implicitHeight: row.height + 9
    width:  implicitWidth
    height: implicitHeight

    // Underline geometry. rep.itemAt() is not a reactive binding, so the
    // target is pushed by sync() — which every cell also calls while its own
    // fold animation runs, so the light tracks the unfolding continuously
    // instead of jumping to where the layout will eventually settle.
    property real ux: 0
    property real uw: 0
    function sync() {
        var it = rep.itemAt(currentIndex);
        if (!it) return;
        ux = it.x + pad;
        uw = Math.max(it.width - 2 * pad, 0);
    }
    onCurrentIndexChanged: sync()
    onExpandedChanged: sync()
    Component.onCompleted: sync()

    Row {
        id: row
        spacing: 0

        Repeater {
            id: rep
            model: sel.labels

            delegate: Item {
                id: cell
                required property int index
                required property string modelData

                readonly property bool active: index === sel.currentIndex
                readonly property bool shown:  sel.expanded || active

                width:  shown ? label.implicitWidth + 2 * sel.pad : 0
                height: label.implicitHeight
                clip: true

                Behavior on width {
                    NumberAnimation { duration: 380; easing.type: Easing.OutCubic }
                }
                onWidthChanged: sel.sync()

                Text {
                    id: label
                    anchors.centerIn: parent
                    text: cell.modelData
                    color: cell.active ? sel.liveColor : sel.dimColor
                    opacity: cell.shown ? 1 : 0
                    font.family: sel.fontFamily
                    font.pixelSize: sel.fontSize
                    font.weight: cell.active ? Font.DemiBold : Font.Normal
                    renderType: Text.NativeRendering
                    Behavior on color   { ColorAnimation  { duration: 260 } }
                    Behavior on opacity { NumberAnimation { duration: 260 } }
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: sel.expanded && !cell.active
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        sel.picked(cell.index);
                        sel.expanded = false;
                    }
                }
            }
        }
    }

    // The travelling light. Same dispersion pair as the password rule, so the
    // control and the input read as lit by one source.
    Rectangle {
        y: row.height + 6
        x: sel.ux
        width: sel.uw
        height: 1
        opacity: sel.interactive ? (sel.expanded ? 1.0 : 0.55) : 0.0
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: sel.prismCool }
            GradientStop { position: 1.0; color: sel.prismWarm }
        }
        Behavior on x       { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
        Behavior on width   { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
        Behavior on opacity { NumberAnimation { duration: 260 } }
    }

    // Collapsed hit target: the current word. Opens the fold.
    MouseArea {
        x: sel.ux - sel.pad
        y: 0
        width: sel.uw + 2 * sel.pad
        height: row.height
        enabled: sel.interactive && !sel.expanded
        cursorShape: Qt.PointingHandCursor
        onClicked: sel.expanded = true
    }

    // Fold back up on its own if it is left open and untouched.
    Timer {
        interval: 6000
        running: sel.expanded
        onTriggered: sel.expanded = false
    }
}
