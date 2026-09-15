import QtQuick
import QtQuick.Effects
import qs.Commons

// The waiting mark: a ring of dots turning about a point, each one swelling
// and brightening as it comes round to the head of the ring and fading as it
// falls behind.
//
// The size and brightness are a function of absolute angle, not of which dot
// it is, so the crest stays put while the dots travel through it. That is what
// separates this from a spinner: a spinner rotates a fixed picture, this has a
// bright place that dots move into. The eye reads the second one as something
// circulating rather than something merely spinning.
//
// A blurred copy sits under the sharp one. On a dark pane that reads as each
// dot glowing rather than as a blur, and it costs one extra pass.
Item {
  id: orbit

  property color tint: Color.foreground
  property int dots: 8
  property real period: 1150

  // Where on the ring the crest sits. Up and to the right, so the motion
  // enters at the top: descending dots read as falling, rising ones as effort.
  property real head: -Math.PI / 4

  readonly property real ringRadius: Math.min(width, height) * 0.33
  readonly property real dotMin: Math.max(1, Math.min(width, height) * 0.075)
  readonly property real dotMax: Math.max(2, Math.min(width, height) * 0.205)

  property real phase: 0
  NumberAnimation on phase {
    running: orbit.visible
    loops: Animation.Infinite
    from: 0
    to: 2 * Math.PI
    duration: orbit.period
  }

  // 0 at the back of the ring, 1 at the crest. Raised to a power so the crest
  // is a place rather than half the ring.
  function weight(angle) {
    return Math.pow((1 + Math.cos(angle - orbit.head)) / 2, 1.7)
  }

  Component {
    id: ring

    Item {
      anchors.fill: parent

      Repeater {
        model: orbit.dots

        Rectangle {
          readonly property real angle: orbit.phase + index * (2 * Math.PI / orbit.dots)
          readonly property real w: orbit.weight(angle)

          width: orbit.dotMin + (orbit.dotMax - orbit.dotMin) * w
          height: width
          radius: width / 2
          antialiasing: true
          color: orbit.tint
          opacity: 0.3 + 0.7 * Math.pow(w, 1.2)

          x: parent.width / 2 + Math.cos(angle) * orbit.ringRadius - width / 2
          y: parent.height / 2 + Math.sin(angle) * orbit.ringRadius - height / 2
        }
      }
    }
  }

  Loader {
    id: sharp
    anchors.fill: parent
    sourceComponent: ring
    visible: false
    layer.enabled: true
  }

  Loader {
    id: halo
    anchors.fill: parent
    sourceComponent: ring
    visible: false
    layer.enabled: true
  }

  MultiEffect {
    anchors.fill: parent
    source: halo
    blurEnabled: true
    blur: 1.0
    blurMax: Math.max(4, Math.round(orbit.dotMax * 1.6))
    opacity: 0.85
  }

  MultiEffect {
    anchors.fill: parent
    source: sharp
  }
}
