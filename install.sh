#!/usr/bin/env bash
# ============================================================================
# Claude Process Tracker — Install Script
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.claude-tracker"
BIN_DIR="${INSTALL_DIR}/bin"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║       Claude Process Tracker — Installer                 ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── 1. Dependency check ───────────────────────────────────────────────────
echo "1)  Checking dependencies..."

if ! command -v jq &>/dev/null; then
    echo "   ERROR: jq is not installed."
    echo ""
    echo "   Install with:"
    echo "     macOS:           brew install jq"
    echo "     Ubuntu/Debian:   sudo apt install jq"
    echo "     Windows (scoop): scoop install jq"
    exit 1
fi
echo "   OK  jq"

if ! command -v curl &>/dev/null; then
    echo "   ERROR: curl is not installed."
    exit 1
fi
echo "   OK  curl"

# bash version check
if (( BASH_VERSINFO[0] < 4 )); then
    echo "   WARNING: bash ${BASH_VERSION} detected. bash 4.0+ is recommended."
    echo "     macOS: brew install bash"
    echo "   Continuing, but some features may not work correctly."
fi

# ── 2. Create directories ─────────────────────────────────────────────────
echo ""
echo "2)  Creating install directories..."
mkdir -p "${BIN_DIR}"
echo "   OK  ${INSTALL_DIR}"

# ── 3. Copy script ────────────────────────────────────────────────────────
echo ""
echo "3)  Installing script..."
cp "${SCRIPT_DIR}/claude-tracker.sh" "${BIN_DIR}/claude-tracker"
chmod +x "${BIN_DIR}/claude-tracker"
echo "   OK  claude-tracker -> ${BIN_DIR}/claude-tracker"

# ── 4. Register hooks in Claude Code settings ─────────────────────────────
echo ""
echo "4)  Configuring Claude Code hooks..."

mkdir -p "${HOME}/.claude"

