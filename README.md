# Lamha

**لمحة — "a glance."** Ask your agent from anywhere without leaving what you
are doing. Press `Super + I`, type a question, get an answer over the top of
your work, press `Esc` and it is gone.

```
Super + I
   ↓
omarchy-shell shell toggle io.github.sl0wzer.lamha
   ↓
Overlay.qml ── one pane of glass that changes shape ──▶ Session.qml
                                                            │
   ask bar  ──▶  working pill  ──▶  answer pane        Agents.qml picks
                                                       the adapter for
   streamed tokens ◀────────────────────────────────   `omarchy default
                                                        agent`
```

Nothing here is an agent, whichever agent is behind it. Each CLI is run with
the hardest lockdown its own flags allow and an empty working directory: this
is a panel that answers a question, so it is given no way to touch the
machine.

## Using it

`Super + I` opens the bar. Type and press `Enter`; `Shift + Enter` writes a
second line. The bar contracts to a pill while the agent is thinking and then
unfolds into the answer.

| Key / control | What it does |
|---|---|
| `Enter` | Ask |
| `Shift + Enter` | Newline in the question |
| `Esc`, click outside, `Super + I` again | Dismiss |
| `Ctrl + C` | Stop the answer in flight, keeping the thread |
| `Ctrl + Y` | Copy the whole last answer |
| Highlight an answer | Copies the selection as soon as it settles |
| `Ctrl + N` | Start over |
| `Ctrl + E` | Carry the whole conversation into the agent's terminal |
| The field at the bottom | Ask a follow-up in the same conversation |
| `+` | Start over — folds back to the bar, forgets the thread |
| The corner brackets | Make the pane bigger, and back |
| The microphone | Dictate instead of typing, when a microphone exists |

`Ctrl + C` only takes the keystroke while an answer is arriving; the rest of
the time it copies whatever you have dragged over, as it should.

Answers are selectable, and highlighting one copies it: the moment a selection
settles it goes to the clipboard, the way selecting in a terminal does, with no
extra keystroke. `Ctrl + Y` still copies the whole of the last answer.

A conversation lasts as long as the pane is open. Dismissing it ends the
session; the next summon starts fresh, which is what you want from something
you reach for by reflex.

## Doing things, not just answering

Ask it to change the wallpaper, set a reminder, switch theme, turn on night
light, mute the microphone or take a screenshot, and it does them.

It is never given a shell. Omarchy publishes its own command list as JSON —
every route, its arguments, a summary, and whether it needs root — and Lamha
reads that list at startup and hands it to the agent as the only vocabulary
it has. The agent answers with one route from the list; the plugin looks that
route up, refuses anything that is not in it, and runs the command directly
as a process rather than through a shell, so no argument can turn into a
second command.

This is what makes the seal hold for an agent that keeps its own tools. A
read-only agent asked to change the wallpaper names the command instead of
reaching for a shell, and if it named one that is not on the list, the lookup
would refuse it here.

Of Omarchy's 354 commands, 89 are offered. Three filters do the narrowing:

- **Root.** Anything needing sudo is not on offer at all.
- **Groups.** Package installs and removals, updates, migrations, reinstalls,
  setup wizards, disk and hardware work, and shutdown are all out.
- **Individual routes.** A few otherwise-allowed commands take a command or a
  path as an argument, which would hand back the shell this design exists to
  avoid: `launch terminal`, `launch editor`, `notification send --exec` and
  their kin. So are the two that print wifi secrets.

Of those 89, the 52 that are reversible, immediate and confined to this desktop
run as soon as they are chosen: theme, wallpaper, toggles, volume, brightness,
reminders, default browser, editor and terminal, and the commands that report
state. The other 37 show you the exact
command and wait for `Enter`. Either way the command is shown, along with
whatever it printed, so a settings change is never something that happened
silently.

Asking something new drops an offer that was never taken up.

## Which agent answers

Omarchy already asks you to pick a coding agent, so Lamha does not ask again:
it reads `~/.config/omarchy/defaults/agent`, the file `omarchy default agent`
writes. Change the desktop's agent and the pane changes with it, live — the
name in the bar is the name of whatever will answer.

