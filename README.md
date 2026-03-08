<div align="center">

<img src="assets/banner.png" alt="Claude Pilot banner" width="100%" />

<br />

### Run Claude Code from Discord.

[![discord.js](https://img.shields.io/badge/discord.js-v14-5865F2?logo=discord&logoColor=white)](https://discord.js.org/)
[![Node.js](https://img.shields.io/badge/node.js-18+-339933?logo=node.js&logoColor=white)](https://nodejs.org/)
[![Platform](https://img.shields.io/badge/platform-Windows-0078D6?logo=windows&logoColor=white)](https://git-scm.com/download/win)
[![Auth](https://img.shields.io/badge/auth-official_claude_CLI-brightgreen)](#auth-model)
[![License](https://img.shields.io/badge/license-MIT-green)](#license)

<br />

**Claude Pilot** turns Discord into a remote control surface for Claude Code on your Windows machine.
Start local coding sessions, continue them from your phone, watch streaming output, switch models,
compact context, and track token usage without sitting at the terminal.

> **Platform:** Windows only (Git Bash required). The session tracking layer relies on Windows-specific
> process detection (`tasklist`, `claude.exe`) and has not been ported to macOS or Linux.

> **Disclaimer:** Not fully tested. Use at your own risk. Review the code before running it in a
> critical environment.

</div>

---

## Why This Exists

Anthropic now ships official
[Remote Control](https://code.claude.com/docs/en/remote-control#continue-local-sessions-from-any-device-with-remote-control)
for Claude Code. Claude Pilot is a separate community project for a different workflow:

- Discord slash commands instead of the Claude mobile or web UI
- Shared thread history that a team can see in one server
- Live dashboards, token reports, and session status inside Discord
- Per-channel project routing for jumping between local repos quickly

If you want a browser or mobile window into Claude Code, use Anthropic Remote Control.
If you want a Discord-native control plane for your local Claude sessions, use Claude Pilot.

---

## Choose Your Surface

| If you want... | Best fit |
|---|---|
| Official Anthropic web/mobile experience connected to your local machine | [Claude Code Remote Control](https://code.claude.com/docs/en/remote-control#continue-local-sessions-from-any-device-with-remote-control) |
| Discord slash commands, shared threads, dashboards, and server-visible status | Claude Pilot |
| A session that still runs on your own machine with your local files and tools | Both |

---

## Auth Model

Claude Pilot is designed around the official Claude Code auth flow.

- It launches the **official `claude` CLI** on your machine.
- Authentication stays inside Claude Code itself.
- It does **not** extract, forward, mint, or relay Claude OAuth tokens.
- It does **not** proxy Claude traffic through a separate hosted service.

Anthropic's published Claude Code docs state that OAuth tokens from Free, Pro, and Max accounts are
intended only for **Claude Code** and **Claude.ai**, and that third-party products should use API keys
instead of consumer OAuth. Claude Pilot avoids that prohibited pattern by acting as a local Discord
wrapper around the official CLI rather than a replacement client.

References:

- [Claude Code Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance)
- [Anthropic Consumer Terms](https://www.anthropic.com/policies/consumer-terms)

---

## Features

- **Remote Claude from Discord**: start or continue local Claude Code sessions from any Discord client
- **Streaming replies**: watch Claude output appear live in Discord
- **Persistent sessions**: survive bot restarts and resume with saved Claude session IDs
- **Project routing**: set a default repo per channel with `/project`
- **Model switching**: move between Opus, Opus Plan, Sonnet, and Haiku
- **Context cleanup**: use `/compact` before history gets too large
- **Status and reporting**: `/status`, `/dashboard`, `/snapshot`, and `/report`
- **Session management**: `/session`, `/sessions`, and `/end`
- **Optional Codex support**: run OpenAI Codex sessions from Discord with `/gpt`

---

## How It Works

```text
Discord client (phone, desktop, browser)
  -> /send, /status, /model, /compact

Discord bot (Node.js)
  -> reads tracker state
  -> starts or resumes Claude CLI sessions
  -> streams output back into Discord threads

claude-tracker hooks (bash)
  -> SessionStart, UserPromptSubmit, Stop, SessionEnd
  -> ~/.claude-tracker/state.json
  -> token snapshots and usage history

Claude Code CLI (official)
  -> authenticated locally on your Windows machine
```

Two components make this work:

1. **`claude-tracker`**: a bash script installed as Claude Code hooks. It captures `SessionStart`,
   `UserPromptSubmit`, `Stop`, and `SessionEnd`, then writes live state to
   `~/.claude-tracker/state.json`.
2. **Discord bot** (`bot.js`): reads tracker state, spawns the Claude CLI on demand, streams updates,
   and exposes everything as slash commands.

---

## Quick Start

### Prerequisites

- **Windows** with [Git for Windows](https://git-scm.com/download/win) (Git Bash)
- [Claude Code CLI](https://code.claude.com/docs/en/overview) installed and authenticated
- [Node.js](https://nodejs.org/) 18+
- [jq](https://jqlang.github.io/jq/)
- [curl](https://curl.se/) (preinstalled on Windows 10+)

### 1. Create a Discord bot

1. Go to the [Discord Developer Portal](https://discord.com/developers/applications).
2. Create a new application and open the **Bot** tab.
3. Enable **Message Content Intent**.
4. Reset the bot token and copy it.
5. Invite the bot with scopes `bot` and `applications.commands`.
6. Give it these permissions:
   `Send Messages`, `Read Message History`, `Create Public Threads`, `Manage Threads`,
   `Embed Links`, `Add Reactions`, `Attach Files`.

### 2. Install

```bash
git clone https://github.com/criel2019/claude-pilot.git
cd claude-pilot
./install.sh
npm install
```

The installer:

- checks dependencies
- copies `claude-tracker.sh` to `~/.claude-tracker/bin/claude-tracker`
- registers Claude Code hooks in `~/.claude/settings.json`
- prompts for your Discord bot token and default working directory
- optionally registers auto-start on Windows login

> Restart Claude Code after install so the hooks take effect.

### 3. Run

```bash
node bot.js
```

Or double-click `start-bot.vbs` to run in the background without a terminal window.

---

## Commands

### Claude sessions

| Command | Description |
|---|---|
| `/send [message] [project] [model] [file] [image...]` | Send a prompt to Claude, optionally with a project, model, text file, and up to 3 images |
| `/project` | Set this channel's default project |
| `/model <model>` | Change the model for the active session |
| `/compact` | Replace long history with a summary |
| `/session` | Show current session metadata and token stats |
| `/sessions` | List saved sessions and reload one |
| `/end` | End the current session in this channel |

### Monitoring

| Command | Description |
|---|---|
| `/status` | Show all running Claude processes with token counts |
| `/dashboard` | Post a live-updating dashboard embed |
| `/snapshot` | Record a token snapshot immediately |
| `/report [period]` | Usage report for `today`, `week`, or `all` |

### GPT / Codex

| Command | Description |
|---|---|
| `/gpt <message> [project] [model]` | Start an OpenAI Codex session in Discord |
| `/gpt-project` | List registered GPT/Codex projects |

The optional GPT path requires the `codex` CLI and an OpenAI API key.

---

## GPT / Codex Setup

Claude Pilot can also trigger OpenAI Codex from Discord if you want the same control surface for both
tools.

Register a local project directory:

```bash
node register-gpt-project.js my-app "C:\Users\YourName\Projects\my-app"
```

Or copy `gpt-projects.example.md` to `gpt-projects.md` and edit it manually.

`gpt-projects.md` is gitignored because it contains local paths.

---

## Configuration

`~/.claude-tracker/config.json` is created by `install.sh` and can be edited later.

| Key | Default | Description |
|---|---|---|
| `bot_token` | none | Discord bot token |
| `default_cwd` | `$HOME` | Default working directory for new sessions |
| `allowed_users` | `[]` | Allowed Discord user IDs; empty means everyone in the server |
| `session_timeout_minutes` | `60` | Idle session cleanup threshold |
| `stream_edit_interval_ms` | `2000` | Discord edit interval for streaming output |
| `max_context_history_turns` | `4` | History turns injected into each Claude request |
| `max_context_chars` | `50000` | Max history size before trimming |
| `token_warning_thresholds` | configured object | Caution, warning, and critical token thresholds |

See [`config.example.json`](config.example.json) for the full schema.

---

## Persistent Sessions

- Active sessions are reloaded from `~/.claude-tracker/bot-sessions/` when the bot restarts.
- Sessions with a Claude session ID can resume with `--resume`.
- Ended sessions are kept for 10 days, then purged automatically.

---

## Security

> The bot runs Claude with `--dangerously-skip-permissions`, so Claude gets full read/write access to
> your machine.

- By default, `allowed_users: []` means anyone in the Discord server can use the bot.
- Put the bot in a private server or restrict `allowed_users` to trusted user IDs.
- Claude Pilot does not transmit or expose your Claude credentials.

---

## Updating

```bash
git pull
```

Then restart the bot. Re-run `install.sh` only if hook behavior or config format changed.

Use `git clone` for installation instead of the zip download so future updates are easy to pull.

---

## Repo Layout

```text
install.sh                  Installer for Windows / Git Bash
claude-tracker.sh           Hook script copied into ~/.claude-tracker/bin/
hooks-settings.json         Claude Code hooks template
bot.js                      Discord bot entry point
register-gpt-project.js     Register a GPT/Codex project path
start-bot.vbs               Background launcher
config.example.json         Config schema reference
gpt-projects.example.md     GPT project registry example

src/
  config.js                 Config loader
  constants.js              Shared paths and limits
  state.js                  In-memory runtime state
  session.js                Session storage and token stats
  claude.js                 Claude CLI execution and streaming
  tracker.js                Hook integration and native process scan
  dashboard.js              Dashboard and report helpers
  embeds.js                 Discord embed builders
  files.js                  Attachment handling
  commands.js               Slash command definitions
  timers.js                 Cleanup and refresh timers
  handlers/                 Interaction handlers
```

---

## License

MIT

---

<div align="center">

Claude Pilot is an independent community project and is not affiliated with or endorsed by Anthropic.

</div>
