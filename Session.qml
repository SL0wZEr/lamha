import QtQuick
import Quickshell
import Quickshell.Io

// The conversation, however the chosen agent wants to be spoken to.
//
// There are two shapes of agent behind this one interface.
//
// A session agent — only Claude, today — holds the conversation open on
// stdin. The process starts the moment the bar opens, so start-up is paid
// while you are still typing and every turn after the first is inference and
// nothing else. That is the whole reason this feels instant, and it is worth
// saying plainly that no other CLI here can do it: re-running a binary per
// question costs about a second a turn before the model has read a word.
//
// A one-shot agent is run again for each question, and the thread is ours to
// carry: Lamha replays the transcript as part of the prompt. The alternative
// is each CLI's own resume flag, and those are the least reliable surface any
// of them expose — resume-latest races every other session you have open and
// answers the wrong question without telling you.
//
// Either way the agent gets an empty working directory and the hardest
// lockdown its own flags allow. See Agents.qml for what that means per agent.
//
// One fact about the Process underneath shapes most of what follows: setting
// `running` to false asks the process to go, but `running` keeps reading true
// until it has actually gone, a few milliseconds later. Anything that ends a
// process and then wants a new one — a stopped turn, a change of agent, a new
// conversation — cannot start it straight away. It says what it wants and the
// exit handler does it, once the old process is out of the way.
Item {
  id: session

  property var agents: null

  signal delta(string text)
  signal whole(string text)
  signal turnFinished()
  signal failed(string message)

  property string model: ""
  property string systemPrompt: ""

  // True from the moment a question goes out until the agent's turn ends. The
  // panel uses it to keep the waiting mark up and to refuse a second question
  // mid-turn.
  property bool busy: false

  // Whether the system prompt is final. It is fixed when a session process
  // starts, so a conversation begun before the command list has been read is
  // one that never learns what it may do, for as long as it lives. Questions
  // asked in the meantime queue up and go out the moment the process starts.
  property bool armed: true

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/lamha/session"

  readonly property bool sessionMode:
    session.agents && session.agents.adapter
    && session.agents.adapter.mode === "session"

  // Whether answers arrive a token at a time or all at once. The pane says so:
  // an agent that cannot stream leaves the pill up for the whole turn, and
  // that should read as this agent's nature rather than as a hang.
  readonly property bool streams:
    session.agents && session.agents.adapter
    ? session.agents.adapter.streams === true : false

  // The thread, kept by us whatever the agent does with its own. It feeds the
  // one-shot agents their context, it survives a stopped turn, and it is what
  // gets handed over when a question turns out to be bigger than this pane.
  property var history: []

  property string _answer: ""
  property string _stderr: ""
  property string _raw: ""
  property var _queue: []

  // The question in flight, as typed. If the agent changes under it — or the
  // binary was still being looked for when it was asked — it is put to
  // whoever is answering now, rather than left as a row that never fills in.
  property string _asked: ""

  // An answer that arrives in named pieces. opencode sends one text part per
  // step, each whole and each with its own id, and a reply that took two steps
  // is two parts that belong end to end — so they are kept in order and
  // rejoined rather than overwriting one another. A part that arrives twice
  // under the same id replaces itself, which is also how a CLI that re-sends a
  // growing part would work.
  property var _parts: []

  // Set when a session process is gone mid-thread. The next question then
  // carries the transcript with it, so losing the process costs the process
  // and not the conversation.
  property bool _replay: false

  // A one-shot agent's turn ends when its output says so, which is a moment
  // before its process is actually gone. A follow-up asked in that window —
  // and that window is exactly when a follow-up gets asked, because the answer
  // is on screen — would find the old process still running and quietly go
  // nowhere. So it waits here and goes out as soon as the old one is clear.
  property string _pending: ""

  // Whether the running process's turn still has to be reported. It is what
  // tells an exit that ends a turn apart from an exit that is just the last
  // turn's process finally letting go.
  property bool _turnOpen: false

  // Set the moment this side tells the process to go, and cleared when a new
  // one starts. An exit that was asked for is not news about the turn; it is
  // the cue to start whatever was waiting on it.
  property bool _dropped: false

  // A session agent wanted warm while the last process was still leaving. It
  // is started from the exit handler instead, so a new conversation is not
  // left cold until its first question.
  property bool _rewarm: false

  // Whether anything in this turn's output was recognised. A CLI that changes
  // its event names between releases would otherwise leave a blank pane; if
  // nothing parsed and the process exited cleanly, whatever it printed is
  // shown instead of nothing.
  property bool _understood: false

  function part(key, text) {
    for (var i = 0; i < session._parts.length; i++) {
      if (session._parts[i].key === key) {
        session._parts[i].text = text
        return
      }
    }
    session._parts.push({ key: key, text: text })
  }

  function joined() {
    var out = ""
    for (var i = 0; i < session._parts.length; i++) out += session._parts[i].text
    return out
  }

  function argv(prompt) {
    return session.agents.adapter.argv(session.agents.binary, {
      model: session.model,
      systemPrompt: session.systemPrompt,
      prompt: prompt || ""
    })
  }

  // Called when the overlay opens, long before there is anything to ask. For a
  // session agent this is the whole trick. For a one-shot agent there is
  // nothing to start early, but the binary is worth finding now rather than on
  // the keystroke.
  //
  // `again` is a fresh summon: worth one more look for a binary that was not
  // there last time, in case it has been installed since.
  function warm(again) {
    if (!session.agents) return
    if (!session.agents.supported) return
    if (session.agents.binary.length === 0) {
      session.agents.resolve(again === true)
      return
    }
    if (!session.sessionMode) return
    if (!session.armed) return
    if (proc.running) {
      if (session._dropped) session._rewarm = true
      return
    }
    start("")
  }

  function start(prompt) {
    if (proc.running) return
    if (!session.agents || session.agents.binary.length === 0) return
    session._stderr = ""
    session._raw = ""
    session._parts = []
    session._understood = false
    session._turnOpen = true
    session._dropped = false
    session._rewarm = false
    proc.command = session.argv(prompt)
    proc.stdinEnabled = true
    proc.running = true
  }

  function ask(text) {
    var trimmed = String(text || "").replace(/^\s+|\s+$/g, "")
    if (!trimmed) return false

    // One question at a time. The pane refuses a second one itself, but the
    // rule belongs here, where the thread is kept.
    if (session.busy) return false

    if (!session.agents || !session.agents.supported) {
      session.failed(session.agents ? session.agents.problem : "no agent")
      return false
    }
    if (session.agents.binary.length === 0) {
      // Still looking, or nothing to find. Either way the question waits; if
      // the search comes back empty the failure arrives from there.
      session.agents.resolve()
      if (!session.agents.resolving) {
        session.failed(session.agents.problem)
        return false
      }
    }

    session.busy = true
    session._asked = trimmed
    session._answer = ""
    session._parts = []
    session.history.push({ role: "user", text: trimmed })

    if (session.sessionMode) {
      // What start() does per process, done per turn instead, since the
      // process outlives the turn here.
      session._raw = ""
      session._stderr = ""
      session._understood = false
      session._turnOpen = true

      // A lost thread is rebuilt by sending what was said before along with
      // what is being asked now.
      var payload = trimmed
      if (session._replay) {
        payload = session.agents.compose(session.systemPrompt,
                                         session.history.slice(0, -1), trimmed)
        session._replay = false
      }
      session._queue.push(payload)

      // A process on its way out is not written to; the exit handler starts
      // a fresh one and the queue goes out then.
      if (proc.running && !session._dropped) flush()
      else if (!proc.running) warm()
    } else {
      var composed = session.agents.compose(session.systemPrompt,
                                            session.history.slice(0, -1), trimmed)
      if (proc.running) session._pending = composed
      else start(composed)
    }
    guard.restart()
    return true
  }

  function flush() {
    if (!proc.running) return
    while (session._queue.length > 0) {
      var text = session._queue.shift()
      proc.write(JSON.stringify({
        type: "user",
        message: { role: "user", content: [{ type: "text", text: text }] }
      }) + "\n")
    }
  }

  function drop() {
    if (!proc.running) return
    session._dropped = true
    proc.running = false
  }

  // Stops the turn in flight. The thread survives: a one-shot agent was never
  // holding it, and a session agent's is rebuilt from our own transcript on
  // the next question.
  function stop() {
    if (!session.busy) return
    guard.stop()
    session._turnOpen = false
    session._pending = ""
    session._queue = []
    session.busy = false
    if (session.sessionMode) session._replay = true
    session.drop()
    // Half an answer is still an answer, and keeping it means a follow-up can
    // refer to it. An empty one is not worth remembering.
    session.remember()
    session.turnFinished()
  }

  // Called when the agent changes under a conversation — from the menu, from
  // the panel's own setting, or simply because the binary has now been found.
  // The old process belongs to the old agent and is let go; the thread is
  // not, so whoever is answering now gets what was said before. A question
  // that was in flight was never answered, so it comes out of the transcript
  // and is put again, composed afresh for the new agent.
  function rebind() {
    guard.stop()
    var again = session.busy ? session._asked : ""
    session._asked = ""
    session._queue = []
    session._pending = ""
    session._turnOpen = false
    session._answer = ""
    session._parts = []
    session.busy = false
    session.drop()
    if (again.length > 0 && session.history.length > 0
        && session.history[session.history.length - 1].role === "user")
      session.history.pop()
    session._replay = session.history.length > 0
    if (again.length > 0) session.ask(again)
    else session.warm()
  }

  // Ends the conversation. The next summon starts a new one, which is what you
  // want from something reached for by reflex: yesterday's thread is not
  // context for today's question.
  function reset() {
    guard.stop()
    session._queue = []
    session.history = []
    session._answer = ""
    session._asked = ""
    session._replay = false
    session._pending = ""
    session._turnOpen = false
    session._rewarm = false
    session.busy = false
    session.drop()
  }

  // The command block is machinery rather than something that was said, so it
  // does not go into the transcript that gets replayed or handed over.
  function remember() {
    var text = String(session._answer || "")
      .replace(/```action[\s\S]*?```/g, "")
      .replace(/^\s+|\s+$/g, "")
    if (text.length > 0) session.history.push({ role: "assistant", text: text })
    session._answer = ""
  }

  function handle(line) {
    if (session._raw.length < 20000) session._raw += line + "\n"

    var record
    try {
      record = JSON.parse(line)
    } catch (e) {
      return
    }

    var result
    try {
      result = session.agents.adapter.parse(record)
    } catch (e) {
      return
    }
    if (!result) return
    session._understood = true

    if (typeof result.text === "string" && result.text.length > 0) {
      session._answer += result.text
      session.delta(result.text)
    }

    // A whole piece of the answer rather than the piece that is new. With a
    // key it is one named part of several; without one it is the lot.
    if (typeof result.whole === "string") {
      if (result.key) {
        session.part(String(result.key), result.whole)
        session._answer = session.joined()
      } else {
        session._answer = result.whole
      }
      session.whole(session._answer)
    }

    if (result.error) {
      guard.stop()
      session.busy = false
      session._turnOpen = false
      session._answer = ""
      session.failed(String(result.error))
      session.close()
      return
    }

    if (result.done) {
      guard.stop()
      session.busy = false
      session._turnOpen = false
      session.remember()
      session.turnFinished()
      session.close()
    }
  }

  // A one-shot agent is finished with when its turn is: holding the process
  // open past its own last word buys nothing and delays the next question.
  // Reported first, then closed, so a follow-up asked from the report lands in
  // _pending rather than racing the shutdown.
  function close() {
    if (session.sessionMode) return
    session.drop()
  }

  // An agent that never answers would otherwise leave the pill up for as long
  // as the pane is open. A session agent loses its process along with the
  // turn; the thread it was holding comes back with the next question.
  Timer {
    id: guard
    interval: 180000
    onTriggered: {
      if (!session.busy) return
      session.busy = false
      session._turnOpen = false
      session._answer = ""
      session._queue = []
      session._pending = ""
      if (session.sessionMode) session._replay = session.history.length > 0
      session.drop()
      session.failed(session.agents.label + " did not answer in three minutes")
    }
  }

  Process {
    id: proc
    running: false
    stdinEnabled: true
    workingDirectory: session.stateDir

    stdout: SplitParser {
      onRead: function (data) { session.handle(String(data || "")) }
    }
    stderr: SplitParser {
      onRead: function (data) {
        if (session._stderr.length < 800) session._stderr += String(data || "") + "\n"
      }
    }

    onStarted: {
      if (session.sessionMode) {
        session.flush()
      } else {
        // The prompt went in on the command line, so there is nothing to send.
        // Closing stdin is what tells a CLI that reads it — Codex does — that
        // there is no more input coming and it may get on with the question.
        proc.stdinEnabled = false
      }
    }

    onExited: function (code, status) {
      // Asked to go, and gone. Nothing about the turn is learned from this;
      // what it does is clear the way for whatever was waiting on it — a
      // one-shot follow-up, a session agent's queued question, or a warm
      // start for a conversation that has only just begun.
      if (session._dropped) {
        session._dropped = false
        var waiting = session._pending
        session._pending = ""
        if (waiting.length > 0) session.start(waiting)
        else if (session.sessionMode
                 && (session._rewarm || (session.busy && session._queue.length > 0)))
          session.warm()
        return
      }

      // From here on the process ended of its own accord. A session agent
      // that is gone took its copy of the thread with it; ours is intact, and
      // the next question carries it.
      if (session.sessionMode && session.history.length > 0) session._replay = true

      // A one-shot process whose turn was already reported ends nothing by
      // exiting late.
      if (!session.sessionMode && !session._turnOpen) {
        var late = session._pending
        session._pending = ""
        if (late.length > 0) session.start(late)
        return
      }
      session._turnOpen = false

      if (!session.busy) {
        session._queue = []
        return
      }

      // The output parsed, and said the turn was over, but the process is
      // gone before we were told. Treat the exit as the ending.
      if (code === 0 && session._understood) {
        guard.stop()
        session.busy = false
        session.remember()
        session.turnFinished()
        return
      }

      // Nothing in the output was recognised. Rather than show a blank pane —
      // which is what an adapter gone stale against a CLI release looks like —
      // show what the agent actually printed.
      if (code === 0 && !session._understood) {
        var text = session.plain(session._raw)
        guard.stop()
        session.busy = false
        if (text.length > 0) {
          session._answer = text
          session.whole(text)
          session.remember()
          session.turnFinished()
        } else {
          session.failed(session.agents.label + " answered with nothing")
        }
        return
      }

      guard.stop()
      session.busy = false
      session._answer = ""
      session._queue = []
      var detail = session.tidy(session._stderr).split("\n")[0]
      session.failed(detail.length > 0 ? detail
                   : (session.sessionMode ? session.agents.label + " exited before answering"
                                          : session.agents.label + " failed"))
    }
  }

  // Output written for a terminal: colour escapes, carriage returns, runs of
  // blank lines. None of that belongs in a pane.
  function tidy(text) {
    return String(text || "")
      .replace(/\[[0-9;?]*[A-Za-z]/g, "")
      .replace(/\r/g, "")
      .replace(/\n{3,}/g, "\n\n")
      .replace(/^\s+|\s+$/g, "")
  }

  // The last-resort reading of a stream the adapter made nothing of — which is
  // what an adapter gone stale against a CLI release looks like from here.
  //
  // Plain lines are kept as they are. JSON lines are worth more than throwing
  // away, though: every one of these CLIs puts the words it is saying under
  // one of a handful of names, so the answer is fished out by shape rather
  // than by knowing whose stream this is. An earlier version dropped every
  // line starting with a brace, which meant a wrong adapter and a silent CLI
  // were indistinguishable — both came out as "answered with nothing".
  function plain(raw) {
    var lines = String(raw || "").split("\n")
    var kept = []
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].replace(/\s+$/, "")
      if (line.length === 0) continue
      if (line.charAt(0) !== "{" && line.charAt(0) !== "[") {
        kept.push(line)
        continue
      }
      try {
        var harvested = session.harvest(JSON.parse(line))
        if (harvested.length > 0) kept.push(harvested)
      } catch (e) {
        // Not JSON after all, so it was prose that happened to start with a
        // brace.
        kept.push(line)
      }
    }
    return session.tidy(kept.join("\n"))
  }

  // The places these CLIs put what the agent said. Walked rather than matched
  // against a fixed path, so a record one level deeper than expected still
  // gives up its text.
  function harvest(node, depth) {
    var level = depth || 0
    if (level > 6 || node === null || typeof node !== "object") return ""

    // A tool call's arguments and a reasoning trace are also strings under
    // these names, so only a node that says it is something the agent said is
    // read that way: agent_message, text, content, and anything unlabelled.
    if (typeof node.text === "string"
        && (node.type === undefined
            || /text|message|content|answer/.test(String(node.type))))
      return node.text

    var out = ""
    for (var key in node) {
      if (key === "usage" || key === "metadata" || key === "tokens") continue
      var child = node[key]
      if (child !== null && typeof child === "object")
        out += session.harvest(child, level + 1)
    }
    return out
  }

  // The CLI inherits this as its working directory, and an empty one is the
  // point: no project files, no CLAUDE.md, no AGENTS.md, no .mcp.json.
  Component.onCompleted: Quickshell.execDetached(["mkdir", "-p", session.stateDir])
}
