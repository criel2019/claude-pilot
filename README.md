# Claude Process Tracker + Discord Bot

Control and monitor your Claude Code sessions from Discord — send messages, watch live token usage, switch models, compress context, and get notifications when Claude finishes — all from your phone or any Discord client.

> **Disclaimer:** This project is not fully tested and is still in development. Use at your own risk. Review the code before running it in a critical environment.

---

## How it works

Two components work together:

- **`claude-tracker`** — a bash script installed as Claude Code hooks. It intercepts `SessionStart`, `UserPromptSubmit`, `Stop`, and `SessionEnd` events and writes live session state to `~/.claude-tracker/state.json`.
- **Discord bot** (`bot.js`) — a Node.js Discord.js bot that reads that state, spawns Claude CLI processes on demand, and exposes everything as slash commands.

```
Claude Code  →  hooks (claude-tracker)  →  state.json  →  Discord bot  →  Discord
```

---

## Prerequisites

> **Windows only tested.** macOS/Linux should work but are less tested.

- [Claude Code CLI](https://claude.ai/code) installed and authenticated (`claude` in PATH)
- [Node.js](https://nodejs.org/) 18+
- [jq](https://jqlang.github.io/jq/) — JSON processor
  - macOS: `brew install jq`
  - Ubuntu/Debian: `sudo apt install jq`
  - Windows: `winget install jqlang.jq` or `scoop install jq`
- [curl](https://curl.se/) (pre-installed on most systems)
- [flock](https://man7.org/linux/man-pages/man1/flock.1.html) — file locking (pre-installed on Linux; **macOS: `brew install util-linux`**)
- bash 4.0+ — **Windows: install [Git for Windows](https://git-scm.com/download/win) and use Git Bash**

> **Security note:** The bot runs Claude with `--dangerously-skip-permissions`, giving Claude read/write access to your machine. By default (`allowed_users: []`) anyone in your Discord server can send commands. Set `allowed_users` to a list of trusted Discord user IDs, or keep the bot in a private server.

---

## Setup

### 1. Create a Discord bot

1. Go to [Discord Developer Portal](https://discord.com/developers/applications)
2. **New Application** → **Bot** tab
3. Under **Privileged Gateway Intents**, enable **Message Content Intent**
4. **Reset Token** → copy it (you'll need it in step 2)
5. Invite the bot via **OAuth2 > URL Generator**:
   - Scopes: `bot`, `applications.commands`
   - Bot Permissions: `Send Messages`, `Read Message History`, `Create Public Threads`, `Manage Threads`, `Embed Links`, `Add Reactions`, `Attach Files`

### 2. Install

**macOS / Linux:**
```bash
chmod +x install.sh
./install.sh
```

**Windows — open Git Bash:**
```bash
./install.sh
```

The installer:
- Checks dependencies (`jq`, `curl`, `flock`, `bash 4+`)
- Copies `claude-tracker.sh` to `~/.claude-tracker/bin/claude-tracker`
- Registers Claude Code hooks in `~/.claude/settings.json`
- Prompts for Discord Webhook URL, Bot Token, and default working directory
- Optionally registers auto-start on login (Windows Startup folder / macOS launchd / Linux systemd)

All settings are saved to `~/.claude-tracker/config.json`. See `config.example.json` for the full schema.

> **Restart Claude Code after install** so the hooks take effect.

### 3. Install Node.js dependencies

```bash
npm install
```

### 4. Run the bot

```bash
node bot.js
```

**Windows shortcut:** double-click `start-bot.vbs`

Slash commands are registered automatically on first run.

---

## Updating

To update `claude-tracker` to the latest version from GitHub without reinstalling:

```bash
claude-tracker upgrade
```

To update the Discord bot, pull the repo and restart:

```bash
git pull
node bot.js
```

---

## Discord Commands

### Claude Sessions

| Command | Description |
|---------|-------------|
| `/send [message] [project] [model] [file] [image]` | Send a message to Claude. Creates a new session or continues the existing one. |
| `/end` | End the current session in this channel |
| `/session` | Show current session info (model, turns, context size, token usage) |
| `/sessions` | List saved sessions and reload one |
| `/project` | Set the default project for this channel |
| `/compact` | Summarize and compress the conversation to reduce context size |
| `/model <model>` | Switch the model for the current session |

### Monitoring

| Command | Description |
|---------|-------------|
| `/status` | Show all running Claude processes with token counts |
| `/dashboard` | Post a live-updating dashboard embed in this channel |
| `/snapshot` | Record a token usage snapshot immediately |
| `/report [period]` | Token usage report — `today` (default), `week`, or `all` |

### GPT / Codex _(optional)_

| Command | Description |
|---------|-------------|
| `/gpt <message> [project] [model]` | Start an OpenAI Codex session |
| `/gpt-project` | List registered GPT projects |

Requires the `codex` CLI (`npm install -g @openai/codex`) and an OpenAI API key. These commands have no effect on Claude features if unused.

---

## Configuration

`~/.claude-tracker/config.json` — created by `install.sh`, edit at any time:

| Key | Default | Description |
|-----|---------|-------------|
| `bot_token` | — | Discord bot token (required) |
| `default_cwd` | `$HOME` | Default working directory for Claude sessions |
| `allowed_users` | `[]` | Discord user IDs allowed to send commands (empty = all) |
| `session_timeout_minutes` | `60` | Idle session auto-cleanup threshold |
| `stream_edit_interval_ms` | `2000` | How often streaming responses are edited in Discord |
| `max_context_history_turns` | `4` | Turns of history included in each Claude request |
| `max_context_chars` | `50000` | Max character size of context history |

See `config.example.json` for the full schema with comments.

---

## GPT Projects

Register a local project directory for use with `/gpt`:

```bash
node register-gpt-project.js my-app "C:\Users\YourName\Projects\my-app"
```

Or copy `gpt-projects.example.md` to `gpt-projects.md` and edit manually.

`gpt-projects.md` is gitignored — it contains your local paths and is never committed.

---

## Hook Flow

```
SessionStart       → register session as active  + Discord notification
UserPromptSubmit   → idle → active transition
Stop               → active → idle               + debounced completion notification
SessionEnd         → remove session              + record token stats
```

---

## Persistent Sessions

Bot sessions survive restarts. On startup, the bot reloads all active sessions from `~/.claude-tracker/bot-sessions/` and reconnects to their Discord threads.

Sessions with a Claude session ID support `--resume` so conversation context is preserved across bot restarts.

Ended sessions are kept for 10 days, then automatically purged along with their Discord thread messages.

---

## File Structure

```
install.sh                  Installer — copies tracker, registers hooks, sets config
claude-tracker.sh           claude-tracker bash script (copied to ~/.claude-tracker/bin/)
hooks-settings.json         Claude Code hooks template used by install.sh
bot.js                      Bot entry point — Discord client, timers, graceful shutdown
register-gpt-project.js     CLI tool to register a GPT/Codex project
start-bot.vbs               Windows one-click bot launcher
config.example.json         Config schema reference
gpt-projects.example.md     GPT project registry example

src/
  config.js                 Config loader (TTL cache + hot-reload)
  constants.js              Shared constants — paths, limits, colors
  state.js                  In-memory state (activeSessions, Discord client)
  session.js                Session CRUD, message history, token stats, queue
  claude.js                 Claude CLI spawn, streaming parser, turn runner
  tracker.js                claude-tracker integration + native process scan
  dashboard.js              /status, /report, /dashboard, auto-refresh
  embeds.js                 Discord embed builders
  files.js                  File/image attachment handling
  commands.js               Slash command definitions
  timers.js                 Periodic timers (dashboard refresh, session cleanup)
  handlers/
    interactions.js         Dispatcher — slash commands, buttons, modals, select menus
    send.js                 /send handler
    sessions.js             /end, /session, /sessions, terminateSession
    project.js              /project handler
    message.js              Plain message handler (follow-up in active sessions)
    buttons.js              All button interaction handlers
    modals.js               Modal submit handlers
    gpt.js                  /gpt and /gpt-project handlers

~/.claude-tracker/          Created by install.sh (not in repo)
  bin/claude-tracker        Installed tracker binary
  config.json               Your configuration
  state.json                Live session state
  bot-sessions/             Persisted bot sessions (one JSON file per session)
  token-history.jsonl       Token usage snapshots
  usage.jsonl               Per-session token records
  failed-prompts.jsonl      Failed send log (for debugging)
```

---

## Dependencies

- [`discord.js`](https://discord.js.org/) ^14 — Discord API
- `claude` CLI — Claude Code, must be in PATH
- `bash`, `jq`, `curl` — required by `claude-tracker`
