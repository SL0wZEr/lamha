import QtQuick
import Quickshell
import Quickshell.Io

// Which agent answers, and how to talk to it.
//
// Omarchy already asks you to pick a coding agent — `omarchy default agent`
// writes the choice to ~/.config/omarchy/defaults/agent — so Lamha reads that
// rather than asking a second time. Change the desktop's agent and this pane
// changes with it, live, without a restart.
//
// Every CLI here is a different program with its own idea of non-interactive
// output, so each gets an adapter: how to invoke it, how to read what comes
// back, and — the part that matters most — how far it can be shut in.
//
// Two things the adapters do NOT share with the agents themselves:
//
//   The thread is ours. Only Claude can hold a conversation open on stdin;
//   the rest are one-shot programs with their own resume flags, and those
//   flags are the flakiest part of every one of these CLIs (resume-latest
//   races anything else you have running, and silently picks the wrong
//   conversation). So Lamha keeps the transcript itself and replays it as one
//   prompt. It costs tokens on a long thread and buys a thread that is always
//   the thread you are looking at.
//
//   The working directory is ours. Every agent runs in an empty state
//   directory, so there is no project, no AGENTS.md, no CLAUDE.md and no
//   .mcp.json to pick up — whatever the CLI would otherwise have read.
Item {
  id: agents

  // Set on the plugin's entry in shell.json to use something other than the
  // desktop's default agent for this pane only.
  property string override: ""

  property string omarchyDefault: ""

  readonly property string name: agents.override.length > 0 ? agents.override
                                                            : agents.omarchyDefault

  // Resolved path to the binary, and whether we are still looking.
  property string binary: ""
  property bool resolving: false

  // Whether a search has already come back for this agent. A search that
  // found nothing is not run again on its own account: the answer will not
  // have changed between one signal and the next, and every listener that
  // reacts to `switched` by asking for the binary would otherwise chase its
  // own tail — with the pane open on an agent that was not installed, the
  // finder used to be spawned several hundred times a second. It runs again
  // when the agent changes and once per fresh summon, which is often enough
  // to notice an install.
  property bool searched: false

  // Why there is no agent to talk to, in words that say what to do about it.
  property string problem: ""

  // Assigned by refresh() rather than bound to `name`. A binding would be
  // correct everywhere except the one place it is needed: inside the handler
  // that runs when `name` changes, where the binding has not caught up yet and
  // every agent looks unsupported. Assigning it first, and deciding from the
  // local copy, takes that ordering out of the question entirely.
  property var adapter: null
  readonly property bool supported: agents.adapter !== null
  readonly property bool ready: agents.supported && agents.binary.length > 0

  readonly property string label: agents.adapter ? agents.adapter.label
                                : agents.name.length > 0 ? agents.name : "no agent"

  // How thoroughly this agent can be prevented from touching the machine.
  //
  //   sealed     no tools at all — it can only produce words
  //   read-only  it keeps its tools but cannot write, and starts nowhere
  //
  // The distinction is shown in the pane rather than smoothed over, because
  // it is a real difference and the person asking is the one carrying it.
  readonly property string seal: agents.adapter ? agents.adapter.seal : "unknown"
  readonly property string sealNote: agents.adapter ? agents.adapter.sealNote : ""

  signal switched()

  // Every name `omarchy default agent` accepts, so the pane can say "crush is
  // not supported yet" instead of the uselessly true "no agent".
  readonly property var known: [
    "claude", "codex", "gemini", "opencode", "crush", "grok", "copilot",
    "pi", "omp"
  ]

  // --- the adapters --------------------------------------------------------
  //
  // argv(binary, o) builds the command line, where o carries model,
  // systemPrompt and — for the one-shot agents — the whole composed prompt.
  //
  // parse(record) reads one decoded stdout record and answers with any of:
  //   { text }      more of the answer, to append
  //   { whole }     the answer entire, replacing whatever was shown
  //   { done }      the turn is over
  //   { error }     the turn failed, with a reason
  // or null for a record that is none of Lamha's business — a tool call, a
  // token count, a heartbeat.

  readonly property var adapters: ({

    // The only one that can be sealed outright, and the only one that can
    // hold the conversation open on stdin. Everything about how Lamha feels
    // was built against this: the process starts while you are still typing,
    // so the first answer costs no more than the second.
    "claude": {
      label: "Claude",
      seal: "sealed",
      sealNote: "no tools, no MCP, no settings",
      mode: "session",
      streams: true,
      argv: function (bin, o) {
        var a = [bin, "-p",
          "--input-format", "stream-json",
          "--output-format", "stream-json",
          "--include-partial-messages",
          "--verbose",
          "--tools", "",
          "--no-session-persistence",
          "--setting-sources", "",
          "--strict-mcp-config",
          "--mcp-config", "{\"mcpServers\":{}}"]
        if (o.systemPrompt.length > 0) a.push("--system-prompt", o.systemPrompt)
        if (o.model.length > 0) a.push("--model", o.model)
        return a
      },
      parse: function (r) {
        if (r.type === "stream_event" && r.event) {
          var e = r.event
          if (e.type === "content_block_delta" && e.delta
              && e.delta.type === "text_delta")
            return { text: String(e.delta.text || "") }
          return null
        }
        if (r.type === "result") {
          if (r.is_error || (r.subtype && r.subtype !== "success"))
            return { error: String(r.subtype || "the request failed") }
          return { done: true }
        }
        return null
      }
    },

    // Codex has no partial messages: `exec --json` emits the finished reply
    // as one item, so the pill stays up for the whole turn rather than
    // filling in. Nothing to be done about that from out here.
    //
    // --ignore-user-config is doing real work — without it Codex loads your
    // config and instructions and spends a five-figure token count before it
    // has read the question.
    "codex": {
      label: "Codex",
      seal: "read-only",
      sealNote: "read-only sandbox, no config, nothing persisted",
      mode: "oneshot",
      streams: false,
      argv: function (bin, o) {
        var a = [bin, "exec", "--json",
          "--sandbox", "read-only",
          "--skip-git-repo-check",
          "--ephemeral",
          "--ignore-user-config",
          "--ignore-rules",
          "--color", "never"]
        if (o.model.length > 0) a.push("--model", o.model)
        a.push(o.prompt)
        return a
      },
      parse: function (r) {
        if (r.type === "item.completed" && r.item
            && r.item.type === "agent_message")
          return { whole: String(r.item.text || "") }
        if (r.type === "turn.completed") return { done: true }
        if (r.type === "turn.failed" || r.type === "error") {
          var m = r.error && r.error.message ? r.error.message
                : r.message ? r.message : "the request failed"
          return { error: String(m) }
        }
        return null
      }
    },

    // `--approval-mode plan` is Gemini's read-only mode. It gets overridden
    // back to "default" when the working directory is untrusted, which ours
    // always is — that is a downgrade in Gemini's favour, not ours, so
    // --skip-trust goes with it to keep plan mode in force.
    //
    // Gemini's stream-json is meant to be interchangeable with Claude's, but
    // the two have drifted in both directions across releases, so this reads
    // whichever shape turns up.
    "gemini": {
      label: "Gemini",
      seal: "read-only",
      sealNote: "plan mode — it can look, not touch",
      mode: "oneshot",
      streams: true,
      argv: function (bin, o) {
        var a = [bin,
          "--output-format", "stream-json",
          "--approval-mode", "plan",
          "--skip-trust"]
        if (o.model.length > 0) a.push("--model", o.model)
        a.push("--prompt", o.prompt)
        return a
      },
      parse: function (r) {
        // Claude-shaped deltas.
        if (r.type === "stream_event" && r.event && r.event.type === "content_block_delta"
            && r.event.delta && r.event.delta.type === "text_delta")
          return { text: String(r.event.delta.text || "") }

        // Whole assistant messages, which is what Gemini sends more often.
        if (r.type === "assistant" && r.message && Array.isArray(r.message.content)) {
          var out = ""
          for (var i = 0; i < r.message.content.length; i++) {
            var block = r.message.content[i]
            if (block && block.type === "text") out += String(block.text || "")
          }
          return out.length > 0 ? { text: out } : null
        }

        if (r.type === "content" && typeof r.content === "string")
          return { text: r.content }

        if (r.type === "result") {
          if (r.is_error || (r.subtype && r.subtype !== "success"))
            return { error: String(r.error || r.subtype || "the request failed") }
          return { done: true }
        }
        if (r.type === "error")
          return { error: String((r.error && r.error.message) || r.message || "the request failed") }
        return null
      }
    },

    // opencode has no flag that takes its tools away, but it does ask before
    // it writes, and a `run` with nowhere to ask is a `run` that cannot say
    // yes. The one thing never passed here is --dangerously-skip-permissions.
    //
    // Its JSON is a part stream: step_start, then a `text` part per step, then
    // step_finish. The parts are whole when they arrive rather than streamed a
    // token at a time — a fifteen-line answer came as one — so this cannot
    // fill the pane in as it is written, and says so.
    //
    // Each part is keyed by its own id, because a reply that takes more than
    // one step sends more than one text part and they belong end to end.
    "opencode": {
      label: "opencode",
      seal: "read-only",
      sealNote: "writes need an approval it has no way to ask for",
      mode: "oneshot",
      streams: false,
      argv: function (bin, o) {
        var a = [bin, "run", "--format", "json", "--log-level", "ERROR"]
        if (o.model.length > 0) a.push("--model", o.model)
        a.push(o.prompt)
        return a
      },
      parse: function (r) {
        var part = r.part || {}

        // Reasoning and tool parts come through here too, under their own
        // type. Only what the agent actually said belongs in the pane.
        if (r.type === "text" && typeof part.text === "string")
          return { whole: part.text, key: String(part.id || "text") }

        if (r.type === "step_finish" || r.type === "session.idle")
          return { done: true }

        if (r.type === "error") {
          var e = r.error || {}
          var m = (e.data && e.data.message) ? e.data.message
                : e.name ? e.name : "the request failed"
          return { error: String(m) }
        }
        return null
      }
    }
  })

  // --- what the agent is told ----------------------------------------------

  // The one-shot agents have no flag for a system prompt, so it rides at the
  // front of the message. The framing is explicit rather than implied: these
  // are agents, and left to themselves they will try to go and do the thing
  // with their own tools instead of naming it.
  //
  // A session agent gets its system prompt on the command line and needs
  // neither, so for it this is only the transcript — which it is sent once, by
  // a fresh process picking up a thread the last one was holding.
  function compose(systemPrompt, history, question) {
    if (!agents.adapter) return question

    var parts = []
    if (agents.adapter.mode !== "session") {
      if (systemPrompt.length > 0) parts.push(systemPrompt)
      parts.push(
        "You are answering inside a small desktop panel. You have no task to "
        + "carry out with your own tools and no files to look at: answer from "
        + "what you know, and when the request is something the desktop can do, "
        + "name the command in the block described above instead of running "
        + "anything yourself.")
    }

    if (history && history.length > 0) {
      var lines = ["Here is the conversation so far."]
      for (var i = 0; i < history.length; i++) {
        var turn = history[i]
        lines.push((turn.role === "user" ? "User: " : "You: ") + turn.text)
      }
      parts.push(lines.join("\n\n"))
    }

    if (parts.length === 0) return question
    parts.push("User: " + question)
    return parts.join("\n\n---\n\n")
  }

  // --- where the agent lives -----------------------------------------------

  // Omarchy puts a stub on PATH for every agent it knows about, installed or
  // not, and running one installs it: a minute or three of mise downloading a
  // hundred megabytes. That is a fine thing to happen in a terminal you chose
  // to open and a terrible thing to happen behind a pane that is supposed to
  // answer before you have finished reading your own question. So a stub does
  // not count as installed, exactly as `omarchy default agent` has it.
  function resolve(again) {
    if (agents.resolving || agents.adapter === null) return
    if (agents.searched && again !== true) return
    agents.resolving = true
    agents.problem = ""
    finder.command = ["bash", "-lc", agents.finderScript(agents.name)]
    finder.running = true
  }

  function finderScript(name) {
    return 'a=' + JSON.stringify(name) + '; '
      // A real binary at the wrapper's path — a symlink left by the agent's
      // own installer, say — rather than the mise stub that installs on use.
      + 'w="$HOME/.local/bin/$a"; '
      + 'if [ -x "$w" ] && { [ -L "$w" ] || ! grep -q "^mise use -g" "$w"; }; then echo "$w"; exit 0; fi; '
      // Installed through mise, which is how Omarchy puts them there. `mise
      // which` rather than `mise where`: every one of these packages buries
      // its executable somewhere different — bin/codex, node_modules/.bin for
      // the npm ones, a versioned tarball directory for Crush — and asking
      // mise beats keeping a table of layouts that go stale on release day.
      // It errors rather than installing when the tool is not there, which is
      // the behaviour this whole function exists to get.
      + 'p=$(mise which "$a" 2>/dev/null); '
      + '[ -n "$p" ] && [ -x "$p" ] && echo "$p" && exit 0; '
      // Installed by hand, or by the agent's own installer.
      + 'for c in "$HOME/.opencode/bin/$a" "$HOME/.$a/local/$a" "$HOME/.local/share/$a/bin/$a" '
      + '"/usr/local/bin/$a" "/usr/bin/$a"; do [ -x "$c" ] && echo "$c" && exit 0; done; '
      // Anything else on PATH, as long as it is not one of those stubs.
      + 'c=$(command -v "$a" 2>/dev/null) || exit 1; '
      + '[ -n "$c" ] && ! grep -qs "^mise use -g" "$c" && echo "$c" && exit 0; '
      + 'exit 1'
  }

  function refresh() {
    var found = agents.adapters[agents.name] || null
    agents.adapter = found
    agents.binary = ""
    agents.problem = ""
    agents.searched = false

    // Decided from the local copy, not from the bindings that hang off it —
    // those are a tick behind for as long as this function is running.
    var shown = found ? found.label
              : agents.name.length > 0 ? agents.name : "no agent"

    if (agents.name.length === 0) {
      agents.problem = "no default agent — set one with: omarchy default agent"
      console.warn("lamha: no agent —", agents.problem)
    } else if (!found) {
      agents.problem = agents.has(agents.known, agents.name)
        ? shown + " is not one Lamha can speak to yet"
        : "unknown agent: " + agents.name
      console.warn("lamha: no agent —", agents.problem)
    } else {
      agents.resolve()
    }
    agents.switched()
  }

  onNameChanged: agents.refresh()

  function has(list, value) { return list.indexOf(value) !== -1 }

  // The agents there is an adapter for, named for the prompt. Read off the
  // adapter table rather than written out again, so an agent added there is
  // offered without anyone remembering to mention it here.
  function agentList() {
    var names = []
    for (var key in agents.adapters) names.push(key)
    names.sort()
    return "The ones with an adapter here are " + names.join(", ")
      + " — no other value is accepted."
  }

  Process {
    id: finder
    running: false
    stdout: SplitParser {
      onRead: function (data) {
        var path = String(data || "").replace(/^\s+|\s+$/g, "")
        if (path.length > 0 && agents.binary.length === 0) agents.binary = path
      }
    }
    onExited: function (code, status) {
      agents.resolving = false
      agents.searched = true
      if (agents.binary.length === 0)
        agents.problem = agents.label + " is not installed — "
          + "install it with: omarchy default agent " + agents.name

      // Worth a line in the log either way. A pane that will not answer and a
      // pane that is answering from somewhere unexpected look identical from
      // the outside, and this is the one place that can tell them apart.
      if (agents.binary.length > 0)
        console.log("lamha: " + agents.name + " (" + agents.seal + ") at " + agents.binary)
      else
        console.warn("lamha: no agent —", agents.problem)

      agents.switched()
    }
  }

  // Read live rather than at startup: switching the desktop's agent should
  // switch this pane's agent, and the next summon should be the new one.
  FileView {
    path: Quickshell.env("HOME") + "/.config/omarchy/defaults/agent"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var next = String(text() || "").replace(/^\s+|\s+$/g, "")
      // Setting it is usually enough, because changing it is what starts the
      // search. The first read of a file that says what we already hold is the
      // exception — and that is exactly the case where nothing has looked yet.
      // A rewrite that changes nothing, once something has looked, is left
      // alone: restarting the agent under a conversation because its name was
      // written down again is not a change anyone asked for.
      if (next !== agents.omarchyDefault) agents.omarchyDefault = next
      else if (!agents.searched && !agents.resolving) agents.refresh()
    }
    onLoadFailed: {
      if (agents.omarchyDefault.length === 0) agents.refresh()
      else agents.omarchyDefault = ""
    }
  }
}
