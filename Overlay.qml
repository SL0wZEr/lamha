import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Lamha — لمحة, "a glance." Ask your agent without leaving what you are doing.
//
// One surface does the whole thing. A bar you type into contracts to a pill
// that shows it is working, and the pill unfolds into the answer; dismiss it
// and the answer folds back to nothing. It is deliberately never two windows
// swapped behind a crossfade: the same pane of glass changes shape, so there
// is always something to follow from one state to the next, and the wait feels
// like part of the same object rather than a gap between two of them.
//
// Summon with: omarchy-shell shell toggle io.github.sl0wzer.lamha
Item {
  id: root

  // Injected by the shell when it mounts the plugin.
  property var shell: null
  property var manifest: null

  readonly property string pluginId:
    (root.manifest && root.manifest.id) || "io.github.sl0wzer.lamha"

  property bool opened: false
  property bool closing: false

  // ask → thinking → answer. Nothing goes backwards except by dismissing or
  // by starting a new conversation.
  property string phase: "ask"

  // The first beat of the shrink, where the bar pulls in to a disc before it
  // reopens as the working pill. Without it the bar just slides narrower and
  // the change of state does not register.
  property bool pinched: false

  property bool expanded: false
  property string topic: ""

  // The question as a heading: its first line, and a mark that there was
  // more. The label it goes in is one line high, and a question written on
  // several — Shift+Enter is right there — would otherwise stack every line
  // through the top of the pane and down over the answer.
  readonly property string topicLine: {
    var lines = String(root.topic || "").split("\n")
    var kept = []
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].replace(/\s+/g, " ").replace(/^\s+|\s+$/g, "")
      if (line.length > 0) kept.push(line)
    }
    if (kept.length === 0) return ""
    return kept.length > 1 ? kept[0] + " …" : kept[0]
  }
  property bool micAvailable: false

  // The command the agent picked for this turn, if it picked one, and how far it
  // has got. none | pending | running | done | failed
  property string actionState: "none"
  property string actionRoute: ""
  property var actionArgs: []
  property string actionOutput: ""

  // Whether this action is a setting of the panel's own rather than an Omarchy
  // command. Those go nowhere near the catalogue or the Runner: nothing is
  // executed, a key is written to the panel's own config file, and the only
  // values accepted are the names of agents there is an adapter for.
  property bool actionPanel: false

  // Something the panel needs to say about itself rather than about the
  // question — a missing transcriber, a microphone that heard nothing. It
  // takes the placeholder's place for a moment and then gets out of the way.
  property string notice: ""

  // Held down until the frozen backdrop has actually been grabbed, so the
  // pane arrives as glass rather than arriving as a flat tint and then
  // turning into glass a frame later.
  property bool dressed: false

  // What the waiting pill says. It starts plainly and then admits who it is
  // waiting on, which is the difference between a progress indicator and
  // something that is talking to you.
  property string waitLabel: "Working"

  // The agent's name is in the placeholder and in the pill, so switching the
  // desktop's default agent is something you notice the next time you reach
  // for the hotkey rather than something you have to go and check.
  readonly property string askLabel:
    !agents.supported ? "Ask" : "Ask " + agents.label
  readonly property string askingLabel: "Asking " + agents.label + "…"
  readonly property string patienceLabel:
    agents.label + " sends its answer in one piece"

  readonly property color surface: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color accent: Color.accent

  // Nothing is shown until the surface has been configured and the backdrop
  // grabbed. Without the size check the very first summon after the shell
  // starts can win the race against the compositor's configure, and the pane
  // is then on screen while its measurements are still those of an unsized
  // surface — which is exactly the frame in which they change.
  readonly property bool visibleNow: root.opened && !root.closing
    && root.dressed && surface.stableWidth > 0

  // --- lifecycle (the shell's overlay contract) ----------------------------

  function open(payloadJson) {
    if (root.opened && !root.closing) {
      root.focusInput()
      return
    }

    root.closing = false
    closeTimer.stop()
    root.reset()

    // Follow the screen you are working on. A panel that always opens on the
    // first monitor is a panel you have to go and find.
    var target = root.focusedScreen()
    if (target) panel.screen = target

    root.opened = true
    // Activating the glass is what takes the grab; see Glass.qml. A summon
    // that lands while the last dismissal is still fading finds it active
    // already, and would otherwise be shown last time's desktop.
    if (glass.active) glass.active = false
    glass.active = true
    dressTimeout.restart()

    micProbe.running = true
    session.warm(true)

    var preset = ""
    try {
      preset = String((JSON.parse(payloadJson || "{}")).text || "").replace(/^\s+|\s+$/g, "")
    } catch (e) {
      preset = ""
    }

    Qt.callLater(function () {
      root.focusInput()
      if (preset.length > 0) root.submit(preset)
    })
  }

  function close() {
    if (!root.opened || root.closing) return
    root.closing = true
    closeTimer.restart()
  }

  function dismiss() {
    if (!root.opened || root.closing) return
    root.closing = true
    closeTimer.restart()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened && !root.closing) root.dismiss()
    else root.open("{}")
  }

  function focusedScreen() {
    var name = ""
    try {
      name = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name || "") : ""
    } catch (e) {
      name = ""
    }
    var screens = Quickshell.screens
    if (!screens || screens.length === 0) return null
    for (var i = 0; i < screens.length; i++)
      if (screens[i].name === name) return screens[i]
    return screens[0]
  }

  function focusInput() {
    if (root.phase === "answer") followField.focusEditor()
    else askField.focusEditor()
  }

  // Held just long enough for the pane to fold away. Hiding the window on the
  // keystroke would throw away the only part of a dismissal you can see.
  Timer {
    id: closeTimer
    interval: 200
    onTriggered: {
      root.opened = false
      root.closing = false
      glass.active = false
      root.reset()
    }
  }

  // The grab is quick, but a missing capture must never mean a missing panel.
  Timer {
    id: dressTimeout
    interval: 110
    onTriggered: root.dressed = true
  }

  Connections {
    target: glass
    function onReadyChanged() {
      if (glass.ready && root.opened) root.dressed = true
    }
  }

  function reset() {
    waitTimer.stop()
    patienceTimer.stop()
    pinchTimer.stop()
    dressTimeout.stop()
    session.reset()
    turns.clear()
    root.phase = "ask"
    root.pinched = false
    root.expanded = false
    root.dressed = false
    root.topic = ""
    root.notice = ""
    noticeTimer.stop()
    root.waitLabel = "Working"
    root.clearAction()
    askField.clear()
    followField.clear()
  }

  // --- the conversation ----------------------------------------------------

  ListModel { id: turns }

  // The command list is read once, when the shell mounts the plugin, so it is
  // normally long ready before anyone reaches for the hotkey. Summoning the
  // panel in the first second or two of a shell's life is the exception, and
  // this is what keeps that case from starting a conversation that cannot act.
  Connections {
    target: catalogue
    function onReadyChanged() { if (root.opened) session.warm() }
    function onErrorChanged() { if (root.opened) session.warm() }
  }

  // Which agent, and how to speak to it. Follows `omarchy default agent`
  // unless the plugin's entry in shell.json names one for this pane only.
  Agents {
    id: agents
    override: config.agent

    // A change of agent while the pane is open — from the menu, from another
    // machine's dotfiles, or from the panel's own setting — would otherwise
    // leave a process belonging to something that is no longer answering,
    // whether or not a conversation has started. The old process is dropped
    // and the transcript carried across, so the new agent picks up the
    // conversation rather than walking into the middle of one it has never
    // seen; with no conversation yet, that is simply a warm start for the
    // right agent.
    onSwitched: if (root.opened) session.rebind()
  }

  Session {
    id: session
    agents: agents
    armed: catalogue.ready || catalogue.error.length > 0
    model: config.model
    systemPrompt: (config.systemPrompt.length > 0 ? config.systemPrompt
                                                  : root.defaultPrompt)
                  + root.actionContract

    onDelta: function (text) {
      if (turns.count === 0) return
      var last = turns.count - 1
      if (turns.get(last).pending) turns.setProperty(last, "pending", false)
      turns.setProperty(last, "text", turns.get(last).text + text)
      if (root.phase !== "answer") root.setPhase("answer")
    }

    // Agents whose output is an event bus rather than a transcript re-send
    // the whole answer so far each time, so this replaces where onDelta
    // appends. One or the other is used per agent, never both.
    onWhole: function (text) {
      if (turns.count === 0) return
      var last = turns.count - 1
      if (turns.get(last).pending) turns.setProperty(last, "pending", false)
      turns.setProperty(last, "text", text)
      if (root.phase !== "answer") root.setPhase("answer")
    }

    onTurnFinished: {
      if (turns.count > 0 && turns.get(turns.count - 1).pending)
        turns.setProperty(turns.count - 1, "pending", false)
      if (root.phase !== "answer") root.setPhase("answer")

      // The command is read only once the reply is whole. Reading it while it
      // streams would mean acting on half a line of JSON.
      var chosen = turns.count > 0
        ? root.extractAction(turns.get(turns.count - 1).text) : null
      if (chosen) {
        root.actionRoute = chosen.route
        root.actionArgs = chosen.args
        root.actionPanel = chosen.panel === true
        root.actionOutput = ""
        root.actionState = "pending"
        // Reversible desktop settings go through; everything else waits to be
        // told, because a wrong guess there costs more than a keystroke.
        if (chosen.panel === true || catalogue.isAuto(chosen.route))
          root.runAction()
      } else {
        root.clearAction()
      }

      Qt.callLater(function () { followField.focusEditor() })
    }

    onFailed: function (message) {
      if (turns.count > 0) {
        var last = turns.count - 1
        turns.setProperty(last, "pending", false)
        turns.setProperty(last, "failed", true)
        turns.setProperty(last, "text", message)
      }
      root.setPhase("answer")
    }
  }

  Catalogue { id: catalogue }

  Runner {
    id: runner
    catalogue: catalogue

    onFinished: function (ok, output) {
      root.actionState = ok ? "done" : "failed"
      root.actionOutput = output
      Qt.callLater(body.toBottom)
    }
  }

  // Whether this command's output is worth reading. A command that reports
  // something prints the answer; a command that does something prints its own
  // diary — turning the night light on spills eight lines about colour
  // matrices, which is noise where "Done" is the whole story. Omarchy names
  // its reporting commands consistently enough to tell them apart, and a
  // single short line is worth showing whatever the verb.
  readonly property bool actionReports: {
    if (/\b(current|list|status|show|state|present|dir|extras|availability|sink|channel|pkgs|location|icon)$/.test(root.actionRoute))
      return true
    var out = root.actionOutput
    return out.length > 0 && out.length <= 160 && out.indexOf("\n") === -1
  }

  function clearAction() {
    root.actionState = "none"
    root.actionRoute = ""
    root.actionArgs = []
    root.actionOutput = ""
    root.actionPanel = false
  }

  // Pulls the chosen command out of a finished reply. Anything malformed, or
  // any route the catalogue does not know, is simply not an action: the reply
  // stays a reply and nothing runs.
  function extractAction(text) {
    var found = String(text || "").match(/```action\s*([\s\S]*?)```/)
    if (!found) return null
    try {
      var parsed = JSON.parse(found[1])

      // A setting of the panel's own. Only one exists, and only the agents
      // there is an adapter for are accepted as its value — an invented name
      // fails here exactly as an invented route would.
      if (parsed.panel !== undefined) {
        if (String(parsed.panel) !== "agent") return null
        var value = String(parsed.value || "")
        if (!agents.adapters[value]) return null
        return { route: "panel agent", args: [value], panel: true }
      }

      var route = String(parsed.route || "").replace(/\s+/g, " ")
      if (route.length === 0 || !catalogue.lookup(route)) return null
      var args = []
      if (Array.isArray(parsed.args))
        for (var i = 0; i < parsed.args.length; i++) args.push(String(parsed.args[i]))
      return { route: route, args: args, panel: false }
    } catch (e) {
      return null
    }
  }

  function runAction() {
    if (root.actionState !== "pending" && root.actionState !== "failed") return
    root.actionOutput = ""
    root.actionState = "running"
    if (root.actionPanel) root.applyAgent(String(root.actionArgs[0] || ""))
    else if (!runner.run(root.actionRoute, root.actionArgs)) root.actionState = "failed"
  }

  // Changes which agent answers here, and only here, by writing one key onto
  // this plugin's entry in shell.json. Omarchy's `default agent` is not
  // touched, so nothing is launched and nothing changes outside this pane.
  //
  // The shell does the writing, through the same call its own settings forms
  // use: it applies the change to its in-memory config first, which is what
  // this pane reads, and then saves the file. So the switch is felt at once,
  // and a save that fails is a switch that does not outlive the shell rather
  // than one that never happened. The rest of the entry is carried across, so
  // a model or a system prompt set by hand survives.
  function applyAgent(name) {
    if (!agents.adapters[name]) {
      root.actionState = "failed"
      root.actionOutput = "not an agent this panel knows"
      return
    }
    if (!root.shell || typeof root.shell.updateEntryInline !== "function") {
      root.actionState = "failed"
      root.actionOutput = "this shell cannot save a plugin's settings"
      return
    }

    var next = {}
    var current = config.entry
    for (var key in current) if (key !== "id") next[key] = current[key]
    next.agent = name

    root.shell.updateEntryInline(root.pluginId, next)
    console.log("lamha: panel agent set to " + name)
    root.actionState = "done"
    root.actionOutput = ""
  }

  readonly property string defaultPrompt:
    "You are a desktop assistant summoned by a keyboard shortcut on an Arch "
    + "Linux machine running Hyprland. Answer the question directly. Two or "
    + "three sentences is usually right; go longer only when the question "
    + "genuinely needs it. No preamble, no restating the question, no offers "
    + "of further help. Use markdown only where it earns its place."

  // What the agent is told it may do, and the list it must choose from. Present
  // only once the catalogue has been read; until then this is a panel that
  // answers questions and nothing else, which is the safe way round.
  readonly property string actionContract: !catalogue.ready ? "" :
    "\n\nYou can also carry out desktop settings changes on this machine, not "
    + "only answer questions. When the request is something one of the "
    + "commands below does, end your reply with a single fenced block:\n\n"
    + "```action\n{\"route\": \"omarchy theme bg next\", \"args\": []}\n```\n\n"
    + "Rules for that block:\n"
    + "- Use a route exactly as it is written in the list. Never invent one, "
    + "never shorten one, never guess at one that is not listed.\n"
    + "- Each argument is its own string in args. No shell quoting, no pipes, "
    + "no chaining.\n"
    + "- Before the block, say in one short sentence what you are doing.\n"
    + "- At most one block per reply, and only when a listed command genuinely "
    + "does what was asked. Otherwise answer normally and emit no block.\n"
    + "- A question about the state of the machine is often best answered by "
    + "the command that reports it.\n\n"
    + "What the list is, and is not:\n"
    + "- It is a narrowed subset of what Omarchy can do, not an inventory of "
    + "it. Commands were left out because they need root, install things, or "
    + "hand back a shell — not because they do not exist.\n"
    + "- So never reason from an absence. If something is not listed, that "
    + "means this panel will not do it; it does not mean the setting, the "
    + "command or the feature is missing from Omarchy. Say you cannot do it "
    + "from here, name the command the user can run themselves if you know "
    + "it, and do not tell them it does not exist.\n"
    + "\n"
    + "Two ways to change which agent answers, and they are not the same:\n"
    + "- `omarchy default agent <name>` is the listed command and changes the "
    + "whole desktop's default. Besides writing that setting it also opens a "
    + "terminal running that agent with its approvals turned off, and "
    + "installs it first if it is missing. Say so in your sentence before the "
    + "block, so the person pressing Enter knows a terminal is about to "
    + "appear.\n"
    + "- This panel has its own setting for the agent that answers here, "
    + "changing nothing else and launching nothing. Use a block of this shape "
    + "instead of a route:\n\n"
    + "```action\n{\"panel\": \"agent\", \"value\": \"opencode\"}\n```\n\n"
    + "- " + agents.agentList() + "\n"
    + "- Pick between them by what was asked. \"this panel\" or \"here\" is the "
    + "panel setting; \"default agent\" or \"desktop\" is the Omarchy command. "
    + "If it is genuinely ambiguous, offer the panel one and mention the "
    + "other in the same sentence.\n"
    + "- The agent answering right now is " + agents.name + ".\n\n"
    + "Commands:\n" + catalogue.promptBlock

  // --- copying, stopping, handing over -------------------------------------

  // The last thing the agent said, as it was said — without the command block,
  // which is machinery rather than an answer.
  //
  // A function, not a bound property: it reads the turns model, and a binding
  // over a ListModel is not re-evaluated when a row's text is filled in with
  // setProperty, which is exactly how a streamed answer arrives. Bound, this
  // stayed empty for the whole turn and Ctrl+Y copied nothing. Read fresh each
  // time it is asked, it is always the answer on screen.
  function lastAnswer() {
    for (var i = turns.count - 1; i >= 0; i--) {
      var turn = turns.get(i)
      if (turn.role === "user" || turn.failed) continue
      var text = String(turn.text || "").replace(/```action[\s\S]*?```/g, "")
        .replace(/^\s+|\s+$/g, "")
      if (text.length > 0) return text
    }
    return ""
  }

  function copyAnswer() {
    var text = root.lastAnswer()
    if (text.length === 0) {
      root.say("Nothing to copy yet")
      return
    }
    root.toClipboard(text)
    root.say("Copied the answer")
  }

  // Puts text on the clipboard. A fresh detached wl-copy each time, given the
  // text as one argument — no shell, so a semicolon or a newline in it is data
  // and never a second command. wl-copy forks and holds the selection on its
  // own, so nothing here has to be kept alive.
  //
  // The earlier version toggled one long-lived Process, which copied the first
  // time and silently refused every time after: wl-copy forks a resident child
  // and the tracked parent exits, so restarting it fought that lifecycle and
  // the clipboard stuck on whatever was copied first. A separate process per
  // copy has no such state to get wrong.
  //
  // An argument has a length ceiling a pipe would not, but it is far above any
  // answer this pane holds, let alone a highlighted piece of one.
  function toClipboard(text) {
    if (String(text || "").length === 0) return
    Quickshell.execDetached(["wl-copy", "--", String(text)])
  }

  // Copy on highlight. Selecting text in the answer puts it on the clipboard
  // the moment the selection settles, the way selecting in a terminal does —
  // no Ctrl+Y, no menu. It is debounced because a drag changes the selection
  // continuously, so the copy happens once the highlight stops growing rather
  // than on every character it sweeps over. The last thing copied is
  // remembered so an unchanged selection is not written again and again.
  property string lastSelection: ""

  function autoCopy(text) {
    var t = String(text || "")
    if (t.length === 0) { root.lastSelection = ""; return }
    if (t === root.lastSelection) return
    root.lastSelection = t
    root.toClipboard(t)
    // A quiet confirmation, so a highlight that copied is not indistinguishable
    // from a highlight that only looked selected. The word count says what
    // landed on the clipboard without repeating the selection back.
    var words = t.replace(/^\s+|\s+$/g, "").split(/\s+/).length
    root.say(words > 1 ? "Copied " + words + " words" : "Copied")
  }

  Timer {
    id: selectionCopyTimer
    interval: 200
    property string pending: ""
    onTriggered: root.autoCopy(selectionCopyTimer.pending)
  }

  // The escape hatch, and the reason a sealed panel can afford to stay sealed.
  //
  // Some questions turn out to want the machine rather than an answer, and
  // this pane is deliberately unable to give them that. Rather than loosen it
  // until it can, the whole conversation is handed to the same agent running
  // properly in a terminal, with its tools and its own approval prompts.
  // Omarchy's own launcher does the honours, so the agent is started exactly
  // as `omarchy agent` would start it.
  function handOver() {
    var lines = []
    for (var i = 0; i < session.history.length; i++) {
      var turn = session.history[i]
      lines.push((turn.role === "user" ? "Me: " : "You: ") + turn.text)
    }
    if (lines.length === 0) {
      var typed = root.phase === "answer" ? followField.text : askField.text
      typed = String(typed || "").replace(/^\s+|\s+$/g, "")
      if (typed.length === 0) return
      lines.push("Me: " + typed)
    } else {
      lines.unshift("We were talking in a desktop panel and I would like to "
        + "carry on here, where you can actually do things.")
    }
    Quickshell.execDetached(["omarchy", "agent", "prompt", lines.join("\n\n")])
    root.dismiss()
  }

  function say(message) {
    root.notice = message
    noticeTimer.restart()
  }

  function submit(text) {
    var trimmed = String(text || "").replace(/^\s+|\s+$/g, "")
    if (trimmed.length === 0 || session.busy) return

    // An agent that is missing, unsupported or still being looked for is worth
    // saying out loud in the field the question was typed into, rather than
    // letting the question vanish into a pane that never answers.
    if (!agents.supported || agents.problem.length > 0) {
      root.say(agents.problem.length > 0 ? agents.problem : "no agent")
      return
    }

    // Asking something new drops whatever the last turn offered to do. An
    // offer that outlived the question it came from would eventually be
    // accepted by someone who had forgotten what it was for.
    root.clearAction()

    if (root.phase === "ask") {
      root.topic = trimmed
      turns.append({ role: "agent", text: "", pending: true, failed: false })
      root.beginWaiting()
    } else {
      turns.append({ role: "user", text: trimmed, pending: false, failed: false })
      turns.append({ role: "agent", text: "", pending: true, failed: false })
      root.waitLabel = "Working"
      waitTimer.restart()
      patienceTimer.restart()
      followField.clear()
      Qt.callLater(body.toBottom)
    }

    session.ask(trimmed)
  }

  function startOver() {
    session.reset()
    turns.clear()
    root.topic = ""
    root.waitLabel = "Working"
    root.expanded = false
    root.setPhase("ask")
    askField.clear()
    session.warm()
    Qt.callLater(function () { askField.focusEditor() })
  }

  // The shrink. Pinch to a disc first, let go a beat later, and only then
  // start admitting who we are waiting on.
  function beginWaiting() {
    root.setPhase("thinking")
    root.pinched = true
    pinchTimer.restart()
    root.waitLabel = "Working"
    waitTimer.restart()
    patienceTimer.restart()
  }

  Timer {
    id: pinchTimer
    interval: 250
    onTriggered: root.pinched = false
  }

  Timer {
    id: noticeTimer
    interval: 2100
    onTriggered: root.notice = ""
  }

  Timer {
    id: waitTimer
    interval: 950
    onTriggered: root.waitLabel = root.askingLabel
  }

  // Only Claude sends an answer as it writes it. The rest hand over a finished
  // reply, so the pill sits there saying the same thing for the whole turn —
  // which after a few seconds is indistinguishable from a hang. Saying which
  // it is costs one line of text and buys the difference between waiting and
  // wondering.
  Timer {
    id: patienceTimer
    interval: 5500
    onTriggered: if (!session.streams) root.waitLabel = root.patienceLabel
  }

  // While streaming, markdown arrives half-written: a bold run whose closing
  // stars have not been typed yet, a code fence with no partner. Rendering
  // that literally makes the asterisks flash up and then vanish a token
  // later. Closing the open constructs off for as long as they are open keeps
  // the text settled, and costs nothing once the turn ends.
  function settled(text, streaming) {
    var out = String(text || "")

    // The chosen command is machinery, not prose. It is shown as a row of its
    // own below the answer, so it never appears as JSON in the middle of a
    // sentence — including while it is still arriving.
    out = out.replace(/```action[\s\S]*?```/g, "")
    var opening = out.indexOf("```action")
    if (opening !== -1) out = out.substring(0, opening)

    // The fence arrives a character at a time, so for a frame or two the tail
    // reads as bare backticks and then as half the word. Cut any tail that
    // could still become one of these blocks — but only a tail that spells the
    // start of "action", so a code fence in a real answer survives.
    if (streaming)
      out = out.replace(/```(?:a|ac|act|acti|actio|action)?\s*$/, "")

    out = out.replace(/\s+$/, "")

    if (!streaming) return out

    // Drop a marker run that is still being typed, then close whatever is
    // legitimately open. Underscores are left alone on purpose: snake_case
    // identifiers are far more common in answers than underscore emphasis,
    // and balancing them would mangle the identifiers.
    out = out.replace(/(\*{1,3}|`{1,3})+$/, "")

    var fences = (out.match(/```/g) || []).length
    if (fences % 2 === 1) { out += "\n```"; fences += 1 }

    var ticks = (out.match(/`/g) || []).length - fences * 3
    if (ticks % 2 === 1) out += "`"

    var strong = (out.match(/\*\*/g) || []).length
    if (strong % 2 === 1) { out += "**"; strong += 1 }

    var stars = (out.match(/\*/g) || []).length - strong * 2
    if (stars % 2 === 1) out += "*"

    return out
  }

  // --- morph ---------------------------------------------------------------
  //
  // Every shape change runs through here, because the curve is the difference
  // between states that swap and an object that moves.
  //
  // Only one move overshoots: the pill popping open from the disc, where the
  // pane holds nothing that reflows. Anywhere text is wrapped inside the pane,
  // an overshoot would wrap the paragraph at the wrong width and then wrap it
  // again on the way back — a settle you can read, which is the one kind of
  // motion worse than none.

  property int morphMs: 380
  property int morphEase: Easing.OutCubic
  property real morphOvershoot: 1.0

  function setPhase(next) {
    if (root.phase === next) return

    if (next !== "thinking") {
      pinchTimer.stop()
      waitTimer.stop()
      patienceTimer.stop()
      root.pinched = false
    }

    if (next === "thinking") {
      root.morphMs = 290
      root.morphEase = Easing.InOutQuart
      root.morphOvershoot = 1.0
    } else if (next === "answer") {
      root.morphMs = 460
      root.morphEase = Easing.OutQuint
      root.morphOvershoot = 1.0
    } else {
      root.morphMs = 330
      root.morphEase = Easing.OutCubic
      root.morphOvershoot = 1.0
    }

    root.phase = next
  }

  onPinchedChanged: {
    root.morphMs = root.pinched ? 290 : 380
    root.morphEase = root.pinched ? Easing.InOutQuart : Easing.OutBack
    root.morphOvershoot = root.pinched ? 1.0 : 1.5
  }

  onExpandedChanged: {
    root.morphMs = 420
    root.morphEase = Easing.OutQuint
    root.morphOvershoot = 1.0
  }

  // --- config --------------------------------------------------------------
  //
  // Settings live inline on this plugin's entry in ~/.config/omarchy/shell.json,
  // which is where the shell keeps every plugin's: there is no file of Lamha's
  // own to know about. The shell hands its parsed config in as
  // `shell.shellConfig` and re-reads the file whenever it changes, so this is
  // live without a watcher here.
  QtObject {
    id: config

    readonly property var entry: {
      var cfg = root.shell ? root.shell.shellConfig : null
      var list = cfg && Array.isArray(cfg.plugins) ? cfg.plugins : []
      for (var i = 0; i < list.length; i++)
        if (list[i] && list[i].id === root.pluginId) return list[i]
      return ({})
    }

    readonly property string model: String(config.entry.model || "")
    readonly property string systemPrompt: String(config.entry.systemPrompt || "")
    // Empty means "whatever the desktop's default agent is", which is the
    // answer that stays right when you change your mind in the menu.
    readonly property string agent: String(config.entry.agent || "")
  }

  // A monitor's own loopback is not a microphone. Offering dictation with no
  // way to hear anything would be a button that lies.
  Process {
    id: micProbe
    running: false
    command: ["bash", "-c",
      "pactl list short sources 2>/dev/null | grep -v '\\.monitor' | grep -q . "
      + "&& echo yes || echo no"]
    stdout: SplitParser {
      onRead: function (data) {
        root.micAvailable = String(data || "").indexOf("yes") === 0
      }
    }
  }

  // --- surface -------------------------------------------------------------

  PanelWindow {
    id: panel
    visible: root.opened
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore

    anchors { top: true; bottom: true; left: true; right: true }

    WlrLayershell.namespace: "lamha"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    // Everything lives inside this rather than directly in the window.
    // A layer surface's own width and height are not dependable to build a
    // layout on: between the window being created and the compositor giving
    // it a size it reports a hundred pixels square, and it can drop back to
    // that without telling anything that was watching. Bindings reading it
    // disagreed with each other — one state placed from the real screen
    // height, the next from the placeholder, which is what made the pane
    // jump. An ordinary Item filled to the window reports its size properly
    // and notifies when it changes, so every measurement below comes from
    // here and they all move together.
    Item {
      id: surface
      anchors.fill: parent

      // The last size the compositor actually gave this surface.
      //
      // A layer surface reports itself as a hundred pixels square before it is
      // configured, and drops back to that when it unmaps. Measuring from that
      // directly meant the pane's width, height and resting position all
      // collapsed the moment it was dismissed, and since those are animated,
      // the pane spent its fade-out shrinking toward the top-left corner and
      // its fade-in growing back out of it. That is the movement you could see
      // on every summon and every dismissal. Holding the last real size keeps
      // the geometry still while the surface comes and goes.
      property real stableWidth: 0
      property real stableHeight: 0
      onWidthChanged: if (width > 200) stableWidth = width
      onHeightChanged: if (height > 200) stableHeight = height

      readonly property real usableWidth: stableWidth > 0 ? stableWidth : width
      readonly property real usableHeight: stableHeight > 0 ? stableHeight : height

      // No scrim. What you were looking at is usually why you are asking.
      MouseArea {
        anchors.fill: parent
        onClicked: root.dismiss()
      }

      // --- geometry ---
      //
      // Every resting size and position is snapped to whole device pixels. On a
      // fractionally scaled screen a whole logical pixel is not a whole physical
      // one — at scale 1.25 a card one logical pixel wide lands a quarter of the
      // way into a physical pixel — and an edge that falls mid-pixel is drawn
      // across two of them. Invisible while something is moving, unmistakable
      // once it stops, and worst along a long straight side.
      function snap(value) {
        var ratio = panel.devicePixelRatio > 0 ? panel.devicePixelRatio : 1
        return Math.round(value * ratio) / ratio
      }

      readonly property real inset: Style.space(20)

      // The gap kept from the screen edges, snapped like everything else. The
      // shell's own value is in logical pixels and lands mid-pixel at a
      // fractional scale, which was enough to leave the expanded pane a quarter
      // of a pixel off the line the other states sit on.
      readonly property real edgeGap: surface.snap(Style.gapsOut)

      // The bar's resting height. Everything that has to line up with the bar —
      // its padding, where it sits, where the pill sits when it takes its
      // place — is measured from this one number rather than repeating it.
      readonly property real askBase: Style.space(48)

      readonly property real askWidth: surface.snap(
        Math.min(Style.space(620), surface.usableWidth * 0.54))
      readonly property real askPadY: surface.snap(
        Math.max(Style.space(8), (surface.askBase - askField.lineHeight) / 2))
      readonly property real askHeight: surface.snap(
        Math.max(surface.askBase, askField.wantedHeight + askPadY * 2))

      readonly property real waitHeight: surface.snap(Style.space(46))
      // Left inset, ring, gap, label, right inset — measured rather than
      // guessed, so the pill sits the same distance from the text at both ends
      // however wide the wording gets.
      readonly property real waitWidth: surface.snap(Math.max(Style.space(120),
        Style.space(37) + orbit.width + waitMetrics.width))

      // The one line everything hangs from. Bar, pill and pane all start here,
      // and every growth — a second line of question, the pane opening, the
      // pane expanding — goes downward from it.
      //
      // Each state used to be centred on its own idea of the right place: the
      // bar on a fifth of the screen, the pill on the bar, the pane on the
      // middle of the display. Three states, three top edges a few pixels
      // apart, and the whole thing appeared to sink a step at a time as it
      // worked. Anchoring the top makes it one object that changes shape.
      readonly property real restTop: surface.snap(surface.usableHeight * 0.18)

      // What is left below that line. The pane is capped by it, so expanding
      // makes the pane taller without ever moving its top edge or running off
      // the bottom of the screen.
      readonly property real roomBelow:
        surface.usableHeight - surface.restTop - surface.edgeGap

      // Floors on both, because a layer surface that has lost its screen — the
      // monitor sleeping is enough — reports itself as a hundred pixels square,
      // and the room-below cap then works out negative. A pane cannot be given
      // a negative size, and one that swallowed the screen would take every
      // click with it, so neither is left to chance.
      readonly property real paneWidth: surface.snap(Math.max(Style.space(280),
        Math.min(surface.usableWidth - surface.edgeGap * 2, root.expanded
          ? Math.min(Style.space(860), surface.usableWidth * 0.62)
          : Math.min(Style.space(560), surface.usableWidth * 0.44))))
      readonly property real paneHeight: surface.snap(Math.max(Style.space(220),
        Math.min(surface.roomBelow, root.expanded
          ? Math.min(Style.space(980), surface.usableHeight * 0.84)
          : Math.min(Style.space(700), surface.usableHeight * 0.66))))

      TextMetrics {
        id: waitMetrics
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        text: root.waitLabel
      }

      Item {
        id: card

        readonly property real targetWidth: {
          if (root.phase === "ask") return surface.askWidth
          if (root.phase === "thinking") return root.pinched ? surface.waitHeight
                                                            : surface.waitWidth
          return surface.paneWidth
        }
        readonly property real targetHeight: {
          if (root.phase === "ask") return surface.askHeight
          if (root.phase === "thinking") return surface.waitHeight
          return surface.paneHeight
        }
        // Constant. Kept as a binding rather than a literal so a monitor change
        // or a font-size change moves it, and clamped only so a pane can never
        // be pushed off the bottom of a very short screen.
        readonly property real targetY:
          Math.max(surface.edgeGap,
            Math.min(surface.restTop,
              surface.usableHeight - surface.edgeGap - card.targetHeight))

        width: targetWidth
        height: targetHeight
        y: targetY
        x: surface.snap((surface.usableWidth - width) / 2)

        // The capsule is the point, so this does not follow the theme's corner
        // radius down to a square. It does follow it up: a theme that rounds
        // its windows more than this gets a pane that matches.
        //
        // A single-line bar is a true pill, its ends full semicircles, because
        // there height/2 is the corner radius. A bar that has grown to two or
        // three lines is not: letting the radius keep pace with the height
        // turns it into a tall stadium, the whole left and right ends bulging
        // into half-circles. So the radius is held at the pill's own — the
        // corner it has when it is one line high — and the extra height stacks
        // as a rounded rectangle with the same corners top and bottom, the way
        // a text box grows rather than the way a lozenge inflates.
        readonly property real radius: root.phase === "answer"
          ? Math.max(Style.space(26), Style.cornerRadius)
          : Math.min(height / 2, surface.askBase / 2)

        // Only while the pane can be seen. Anything that changes shape while
        // it is hidden — a screen being reconfigured, the surface unmapping —
        // should be in place by the time it is shown again, not still on its
        // way there.
        Behavior on width {
          enabled: root.visibleNow
          NumberAnimation {
            duration: root.morphMs
            easing.type: root.morphEase
            easing.overshoot: root.morphOvershoot
          }
        }
        Behavior on height {
          enabled: root.visibleNow
          NumberAnimation {
            duration: root.morphMs
            easing.type: root.morphEase
            easing.overshoot: root.morphOvershoot
          }
        }
        Behavior on y {
          enabled: root.visibleNow
          NumberAnimation {
            duration: root.morphMs
            easing.type: Easing.OutQuint
          }
        }

        // Arrival and departure, and nothing else: the pane fades, it does not
        // move and it does not change size.
        //
        // It used to rise into place and drop back out, and to scale a little
        // as it went. Both were mistakes. The translate had no animation
        // attached at all, so dismissing jerked the surface down twelve pixels
        // in a single frame; the scale, small as it was, still swept a
        // twenty-three pixel change of width across the two tenths of a second
        // it took to fade. Against a shape this wide that reads as a flicker
        // rather than as a flourish. A summoned panel should arrive where it
        // is going to stay.
        opacity: root.visibleNow ? 1 : 0

        Behavior on opacity {
          NumberAnimation { duration: 130; easing.type: Easing.OutQuad }
        }

        Glass {
          id: glass
          anchors.fill: parent
          radius: card.radius
          tint: root.surface
          edge: root.foreground
          captureSource: panel.screen
          originX: card.x
          originY: card.y
          screenWidth: surface.usableWidth
          screenHeight: surface.usableHeight
        }

        // Clicks on the pane are not clicks on the desktop behind it.
        MouseArea {
          anchors.fill: parent
          onClicked: root.focusInput()
        }

        // Escape and the control keys reach here by propagation from whichever
        // field has focus, so there is one handler rather than one per input.
        Keys.onPressed: function (event) {
          if (event.key === Qt.Key_Escape) {
            root.dismiss()
            event.accepted = true
            return
          }

          if (!(event.modifiers & Qt.ControlModifier)) return

          switch (event.key) {
            case Qt.Key_C:
              // Only when there is a turn to stop. Otherwise Ctrl+C is left
              // alone, so it still copies the selection you dragged over.
              if (session.busy) {
                session.stop()
                root.say("Stopped")
                event.accepted = true
              }
              break
            case Qt.Key_Y:
              root.copyAnswer()
              event.accepted = true
              break
            case Qt.Key_E:
              root.handOver()
              event.accepted = true
              break
            case Qt.Key_N:
              root.startOver()
              event.accepted = true
              break
          }
        }

        // --- the bar you type into ---

        Item {
          id: askLayer
          anchors.fill: parent
          opacity: root.phase === "ask" ? 1 : 0
          visible: opacity > 0.01
          Behavior on opacity {
            NumberAnimation { duration: root.phase === "ask" ? 200 : 110 }
          }

          AskField {
            id: askField
            anchors.left: parent.left
            anchors.right: micButton.visible ? micButton.left : parent.right
            anchors.top: parent.top
            anchors.leftMargin: Style.space(26)
            anchors.rightMargin: Style.space(18)
            anchors.topMargin: surface.askPadY
            height: wantedHeight

            foreground: root.foreground
            fontFamily: Style.font.family
            // The same size as the answer and the follow-up field. The bar was
            // set larger to fill its height, which made the question and its
            // answer look like they came from two different applications.
            fontSize: Style.font.subtitle
            placeholder: root.notice.length > 0 ? root.notice
                       : dictation.listening ? "Listening…"
                       : root.askLabel
            maxHeight: Style.space(132)

            onAccepted: function (text) { root.submit(text) }
          }

          GlyphButton {
            id: micButton
            kind: "mic"
            tint: dictation.listening ? root.accent : root.foreground
            pulsing: dictation.listening
            filled: false
            visible: root.micAvailable
            diameter: Style.space(30)
            iconSize: Style.font.iconLarge
            anchors.right: parent.right
            anchors.rightMargin: Style.space(18)
            anchors.top: parent.top
            anchors.topMargin: Math.round((surface.askBase - height) / 2)
            onClicked: dictation.start(askField)
          }
        }

        // --- the waiting pill ---

        Item {
          id: waitLayer
          anchors.fill: parent
          opacity: (root.phase === "thinking" && !root.pinched) ? 1 : 0
          visible: opacity > 0.01
          Behavior on opacity { NumberAnimation { duration: 180 } }

          Orbit {
            id: orbit
            anchors.left: parent.left
            anchors.leftMargin: Style.space(13)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(24)
            height: Style.space(24)
            tint: root.foreground
          }

          // Both labels are drawn, so the change of wording is a dissolve on the
          // spot rather than a word being replaced between frames.
          Item {
            anchors.left: orbit.right
            anchors.leftMargin: Style.space(9)
            anchors.verticalCenter: parent.verticalCenter
            width: waitMetrics.width
            height: waitMetrics.height

            Repeater {
              model: ["Working", root.askingLabel, root.patienceLabel]

              Text {
                text: modelData
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                renderType: Text.QtRendering
                opacity: root.waitLabel === modelData ? 0.92 : 0
                Behavior on opacity { NumberAnimation { duration: 420 } }
              }
            }
          }
        }

        // --- the answer ---

        Item {
          id: paneLayer
          anchors.fill: parent
          opacity: root.phase === "answer" ? 1 : 0
          visible: opacity > 0.01
          Behavior on opacity { NumberAnimation { duration: 260 } }

          // The content arrives just behind the shape, so the pane opens and is
          // then filled rather than growing with a finished page inside it.
          transform: Translate {
            y: root.phase === "answer" ? 0 : Style.space(12)
            Behavior on y {
              NumberAnimation { duration: 320; easing.type: Easing.OutCubic }
            }
          }

          GlyphButton {
            id: closeButton
            kind: "close"
            tint: root.foreground
            diameter: Style.space(26)
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.margins: surface.inset
            onClicked: root.dismiss()
          }

          // The question, kept in view but out of the way — you asked it, you do
          // not need to read it again, you need to know which answer this is.
          Text {
            anchors.left: closeButton.right
            anchors.right: expandButton.left
            anchors.verticalCenter: closeButton.verticalCenter
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            horizontalAlignment: Text.AlignHCenter
            text: root.topicLine
            maximumLineCount: 1
            elide: Text.ElideRight
            color: Qt.alpha(root.foreground, 0.32)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            renderType: Text.QtRendering
          }

          GlyphButton {
            id: expandButton
            kind: root.expanded ? "collapse" : "expand"
            tint: root.foreground
            diameter: Style.space(26)
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: surface.inset
            onClicked: root.expanded = !root.expanded
          }

          Flickable {
            id: body
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: closeButton.bottom
            anchors.bottom: composer.top
            anchors.topMargin: Style.space(20)
            anchors.bottomMargin: Style.space(12)
            anchors.leftMargin: surface.inset
            anchors.rightMargin: surface.inset
            clip: true
            contentWidth: width
            contentHeight: column.implicitHeight
            boundsBehavior: Flickable.StopAtBounds

            function toBottom() {
              body.contentY = Math.max(0, body.contentHeight - body.height)
            }

            // Follow the stream, but only from the bottom: scrolling up to read
            // something should not be undone by the next token.
            onContentHeightChanged: {
              if (contentY >= contentHeight - height - Style.space(80)) toBottom()
            }

            // Capped and centred rather than filling the pane. Expanding is for
            // seeing more of the answer at once, not for stretching each line to
            // a hundred characters — past about eighty the eye loses the start
            // of the next line on the way back.
            Column {
              id: column
              width: Math.min(body.width, Style.space(660))
              x: Math.round((body.width - width) / 2)
              spacing: Style.space(18)

              Repeater {
                model: turns

                // One delegate for both kinds of turn rather than a Loader per
                // row: a Component declared elsewhere cannot see the delegate's
                // scope, and reaching the model through a Loader costs more code
                // than simply hiding the half that does not apply.
                Item {
                  id: entry

                  readonly property string entryText: model.text
                  readonly property bool entryPending: model.pending
                  readonly property bool entryFailed: model.failed
                  readonly property bool fromUser: model.role === "user"
                  readonly property bool streaming:
                    session.busy && index === turns.count - 1

                  width: column.width
                  implicitHeight: entry.fromUser ? saidBlock.implicitHeight
                                                 : answerBlock.implicitHeight
                  height: implicitHeight

                  // What you said, set to the right the way a reply is.
                  Item {
                    id: saidBlock
                    width: parent.width
                    visible: entry.fromUser
                    implicitHeight: bubble.height

                    Rectangle {
                      id: bubble
                      anchors.right: parent.right
                      width: Math.round(Math.min(parent.width * 0.8,
                        bubbleText.implicitWidth + Style.space(26)))
                      height: Math.round(bubbleText.implicitHeight + Style.space(16))
                      radius: Style.space(14)
                      antialiasing: true
                      color: Qt.alpha(root.foreground, 0.1)

                      Text {
                        id: bubbleText
                        anchors.fill: parent
                        anchors.leftMargin: Style.space(13)
                        anchors.rightMargin: Style.space(13)
                        anchors.topMargin: Style.space(8)
                        anchors.bottomMargin: Style.space(8)
                        text: entry.entryText
                        textFormat: Text.PlainText
                        color: root.foreground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.subtitle
                        renderType: Text.QtRendering
                        wrapMode: Text.Wrap
                      }
                    }
                  }

                  Column {
                    id: answerBlock
                    width: parent.width
                    visible: !entry.fromUser
                    spacing: Style.space(8)

                    Row {
                      spacing: Style.space(8)

                      Mark {
                        width: Style.space(13)
                        height: Style.space(13)
                        anchors.verticalCenter: parent.verticalCenter
                        tint: entry.entryFailed ? Color.urgent : root.accent
                        working: entry.entryPending || entry.streaming
                      }

                      Text {
                        text: agents.label
                        color: Qt.alpha(root.foreground, 0.75)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        font.bold: true
                        renderType: Text.QtRendering
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      // How far this agent is actually shut in. Claude can be
                      // left with no tools at all; the others keep theirs and
                      // are held to reading. That is a real difference and the
                      // person asking is the one carrying it, so it is said
                      // here rather than smoothed over — quietly, because it
                      // is the answer you came for, not this.
                      Rectangle {
                        visible: agents.seal.length > 0 && agents.seal !== "unknown"
                        anchors.verticalCenter: parent.verticalCenter
                        width: sealText.implicitWidth + Style.space(12)
                        height: sealText.implicitHeight + Style.space(4)
                        radius: height / 2
                        antialiasing: true
                        color: Qt.alpha(root.foreground, 0.08)

                        Text {
                          id: sealText
                          anchors.centerIn: parent
                          text: agents.seal
                          color: Qt.alpha(root.foreground, 0.45)
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                          renderType: Text.QtRendering
                        }

                        MouseArea {
                          anchors.fill: parent
                          hoverEnabled: true
                          onEntered: root.say(agents.sealNote)
                          onExited: if (root.notice === agents.sealNote) root.notice = ""
                        }
                      }
                    }

                    // While there is nothing to show, the pill's own wording
                    // carries on inside the pane, so a follow-up waits the same
                    // way the first question did.
                    Row {
                      visible: entry.entryPending
                      spacing: Style.space(9)

                      Orbit {
                        width: Style.space(20)
                        height: Style.space(20)
                        tint: root.foreground
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      Text {
                        text: root.waitLabel
                        color: Qt.alpha(root.foreground, 0.55)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        renderType: Text.QtRendering
                        anchors.verticalCenter: parent.verticalCenter
                      }
                    }

                    // Read-only, but still a text editor: that is what makes the
                    // answer selectable and copyable, which a panel you cannot
                    // get the text out of would not be.
                    TextEdit {
                      width: answerBlock.width
                      visible: !entry.entryPending
                      text: root.settled(entry.entryText, entry.streaming)
                      readOnly: true
                      selectByMouse: true
                      textFormat: TextEdit.PlainText
                      wrapMode: TextEdit.Wrap
                      renderType: Text.QtRendering
                      color: entry.entryFailed ? Color.urgent : root.foreground
                      selectionColor: Style.selectionFill
                      selectedTextColor: root.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.subtitle

                      // Copy on highlight. A drag reports the selection as it
                      // grows, so the copy is deferred to when it settles
                      // rather than run for every character swept over.
                      onSelectedTextChanged: {
                        if (selectedText.length === 0) return
                        selectionCopyTimer.pending = selectedText
                        selectionCopyTimer.restart()
                      }
                    }
                  }
                }
              }

              // --- what it is about to do, or has just done ---
              //
              // The command is always shown, even when it ran by itself. A panel
              // that quietly changes settings and tells you only in prose is a
              // panel you cannot audit; this way the exact thing that ran is on
              // screen, in the machine's own words.
              Item {
                width: column.width
                visible: root.actionState !== "none"
                // A Column lays its children out by their height, so a wrapper
                // that only states what it would like to be gets none, and its
                // contents are drawn over whatever came before.
                implicitHeight: visible ? deed.height : 0
                height: implicitHeight

                Rectangle {
                  id: deed
                  width: parent.width
                  implicitHeight: deedRows.implicitHeight + Style.space(20)
                  height: implicitHeight
                  radius: Style.space(12)
                  antialiasing: true
                  color: Qt.alpha(root.actionState === "failed" ? Color.urgent
                                                                : root.accent, 0.09)
                  border.width: 1
                  border.color: Qt.alpha(root.actionState === "failed" ? Color.urgent
                                                                       : root.accent, 0.22)

                  Column {
                    id: deedRows
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Style.space(10)
                    anchors.leftMargin: Style.space(13)
                    anchors.rightMargin: Style.space(13)
                    spacing: Style.space(7)

                    Text {
                      width: parent.width
                      text: root.actionRoute
                        + (root.actionArgs.length > 0
                           ? " " + root.actionArgs.join(" ") : "")
                      color: root.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      renderType: Text.QtRendering
                      wrapMode: Text.Wrap
                    }

                    Row {
                      spacing: Style.space(8)
                      visible: root.actionState === "running"

                      Orbit {
                        width: Style.space(16)
                        height: Style.space(16)
                        tint: root.foreground
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      Text {
                        text: "Running…"
                        color: Qt.alpha(root.foreground, 0.55)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        renderType: Text.QtRendering
                        anchors.verticalCenter: parent.verticalCenter
                      }
                    }

                    // Output is worth showing: half of what you ask a desktop is
                    // a question its own commands already answer.
                    Text {
                      width: parent.width
                      visible: (root.actionState === "failed"
                                || (root.actionState === "done"
                                    && root.actionReports))
                               && root.actionOutput.length > 0
                      text: root.actionOutput
                      color: root.actionState === "failed"
                        ? Color.urgent : Qt.alpha(root.foreground, 0.7)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      renderType: Text.QtRendering
                      wrapMode: Text.Wrap
                      maximumLineCount: 8
                      elide: Text.ElideRight
                    }

                    Text {
                      visible: root.actionState === "done"
                               && (root.actionOutput.length === 0
                                   || !root.actionReports)
                      text: "Done"
                      color: Qt.alpha(root.foreground, 0.55)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      renderType: Text.QtRendering
                    }

                    // The consent line. Clickable, and Enter takes it too while
                    // the follow-up field is empty.
                    Text {
                      visible: root.actionState === "pending"
                      text: "Press Enter to run this"
                      color: root.accent
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      renderType: Text.QtRendering

                      MouseArea {
                        anchors.fill: parent
                        anchors.margins: -Style.space(6)
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.runAction()
                      }
                    }
                  }
                }
              }
            }

          }

          // --- the follow-up row ---

          Item {
            id: composer
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: surface.inset
            height: Math.round(Math.max(Style.space(40),
              followField.wantedHeight + Style.space(18)))

            GlyphButton {
              id: newButton
              kind: "new"
              tint: root.foreground
              diameter: Style.space(30)
              iconSize: Style.font.iconLarge
              anchors.left: parent.left
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Math.round((Style.space(40) - height) / 2)
              // Same pane, new conversation: fold back to the bar rather than
              // clearing in place, so it is unmistakable that the thread is gone
              // rather than merely scrolled out of sight.
              onClicked: root.startOver()
            }

            Rectangle {
              id: followBox
              anchors.left: newButton.right
              anchors.right: followMic.visible ? followMic.left : parent.right
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(8)
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              radius: Math.round(Style.space(40) / 2)
              antialiasing: true
              color: Qt.alpha(root.foreground, 0.07)
              border.width: 1
              border.color: Qt.alpha(root.foreground, 0.10)

              AskField {
                id: followField
                anchors.left: parent.left
                anchors.right: clearButton.left
                anchors.top: parent.top
                anchors.leftMargin: Style.space(16)
                anchors.rightMargin: Style.space(6)
                anchors.topMargin: Math.round((Style.space(40) - lineHeight) / 2)
                height: wantedHeight

                foreground: root.foreground
                fontFamily: Style.font.family
                fontSize: Style.font.subtitle
                // A notice in the answer pane rides the toast chip above, not
                // this placeholder: down here in placeholder grey it read as
                // the idle prompt, so a copy changed nothing the eye caught.
                placeholder: dictation.listening ? "Listening…"
                           : session.busy ? "Waiting for " + agents.label + "…"
                           : root.askLabel
                maxHeight: Style.space(76)

                // Enter on an empty field takes up the offer, if there is one.
                // Typing first and pressing Enter asks a new question instead,
                // so consent is never something you give by accident while
                // reaching for the next thing to say.
                onAccepted: function (text) {
                  if (String(text || "").replace(/^\s+|\s+$/g, "").length === 0) {
                    if (root.actionState === "pending") root.runAction()
                    return
                  }
                  root.submit(text)
                }
              }

              GlyphButton {
                id: clearButton
                kind: "close"
                tint: root.foreground
                diameter: Style.space(18)
                iconSize: Style.font.iconSmall
                opacity: followField.length > 0 ? 1 : 0
                visible: opacity > 0.01
                Behavior on opacity { NumberAnimation { duration: 140 } }
                anchors.right: parent.right
                anchors.rightMargin: Style.space(9)
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Math.round((Style.space(40) - height) / 2)
                onClicked: {
                  followField.clear()
                  followField.focusEditor()
                }
              }
            }

            GlyphButton {
              id: followMic
              kind: "mic"
              tint: dictation.listening ? root.accent : root.foreground
              pulsing: dictation.listening
              filled: false
              visible: root.micAvailable
              diameter: Style.space(30)
              iconSize: Style.font.iconLarge
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Math.round((Style.space(40) - height) / 2)
              onClicked: dictation.start(followField)
            }
          }

          // --- the toast --------------------------------------------------

          // A word said where the eye already is. Copy feedback used to ride
          // the follow field's placeholder: faint by design, at the far foot
          // of the pane, wearing the same grey as the idle "Ask" prompt — so a
          // copy landed with nothing you could see change. This is a chip
          // instead, in the theme's accent so it stands off the muted glass
          // rather than sinking into it. It fades up over the foot of the
          // answer, holds for the notice's few seconds, and drops back out.
          Item {
            id: toast
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: composer.top
            anchors.bottomMargin: Style.space(16)
            width: toastLabel.implicitWidth + Style.space(34)
            height: Style.space(36)

            readonly property bool shown:
              root.phase === "answer" && root.notice.length > 0

            // The last thing it said, kept even after the notice clears. The
            // chip's width follows its text, and the text going empty as the
            // notice expired collapsed the pill to its fixed height — a circle
            // — for the length of the fade. Holding the label means the chip
            // fades out at the size it was read at, and only takes a new width
            // when there is a new thing to say.
            property string label: ""
            Connections {
              target: root
              function onNoticeChanged() {
                if (root.notice.length > 0) toast.label = root.notice
              }
            }

            // Text that stays legible on whatever the accent is: dark ink on a
            // pale accent, light on a dark one, the same luminance test the
            // glass uses to stay readable on either kind of theme.
            readonly property color onAccent:
              (0.2126 * root.accent.r + 0.7152 * root.accent.g
                + 0.0722 * root.accent.b) > 0.6
              ? Qt.rgba(0, 0, 0, 0.9) : Qt.rgba(1, 1, 1, 0.96)

            // Simple and symmetric: it comes up from below as it appears and
            // goes back down the same way as it leaves, the fade and the slide
            // sharing one duration and one curve so they read as a single move
            // rather than two effects that happen to overlap.
            opacity: shown ? 1 : 0
            visible: opacity > 0.01
            transform: Translate {
              y: toast.shown ? 0 : Style.space(8)
              Behavior on y {
                NumberAnimation { duration: 200; easing.type: Easing.OutQuad }
              }
            }

            Behavior on opacity {
              NumberAnimation { duration: 200; easing.type: Easing.OutQuad }
            }

            Rectangle {
              anchors.fill: parent
              radius: height / 2
              color: root.accent
              antialiasing: true
            }

            Text {
              id: toastLabel
              anchors.centerIn: parent
              text: toast.label
              color: toast.onAccent
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.weight: Font.DemiBold
            }
          }
        }
      }
    }
  }

  // --- dictation -----------------------------------------------------------

  Dictation {
    id: dictation
    pluginDir: {
      var dir = Qt.resolvedUrl(".").toString()
      return dir.startsWith("file://") ? dir.substring(7) : dir
    }
    onFailed: function (message) {
      root.notice = message
      noticeTimer.restart()
    }
  }
}
