import QtQuick
import Quickshell.Io

// Speaking into the field instead of typing into it.
//
// The transcript is put into whichever field asked for it rather than being
// sent straight off, because speech recognition is wrong often enough that
// you want to see it before it becomes a question. Everything runs locally:
// pw-record into whisper.cpp, nothing leaves the machine on this path.
Item {
  id: dictation

  property string pluginDir: ""
  property var target: null
  property bool listening: false

  signal failed(string message)

  function start(field) {
    if (dictation.listening) {
      dictation.stop()
      return
    }
    dictation.target = field
    dictation.listening = true
    proc.running = true
  }

  function stop() {
    dictation.listening = false
    if (proc.running) proc.running = false
  }

  Process {
    id: proc
    running: false
    command: ["python3", dictation.pluginDir + "bin/lamha-listen"]

    stdout: SplitParser {
      onRead: function (data) {
        var line = String(data || "")
        var space = line.indexOf(" ")
        var kind = space < 0 ? line : line.substring(0, space)
        var value = space < 0 ? "" : line.substring(space + 1)

        if (kind === "TEXT" && dictation.target) {
          var existing = String(dictation.target.text || "")
          dictation.target.text = existing.length > 0 ? existing + " " + value : value
          dictation.target.focusEditor()
        } else if (kind === "ERROR") {
          dictation.failed(value)
        }
      }
    }

    onExited: dictation.listening = false
  }
}
