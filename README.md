# Claude Process Tracker + Discord Bot

Discord bot that lets you send messages to Claude Code sessions, monitor running sessions, track token usage, and manage multiple projects — all from your phone or any Discord client.

---

## Prerequisites [Only Windows was tested]

- [Claude Code CLI](https://claude.ai/code) installed and authenticated (`claude` in PATH)
- [Node.js](https://nodejs.org/) 18+
- [jq](https://jqlang.github.io/jq/) — JSON processor used by `claude-tracker`
  - macOS: `brew install jq`
  - Ubuntu/Debian: `sudo apt install jq`
  - Windows: `winget install jqlang.jq` or `choco install jq` or `scoop install jq`
- [curl](https://curl.se/) (usually pre-installed on macOS/Linux/Windows 10+)
- bash 4.0+ — **Windows users: install [Git for Windows](https://git-scm.com/download/win) and use Git Bash**

> **Security note:** The bot runs Claude with `--dangerously-skip-permissions`, which allows Claude to read and write files on your machine. By default (`allowed_users: []`) anyone in your Discord server can send commands. Set `allowed_users` in `config.json` to a list of trusted Discord user IDs, or keep the bot in a private server.

---

## Setup

### 1. Create a Discord Bot

1. Go to [Discord Developer Portal](https://discord.com/developers/applications)
2. **New Application** → name it anything → **Bot** tab
3. Enable **Message Content Intent** under Bot > Privileged Gateway Intents
4. **Reset Token** → copy the bot token (you'll need it in step 2)
5. **Invite the bot** to your server via OAuth2 > URL Generator:
   - Scopes: `bot`, `applications.commands`
   - Bot Permissions: `Send Messages`, `Read Message History`, `Create Public Threads`, `Manage Threads`, `Embed Links`, `Add Reactions`, `Attach Files`

### 2. Install

**macOS / Linux:**
```bash
chmod +x install.sh
./install.sh
```

**Windows — open Git Bash, then:**
```bash
./install.sh
```

The installer will:
- Check dependencies (`jq`, `curl`, `bash 4+`)
- Install `claude-tracker` to `~/.claude-tracker/bin/`
- Register Claude Code hooks in `~/.claude/settings.json`
- Prompt for: Discord **Webhook URL**, **Bot Token**, **default working directory**

All answers are saved to `~/.claude-tracker/config.json`. You can edit it manually at any time — see `config.example.json` for the full schema.

> **After install.sh: restart Claude Code** so the newly registered hooks take effect.

### 3. Install Node dependencies

```bash
npm install
```

### 4. Invite the bot and run

Make sure the bot is in your Discord server, then:

```bash
node bot.js
```

**Windows shortcut:** double-click `start-bot.vbs`

Slash commands (`/send`, `/status`, etc.) are registered automatically when the bot starts.

---

## File Structure

```
bot.js                      Entry point — Discord client setup, timers, shutdown
src/
  config.js                 Config loader with TTL cache + hot-reload
  constants.js              Path constants, Discord limits, color codes
  state.js                  Shared in-memory state (activeSessions, client)
  session.js                Session CRUD, history, token stats, queue
  claude.js                 Claude CLI spawning, stream parsing, turn execution
  tracker.js                claude-tracker shell integration + native process scan
  dashboard.js              /status, /report, /dashboard, auto-refresh logic
  embeds.js                 Discord embed builders
  files.js                  Image/text attachment handling
  commands.js               Slash command definitions
  handlers/
    interactions.js         Main dispatcher: buttons, modals, select menus, slash commands
    send.js                 /send — create/resume Claude sessions
    sessions.js             /end, /session, /sessions, terminateSession
    project.js              /project — set channel default project
    message.js              Plain message handler (follow-up in active sessions)
    gpt.js                  /gpt — OpenAI Codex sessions

~/.claude-tracker/          Created by install.sh
  bin/claude-tracker        Main shell script
  config.json               Your configuration (bot_token, default_cwd, etc.)
  state.json                Live session state (updated by hooks + monitor)
  bot-sessions/             Persisted Discord bot sessions (JSON per session)
  token-history.jsonl       Token usage records
  failed-prompts.jsonl      Log of failed sends (for debugging)
```

---

## Discord Commands

### Claude Sessions

| Command | Description |
|---------|-------------|
| `/send [message] [project] [model] [file] [image]` | Send a message to Claude. Creates a new session or resumes the existing one. |
| `/end` | Terminate the current session in this channel |
| `/session` | Show current session info (model, turns, context size, etc.) |
| `/sessions` | List saved sessions and reload one |
| `/project` | Set this channel's default project |
| `/compact` | Summarize and compress the conversation context |
| `/model <model>` | Change the model for the current session |

### Monitoring

| Command | Description |
|---------|-------------|
| `/status` | Show all running Claude processes |
| `/dashboard` | Post a live-updating dashboard embed |
| `/snapshot` | Record a token usage snapshot now |
| `/report [period]` | Token usage report (today / week / all) |

### GPT / Codex _(optional — requires OpenAI Codex CLI)_

| Command | Description |
|---------|-------------|
| `/gpt <message> [project] [model]` | Start a Codex session |
| `/gpt-project` | List registered GPT projects |

> Requires the `codex` CLI (`npm install -g @openai/codex`) and an OpenAI API key. If you don't use Codex, ignore these commands — they have no effect on the Claude features.

---

## GPT Projects

Register projects for use with `/gpt`:

```bash
node register-gpt-project.js my-app "C:\Users\YourName\Projects\my-app"
```

Or copy `gpt-projects.example.md` to `gpt-projects.md` and edit it manually.

The bot auto-creates `gpt-projects.md` on first registration. This file is gitignored (contains your local paths).

---

## Hook Flow (claude-tracker)

```
SessionStart       → active session registered  + Discord notification
UserPromptSubmit   → idle → active transition
Stop               → active → idle             + debounced completion notification
SessionEnd         → session removed           + token stats recorded
```

---

## Persistent Sessions

Sessions survive bot restarts. On startup, the bot restores all non-ended sessions from `~/.claude-tracker/bot-sessions/` and reconnects to their Discord threads.

Sessions with an existing Claude session ID support `--resume` (conversation context is preserved across bot restarts).

Ended sessions are kept for 10 days, then automatically deleted along with their Discord thread starter messages.

---

## Dependencies

- `discord.js` ^14 — Discord API client
- `claude` CLI — must be installed and in PATH
- `bash`, `jq`, `curl` — used by the claude-tracker shell script
