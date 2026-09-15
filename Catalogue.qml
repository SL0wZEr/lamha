import QtQuick
import Quickshell
import Quickshell.Io

// What Lamha is allowed to do to the machine.
//
// Omarchy publishes its own command list as JSON — every route, its arguments,
// a summary, and whether it needs sudo — so the set of things that can be
// asked for is read from the system rather than written out here and left to
// rot. When Omarchy gains a command, so does this.
//
// The model never gets a shell. It gets this list, it answers with one route
// from it, and anything that is not in the list cannot be run: an invented
// command fails the lookup and nothing happens.
//
// Three filters narrow the 350-odd commands down to the ones a panel on a
// hotkey has any business running:
//
//   sudo         — anything that needs root is not on offer at all
//   groups       — package installs, updates, migrations, disk and hardware
//                  work, setup wizards and shutdown are all out
//   routes       — a handful of otherwise-allowed commands that take a
//                  command or a path as an argument, which would hand back
//                  the shell this design is built to avoid, plus the two that
//                  print wifi secrets
Item {
  id: catalogue

  property bool ready: false
  property string error: ""

  // route → { args, summary, auto }
  property var entries: ({})

  // The block handed to the model. Built once, when the list is read.
  property string promptBlock: ""

  readonly property var allowedGroups: [
    "audio", "bluetooth", "brightness", "capture", "default", "display", "font",
    "launch", "menu", "monitor", "network", "osd", "power", "powerprofiles",
    "reminder", "screensaver", "theme", "toggle", "version", "weather", "webapp"
  ]

  // Runs the moment it is chosen. Reversible, immediate, and confined to this
  // desktop: a wrong guess here costs one keystroke to undo.
  readonly property var autoGroups: [
    "audio", "brightness", "default", "display", "font", "monitor", "osd",
    "power", "powerprofiles", "reminder", "screensaver", "theme", "toggle",
    "version", "weather"
  ]

  // Commands that open something and then stay in the foreground for as long
  // as it is open. These are started and let go of, because waiting on one and
  // then giving up would mean killing the window the user just asked for.
  readonly property var detachedGroups: ["launch", "menu", "screensaver"]
  readonly property var detachedRoutes: [
    // Holds the terminal it opens for as long as it is open, so it is started
    // and let go of rather than waited on.
    "omarchy default agent",
    "omarchy theme switcher",
    "omarchy theme bg-switcher",
    "omarchy theme bg install",
    "omarchy capture screenrecording",
    "omarchy capture screenrecording with webcam",
    "omarchy capture screenshot",
    "omarchy capture text",
    "omarchy capture qr"
  ]

  // In an allowed group, but shown for confirmation rather than run outright:
  // these reach outside the desktop, cost real time, or open something.
  readonly property var confirmRoutes: [
    // The other three defaults write a setting and exit. This one also ends
    // with `exec omarchy-agent`, so it opens a terminal running the agent you
    // picked, the way Omarchy runs it. That is Omarchy's command meaning what
    // it has always meant, not something this panel invented, so it is offered
    // — and shown, with its arguments, for you to press Enter on. The model
    // is told to say what it will do before proposing it.
    "omarchy default agent",
    "omarchy network speedtest",
    "omarchy bluetooth device",
    "omarchy powerprofiles init",
    "omarchy theme refresh"
  ]

  // Excluded outright. Each either takes a command or a path to run — which is
  // a shell by another name — installs or removes something, or prints a
  // secret.
  readonly property var deniedRoutes: [
    "omarchy launch terminal",
    "omarchy launch tui",
    "omarchy launch or focus",
    "omarchy launch or focus tui",
    "omarchy launch or focus webapp",
    "omarchy launch floating terminal with presentation",
    "omarchy launch config editor",
    "omarchy launch editor",
    "omarchy notification send",
    "omarchy notification dismiss",
    "omarchy file select",
    "omarchy menu file",
    "omarchy menu input",
    "omarchy menu select",
    "omarchy menu plugin",
    "omarchy network password",
    "omarchy network qr",
    "omarchy theme install",
    "omarchy theme remove",
    "omarchy theme update",
    "omarchy webapp install",
    "omarchy webapp remove",
    "omarchy webapp remove all",
    "omarchy audio input set default",
    "omarchy audio output set default",
    "omarchy toggle",
    "omarchy toggle enabled",
    "omarchy bar",
    "omarchy share",
    "omarchy show done",
    "omarchy show logo"
  ]

  function has(list, value) {
    return list.indexOf(value) !== -1
  }

  function lookup(route) {
    var key = String(route || "").replace(/\s+/g, " ").replace(/^\s+|\s+$/g, "")
    return catalogue.entries[key] || null
  }

  function isAuto(route) {
    var entry = catalogue.lookup(route)
    return entry ? entry.auto === true : false
  }

  function load(raw) {
    var parsed
    try {
      parsed = JSON.parse(raw || "{}")
    } catch (e) {
      catalogue.error = "could not read the omarchy command list"
      return
    }

    var commands = parsed && parsed.commands ? parsed.commands : []
    var next = ({})
    var lines = []

    for (var i = 0; i < commands.length; i++) {
      var command = commands[i]
      var route = String(command.route || "")
      if (route.length === 0) continue
      if (command.requires_sudo) continue
      if (!catalogue.has(catalogue.allowedGroups, String(command.group || ""))) continue
      if (catalogue.has(catalogue.deniedRoutes, route)) continue

      var auto = catalogue.has(catalogue.autoGroups, String(command.group || ""))
        && !catalogue.has(catalogue.confirmRoutes, route)

      next[route] = {
        args: String(command.args || ""),
        summary: String(command.summary || ""),
        auto: auto,
        detached: catalogue.has(catalogue.detachedGroups, String(command.group || ""))
          || catalogue.has(catalogue.detachedRoutes, route)
      }

      lines.push(route + (command.args ? "  " + command.args : "")
        + "\n    " + String(command.summary || ""))
    }

    catalogue.entries = next
    catalogue.promptBlock = lines.join("\n")
    catalogue.ready = lines.length > 0
    if (!catalogue.ready) catalogue.error = "the omarchy command list came back empty"

    // Worth a line in the log either way: if this list is empty the panel
    // silently becomes answers-only, which is otherwise indistinguishable
    // from the model simply not knowing how to do what was asked.
    if (catalogue.ready)
      console.log("lamha: " + lines.length + " omarchy commands available")
    else
      console.warn("lamha: no omarchy commands available —", catalogue.error)
  }

  Process {
    id: reader
    running: true
    command: ["omarchy", "commands", "--json"]
    stdout: StdioCollector {
      onStreamFinished: catalogue.load(text)
    }
    onExited: function (code, status) {
      if (!catalogue.ready && catalogue.error.length === 0)
        catalogue.error = "omarchy commands did not answer"
    }
  }
}
