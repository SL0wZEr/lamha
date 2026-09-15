import QtQuick
import qs.Commons

// A text field that grows with what you type and then stops.
//
// Unbounded growth would let one pasted paragraph push the pane off the
// screen; a fixed height would hide the second line of a two-line question.
// So it grows to a stated ceiling and scrolls after that, keeping the caret
// in view the whole way. The field reports the height it wants, and whoever
// owns the surface decides what to do with it.
Item {
  id: field

  property alias text: editor.text
  property alias placeholder: ghost.text
  property color foreground: Color.menu.text
  property real fontSize: Style.font.body
  property string fontFamily: Style.font.family
  property real maxHeight: Style.space(120)

  signal accepted(string text)

  // One line of this text, used by the surface to work out its resting size.
  readonly property real lineHeight: Math.ceil(metrics.height)
  readonly property real wantedHeight:
    Math.min(Math.max(field.lineHeight, Math.ceil(editor.implicitHeight)), field.maxHeight)
  readonly property int length: editor.length

  implicitHeight: wantedHeight

  function focusEditor() {
    editor.forceActiveFocus()
    editor.cursorPosition = editor.length
  }

  function clear() {
    editor.text = ""
  }

  TextMetrics {
    id: metrics
    font.family: field.fontFamily
    font.pixelSize: field.fontSize
    text: "Ag"
  }

  Flickable {
    id: flick
    anchors.fill: parent
    contentWidth: width
    contentHeight: editor.implicitHeight
    clip: true
    interactive: contentHeight > height
    boundsBehavior: Flickable.StopAtBounds

    function reveal(rect) {
      if (contentY >= rect.y) contentY = rect.y
      else if (contentY + height <= rect.y + rect.height)
        contentY = rect.y + rect.height - height
    }

    TextEdit {
      id: editor
      width: flick.width

      color: field.foreground
      font.family: field.fontFamily
      font.pixelSize: field.fontSize
      selectionColor: Style.selectionFill
      selectedTextColor: field.foreground
      selectByMouse: true
      wrapMode: TextEdit.Wrap
      textFormat: TextEdit.PlainText
      renderType: Text.QtRendering

      onCursorRectangleChanged: flick.reveal(cursorRectangle)

      // Enter asks. Shift+Enter is how you write the second line of a
      // question, which is worth keeping for the times one line is not enough.
      Keys.onPressed: function (event) {
        if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
            && !(event.modifiers & Qt.ShiftModifier)) {
          field.accepted(editor.text)
          event.accepted = true
        }
      }

      Text {
        id: ghost
        anchors.left: parent.left
        anchors.top: parent.top
        width: parent.width
        visible: editor.length === 0
        color: Qt.alpha(field.foreground, 0.36)
        font: editor.font
        elide: Text.ElideRight
      }
    }
  }
}
