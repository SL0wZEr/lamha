import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import qs.Commons

// The surface everything else sits on: a rounded pane of frosted glass.
//
// Hyprland's own backdrop blur is off in this config, and turning it on is a
// system-wide change to pay for one overlay. So the blur is done here instead:
// ScreencopyView grabs the screen once, MultiEffect blurs that grab, and a
// rounded mask cuts the pane out of it.
//
// The grab is deliberately frozen rather than live. Nothing behind a modal
// panel is moving while you type at it, a live capture would film this very
// window and recurse, and one still frame costs nothing to keep blurring as
// the pane morphs. Because the capture stays pinned to screen coordinates
// while the mask moves over it, the blurred content slides under the pane
// exactly the way real glass does — the shrink from bar to pill reveals a
// different part of the same wall, instead of squashing a picture of it.
//
// Blur, tint, sheen and rim are composed into one texture and that single
// texture is rounded off once. Rounding each of them separately looked almost
// right and was not: every layer contributes its own softened edge, they stack
// a few pixels wide, and the result is a faint halo that reads as a blurry
// corner. One mask, one edge.
Item {
  id: glass

  // Screen to capture, and this item's offset within it. The capture is laid
  // out in screen space and then shifted, so it stays put as the pane moves.
  property var captureSource: null
  property real originX: 0
  property real originY: 0
  property real screenWidth: 0
  property real screenHeight: 0

  // Holding the capture costs a screen-sized texture, so it is taken on
  // summon and dropped on dismissal rather than kept between uses.
  property bool active: false

  property real radius: Style.cornerRadius
  property color tint: Color.menu.background
  property real tintAlpha: 0.82
  property color edge: Color.menu.text
  property real blurAmount: 1.0

  // Which way to push what is behind the pane before tinting it. A theme with
  // a pale surface carries dark text, so its glass has to stay pale over a
  // dark window behind it; a dark theme needs the opposite. One test on the
  // surface colour keeps the pane legible on either kind of theme instead of
  // assuming the dark one.
  readonly property bool paleSurface:
    (0.2126 * tint.r + 0.7152 * tint.g + 0.0722 * tint.b) > 0.5

  // How far outside the pane the capture is kept so the blur has something to
  // sample there. A blur reads pixels around each one it writes; at the very
  // edge of a clipped texture those neighbours do not exist, the kernel falls
  // back to nothing, and the outermost few pixels come out thinner than the
  // rest — a pale seam running down the side of the pane that looks like a
  // bad edge and is really a starved filter. Keeping a margin of real content
  // beyond the cut and only then masking down to the pane fixes it at source.
  readonly property int bleed: 72
  property real shadowOffset: Style.space(8)
  property real shadowStrength: glass.paleSurface ? 0.22 : 0.45

  readonly property bool ready: capture.item ? capture.item.hasContent : false

  // A fresh grab per summon: the Loader is torn down between times, and
  // building the view is itself what starts a capture. Keeping one view alive
  // would mean showing the desktop as it looked when the shell last started.
  onActiveChanged: capture.active = glass.active

  // --- shadow ---------------------------------------------------------------

  Item {
    anchors.fill: parent
    anchors.topMargin: glass.shadowOffset
    anchors.bottomMargin: -glass.shadowOffset

    // The silhouette is rendered into a texture larger than the pane, with
    // clear space all round, for the same reason the backdrop is. A blur
    // samples past the edge of its source and a texture is clamped to its
    // last pixel there, so a shape that runs to the edge of its texture is
    // smeared outward: the pill's middle rows became a dark streak level with
    // the pane and as wide as the screen, plain against a pale wallpaper.
    // Padding the texture makes the last pixel a clear one, and the effect
    // is told not to pad again on its own.
    Item {
      id: silhouette
      anchors.fill: parent
      anchors.margins: -glass.bleed
      visible: false
      layer.enabled: true
      layer.samples: 4

      Rectangle {
        anchors.fill: parent
        anchors.margins: glass.bleed
        radius: glass.radius
        color: "white"
        antialiasing: true
      }
    }

    MultiEffect {
      anchors.fill: silhouette
      source: silhouette
      autoPaddingEnabled: false
      blurEnabled: true
      blur: 1.0
      blurMax: 40
      brightness: -1.0
      saturation: -1.0
      opacity: glass.shadowStrength
    }
  }

  // --- the pane, composed flat and cut out once -----------------------------

  Item {
    id: composite
    anchors.fill: parent
    visible: false
    layer.enabled: true
    layer.samples: 4
    layer.smooth: true
    clip: true

    // Deliberately larger than the pane. Everything drawn out here is cut away
    // when this is captured into the pane-sized texture above; its only job is
    // to give the blur real pixels to reach for at the edges.
    Item {
      id: blurHost
      anchors.fill: parent
      anchors.margins: -glass.bleed

      Item {
        id: backdrop
        anchors.fill: parent
        visible: false
        layer.enabled: true
        // The capture is the whole screen and would otherwise inflate the
        // layer texture to match.
        clip: true

        Loader {
          id: capture
          active: false
          x: -glass.originX + glass.bleed
          y: -glass.originY + glass.bleed
          width: glass.screenWidth
          height: glass.screenHeight

          sourceComponent: ScreencopyView {
            captureSource: glass.captureSource
            live: false
            paintCursor: false
          }
        }
      }

      MultiEffect {
        anchors.fill: parent
        source: backdrop
        blurEnabled: true
        blur: glass.blurAmount
        blurMax: 56

        // Pushed hard toward the theme's own end of the scale and drained of
        // colour before the tint goes over it. Frosted glass that merely
        // averages what is behind it is legible over a dark wallpaper and
        // unreadable over a white web page — the text is one fixed colour, so
        // the surface under it has to be one too. What survives is the shape
        // and movement of what is behind, which is all the blur was ever for.
        saturation: -0.35
        brightness: glass.paleSurface ? 0.34 : -0.35

        // The grab lands a frame or two after the pane is summoned, and
        // without this the frosting snaps on: the pane shows as a flat tint
        // and then abruptly becomes glass. Short enough that a grab arriving
        // on time is indistinguishable from instant.
        opacity: glass.ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 120 } }
      }
    }

    // The tint, flat. An earlier version graded it light-to-dark down the
    // pane to suggest a light source above; against Omarchy's flat surfaces
    // that reads as a panel from a different toolkit. A single value is what
    // the rest of the desktop does.
    Rectangle {
      anchors.fill: parent
      color: Qt.alpha(glass.tint, glass.tintAlpha)
    }

    // Rim. Drawn on the shape's own outline and left for the mask to trim:
    // half-pixel insets put the hairline across two rows of pixels and make
    // one crisp line look like two soft ones.
    Rectangle {
      anchors.fill: parent
      radius: glass.radius
      color: "transparent"
      antialiasing: true
      border.width: 1
      border.color: Qt.alpha(glass.edge, 0.10)
    }

  }

  Item {
    id: maskShape
    anchors.fill: parent
    visible: false
    layer.enabled: true
    layer.samples: 4
    layer.smooth: true

    Rectangle {
      anchors.fill: parent
      radius: glass.radius
      color: "white"
      antialiasing: true
    }
  }

  MultiEffect {
    anchors.fill: parent
    source: composite
    maskEnabled: true
    maskSource: maskShape

    // Without these the mask is a threshold, not a gradient: the default
    // spread of zero turns every partially covered pixel along the rounded
    // edge fully opaque, throwing away the antialiasing that was carefully
    // rendered into the mask and leaving a hard binary cut. It is invisible
    // where the pane sits on a similar colour and obvious as a staircase
    // where it crosses something bright. A spread of one lets the mask's own
    // coverage through.
    maskThresholdMin: 0.5
    maskSpreadAtMin: 1.0
  }
}
