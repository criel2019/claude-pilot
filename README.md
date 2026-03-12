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
- Bidirectional file transfer between PC and mobile
- Auto code review with one-click fix application

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
- **Thread-based conversation**: each session runs in its own Discord thread — just type messages to continue
- **Project routing**: set a default repo per channel with `/project`
- **Model switching**: move between Opus, Opus Plan, Sonnet, and Haiku
- **Context cleanup**: use `/compact` before history gets too large
- **Message queue**: when Claude is busy, follow-up messages queue automatically (up to 5)
- **File transfer**: send files from PC to Discord (`/file`) and save Discord files to PC (`/receive`)
- **Natural-language save**: attach a file and say "save to desktop" or "바탕화면에 저장해줘"
- **Image support**: attach up to 3 images per `/send` — or just drop images into the thread
- **Auto code review**: one-click diff-based review with fix application
- **Status and reporting**: `/status`, `/dashboard`, `/snapshot`, and `/report`
- **Session management**: `/session`, `/sessions`, and `/end`
- **Interactive buttons**: continue, cancel, retry, end, cleanup, and reset history — all from Discord
- **Optional Codex support**: run OpenAI Codex sessions from Discord with `/gpt`

---

## How It Works

```text
Discord client (phone, desktop, browser)
  -> /send, /status, /model, /compact
  -> type messages in thread to continue conversation
  -> attach files, images, or text files

Discord bot (Node.js)
  -> reads tracker state
  -> starts or resumes Claude CLI sessions
  -> streams output back into Discord threads
  -> handles file transfers between PC and Discord

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

### Claude Sessions

| Command | Description |
|---|---|
| `/send [message] [project] [model] [file] [image...]` | Send a prompt to Claude with optional project, model, text file, and up to 3 images |
| `/project` | Set this channel's default project |
| `/model <model>` | Change the model for the active session (opus / opusplan / sonnet / haiku) |
| `/compact` | Replace long history with a summary to reduce context size |
| `/session` | Show current session metadata and token stats |
| `/sessions` | List saved sessions and reload one |
| `/end` | End the current session in this channel |

### File Transfer

| Command | Description |
|---|---|
| `/file <path>` | Send a file from your PC to Discord (up to 24 MB) |
| `/receive <file> [folder]` | Save a Discord attachment to your PC (default: `discord-received/`) |

### Monitoring

| Command | Description |
|---|---|
| `/status` | Show all running Claude processes with token counts |
| `/dashboard` | Post a live-updating dashboard embed (auto-refreshes every 30s) |
| `/snapshot` | Record a token snapshot immediately |
| `/report [period]` | Usage report for `today`, `week`, or `all` |

### GPT / Codex

| Command | Description |
|---|---|
| `/gpt <message> [project] [model]` | Start an OpenAI Codex session in Discord |
| `/gpt-project` | List registered GPT/Codex projects |

The optional GPT path requires the `codex` CLI and an OpenAI API key.

---

## Thread-Based Conversation

Once `/send` starts a session, a Discord thread is created. You can continue the conversation by
simply **typing messages in the thread** — no need to use `/send` every time.

Messages in the parent channel also work if the channel has an active session.

### What happens to your messages

- **Text**: forwarded to Claude as a follow-up prompt
- **Text files** (`.txt`, `.md`, `.json`, `.js`, `.ts`, `.py`, `.css`, `.html`, `.sh`, `.yaml`, `.yml`, `.log`): content is read and injected into the prompt
- **Images** (`.png`, `.jpg`, `.jpeg`, `.gif`, `.webp`, `.bmp`): downloaded, paths sent to Claude for analysis
- **Other files**: saved to your PC automatically (default: `discord-received/`)

### Queue system

If Claude is still processing, your message is queued (up to 5 items) and runs automatically when
the current task finishes. You'll see these reactions:

| Reaction | Meaning |
|---|---|
| :hourglass: | Message queued, waiting for current task |
| :arrows_counterclockwise: | Processing your message |
| :white_check_mark: | Completed successfully |
| :x: | Error occurred |
| :no_entry: | Queue is full |

---

## File Transfer

### PC to Discord (`/file`)

Send any file from your PC to Discord:

```
/file path:C:\Users\You\project\output.png
```

- Supports absolute and relative paths
- Max size: 24 MB (Discord bot limit)

### Discord to PC (`/receive`)

Save a Discord attachment to your PC:

```
/receive file:<attachment> folder:my-project
```

- Default location: `discord-received/` (configurable via `CLAUDE_RECEIVED_DIR` env var)
- Optional subfolder for organization
- Filenames are deduplicated automatically (adds `(1)`, `(2)`, etc.)

### Natural-Language File Saving

Attach a file and type a destination in natural language. The bot recognizes:

| What you type | Where it saves |
|---|---|
| `바탕화면에 저장해줘` / `save to desktop` | `~/Desktop/` |
| `다운로드 폴더에 넣어` / `download folder` | `~/Downloads/` |
| `문서에 저장` / `documents` | `~/Documents/` |
| `사진 폴더` / `pictures` | `~/Pictures/` |
| `음악` / `music` | `~/Music/` |
| `동영상` / `비디오` / `video` | `~/Videos/` |
| `기본 폴더에 저장` | Default receive directory |
| `E:/projects/my-app` | Explicit path (any drive) |

If the message is **only** a save instruction (e.g. "바탕화면에 저장해줘"), the file is saved without
involving Claude. If the message also contains a prompt, the file is saved **and** forwarded to Claude.

### Auto-Upload from Claude (`[SEND_FILE]`)

Claude can send files back to you. When Claude includes `[SEND_FILE:/absolute/path/to/file]` in its
response, the bot automatically uploads that file to the Discord thread.

- Multiple files per response are supported
- Sensitive files (`.env`, `.pem`, `.key`, SSH keys, etc.) are blocked
- Only files under allowed directories are sent (user profile and configured drives)

---

## Auto Code Review

After each Claude turn, a **Code Review** button appears. Click it to get an automated review of
the changes made during the session.

### How it works

1. Detects files modified by Claude during the session
2. Runs `git diff` scoped to those files (staged, unstaged, or last commit)
3. Extracts changed functions and greps for callers across the codebase
4. Classifies the review perspective (CSS/layout, game logic, refactoring, new feature, or general)
5. Sends everything to a fresh Sonnet session for minimal token cost
6. Displays results with file references, perspective, and dependency count

### Review perspectives

The reviewer automatically adjusts its focus based on what changed:

| Type | Focus |
|---|---|
| CSS/layout | Responsive breakage, duplicate properties, z-index conflicts |
| Game logic | Runtime errors, edge cases, multiplayer sync, state inconsistency |
| Refactoring | Missing imports, broken callers, scope changes |
| New feature | Existing code conflicts, naming consistency, missing initialization |
| General | Runtime errors, logic flaws, type mismatches |

### Applying fixes

If the review finds issues, an **Apply Fix** button appears. Click it to open a modal where you can
add optional instructions (e.g. "match existing style", "add comments"), then Claude applies the
fixes in the current session.

---

## Session Buttons

Each session thread includes interactive buttons:

| Button | Action |
|---|---|
| **Continue** | Opens a modal to type a follow-up message |
| **Cancel** | Kills the running Claude process and clears the queue |
| **End** | Ends the session and archives the thread |
| **Cleanup** | Saves the session and starts fresh (history cleared, previous loadable via `/sessions`) |
| **Reset History** | Clears the bot's context history while keeping the Claude session alive |
| **Retry** | Re-runs the last prompt (removes the previous response from history first) |
| **Code Review** | Triggers an automated diff-based code review (see above) |

---

## Persistent Sessions

- Active sessions are reloaded from `~/.claude-tracker/bot-sessions/` when the bot restarts.
- Sessions with a Claude session ID can resume with `--resume`.
- Ended sessions are kept for 10 days, then purged automatically.
- Each session stores up to 100 messages of history.
- Token statistics are tracked per session with warning levels (safe / caution / warning / critical).

---

## GPT / Codex Setup

Claude Pilot can also trigger OpenAI Codex from Discord if you want the same control surface for both
tools.

### Prerequisites

- `codex` CLI installed and on your PATH
- OpenAI API key configured

### Register a project

```bash
node register-gpt-project.js my-app "C:\Users\YourName\Projects\my-app"
```

Or copy `gpt-projects.example.md` to `gpt-projects.md` and edit it manually.
`gpt-projects.md` is gitignored because it contains local paths.

### How GPT sessions work

1. Your message is first rewritten by Claude (Sonnet) to optimize it for Codex
2. The optimized prompt is sent to the `codex` CLI
3. Results appear in a Discord thread, similar to Claude sessions
4. If Claude rewriting fails, the original message is sent directly with a fallback prompt
5. Available models: GPT-5.4 (default), GPT-5.3 Instant, GPT-5.2, GPT-4o (legacy)

---

## Configuration

`~/.claude-tracker/config.json` is created by `install.sh` and can be edited later.

| Key | Default | Description |
|---|---|---|
| `bot_token` | none | Discord bot token (required) |
| `default_cwd` | `$HOME` | Default working directory for new sessions |
| `allowed_users` | `[]` | Allowed Discord user IDs; empty means everyone in the server |
| `session_timeout_minutes` | `60` | Idle session cleanup threshold |
| `stream_edit_interval_ms` | `2000` | Discord edit interval for streaming output |
| `max_context_history_turns` | `4` | History turns injected into each Claude request |
| `max_context_chars` | `50000` | Max history size before trimming |
| `token_warning_thresholds` | object | Token levels: `caution: 20000`, `warning: 50000`, `critical: 100000` |
| `known_projects` | `{}` | Remembered project names and their paths |
| `channel_defaults` | `{}` | Default project per Discord channel |
| `dashboard_channel_id` | none | Channel for the live dashboard |
| `dashboard_message_id` | none | Message ID for dashboard auto-updates |

### Environment variables

| Variable | Description |
|---|---|
| `CLAUDE_RECEIVED_DIR` | Override the default directory for received files (default: `E:/discord-received`) |

See [`config.example.json`](config.example.json) for the full schema.

---

## Security

> The bot runs Claude with `--dangerously-skip-permissions`, so Claude gets full read/write access to
> your machine.

- By default, `allowed_users: []` means anyone in the Discord server can use the bot.
- Put the bot in a private server or restrict `allowed_users` to trusted user IDs.
- Claude Pilot does not transmit or expose your Claude credentials.
- File uploads via `[SEND_FILE]` are restricted to allowed directories and block sensitive files.
- File paths containing special characters are sanitized to prevent injection.

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
  config.js                 Config loader with caching
  constants.js              Shared paths, limits, and color palette
  state.js                  In-memory runtime state
  session.js                Session storage, token stats, and queue management
  claude.js                 Claude CLI execution, streaming, and file send parsing
  tracker.js                Hook integration and native process scan
  dashboard.js              Dashboard and report helpers
  embeds.js                 Discord embed builders
  files.js                  Attachment handling and natural-language path parsing
  review.js                 Auto code review (diff, dependency, prompt assembly)
  commands.js               Slash command definitions
  timers.js                 Cleanup and refresh timers
  handlers/
    interactions.js          Main interaction router
    send.js                 /send command handler
    sessions.js             Session management handlers
    buttons.js              Button interaction handlers (continue, cancel, retry, review, etc.)
    modals.js               Modal submission handlers
    message.js              Message and file handling (thread follow-ups, auto-save)
    filetransfer.js         /file and /receive handlers
    project.js              Project configuration
    gpt.js                  OpenAI Codex integration
```

---

## License

MIT

---

<div align="center">

Claude Pilot is an independent community project and is not affiliated with or endorsed by Anthropic.

</div>
