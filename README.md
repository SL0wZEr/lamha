# Lamha

Ask your AI from anywhere. Press `Super + I`, type a question, get the answer
over your work, press `Esc` and it's gone.

A plugin for the Omarchy desktop. It uses whatever agent you already set up —
Claude, Codex, Gemini, or opencode.

## Using it

| Key | Does |
|---|---|
| `Super + I` | Open (and close) the bar |
| `Enter` | Ask |
| `Shift + Enter` | New line |
| `Esc` / click away | Close |
| `Ctrl + C` | Stop a reply, keep the chat |
| `Ctrl + Y` | Copy the answer |
| Highlight text | Copies it right away |
| `Ctrl + N` | Start over |
| `Ctrl + E` | Move the chat into a real terminal |

The chat lasts while the pane is open. Close it and the next one starts fresh.

## It can do things too

Ask it to change the wallpaper, switch theme, set a reminder, or take a
screenshot, and it does them.

It can't run arbitrary commands — it only has Omarchy's own list of safe
actions. The small, reversible ones (theme, volume, brightness, reminders…)
run right away. Anything bigger shows you the exact command first and waits
for `Enter`.

## Which agent

Lamha uses your Omarchy default (`omarchy default agent`); change that and it
follows. Claude is the smoothest — it streams the answer as it's written. The
others reply all at once, but work fine.

Want a different agent for just this panel? Say "use opencode".

## Voice

If you have a mic, a mic button shows up. It records, transcribes on your
machine, and drops the text in the box for you to check before sending.

## Install

```bash
omarchy plugin add https://github.com/sl0wzer/lamha.git --enable
```

Then add a keybind in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + I", "Ask", "omarchy-shell -q shell toggle io.github.sl0wzer.lamha")
```

You'll need a default agent installed and signed in.

Remove it with:

```bash
omarchy plugin remove io.github.sl0wzer.lamha
```

## Settings (optional)

In `~/.config/omarchy/shell.json`, on Lamha's entry:

```json
{ "id": "io.github.sl0wzer.lamha", "agent": "", "model": "", "systemPrompt": "" }
```

- `agent` — pin one agent, or leave empty to follow your default
- `model` — a specific model, or empty for the agent's default
- `systemPrompt` — your own instructions

MIT.