There are two of these to change and the pane keeps them apart:

- **This panel only.** "switch this panel to opencode" writes `"agent"` onto
  Lamha's entry in `shell.json`, and the next answer comes from the new agent
  with the conversation carried across. Nothing is launched; the desktop is
  untouched.
- **The desktop default.** "set the default agent to opencode" is Omarchy's
  own `omarchy default agent`, offered like any other command on the list. It
  waits for `Enter`, because besides writing the setting it ends with `exec
  omarchy-agent` and opens a terminal running that agent with approvals off —
  which the reply says before you confirm, rather than leaving you to find out.

Asked plainly — "use opencode" — it switches the panel and names the other in
the same breath.

### The panel's own setting

The agent is the one thing about itself the pane can change, and it does not
go through the catalogue to do it. The block names a setting rather than a
route:

```action
{"panel": "agent", "value": "opencode"}
```

Nothing is executed. The only values accepted are the names of agents there is
an adapter for — read off the adapter table, so the list cannot drift — and
anything else is refused before a byte is written. The shell does the writing,
through the same call its own settings forms use, and the rest of the entry
is carried across, so a `model` or `systemPrompt` you set by hand survives the
switch.

Four are supported, and they are not equally good at this. The differences are
in the CLIs, not in the adapters, and the pane tells you which one you have
rather than papering over it:

| Agent | Answer arrives | Conversation | Shut in |
|---|---|---|---|
| `claude` | a token at a time | held open on stdin | **sealed** — no tools, no MCP, no settings |
| `gemini` | a token at a time | replayed per question | **read-only** — plan mode |
| `opencode` | all at once, at the end | replayed per question | **read-only** — writes need an approval it cannot ask for |
| `codex` | all at once, at the end | replayed per question | **read-only** — sandboxed, config ignored |

Only Claude fills the pane in as the answer is written. Codex and opencode
hand over a finished reply, so the pill stays up for the whole turn and says
which of the two you are waiting on rather than leaving you to wonder.

`crush`, `grok`, `copilot`, `pi` and `omp` are the other agents Omarchy will
set as your default, and Lamha does not speak to them yet. It says so in the
bar rather than failing quietly.

When an adapter does go stale — a CLI renames its events in a release, which
is the normal way this breaks — the stream is read a second time by shape
rather than by name, and whatever the agent said is shown anyway. A wrong
adapter should cost you the streaming, not the answer.

An agent Omarchy has a stub for but has not installed is treated as missing,
not as present — running the stub would start a multi-minute `mise` download
behind a pane that is meant to answer in under a second.

### The seal

Only Claude can be made to have no tools at all. The rest keep theirs and are
held to reading, which is a real difference, so the pane wears a small word
next to the agent's name saying which it is. Hover it for the specifics.

What none of them get is a shell, whatever their seal says. The command
catalogue below is the only route from an answer to a change on this machine,
and it is enforced on this side of the conversation — so a read-only agent
that decides to be helpful still cannot do anything that is not on the list.

### The thread is ours

Only Claude can hold a conversation open on stdin. The others are one-shot
programs with their own resume flags, and those flags are the least reliable
surface any of these CLIs expose: resume-latest races every other session you
have open and answers the wrong question without saying so. So Lamha keeps
the transcript itself and replays it as part of each prompt. It costs tokens
on a long thread and buys a thread that is always the one you are looking at
— including after `Ctrl + C`, which stops an answer without losing the
conversation it belonged to.

### When the question outgrows the pane

`Ctrl + E` hands the whole conversation to the same agent running properly in
a terminal, through Omarchy's own `omarchy agent prompt`. That escape hatch is
why the pane can afford to stay sealed: it never has to be loosened until it
can do the job, because the job can leave.

## Why it feels the way it does

With Claude the process starts the moment the bar opens, not when you press
Enter, and it stays open on stdin for the whole conversation. Start-up is
paid while you are still typing, so the first answer arrives as fast as the
second. Re-running the binary per question adds about a second to every turn
— which is exactly what the one-shot agents have to pay, and why Claude
remains the one this was built around.

