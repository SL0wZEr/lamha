import QtQuick
import qs.Commons

// The small round controls on the pane: close, expand, collapse, new, mic.
//
// The glyphs are Material Design icons out of the Nerd Font the shell is
// already set in — the same vocabulary Omarchy's own bar and panels draw
// from — so a control here looks like a control anywhere else on the desktop.
// An earlier version drew each one from rectangles and arcs, which was
// precise and quietly foreign.
Item {
  id: button

  property string kind: "close"
  property color tint: Color.menu.text
  property real diameter: Style.space(26)
  property real iconSize: Style.font.icon
  property bool filled: true

  // Breathing, for a control that is doing something for as long as it is
  // held open — recording, in practice. A still microphone icon cannot tell
  // you whether the room is being listened to.
  property bool pulsing: false

  signal clicked()

  readonly property string glyph: {
    switch (button.kind) {
      case "close": return "󰅖"
      case "expand": return "󰊓"
      case "collapse": return "󰊔"
      case "new": return "󰐕"
      case "mic": return "󰍬"
    }
    return ""
  }

  implicitWidth: diameter
  implicitHeight: diameter
  width: diameter
  height: diameter

  Rectangle {
    anchors.fill: parent
    radius: width / 2
    antialiasing: true
    visible: button.filled
    color: Qt.alpha(button.tint, mouse.containsMouse ? 0.18 : 0.10)
    Behavior on color { ColorAnimation { duration: 120 } }
  }

  Text {
    anchors.centerIn: parent
    text: button.glyph
    color: button.tint
    font.family: Style.font.family
    font.pixelSize: button.iconSize
    renderType: Text.QtRendering
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    opacity: mouse.containsMouse ? 1 : (button.filled ? 0.8 : 0.62)
    Behavior on opacity { NumberAnimation { duration: 120 } }
  }

  // The target is bigger than the mark. A 26px circle is the right size to
  // look at and the wrong size to hit, so the pointer gets a few pixels of
  // slack on every side that nothing is drawn in.
  MouseArea {
    id: mouse
    anchors.fill: parent
    anchors.margins: -Style.space(5)
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: button.clicked()
  }

  scale: mouse.pressed ? 0.9 : 1
  Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }

  SequentialAnimation on opacity {
    running: button.pulsing
    loops: Animation.Infinite
    alwaysRunToEnd: true
    NumberAnimation { from: 1.0; to: 0.45; duration: 620; easing.type: Easing.InOutSine }
    NumberAnimation { from: 0.45; to: 1.0; duration: 620; easing.type: Easing.InOutSine }
  }
}
