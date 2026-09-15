import QtQuick
import QtQuick.Shapes
import qs.Commons

// The small square that stands in for the agent beside its name.
//
// While a turn is in flight the outline is dashed and the dashes travel, so
// the name itself is what tells you something is happening; when the text
// lands the outline closes up and goes still. It is the quietest possible
// progress indicator and it sits exactly where you are already looking.
Item {
  id: mark

  property color tint: Color.accent
  property bool working: false

  readonly property real stroke: Math.max(1, Style.space(1.4))
  readonly property real inset: stroke

  property real travel: 0

  NumberAnimation on travel {
    running: mark.working && mark.visible
    loops: Animation.Infinite
    from: 0
    to: 12
    duration: 900
  }

  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    antialiasing: true

    ShapePath {
      strokeColor: mark.tint
      strokeWidth: mark.stroke
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      strokeStyle: mark.working ? ShapePath.DashLine : ShapePath.SolidLine
      dashPattern: [2.2, 2.2]
      dashOffset: -mark.travel

      PathPolyline {
        path: [
          Qt.point(mark.inset, mark.inset),
          Qt.point(mark.width - mark.inset, mark.inset),
          Qt.point(mark.width - mark.inset, mark.height - mark.inset),
          Qt.point(mark.inset, mark.height - mark.inset),
          Qt.point(mark.inset, mark.inset)
        ]
      }
    }
  }

  opacity: mark.working ? 1 : 0.8
  Behavior on opacity { NumberAnimation { duration: 240 } }
}