if [[ -f "${CLAUDE_SETTINGS}" ]]; then
    echo "   Found existing settings.json."

    # Check if tracker hook is already registered
    if jq -e '.hooks.SessionStart[]?.hooks[]?.command | test("claude-tracker")' "${CLAUDE_SETTINGS}" >/dev/null 2>&1; then
        echo "   OK  tracker hooks already installed (skipped)"
    else
        # Backup existing settings
        cp "${CLAUDE_SETTINGS}" "${CLAUDE_SETTINGS}.backup.$(date '+%Y%m%d%H%M%S')"
        echo "   OK  backup created"

        # Convert Unix path to Windows path for the tracker binary
        # Windows Git Bash: /c/Users/... -> C:/Users/...
        TRACKER_BIN_WIN=$(echo "${BIN_DIR}/claude-tracker" | sed 's|^/\([a-zA-Z]\)/|\1:/|')
        local_hooks=$(sed "s|__TRACKER_BIN__|${TRACKER_BIN_WIN}|g" "${SCRIPT_DIR}/hooks-settings.json")

        merged=$(jq --argjson new_hooks "$(echo "${local_hooks}" | jq '.hooks')" '
            .hooks.SessionStart = ((.hooks.SessionStart // []) + $new_hooks.SessionStart) |
            .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) + $new_hooks.UserPromptSubmit) |
            .hooks.Stop = ((.hooks.Stop // []) + $new_hooks.Stop) |
            .hooks.SessionEnd = ((.hooks.SessionEnd // []) + $new_hooks.SessionEnd)
        ' "${CLAUDE_SETTINGS}")

        echo "${merged}" | jq '.' > "${CLAUDE_SETTINGS}"
        echo "   OK  hooks added"
    fi
else
    # Create new settings.json with placeholder replaced
    TRACKER_BIN_WIN=$(echo "${BIN_DIR}/claude-tracker" | sed 's|^/\([a-zA-Z]\)/|\1:/|')
    sed "s|__TRACKER_BIN__|${TRACKER_BIN_WIN}|g" "${SCRIPT_DIR}/hooks-settings.json" > "${CLAUDE_SETTINGS}"
    echo "   OK  settings.json created"
fi

# ── 5. Initialize config ──────────────────────────────────────────────────
echo ""
echo "5)  Initializing config..."

# Run tracker once to generate config file
"${BIN_DIR}/claude-tracker" help > /dev/null 2>&1

echo "   OK  config.json created"

# ── 6. PATH registration ──────────────────────────────────────────────────
echo ""
echo "6)  PATH registration (optional)..."
echo ""

SHELL_NAME=$(basename "${SHELL:-bash}")
RC_FILE=""
case "${SHELL_NAME}" in
    zsh)  RC_FILE="${HOME}/.zshrc" ;;
    bash) RC_FILE="${HOME}/.bashrc" ;;
    fish) RC_FILE="${HOME}/.config/fish/config.fish" ;;
esac

if [[ -n "${RC_FILE}" ]]; then
    if grep -q "claude-tracker" "${RC_FILE}" 2>/dev/null; then
        echo "   OK  already in PATH"
    else
        echo "   Add the following line to ${RC_FILE}?"
        echo ""
        if [[ "${SHELL_NAME}" == "fish" ]]; then
            echo "     fish_add_path ${BIN_DIR}"
        else
            echo "     export PATH=\"\${PATH}:${BIN_DIR}\""
        fi
        echo ""
        read -r -p "   Add it now? [y/N] " response
        if [[ "${response}" =~ ^[Yy]$ ]]; then
            if [[ "${SHELL_NAME}" == "fish" ]]; then
                echo "fish_add_path ${BIN_DIR}" >> "${RC_FILE}"
            else
                echo "export PATH=\"\${PATH}:${BIN_DIR}\"" >> "${RC_FILE}"
            fi
            echo "   OK  PATH updated. Restart your shell or run: source ${RC_FILE}"
        fi
    fi
fi

# ── 7. Discord Webhook configuration ──────────────────────────────────────
echo ""
echo "7)  Discord Webhook setup (for claude-tracker notifications)..."
echo ""
echo "   Create a Webhook URL in your Discord channel:"
echo "   Channel Settings -> Integrations -> Webhooks -> New Webhook"
echo ""
read -r -p "   Webhook URL (press Enter to skip): " webhook_url

if [[ -n "${webhook_url}" ]]; then
    "${BIN_DIR}/claude-tracker" config webhook "${webhook_url}"
fi

# ── 8. Discord Bot Token configuration ────────────────────────────────────
echo ""
echo "8)  Discord Bot Token setup..."
echo ""
echo "   Create a bot at the Discord Developer Portal:"
echo "   https://discord.com/developers/applications"
echo "   -> New Application -> Bot -> Reset Token"
echo "   (Also enable Message Content Intent)"
echo ""
read -r -p "   Bot Token (press Enter to skip): " bot_token

CONFIG_FILE="${INSTALL_DIR}/config.json"
if [[ -n "${bot_token}" ]]; then
    if [[ -f "${CONFIG_FILE}" ]]; then
        tmp=$(jq --arg v "${bot_token}" '.bot_token = $v' "${CONFIG_FILE}")
        echo "${tmp}" > "${CONFIG_FILE}"
    else
        jq -n --arg v "${bot_token}" '{"bot_token": $v}' > "${CONFIG_FILE}"
    fi
    echo "   OK  bot_token saved"
else
    echo "   NOTE: Add bot_token manually to ~/.claude-tracker/config.json later."
fi

# ── 9. Default working directory ──────────────────────────────────────────
echo ""
echo "9)  Default working directory..."
echo ""
echo "   This is the folder Claude opens when no project is specified in /send."
if [[ -n "${USERPROFILE:-}" ]]; then
    echo "   Example: ${USERPROFILE}\\Projects"
else
    echo "   Example: ${HOME}/projects"
fi
echo ""
read -r -p "   Default working directory (Enter = home directory): " default_cwd

if [[ -n "${default_cwd}" ]]; then
    if [[ -f "${CONFIG_FILE}" ]]; then
        tmp=$(jq --arg v "${default_cwd}" '.default_cwd = $v' "${CONFIG_FILE}")
        echo "${tmp}" > "${CONFIG_FILE}"
    else
        jq -n --arg v "${default_cwd}" '{"default_cwd": $v}' > "${CONFIG_FILE}"
    fi
    echo "   OK  default_cwd saved"
else
    echo "   INFO: Using home directory as default."
fi

# ── Done ───────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                  Installation Complete!                  ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  IMPORTANT: Restart Claude Code for hooks to take effect ║"
echo "║                                                          ║"
echo "║  Next steps:                                             ║"
echo "║    1. Restart Claude Code                                ║"
echo "║    2. npm install        (in the bot directory)          ║"
echo "║    3. node bot.js        (start the bot)                 ║"
echo "║       Windows: double-click start-bot.vbs                ║"
echo "║                                                          ║"
echo "║  Config file: ~/.claude-tracker/config.json              ║"
echo "║    bot_token    Discord bot token (required)             ║"
echo "║    default_cwd  Default working directory                ║"
echo "║    webhook      Discord notification Webhook URL         ║"
echo "║    allowed_users  List of allowed Discord user IDs       ║"
echo "║                   (leave empty to allow all server users)║"
echo "║                                                          ║"
echo "║  claude-tracker commands:                                ║"
echo "║    status    Show current status                         ║"
echo "║    usage     Token usage statistics                      ║"
echo "║    monitor   Start background polling                    ║"
echo "║    upgrade   Update to the latest version from GitHub    ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "Restart Claude Code and tracking will begin automatically."
