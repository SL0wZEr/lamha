import QtQuick
import Quickshell
import Quickshell.Io

// Carries out one command, and only ever one the catalogue vouches for.
//
// The route is looked up before anything runs, and the process is given the
// route's own words as its argument list rather than a string for a shell to
// interpret. Nothing a model writes can become a second command: an argument
// full of semicolons is just an argument.
Item {
  id: runner

  property var catalogue: null
  property bool busy: false

  signal finished(bool ok, string output)

  // Collected output for the run in progress. The collectors' own `text` is
  // read-only, so what they hand over is kept here instead — an earlier
  // version tried to clear it before each run, which threw, which meant the
  // process was never started at all and the pane sat on "Running…" for as
  // long as it was left open.
  property string _out: ""
  property string _err: ""
  property int _code: -1
  property bool _exited: false
  property bool _drained: false
  property bool _timedOut: false

  function run(route, args) {
    if (runner.busy) return false

    var entry = runner.catalogue ? runner.catalogue.lookup(route) : null
    if (!entry) {
      runner.finished(false, "that is not a command I am allowed to run")
      return false
    }

    var argv = String(route).replace(/\s+/g, " ").split(" ")
    var extra = Array.isArray(args) ? args : []
    for (var i = 0; i < extra.length; i++) argv.push(String(extra[i]))

    runner._out = ""
    runner._err = ""
    runner._code = -1
    runner._exited = false
    runner._drained = false
    runner._timedOut = false

    // Anything that opens a window is started and let go of. Holding on to it
    // would mean holding the window's own process, and the timeout that stops
    // a hung command from hanging the pane would then close the file manager
    // a quarter of a minute after opening it.
    if (entry.detached === true) {
      Quickshell.execDetached(argv)
      runner.finished(true, "Started")
      return true
    }

    runner.busy = true
    proc.command = argv
    proc.running = true
    guard.restart()
    return true
  }

  // A command's output and its exit can arrive in either order, so the result
  // is reported once both have. The grace timer is there for the case where a
  // stream never closes cleanly, so a finished command is never left looking
  // like a running one.
  function _settle() {
    if (!runner._exited) return
    if (!runner._drained && grace.running) return

    guard.stop()
    grace.stop()
    runner.busy = false

    if (runner._code === 0) {
      runner.finished(true, runner.tidy(runner._out))
    } else if (runner._timedOut) {
      // Whatever it printed on the way out, the reason it failed is that it
      // was still going when we stopped waiting.
      runner.finished(false, "it took too long")
    } else {
      var detail = runner.tidy(runner._err).split("\n")[0]
      runner.finished(false, detail.length > 0 ? detail : "it did not work")
    }
  }

  // Command output is written for a terminal: colour escapes, progress
  // characters, blank lines. None of that belongs in a pane.
  function tidy(text) {
    return String(text || "")
      .replace(/\[[0-9;?]*[A-Za-z]/g, "")
      .replace(/\r/g, "")
      .replace(/\n{3,}/g, "\n\n")
      .replace(/^\s+|\s+$/g, "")
  }

  // Nothing here should take long. A command that hangs would otherwise leave
  // the pane claiming to be working for as long as the session lives.
  Timer {
    id: guard
    interval: 15000
    onTriggered: {
      runner._timedOut = true
      if (proc.running) proc.running = false
      else if (runner.busy) {
        runner._exited = true
        runner._drained = true
        runner._code = -1
        runner._settle()
      }
    }
  }

  Timer {
    id: grace
    interval: 250
    onTriggered: runner._settle()
  }

  Process {
    id: proc
    running: false

    stdout: StdioCollector {
      onStreamFinished: {
        runner._out = text
        runner._drained = true
        runner._settle()
      }
    }

    stderr: StdioCollector {
      onStreamFinished: runner._err = text
    }

    onExited: function (code, status) {
      runner._code = code
      runner._exited = true
      if (runner._drained) runner._settle()
      else grace.restart()
    }
  }
}