The bar, the pill and the pane are one surface changing shape rather than
three windows crossfading, so there is always something to follow from one
state to the next, and waiting feels like part of the same object instead of
a gap between two of them.

Hyprland's backdrop blur is off in Omarchy and turning it on is a
system-wide change to pay for one overlay, so the frosting is done in the
plugin: the screen is captured once on summon, blurred, and masked to the
pane's shape. Because the capture stays pinned to screen coordinates while
the mask moves over it, the blurred content slides under the pane the way
real glass does.

## Configuration

Optional, and kept where the shell keeps every plugin's settings: inline on
Lamha's entry in `~/.config/omarchy/shell.json`, read live — no restart:

```json
{
  "plugins": [
    {
      "id": "io.github.sl0wzer.lamha",
      "agent": "claude",
      "model": "claude-haiku-4-5-20251001",
      "systemPrompt": "Answer in one sentence. Assume I know the jargon."
    }
  ]
}
```

- `agent` — one of `claude`, `codex`, `gemini`, `opencode`, for this pane
  only. Empty — the default — means whatever `omarchy default agent` says,
  which is the answer that stays right when you change your mind in the menu.
- `model` — anything the chosen agent's `--model` accepts. Empty means the
  CLI's default. A smaller model is noticeably quicker for quick questions.
- `systemPrompt` — replaces the built-in one, which asks for two or three
  sentences and no preamble.

## Dictation

The microphone button only appears when a real capture device exists; a
monitor's own loopback is not a microphone. It records until you stop
talking, transcribes locally with whisper.cpp, and puts the text in the
field rather than sending it, because speech recognition is wrong often
enough that you want to see it first.

It shares Nida's whisper model when that is installed, so it costs no extra
download on a machine that already speaks. Otherwise put a model at
`~/.local/share/lamha/models/ggml-base.en.bin`.

```bash
bin/lamha-listen      # record one utterance and print the transcript
```

## Installing

From the plugin marketplace:

```bash
omarchy plugin add https://github.com/sl0wzer/lamha.git --enable
```

Or by hand: the plugin lives at
`~/.config/omarchy/plugins/io.github.sl0wzer.lamha/` and is enabled in
`~/.config/omarchy/shell.json`:

```json
{ "plugins": [{ "id": "io.github.sl0wzer.lamha" }] }
```

The keybinding is in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + I", "Ask", "omarchy-shell -q shell toggle io.github.sl0wzer.lamha")
```

and `~/.config/hypr/looknfeel.lua` tells Hyprland not to animate the layer,
since the pane animates itself.

Requires a default agent that Lamha speaks to, installed and signed in. The
plugin finds the binary through a login shell and asks `mise` where it really
lives, so version managers are fine and an uninstalled stub is not mistaken
for an install.

The shell reloads a plugin when its files change, but a reloaded pane can
still be running the previous code: a new QML file is not in the import graph
until the shell restarts, and an edited one can be served from the component
cache. After installing, and after editing, `omarchy restart shell` is the
way to be sure what is running is what is on disk.

## Files

| File | What it is |
|---|---|
| `Overlay.qml` | The surface and the whole choreography |
| `Catalogue.qml` | Which Omarchy commands are on offer, read from Omarchy |
| `Runner.qml` | Carries out one vouched-for command, never through a shell |
| `Glass.qml` | Frozen screen capture, blurred, masked to the pane |
| `Orbit.qml` | The ring of dots that turns while you wait |
| `Mark.qml` | The small square beside the agent's name |
| `GlyphButton.qml` | Close, expand, new, microphone — drawn, not a font |
| `AskField.qml` | A text field that grows to a ceiling and then scrolls |
| `Agents.qml` | Which agent answers, how to speak to it, how far it is shut in |
| `Session.qml` | The conversation, held open on stdin or replayed per question |
| `Dictation.qml` | Speech into the field |
| `bin/lamha-listen` | Record, transcribe, print |

MIT.
