#!/usr/bin/env bash
# ============================================================================
# Claude Process Tracker v2.2 — Discord notifications + process monitoring
# ============================================================================
# Auto-called from Claude Code hooks to track processes and send Discord notifications
#
# Usage:
#   claude-tracker <command> [options]
#
# Commands (auto-called by hooks):
#   register    — register new session (SessionStart hook)
#   update      — update status (Stop hook, debounced)
#   end         — end session (SessionEnd hook)
#
# Commands (manual):
#   s|status    — all project status (ANSI colors)
#   d|dashboard — send dashboard embed to Discord
#   w|watch     — real-time monitoring
#   h|history   — per-project stats & recent events
#   t|test      — connection & config diagnostics
#   cleanup     — clean up dead sessions
#   config      — config management (webhook, alias, notify, show)
#   reset       — reset state
#   uninstall   — remove tracker
#
# Safety:
#   - Hook commands: always exit 0 via trap (no impact on Claude Code)
#   - flock/mkdir-based file locking (works on Linux/macOS/Windows)
#   - jq --arg to prevent JSON injection
#   - PID-based safe file writes (atomic mv)
#   - Stop hook debouncing (prevents notification spam)
# ============================================================================

# Basic options: for manual commands. Hook commands are handled safely via trap.
set -uo pipefail

# Force PATH addition in case jq is not found in hook environment
export PATH="${HOME}/bin:/usr/bin:/usr/local/bin:${PATH}"

# ── Constants ────────────────────────────────────────────────────────────────
readonly TRACKER_DIR="${HOME}/.claude-tracker"
readonly STATE_FILE="${TRACKER_DIR}/state.json"
readonly CONFIG_FILE="${TRACKER_DIR}/config.json"
readonly LOG_FILE="${TRACKER_DIR}/tracker.log"
readonly USAGE_LOG="${TRACKER_DIR}/usage.jsonl"
readonly LOCK_FILE="${TRACKER_DIR}/.state.lock"
readonly TOKEN_HISTORY="${TRACKER_DIR}/token-history.jsonl"
readonly CURL_CONNECT_TIMEOUT=5
readonly CURL_MAX_TIME=10

# ── ANSI colors (terminal UX) ───────────────────────────────────────────────
# Enable colors if stdout is a terminal; disable for pipes/redirects.
if [[ -t 1 ]]; then
    C_RESET="\033[0m"
    C_BOLD="\033[1m"
    C_DIM="\033[2m"
    C_GREEN="\033[32m"
    C_YELLOW="\033[33m"
    C_RED="\033[31m"
    C_CYAN="\033[36m"
    C_WHITE="\033[97m"
    C_BG_GREEN="\033[42m"
    C_BG_YELLOW="\033[43m"
    C_BG_RED="\033[41m"
else
    C_RESET="" C_BOLD="" C_DIM="" C_GREEN="" C_YELLOW="" C_RED=""
    C_CYAN="" C_WHITE="" C_BG_GREEN="" C_BG_YELLOW="" C_BG_RED=""
fi

# ── Initialization ──────────────────────────────────────────────────────────
init_tracker() {
    mkdir -p "${TRACKER_DIR}"
    chmod 700 "${TRACKER_DIR}" 2>/dev/null || true

    if [[ ! -f "${STATE_FILE}" ]]; then
        echo '{"sessions": {}, "projects": {}}' > "${STATE_FILE}"
        chmod 600 "${STATE_FILE}" 2>/dev/null || true
    fi


    if [[ -f "${LOG_FILE}" ]]; then
        local log_size
        log_size=$(wc -c < "${LOG_FILE}" 2>/dev/null || echo 0)
        if (( log_size > 1048576 )); then
            tail -n 500 "${LOG_FILE}" > "${LOG_FILE}.tmp.$$" && mv "${LOG_FILE}.tmp.$$" "${LOG_FILE}"
        fi
    fi

    if [[ ! -f "${CONFIG_FILE}" ]]; then
        cat > "${CONFIG_FILE}" << 'CONFIGEOF'
{
    "discord_webhook_url": "",
    "notification": {
        "on_start": true,
        "on_complete": true,
        "on_error": true,
        "on_idle": true,
        "idle_threshold_minutes": 10
    },
    "project_aliases": {},
    "dashboard_channel_webhook": ""
}
CONFIGEOF
        chmod 600 "${CONFIG_FILE}" 2>/dev/null || true
        echo "[SETUP] config.json created: ${CONFIG_FILE}" >&2
        echo "[SETUP] Set your Discord Webhook URL:" >&2
        echo "  claude-tracker config webhook <URL>" >&2
    fi
}

# ── Logging ─────────────────────────────────────────────────────────────────
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*" >> "${LOG_FILE}" 2>/dev/null || true
}

# ── jq availability check ───────────────────────────────────────────────────
require_jq() {
    if command -v jq &>/dev/null; then
        return 0
    fi
    log "ERROR" "jq not found (PATH=${PATH})"
    echo "ERROR: jq is not installed." >&2
    return 1
}

# ── Windows PID utilities ───────────────────────────────────────────────────
# kill -0 does not recognize Windows PIDs in Git Bash (MSYS2).
# Use tasklist to check Windows PID liveness.

# Check if a Windows PID is alive (tasklist-based)
_is_win_pid_alive() {
    local pid="$1"
    (( pid > 0 )) || return 1
    tasklist //FI "PID eq ${pid}" //NH < /dev/null 2>/dev/null | grep -q "[0-9]"
}

# Find an unassigned claude.exe PID from tasklist.
# In MSYS2, parent chain traversal is not possible (shim exits immediately),
# so we get all claude.exe PIDs from tasklist and exclude ones already claimed in state.json.
_find_claude_pid() {
    local running_pids
    running_pids=$(tasklist //FI "IMAGENAME eq claude.exe" //FO CSV //NH 2>/dev/null \
        | cut -d'"' -f4 | grep -E '^[0-9]+$' | sort -n)
    [[ -z "${running_pids}" ]] && echo "0" && return

    local claimed_pids=""
    if [[ -f "${STATE_FILE}" ]]; then
        claimed_pids=$(jq -r '.sessions[].pid // 0' "${STATE_FILE}" 2>/dev/null | sort -n -u)
    fi

    while read -r pid; do
        [[ -z "${pid}" || "${pid}" == "0" ]] && continue
        if [[ -z "${claimed_pids}" ]] || ! echo "${claimed_pids}" | grep -qx "${pid}"; then
            echo "${pid}"
            return
        fi
    done <<< "${running_pids}"

    echo "0"
}

# ── PID-based alive filter ───────────────────────────────────────────────────
# Return state with dead-PID sessions removed (in-memory only, not saved).
# Sessions with PID 0 or no PID (auto-discovered) are also removed.
_filter_alive_sessions() {
    local state="$1"
    local dead_sids=()

    while IFS='|' read -r sid pid; do
        [[ -z "${sid}" ]] && continue
        local pid_val
        pid_val=$(to_int "${pid}" 0)
        if (( pid_val == 0 )) || ! _is_win_pid_alive "${pid_val}"; then
            dead_sids+=("${sid}")
        fi
    done < <(echo "${state}" | jq -r '.sessions | to_entries[] | "\(.key)|\(.value.pid // 0)"')

    if (( ${#dead_sids[@]} > 0 )); then
        local dead_json
        dead_json=$(printf '%s\n' "${dead_sids[@]}" | jq -R -s 'split("\n") | map(select(length > 0))')
        state=$(echo "${state}" | jq --argjson dead "${dead_json}" '
            .sessions |= with_entries(select(.key as $k | $dead | index($k) | not)) |
            (.sessions | [.[].project] | unique) as $alive_projects |
            .projects |= with_entries(select(.key as $k | $alive_projects | index($k))) |
            # If active_session is dead, replace with a live session in the same project
            # Note: .sessions cannot be accessed inside with_entries → capture beforehand
            (.sessions) as $live_sessions |
            .projects |= with_entries(
                if (.value.active_session as $as | $dead | index($as)) then
                    (.key as $proj |
                     [$live_sessions | to_entries[] | select(.value.project == $proj)] | first) as $next |
                    if $next != null then
                        .value.active_session = $next.key |
                        .value.status = $next.value.status
                    else .
                    end
                else .
                end
            )
        ')
    fi

    echo "${state}"
}

# ── JSON helpers ────────────────────────────────────────────────────────────
_CONFIG_CACHE=""
_CONFIG_CACHE_TIME=0
get_config() {
    local key="$1"
    local now
    now=$(date '+%s')
    # Cache for 30 seconds
    if [[ -z "${_CONFIG_CACHE}" ]] || (( now - _CONFIG_CACHE_TIME > 30 )); then
        _CONFIG_CACHE=$(cat "${CONFIG_FILE}" 2>/dev/null || echo '{}')
        _CONFIG_CACHE_TIME=${now}
    fi
    echo "${_CONFIG_CACHE}" | jq -r "${key} // empty" 2>/dev/null || echo ""
}

# Safe integer extraction: replaces non-numeric values with default
to_int() {
    local val="${1//$'\r'/}"
    local default="${2:-0}"
    if [[ "${val}" =~ ^-?[0-9]+$ ]]; then
        echo "${val}"
    else
        echo "${default}"
    fi
}

get_state() {
    if [[ -f "${STATE_FILE}" ]]; then
        local content
        content=$(cat "${STATE_FILE}" 2>/dev/null) || true
        if [[ -n "${content}" ]] && echo "${content}" | jq empty 2>/dev/null; then
            echo "${content}"
            return
        fi
    fi
    echo '{"sessions": {}, "projects": {}}'
}

# Safe file write: PID-based tmp + cleanup on failure
safe_write_json() {
    local target_file="$1"
    local json_data="$2"
    local tmp_file="${target_file}.tmp.$$"

    if echo "${json_data}" | jq '.' > "${tmp_file}" 2>/dev/null; then
        mv "${tmp_file}" "${target_file}"
        return 0
    else
        rm -f "${tmp_file}"
        log "ERROR" "JSON write failed: ${target_file}"
        return 1
    fi
}

save_state() {
    safe_write_json "${STATE_FILE}" "$1"
}

# Safely read JSON from stdin
read_stdin_json() {
    # Pass via temp file instead of bash variable/pipe (Windows compatibility)
    local tmp_json="${TRACKER_DIR}/.stdin_tmp.$$"
    cat > "${tmp_json}" 2>/dev/null

    if [[ ! -s "${tmp_json}" ]]; then
        log "WARN" "stdin empty"
        rm -f "${tmp_json}"
        return 1
    fi

    # Remove \r (Windows line endings)
    sed -i "s/$(printf '\r')$//" "${tmp_json}" 2>/dev/null

    local jq_err
    jq_err=$(jq empty "${tmp_json}" 2>&1)
    local rc=$?
    if (( rc != 0 )); then
        cp "${tmp_json}" "${TRACKER_DIR}/.debug_stdin_fail" 2>/dev/null
        log "ERROR" "read_stdin fail (rc=${rc}): jq=$(command -v jq) err=[${jq_err}] size=$(wc -c < "${tmp_json}")"
        rm -f "${tmp_json}"
        return 1
    fi

    cat "${tmp_json}"
    rm -f "${tmp_json}"
}

# ── File locking ────────────────────────────────────────────
# Prevent concurrent access to state.json.
# Linux: flock, macOS/BSD/Windows: mkdir-based atomic lock (POSIX guaranteed).
with_state_lock() {
    local lock_timeout=5

    if command -v flock &>/dev/null; then
        # Linux: use flock
        (
            flock -w "${lock_timeout}" 200 || {
                log "ERROR" "flock timeout (${lock_timeout}s)"
                return 1
            }
            "$@"
        ) 200>"${LOCK_FILE}"
    else
        # macOS/BSD/Windows: mkdir-based atomic lock
        # mkdir is guaranteed atomic by POSIX.
        local lock_dir="${LOCK_FILE}.d"
        local deadline=$(( $(date '+%s') + lock_timeout ))

        while ! mkdir "${lock_dir}" 2>/dev/null; do
            if (( $(date '+%s') >= deadline )); then
                # Stale lock check: release if owning process is dead
                local lock_pid
                lock_pid=$(cat "${lock_dir}/pid" 2>/dev/null || echo "")
                if [[ -n "${lock_pid}" ]] && ! kill -0 "${lock_pid}" 2>/dev/null; then
                    rm -rf "${lock_dir}"
                    continue
                fi
                log "ERROR" "mkdir lock timeout (${lock_timeout}s)"
                return 1
            fi
            sleep 0.1 2>/dev/null || sleep 1
        done

        # Record PID for stale lock detection
        echo $$ > "${lock_dir}/pid" 2>/dev/null

        # Guarantee lock release (normal and abnormal exit)
        local _lock_cleanup_done=false
        _release_lock() {
            if [[ "${_lock_cleanup_done}" == "false" ]]; then
                _lock_cleanup_done=true
                rm -rf "${lock_dir}"
            fi
        }

        "$@"
        local rc=$?
        _release_lock
        return ${rc}
    fi
}

# ── Project name extraction ────────────────────────────────────────────────
# Priority: config alias > metadata auto-detection > basename
_detect_project_name_from_metadata() {
    local dir="$1"

    # package.json → name field
    if [[ -f "${dir}/package.json" ]]; then
        local pkg_name
        pkg_name=$(jq -r '.name // empty' "${dir}/package.json" 2>/dev/null)
        if [[ -n "${pkg_name}" ]]; then
            echo "${pkg_name}"
            return
        fi
    fi

    # .git remote → extract repository name
    if [[ -d "${dir}/.git" ]]; then
        local remote_url
        remote_url=$(git -C "${dir}" remote get-url origin 2>/dev/null || echo "")
        if [[ -n "${remote_url}" ]]; then
            # https://github.com/user/repo.git or git@github.com:user/repo.git
            local repo_name
            repo_name=$(echo "${remote_url}" | sed 's/\.git$//' | sed 's|.*/||')
            if [[ -n "${repo_name}" ]]; then
                echo "${repo_name}"
                return
            fi
        fi
    fi

    # pyproject.toml → name field
    if [[ -f "${dir}/pyproject.toml" ]]; then
        local py_name
        py_name=$(grep -m1 '^name\s*=' "${dir}/pyproject.toml" 2>/dev/null | sed 's/^name\s*=\s*["'"'"']\(.*\)["'"'"']/\1/')
        if [[ -n "${py_name}" ]]; then
            echo "${py_name}"
            return
        fi
    fi

    # Cargo.toml → name field
    if [[ -f "${dir}/Cargo.toml" ]]; then
        local cargo_name
        cargo_name=$(grep -m1 '^name\s*=' "${dir}/Cargo.toml" 2>/dev/null | sed 's/^name\s*=\s*["'"'"']\(.*\)["'"'"']/\1/')
        if [[ -n "${cargo_name}" ]]; then
            echo "${cargo_name}"
            return
        fi
    fi

    # go.mod → last segment of module path
    if [[ -f "${dir}/go.mod" ]]; then
        local go_mod
        go_mod=$(grep -m1 '^module ' "${dir}/go.mod" 2>/dev/null | awk '{print $2}' | sed 's|.*/||')
        if [[ -n "${go_mod}" ]]; then
            echo "${go_mod}"
            return
        fi
    fi

    return 1
}

get_project_name() {
    local dir="$1"
    local project_alias
    project_alias=$(jq -r --arg d "${dir}" '.project_aliases[$d] // empty' "${CONFIG_FILE}" 2>/dev/null || echo "")

    if [[ -n "${project_alias}" ]]; then
        echo "${project_alias}"
        return
    fi

    # Attempt metadata auto-detection
    local detected
    detected=$(_detect_project_name_from_metadata "${dir}" 2>/dev/null) || true
    if [[ -n "${detected}" ]]; then
        echo "${detected}"
        return
    fi

    basename "${dir}"
}

# ── Time formatting ─────────────────────────────────────────────────────────
format_duration() {
    local seconds
    seconds=$(to_int "${1:-0}" 0)

    if (( seconds < 0 )); then
        seconds=0
    fi

    if (( seconds < 60 )); then
        echo "${seconds}s"
    elif (( seconds < 3600 )); then
        echo "$(( seconds / 60 ))m $(( seconds % 60 ))s"
    else
        echo "$(( seconds / 3600 ))h $(( seconds % 3600 / 60 ))m"
    fi
}

# ── Path shortening ─────────────────────────────────────────────────────────
shorten_path() {
    local path="$1"
    local max_len="${2:-40}"
    path="${path/#$HOME/\~}"

    if (( ${#path} <= max_len )); then
        echo "${path}"
    else
        local base
        base=$(basename "${path}")
        local avail=$(( max_len - ${#base} - 5 ))
        if (( avail > 0 )); then
            echo "~/…/${base}"
        else
            echo "…/${base}"
        fi
    fi
}

# ── Exit reason localization ─────────────────────────────────────────────────
localize_reason() {
    case "$1" in
        clear)                       echo "Session cleared (/clear)" ;;
        logout)                      echo "Logged out" ;;
        prompt_input_exit)           echo "User exit (Ctrl+C)" ;;
        bypass_permissions_disabled) echo "Permission mode changed" ;;
        context_compact)             echo "Context compacted (auto-restart)" ;;
        session_replaced)            echo "Session replaced (process alive)" ;;
        process_exit)                echo "Process exited" ;;
        unknown)                     echo "Unknown" ;;
        other)                       echo "Other" ;;
        *)                           echo "$1" ;;
    esac
}

# ── Transcript token usage parsing ─────────────────────────────────────────
# Extract cumulative tokens and cost from Claude Code transcript JSONL.
# Each line has message.usage (input_tokens, output_tokens, cache_*) + costUSD.
# User prompts (type=user) are also extracted for activity summary logging.
parse_transcript_usage() {
    local transcript_path="$1"

    if [[ ! -f "${transcript_path}" ]]; then
        echo "{}"
        return
    fi

    # Single jq call for all aggregation
    # - tokens: sum input/output/cache_creation/cache_read
    # - cost: sum costUSD
    # - model: last used model
    # - user prompts: last 3 messages with type=user
    jq -s '
        reduce .[] as $line ({
            input_tokens: 0,
            output_tokens: 0,
            cache_creation_tokens: 0,
            cache_read_tokens: 0,
            total_cost_usd: 0,
            model: null,
            user_prompts: []
        };
            # Aggregate tokens (exclude sidechain and API error messages)
            if ($line.message?.usage != null)
               and ($line.isSidechain != true)
               and ($line.isApiErrorMessage != true)
            then
                .input_tokens += ($line.message.usage.input_tokens // 0)
                | .output_tokens += ($line.message.usage.output_tokens // 0)
                | .cache_creation_tokens += ($line.message.usage.cache_creation_input_tokens // 0)
                | .cache_read_tokens += ($line.message.usage.cache_read_input_tokens // 0)
                | .model = ($line.message.model // .model)
            else . end
            # Aggregate cost
            | if ($line.costUSD != null) and ($line.costUSD > 0)
              then .total_cost_usd += $line.costUSD
              else . end
            # Collect user prompts
            | if $line.type == "user"
                 and ($line.message?.role == "user")
                 and ($line.message?.content != null)
              then
                  .user_prompts += [
                      ($line.message.content
                       | if type == "array" then
                           [.[] | select(.type == "text") | .text] | join(" ")
                         elif type == "string" then .
                         else "" end
                       | .[0:120])
                  ]
              else . end
        )
        | .total_tokens = .input_tokens + .output_tokens
        | .user_prompts = (.user_prompts | if length > 5 then .[-5:] else . end)
    ' "${transcript_path}" 2>/dev/null || echo "{}"
}

# ── Live token usage (running sessions) ────────────────────────────────────
# Find the current active transcript from CWD path and sum tokens
get_live_tokens() {
    local cwd="$1"

    # CWD (C:/...) → Claude projects directory name conversion
    local dir_name
    dir_name=$(echo "${cwd}" | sed 's/[^A-Za-z0-9._-]/-/g')
    local proj_dir="${HOME}/.claude/projects/${dir_name}"

    [[ -d "${proj_dir}" ]] || { echo "{}"; return; }

    # Most recent jsonl file (transcript of currently active session)
    local latest_jsonl
    latest_jsonl=$(ls -t "${proj_dir}"/*.jsonl 2>/dev/null | head -1)
    [[ -z "${latest_jsonl}" ]] && { echo "{}"; return; }

    # Extract usage lines with grep → aggregate with jq (fast even on large files)
    grep '"usage"' "${latest_jsonl}" 2>/dev/null | jq -s '
        reduce .[] as $line ({input: 0, output: 0};
            .input += ($line.message.usage.input_tokens // 0) |
            .output += ($line.message.usage.output_tokens // 0)
        ) | .total = .input + .output
    ' 2>/dev/null || echo "{}"
}

# ── Session snapshot (tokens + user prompts) ───────────────────────────────
# Sum tokens and extract recent user prompts from transcript
get_session_snapshot() {
    local cwd="$1"

    local dir_name
    dir_name=$(echo "${cwd}" | sed 's/[^A-Za-z0-9._-]/-/g')
    local proj_dir="${HOME}/.claude/projects/${dir_name}"

    [[ -d "${proj_dir}" ]] || { echo "{}"; return; }

    local latest_jsonl
    latest_jsonl=$(ls -t "${proj_dir}"/*.jsonl 2>/dev/null | head -1)
    [[ -z "${latest_jsonl}" ]] && { echo "{}"; return; }

    # 1) Aggregate tokens (usage lines only)
    local token_data
    token_data=$(grep '"usage"' "${latest_jsonl}" 2>/dev/null | jq -s '
        reduce .[] as $line ({input: 0, output: 0};
            .input += ($line.message.usage.input_tokens // 0) |
            .output += ($line.message.usage.output_tokens // 0)
        ) | .total = .input + .output
    ' 2>/dev/null) || token_data='{"input":0,"output":0,"total":0}'

    # 2) Extract user prompts
    # Only actual user input (userType=external), excludes system/tool messages
    local prompts
    prompts=$(grep '"userType":"external"' "${latest_jsonl}" 2>/dev/null | jq -c '
        select(.type == "user") |
        .message.content |
        if type == "string" then .
        elif type == "array" then
            ([.[] | if .type == "text" then .text else empty end] | join(" "))
        else "" end |
        select(length > 0) |
        select(startswith("<task-notification>") | not) |
        .[0:200]
    ' 2>/dev/null | tail -5 | jq -s '.' 2>/dev/null) || prompts='[]'

    # Merge
    echo "${token_data}" | jq --argjson prompts "${prompts}" '. + {prompts: $prompts}' 2>/dev/null || echo "{}"
}

# ── Token history snapshot ────────────────────────────────────────────────
# Called every 30 minutes: saves per-project token + prompt summary to token-history.jsonl
write_token_snapshot() {
    local state
    state=$(get_state)
    local now
    now=$(date '+%s')
    local date_str
    date_str=$(date '+%Y-%m-%d')
    local time_str
    time_str=$(date '+%H:%M')

    local entries=""
    while IFS='|' read -r sid proj cwd status; do
        [[ -z "${sid}" || -z "${cwd}" ]] && continue

        local snapshot
        snapshot=$(get_session_snapshot "${cwd}" 2>/dev/null)
        [[ -z "${snapshot}" || "${snapshot}" == "{}" ]] && continue

        local total
        total=$(echo "${snapshot}" | jq -r '.total // 0' 2>/dev/null)
        (( $(to_int "${total}" 0) == 0 )) && continue

        local entry
        entry=$(echo "${snapshot}" | jq -c \
            --arg date "${date_str}" \
            --arg time "${time_str}" \
            --argjson ts "${now}" \
            --arg proj "${proj}" \
            --arg status "${status}" \
            '{
                date: $date,
                time: $time,
                timestamp: $ts,
                project: $proj,
                status: $status,
                input_tokens: .input,
                output_tokens: .output,
                total_tokens: .total,
                prompts: .prompts
            }' 2>/dev/null)

        if [[ -n "${entry}" && "${entry}" != "null" ]]; then
            echo "${entry}" >> "${TOKEN_HISTORY}"
        fi
    done < <(echo "${state}" | jq -r '.sessions | to_entries[] | "\(.key)|\(.value.project)|\(.value.cwd)|\(.value.status)"')

    # Rotation: keep last 2000 lines when file exceeds 10MB
    if [[ -f "${TOKEN_HISTORY}" ]]; then
        local fsize
        fsize=$(wc -c < "${TOKEN_HISTORY}" 2>/dev/null || echo 0)
        if (( fsize > 10485760 )); then
            tail -n 2000 "${TOKEN_HISTORY}" > "${TOKEN_HISTORY}.tmp.$$" && mv "${TOKEN_HISTORY}.tmp.$$" "${TOKEN_HISTORY}"
        fi
    fi

    log "INFO" "snapshot:written $(date '+%H:%M')"
}

# ── Token count formatting ───────────────────────────────────────────────────
format_tokens() {
    local tokens
    tokens=$(to_int "${1:-0}" 0)
    if (( tokens >= 1000000 )); then
        printf "%.1fM" "$(echo "scale=1; ${tokens}/1000000" | bc 2>/dev/null || echo "${tokens}")"
    elif (( tokens >= 1000 )); then
        printf "%.1fK" "$(echo "scale=1; ${tokens}/1000" | bc 2>/dev/null || echo "${tokens}")"
    else
        echo "${tokens}"
    fi
}

# ── Usage log (JSONL) ────────────────────────────────────────────────────────
# Records per-session tokens/cost/prompts to usage.jsonl.
# Used later by cmd_usage for aggregation.
log_usage() {
    local project="$1"
    local session_id="$2"
    local duration_sec="$3"
    local transcript_path="$4"

    local usage
    usage=$(parse_transcript_usage "${transcript_path}")

    if [[ -z "${usage}" || "${usage}" == "{}" ]]; then
        log "WARN" "usage: transcript parse failed (${transcript_path})"
        return
    fi

    # Build JSONL entry
    local entry
    entry=$(echo "${usage}" | jq -c \
        --arg proj "${project}" \
        --arg sid "${session_id}" \
        --argjson dur "${duration_sec}" \
        --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        '{
            timestamp: $ts,
            project: $proj,
            session_id: $sid,
            duration_sec: $dur,
            input_tokens: .input_tokens,
            output_tokens: .output_tokens,
            cache_creation_tokens: .cache_creation_tokens,
            cache_read_tokens: .cache_read_tokens,
            total_tokens: .total_tokens,
            total_cost_usd: .total_cost_usd,
            model: .model,
            prompts: .user_prompts
        }')

    if [[ -n "${entry}" && "${entry}" != "null" ]]; then
        echo "${entry}" >> "${USAGE_LOG}" 2>/dev/null
        log "INFO" "usage:logged ${project} tokens=$(echo "${entry}" | jq -r '.total_tokens')"
    fi

    # usage.jsonl rotation: keep last 1000 lines when file exceeds 5MB
    if [[ -f "${USAGE_LOG}" ]]; then
        local usage_size
        usage_size=$(wc -c < "${USAGE_LOG}" 2>/dev/null || echo 0)
        if (( usage_size > 5242880 )); then
            tail -n 1000 "${USAGE_LOG}" > "${USAGE_LOG}.tmp.$$" && mv "${USAGE_LOG}.tmp.$$" "${USAGE_LOG}"
        fi
    fi
}


# ── Discord: send ───────────────────────────────────────────────────────────
send_discord() {
    local payload="$1"
    local target_url="${2:-}"

    if [[ -z "${target_url}" ]]; then
        target_url=$(get_config '.discord_webhook_url')
    fi

    if [[ -z "${target_url}" ]]; then
        log "WARN" "Discord webhook URL not configured"
        return 0
    fi


    # Temp-file-based send (workaround for Windows curl encoding issues)
    local tmp_payload="${TRACKER_DIR}/.discord_payload.tmp.$$"
    printf '%s' "${payload}" > "${tmp_payload}"

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
        --max-time "${CURL_MAX_TIME}" \
        -H "Content-Type: application/json" \
        -X POST \
        -d @"${tmp_payload}" \
        "${target_url}" 2>/dev/null) || {
        rm -f "${tmp_payload}"
        log "ERROR" "Discord request failed (curl error)"
        return 0  # Notification failure must not stop the whole hook
    }

    rm -f "${tmp_payload}"

    if [[ "${http_code}" -ge 400 ]]; then
        log "WARN" "Discord returned HTTP ${http_code}"
    fi
}

# ── Discord: safe notification builder ─────────────────
# Build the entire payload in a single jq call. Injection-safe.
send_embed() {
    local title="$1"
    local color="$2"
    local notify_key="$3"
    shift 3

    # Check if notification is enabled (always send if notify_key is empty)
    if [[ -n "${notify_key}" ]]; then
        local should_notify
        should_notify=$(get_config ".notification.${notify_key}")
        [[ "${should_notify}" != "true" ]] && return 0
    fi


    local field_lines=""
    while (( $# > 0 )); do
        local fname="${1:-}"
        local fvalue="${2:-}"
        local finline="true"
        shift 2 2>/dev/null || break

        if [[ "${1:-}" == "--noinline" ]]; then
            finline="false"
            shift
        fi

        field_lines="${field_lines}${fname}	${fvalue}	${finline}
"
    done

    local payload
    payload=$(printf '%s' "${field_lines}" | jq -Rsn \
        --arg t "${title}" \
        --argjson c "${color}" \
        --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg footer "Claude Process Tracker" \
        'input | split("\n") | map(select(length > 0) | split("\t")) |
         map({name: .[0], value: .[1], inline: (.[2] == "true")}) |
         {embeds: [{title: $t, color: $c, fields: ., timestamp: $ts, footer: {text: $footer}}]}')

    send_discord "${payload}"
}

notify_start() {
    local project="$1" session_id="$2" cwd="$3"

    local active_total
    active_total=$(echo "$(get_state)" | jq '[.sessions[] | select(.status == "active")] | length' 2>/dev/null || echo "?")
    local short_cwd
    short_cwd=$(shorten_path "${cwd}" 35)

    send_embed "🟢 Session started" 5763719 "on_start" \
        "Project" "\`${project}\`" \
        "Concurrent" "${active_total} project(s)" \
        "Path" "\`${short_cwd}\`" --noinline
    log "INFO" "notify:start ${project}"
}

notify_complete() {
    local project="$1" session_id="$2" duration="$3"

    send_embed "✅ Task completed" 3066993 "on_complete" \
        "Project" "\`${project}\`" \
        "Duration" "${duration}"
    log "INFO" "notify:complete ${project}"
}

notify_end() {
    local project="$1" session_id="$2" reason="$3" duration="$4"

    local emoji="🔴" title="Session ended" color=15158332
    case "${reason}" in
        clear)                       emoji="🧹"; title="Session cleared";     color=10070709 ;;
        logout)                      emoji="👋"; title="Logged out";          color=10070709 ;;
        prompt_input_exit)           emoji="⏸️";  title="User exit";           color=16776960 ;;
        bypass_permissions_disabled) emoji="🔒"; title="Permission changed";   color=16744576 ;;
        context_compact)             emoji="🔄"; title="Context compacted";   color=3447003 ;;
        session_replaced)            emoji="🔁"; title="Session replaced";    color=3447003 ;;
        process_exit)                emoji="💀"; title="Process exited";       color=15158332 ;;
    esac

    send_embed "${emoji} ${title}" "${color}" "" \
        "Project" "\`${project}\`" \
        "Reason" "$(localize_reason "${reason}")" \
        "Duration" "${duration}"
    log "INFO" "notify:end ${project} (${reason})"
}

notify_end_with_tokens() {
    local project="$1" session_id="$2" reason="$3" duration="$4"
    local input_t="$5" output_t="$6" total_t="$7" cost_str="${8:-}"

    local emoji="🔴" title="Session ended" color=15158332
    case "${reason}" in
        clear)                       emoji="🧹"; title="Session cleared";     color=10070709 ;;
        logout)                      emoji="👋"; title="Logged out";          color=10070709 ;;
        prompt_input_exit)           emoji="⏸️";  title="User exit";           color=16776960 ;;
        bypass_permissions_disabled) emoji="🔒"; title="Permission changed";   color=16744576 ;;
        context_compact)             emoji="🔄"; title="Context compacted";   color=3447003 ;;
        session_replaced)            emoji="🔁"; title="Session replaced";    color=3447003 ;;
        process_exit)                emoji="💀"; title="Process exited";       color=15158332 ;;
    esac

    send_embed "${emoji} ${title}" "${color}" "" \
        "Project" "\`${project}\`" \
        "Reason" "$(localize_reason "${reason}")" \
        "Duration" "${duration}" \
        "Tokens" "⬇${input_t} ⬆${output_t} = ${total_t}${cost_str}"
    log "INFO" "notify:end ${project} (${reason}, tokens=${total_t})"
}

# ── Session removal helper ──────────────────────────────────────────
# If other sessions exist for the same project, transfer active_session to one of them.
remove_session_from_state() {
    local state="$1" session_id="$2" project_name="$3"

    echo "${state}" | jq \
        --arg sid "${session_id}" \
        --arg proj "${project_name}" \
        'del(.sessions[$sid]) |
         if .projects[$proj].active_session == $sid then
            # Find another remaining session in the same project
            ([.sessions | to_entries[] | select(.value.project == $proj)] | first) as $next |
            if $next != null then
                .projects[$proj].active_session = $next.key |
                .projects[$proj].status = $next.value.status |
                .projects[$proj].last_activity = $next.value.last_activity
            else
                .projects[$proj].status = "inactive" |
                .projects[$proj].active_session = null
            end
         else . end'
}

# ── Command: register (SessionStart hook) ───────────────────────────────────
# Hook commands always exit 0 via trap
cmd_register() {
    trap 'exit 0' ERR

    require_jq || exit 0

    local input
    input=$(read_stdin_json) || exit 0

    local session_id cwd transcript_path
    local _fields
    _fields=$(printf '%s\n' "${input}" | jq -r '"\(.session_id // "")\t\(.cwd // "")\t\(.transcript_path // "")"')
    IFS=$'\t' read -r session_id cwd transcript_path <<< "${_fields}"

    if [[ -z "${session_id}" ]]; then
        log "WARN" "register: no session_id"
        exit 0
    fi

    local project_name
    project_name=$(get_project_name "${cwd}")
    local now
    now=$(date '+%s')

    # Find the claude.exe PID via process chain.
    # In Git Bash, $PPID is an MSYS PID and kill -0 cannot track Windows processes.
    # Record the actual Windows PID of claude.exe.
    local claude_pid
    claude_pid=$(_find_claude_pid)

    if with_state_lock _register_impl "${session_id}" "${project_name}" "${cwd}" "${now}" "${transcript_path}" "${claude_pid}"; then
        notify_start "${project_name}" "${session_id}" "${cwd}"
        log "INFO" "session:register ${project_name} (${session_id})"
        # SessionStart: stdout → Claude context
        echo "📊 Project tracker activated: ${project_name}"
    else
        log "ERROR" "register: state lock/save failed for ${project_name}"
    fi
}

_register_impl() {
    local session_id="$1" project_name="$2" cwd="$3" now="$4" transcript_path="${5:-}" pid="${6:-}"

    local state
    state=$(get_state)

    state=$(echo "${state}" | jq \
        --arg sid "${session_id}" \
        --arg proj "${project_name}" \
        --arg cwd "${cwd}" \
        --argjson now "${now}" \
        --arg tp "${transcript_path}" \
        --argjson pid "${pid:-null}" \
        '.sessions[$sid] = {
            project: $proj,
            cwd: $cwd,
            status: "active",
            started_at: $now,
            last_activity: $now,
            stop_count: 0,
            transcript_path: $tp,
            pid: $pid
        } |
        .projects[$proj] = ((.projects[$proj] // {}) * {
            cwd: $cwd,
            active_session: $sid,
            status: "active",
            last_activity: $now
        })')

    save_state "${state}"
}

# ── Command: update (Stop hook) ─────────────────────────────────────────────
# Stop hook is called on every response completion, so debouncing is applied.
# Uses config idle_threshold_minutes as cooldown (default: 10 minutes).
cmd_update() {
    trap 'exit 0' ERR

    require_jq || exit 0

    local input
    input=$(read_stdin_json) || exit 0

    local session_id cwd transcript_path
    local _fields
    _fields=$(printf '%s\n' "${input}" | jq -r '"\(.session_id // "")\t\(.cwd // "")\t\(.transcript_path // "")"')
    IFS=$'\t' read -r session_id cwd transcript_path <<< "${_fields}"
    [[ -z "${session_id}" ]] && exit 0

    # Auto-register if session is missing (recovery from SessionStart hook failure)
    local exists
    exists=$(jq -r --arg sid "${session_id}" 'if .sessions[$sid] != null then "yes" else "no" end' "${STATE_FILE}" 2>/dev/null)
    if [[ "${exists}" != "yes" ]]; then
        log "INFO" "update:auto-register ${session_id}"
        local project_name
        project_name=$(get_project_name "${cwd}")
        local now
        now=$(date '+%s')
        local claude_pid
        claude_pid=$(_find_claude_pid)
        with_state_lock _register_impl "${session_id}" "${project_name}" "${cwd}" "${now}" "${transcript_path}" "${claude_pid}" || exit 0
    fi

    local result
    result=$(with_state_lock _update_impl "${session_id}") || exit 0

    if [[ -n "${result}" ]]; then
        local project_name
        local session_id_out
        local duration
        local should_notify_flag
        IFS='|' read -r project_name session_id_out duration should_notify_flag <<< "${result}"


        if [[ "${should_notify_flag}" == "1" ]]; then
            notify_complete "${project_name}" "${session_id_out}" "${duration}"
        fi
    fi
}

_update_impl() {
    local session_id="$1"
    local now
    now=$(date '+%s')

    local state
    state=$(get_state)


    local session_info
    session_info=$(echo "${state}" | jq -r --arg sid "${session_id}" '
        .sessions[$sid] // null |
        if . == null then "MISSING"
        else "\(.project)|\(.started_at)|\(.last_notify // 0)"
        end
    ')
    [[ "${session_info}" == "MISSING" || -z "${session_info}" ]] && return 0

    local project_name started_at last_notify
    IFS='|' read -r project_name started_at last_notify <<< "${session_info}"
    started_at=$(to_int "${started_at}" 0)
    last_notify=$(to_int "${last_notify}" 0)

    local duration
    duration=$(format_duration $(( now - started_at )))

    # Debounce
    local cooldown_min
    cooldown_min=$(to_int "$(get_config '.notification.idle_threshold_minutes')" 10)
    local cooldown_sec=$(( cooldown_min * 60 ))
    local should_notify=0

    if (( now - last_notify >= cooldown_sec )); then
        should_notify=1
    fi

    state=$(echo "${state}" | jq \
        --arg sid "${session_id}" \
        --argjson now "${now}" \
        --argjson notify "${should_notify}" \
        '.sessions[$sid].last_activity = $now |
         .sessions[$sid].stop_count += 1 |
         .sessions[$sid].status = "idle" |
         (if $notify == 1 then .sessions[$sid].last_notify = $now else . end) |
         .projects[.sessions[$sid].project].last_activity = $now |
         .projects[.sessions[$sid].project].status = "idle"')

    save_state "${state}"
    log "INFO" "session:stop ${project_name} (${duration}, notify=${should_notify})"

    echo "${project_name}|${session_id}|${duration}|${should_notify}"
}

# ── Command: end (SessionEnd hook) ──────────────────────────────────────────
cmd_end() {
    trap 'exit 0' ERR

    require_jq || exit 0

    local input
    input=$(read_stdin_json) || exit 0

    local session_id reason source_field
    local _fields
    _fields=$(printf '%s\n' "${input}" | jq -r '"\(.session_id // "")\t\(.reason // "unknown")\t\(.source // "")"')
    IFS=$'\t' read -r session_id reason source_field <<< "${_fields}"
    [[ -z "${session_id}" ]] && exit 0

    # Clarify "other" reason by inferring from context
    if [[ "${reason}" == "other" ]]; then
        # Use source field if available (compact, etc.)
        if [[ "${source_field}" == "compact" ]]; then
            reason="context_compact"
        else
            # Check PID: if process is still alive → session_replaced, else → process_exit
            local sess_pid
            sess_pid=$(jq -r --arg sid "${session_id}" '.sessions[$sid].pid // 0' "${STATE_FILE}" 2>/dev/null)
            sess_pid=$(to_int "${sess_pid}" 0)
            if (( sess_pid > 0 )) && _is_win_pid_alive "${sess_pid}"; then
                reason="session_replaced"
            else
                reason="process_exit"
            fi
        fi
    fi

    local result
    result=$(with_state_lock _end_impl "${session_id}" "${reason}") || exit 0

    if [[ -n "${result}" ]]; then
        local project_name duration duration_sec transcript_path
        IFS='|' read -r project_name duration duration_sec transcript_path <<< "${result}"

        # Log token usage
        if [[ -n "${transcript_path}" ]]; then
            log_usage "${project_name}" "${session_id}" "${duration_sec}" "${transcript_path}"

            # Include token info in Discord notification
            local usage_summary
            usage_summary=$(parse_transcript_usage "${transcript_path}")
            local total_tokens total_cost
            total_tokens=$(echo "${usage_summary}" | jq -r '.total_tokens // 0')
            total_cost=$(echo "${usage_summary}" | jq -r '.total_cost_usd // 0')

            if (( $(to_int "${total_tokens}" 0) > 0 )); then
                local input_t output_t
                input_t=$(echo "${usage_summary}" | jq -r '.input_tokens // 0')
                output_t=$(echo "${usage_summary}" | jq -r '.output_tokens // 0')
                local cost_str=""
                if [[ "${total_cost}" != "0" && "${total_cost}" != "null" ]]; then
                    cost_str=" · \$$(printf '%.3f' "${total_cost}" 2>/dev/null || echo "${total_cost}")"
                fi
                notify_end_with_tokens "${project_name}" "${session_id}" "${reason}" "${duration}" \
                    "$(format_tokens "${input_t}")" "$(format_tokens "${output_t}")" \
                    "$(format_tokens "${total_tokens}")" "${cost_str}"
            else
                notify_end "${project_name}" "${session_id}" "${reason}" "${duration}"
            fi
        else
            notify_end "${project_name}" "${session_id}" "${reason}" "${duration}"
        fi
    fi
}

_end_impl() {
    local session_id="$1" reason="$2"
    local now
    now=$(date '+%s')

    local state
    state=$(get_state)

    # Extract session info in a single jq call (including transcript_path)
    local session_info
    session_info=$(echo "${state}" | jq -r --arg sid "${session_id}" '
        .sessions[$sid] // null |
        if . == null then "MISSING"
        else "\(.project // "unknown")|\(.started_at // 0)|\(.transcript_path // "")"
        end
    ')
    [[ "${session_info}" == "MISSING" || -z "${session_info}" ]] && return 0

    local project_name started_at transcript_path
    IFS='|' read -r project_name started_at transcript_path <<< "${session_info}"

    local duration="unknown"
    local duration_sec=0
    started_at=$(to_int "${started_at}" 0)
    if (( started_at > 0 )); then
        duration_sec=$(( now - started_at ))
        duration=$(format_duration ${duration_sec})
    fi

    state=$(remove_session_from_state "${state}" "${session_id}" "${project_name}")
    save_state "${state}"
    log "INFO" "session:end ${project_name} (${reason}, ${duration})"

    echo "${project_name}|${duration}|${duration_sec}|${transcript_path}"
}

# ── Command: scan (immediate process scan → update state) ───────────────────
cmd_scan() {
    require_jq || return 1
    local now
    now=$(date '+%s')
    local active_window=120  # 2 minutes
    _monitor_discover_and_save "${now}" "${active_window}"
    _monitor_update_live_tokens 2>/dev/null || true
}

# ── Command: status ─────────────────────────────────────────────────────────
# PID-based: only shows alive processes.
#   ● green  = hook-registered + active + PID alive
#   ◐ yellow = hook-registered + idle   + PID alive
#   PID dead = not shown
cmd_status() {
    require_jq || return 1

    local state
    state=$(_filter_alive_sessions "$(get_state)")
    local now
    now=$(date '+%s')

    local active_count idle_count
    active_count=$(echo "${state}" | jq '[.sessions[] | select(.status == "active")] | length')
    idle_count=$(echo "${state}" | jq '[.sessions[] | select(.status == "idle")] | length')
    local total=$(( active_count + idle_count ))

    echo ""
    printf "  ${C_BOLD}${C_CYAN}🤖 Claude Process Tracker${C_RESET}\n"
    printf "  ${C_DIM}────────────────────────────────────────────────${C_RESET}\n"

    if (( total == 0 )); then
        echo ""
        printf "  ${C_DIM}No running instances.${C_RESET}\n"
        echo ""
        return
    fi

    echo ""
    if (( active_count > 0 )); then
        printf "  ${C_BG_GREEN}${C_WHITE}${C_BOLD} ${active_count} active ${C_RESET}"
    fi
    if (( idle_count > 0 )); then
        printf "  ${C_BG_YELLOW}${C_WHITE}${C_BOLD} ${idle_count} idle ${C_RESET}"
    fi
    echo ""

    echo ""
    printf "  ${C_DIM}%-2s %-18s %-12s %-8s${C_RESET}\n" "" "Project" "Last activity" "Tasks"
    printf "  ${C_DIM}── ────────────────── ──────────── ────────${C_RESET}\n"

    while IFS='|' read -r name status cwd last_activity; do
        [[ -z "${name}" ]] && continue

        local elapsed=0
        last_activity=$(to_int "${last_activity}" 0)
        if (( last_activity > 0 )); then
            elapsed=$(( now - last_activity ))
        fi

        local icon color
        case "${status}" in
            active) icon="●"; color="${C_GREEN}" ;;
            idle)   icon="◐"; color="${C_YELLOW}" ;;
            *)      continue ;;
        esac

        local time_str="--"
        local time_color=""
        if (( elapsed > 0 )); then
            if (( elapsed < 60 )); then
                time_str="just now"; time_color="${C_GREEN}"
            elif (( elapsed < 3600 )); then
                time_str="$(( elapsed / 60 ))m ago"; time_color="${C_GREEN}"
            elif (( elapsed < 86400 )); then
                time_str="$(( elapsed / 3600 ))h ago"; time_color="${C_YELLOW}"
            else
                time_str="$(( elapsed / 86400 ))d ago"; time_color="${C_RED}"
            fi
        fi

        local stop_count session_count
        local _counts
        _counts=$(echo "${state}" | jq -r --arg proj "${name}" '
            [.sessions[] | select(.project == $proj)] |
            "\(map(.stop_count // 0) | add // 0)|\(length)"
        ' 2>/dev/null) || _counts="0|1"
        IFS='|' read -r stop_count session_count <<< "${_counts}"
        stop_count=$(to_int "${stop_count}" 0)
        session_count=$(to_int "${session_count}" 1)

        local display_name="${name}"
        # Show session count if multiple sessions for the same project
        if (( session_count > 1 )); then
            display_name="${name}(x${session_count})"
        fi
        if (( ${#display_name} > 18 )); then
            display_name="${display_name:0:16}.."
        fi

        printf "  ${color}${icon}${C_RESET} "
        printf "%-18s " "${display_name}"
        if [[ -n "${time_color}" ]]; then
            printf "${time_color}%-10s${C_RESET} " "${time_str}"
        else
            printf "%-10s " "${time_str}"
        fi
        printf "%-6s\n" "${stop_count}x"

        local short_path
        short_path=$(shorten_path "${cwd}" 44)
        printf '    %s%s%s\n' "${C_DIM}" "${short_path}" "${C_RESET}"
    done < <(echo "${state}" | jq -r '
        .projects | to_entries | sort_by(
            if .value.status == "active" then 0 else 1 end
        )[] |
        select(.value.status == "active" or .value.status == "idle") |
        "\(.key)|\(.value.status)|\(.value.cwd // "?")|\(.value.last_activity // 0)"
    ')

    echo ""
    printf "  ${C_DIM}$(date '+%H:%M:%S')${C_RESET}\n"
    echo ""
}

# ── Command: dashboard ────────────────────────────────────────────
# Build the entire embed in a single jq call (no manual string concatenation)
cmd_dashboard() {
    require_jq || return 1

    local state
    state=$(_filter_alive_sessions "$(get_state)")

    # Aggregate today's token usage (from usage.jsonl)
    local today_date
    today_date=$(date '+%Y-%m-%d')
    local usage_stats="{}"
    if [[ -f "${USAGE_LOG}" ]]; then
        usage_stats=$(jq -s --arg since "${today_date}" '
            [.[] | select(.timestamp >= $since)] |
            {
                sessions: length,
                total_input: (map(.input_tokens // 0) | add // 0),
                total_output: (map(.output_tokens // 0) | add // 0),
                total_tokens: (map(.total_tokens // 0) | add // 0),
                total_cost: (map(.total_cost_usd // 0) | add // 0),
                by_project: (group_by(.project) | map({
                    key: .[0].project,
                    value: {
                        tokens: (map(.total_tokens // 0) | add // 0),
                        cost: (map(.total_cost_usd // 0) | add // 0)
                    }
                }) | from_entries)
            }
        ' "${USAGE_LOG}" 2>/dev/null) || usage_stats="{}"
    fi

    local payload
    payload=$(echo "${state}" | jq \
        --argjson now "$(date '+%s')" \
        --argjson usage "${usage_stats}" \
        --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg footer "Claude Process Tracker" \
    '{
        embeds: [{
            title: "🤖 Claude Process Dashboard",
            description: ("`" + ($now | strftime("%Y-%m-%d %H:%M:%S")) + "` live status"),
            color: (if ([.sessions[] | select(.status == "active")] | length) > 0
                    then 3066993 else 16776960 end),
            fields: (
                # ── Per-project status ──
                [.sessions | to_entries | sort_by(
                    if .value.status == "active" then 0
                    elif .value.status == "idle" then 1
                    else 2 end
                ) | .[0:8][] |
                {
                    sid: .key,
                    proj: .value.project,
                    status: .value.status,
                    agents: (.value.agent_count // 0),
                    last: (.value.last_activity // 0),
                    live_in: (.value.live_input_tokens // 0),
                    live_out: (.value.live_output_tokens // 0),
                    live_total: (.value.live_total_tokens // 0)
                } | {
                    name: (if .status == "active" then "🟢 " + .proj
                           else "🟡 " + .proj end),
                    value: (
                        (if .status == "active" then "**Working**"
                         else "Idle" end)
                        + " · agents: " + (.agents | tostring)
                        + "\n"
                        + (if .last == 0 then "⏱ --"
                           else (($now - .last) |
                                 if . < 60 then "⏱ \(.)s ago"
                                 elif . < 3600 then "⏱ \(./60|floor)m ago"
                                 else "⏱ \(./3600|floor)h ago" end)
                           end)
                        + (if .live_total > 0 then
                            "\n🔤 " + (.live_total |
                                if . >= 1000000 then "\(. / 1000000 * 10 | floor / 10)M"
                                elif . >= 1000 then "\(. / 1000 | floor)K"
                                else "\(.)" end) + " tokens"
                           else "" end)
                    ),
                    inline: true
                }]

                # ── Empty field (for 3-column alignment) ──
                + (if (([.sessions | to_entries | length] | .[0]) % 3 == 2) then
                    [{name: "\u200b", value: "\u200b", inline: true}]
                   else [] end)

                # ── Divider ──
                + [{name: "\u200b", value: "━━━━━━━━━━━━━━━━━━━━", inline: false}]

                # ── Summary ──
                + [{
                    name: "📊 Summary",
                    value: (
                        "🟢 Working **" + ([.sessions[] | select(.status == "active")] | length | tostring) + "**"
                        + " · 🟡 Idle **" + ([.sessions[] | select(.status == "idle")] | length | tostring) + "**"
                        + " · **" + (.projects | length | tostring) + "** project(s)"
                        + "\nagents: **" + ([.sessions[].agent_count // 0] | add // 0 | tostring) + "**"
                    ),
                    inline: false
                }]

                # ── Live tokens (active sessions) ──
                + (
                    ([.sessions[] | .live_total_tokens // 0] | add // 0) as $live_total |
                    ([.sessions[] | .live_input_tokens // 0] | add // 0) as $live_input |
                    ([.sessions[] | .live_output_tokens // 0] | add // 0) as $live_output |
                    if $live_total > 0 then
                    [{
                        name: "🔤 Live tokens (active sessions)",
                        value: (
                            "Input **" + ($live_input |
                                if . >= 1000000 then "\(. / 1000000 * 10 | floor / 10)M"
                                elif . >= 1000 then "\(. / 1000 | floor)K"
                                else "\(.)" end) + "**"
                            + " · Output **" + ($live_output |
                                if . >= 1000000 then "\(. / 1000000 * 10 | floor / 10)M"
                                elif . >= 1000 then "\(. / 1000 | floor)K"
                                else "\(.)" end) + "**"
                            + " · Total **" + ($live_total |
                                if . >= 1000000 then "\(. / 1000000 * 10 | floor / 10)M"
                                elif . >= 1000 then "\(. / 1000 | floor)K"
                                else "\(.)" end) + "**"
                        ),
                        inline: false
                    }]
                    else [] end
                )

                # ── Completed session tokens (today) ──
                + (if ($usage.total_tokens // 0) > 0 then
                    [{
                        name: "💰 Completed session tokens (today)",
                        value: (
                            "Input **" + (($usage.total_input // 0) |
                                if . >= 1000000 then "\(. / 1000000 * 10 | floor / 10)M"
                                elif . >= 1000 then "\(. / 1000 | floor)K"
                                else "\(.)" end) + "**"
                            + " · Output **" + (($usage.total_output // 0) |
                                if . >= 1000000 then "\(. / 1000000 * 10 | floor / 10)M"
                                elif . >= 1000 then "\(. / 1000 | floor)K"
                                else "\(.)" end) + "**"
                            + " · Total **" + (($usage.total_tokens // 0) |
                                if . >= 1000000 then "\(. / 1000000 * 10 | floor / 10)M"
                                elif . >= 1000 then "\(. / 1000 | floor)K"
                                else "\(.)" end) + "**"
                            + "\n💵 $" + (($usage.total_cost // 0) * 100 | floor / 100 | tostring)
                            + " · " + (($usage.sessions // 0) | tostring) + " session(s) completed"
                        ),
                        inline: false
                    }]
                   else [] end)
            ),
            footer: {text: $footer},
            timestamp: $ts
        }]
    }')

    local dashboard_webhook
    dashboard_webhook=$(get_config '.dashboard_channel_webhook')
    if [[ -n "${dashboard_webhook}" ]]; then
        send_discord "${payload}" "${dashboard_webhook}"
    else
        send_discord "${payload}"
    fi

    echo ""
    printf "  ${C_GREEN}✅${C_RESET} Dashboard sent to Discord.\n\n"
}

# ── Command: report (view token history / send to Discord) ─────────────
# report [date|today|week|send]
#   report          — view today's records
#   report 2026-02-13 — specific date
#   report week     — last 7 days
#   report send     — send today's records to Discord
cmd_report() {
    require_jq || return 1

    local arg="${1:-today}"

    if [[ ! -f "${TOKEN_HISTORY}" ]]; then
        echo ""
        printf "  ${C_DIM}No token history yet.${C_RESET}\n"
        printf "  ${C_DIM}The monitor records snapshots automatically every 30 minutes.${C_RESET}\n\n"
        return
    fi

    # Discord send mode
    if [[ "${arg}" == "send" ]]; then
        _report_send "${2:-today}"
        return
    fi

    # Determine date filter
    local date_filter="" period_label=""
    case "${arg}" in
        today|t)
            date_filter=$(date '+%Y-%m-%d')
            period_label="Today (${date_filter})"
            ;;
        week|w)
            date_filter=$(date -d '7 days ago' '+%Y-%m-%d' 2>/dev/null || date -v-7d '+%Y-%m-%d' 2>/dev/null || echo "")
            period_label="Last 7 days"
            ;;
        all|a)
            date_filter=""
            period_label="All time"
            ;;
        *)
            date_filter="${arg}"
            period_label="Since ${arg}"
            ;;
    esac

    echo ""
    printf "  ${C_BOLD}${C_CYAN}📋 Token history${C_RESET} ${C_DIM}— ${period_label}${C_RESET}\n"
    printf "  ${C_DIM}────────────────────────────────────────${C_RESET}\n\n"

    # Aggregate: by date > by project (tokens + prompts)
    local report
    if [[ -n "${date_filter}" ]]; then
        report=$(jq -s --arg since "${date_filter}" '
            [.[] | select(.date >= $since)]
        ' "${TOKEN_HISTORY}" 2>/dev/null)
    else
        report=$(jq -s '.' "${TOKEN_HISTORY}" 2>/dev/null)
    fi

    if [[ -z "${report}" || "${report}" == "[]" ]]; then
        printf "  ${C_DIM}No records for this period.${C_RESET}\n\n"
        return
    fi

    # Group by date → sort by max tokens per project
    echo "${report}" | jq -r '
        group_by(.date) | reverse | .[] |
        (.[0].date) as $date |
        group_by(.project) |
        map({
            project: .[0].project,
            max_tokens: (map(.total_tokens) | max),
            last_tokens: (.[-1].total_tokens),
            snapshots: length,
            prompts: (map(.prompts // []) | add // [] | unique | .[-5:])
        }) |
        sort_by(-.max_tokens) |
        "  \u001b[1m📅 " + $date + "\u001b[0m",
        (.[] |
            "    " +
            (if .max_tokens >= 100000 then "🔴"
             elif .max_tokens >= 50000 then "🟡"
             else "🟢" end) +
            " \u001b[1m" + .project + "\u001b[0m" +
            "  tokens: " + (.max_tokens |
                if . >= 1000000 then "\(. / 1000000 * 10 | floor / 10)M"
                elif . >= 1000 then "\(. / 1000 | floor)K"
                else "\(.)" end) +
            " (snapshots: " + (.snapshots | tostring) + ")",
            (.prompts[:3][] |
                "      💬 " + (.[0:80]) +
                (if length > 80 then "…" else "" end)
            )
        ),
        ""
    ' 2>/dev/null

    echo ""
    printf "  ${C_DIM}Send to Discord: claude-tracker report send${C_RESET}\n\n"
}

# Send report as Discord embed
_report_send() {
    local period="${1:-today}"

    local date_filter=""
    case "${period}" in
        today|t) date_filter=$(date '+%Y-%m-%d') ;;
        week|w)  date_filter=$(date -d '7 days ago' '+%Y-%m-%d' 2>/dev/null || date -v-7d '+%Y-%m-%d' 2>/dev/null || echo "") ;;
        *)       date_filter="${period}" ;;
    esac

    local data
    if [[ -n "${date_filter}" ]]; then
        data=$(jq -s --arg since "${date_filter}" '[.[] | select(.date >= $since)]' "${TOKEN_HISTORY}" 2>/dev/null)
    else
        data=$(jq -s '.' "${TOKEN_HISTORY}" 2>/dev/null)
    fi

    if [[ -z "${data}" || "${data}" == "[]" ]]; then
        printf "  ${C_DIM}No records to send.${C_RESET}\n"
        return
    fi

    local payload
    payload=$(echo "${data}" | jq \
        --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg footer "Claude Process Tracker" \
        --arg title "📋 Token History Report" \
    '{
        embeds: [{
            title: $title,
            color: 3447003,
            fields: (
                # Group by date → aggregate per project
                [group_by(.date) | reverse | .[0:7][] |
                    (.[0].date) as $date |
                    group_by(.project) |
                    map({
                        project: .[0].project,
                        max_tokens: (map(.total_tokens) | max),
                        prompts: (map(.prompts // []) | add // [] | unique | .[-3:])
                    }) |
                    sort_by(-.max_tokens) |
                    {
                        name: ("📅 " + $date),
                        value: (
                            [.[] |
                                (if .max_tokens >= 100000 then "🔴"
                                 elif .max_tokens >= 50000 then "🟡"
                                 else "🟢" end) +
                                " **" + .project + "** — " +
                                (.max_tokens |
                                    if . >= 1000000 then "\(. / 1000000 * 10 | floor / 10)M"
                                    elif . >= 1000 then "\(. / 1000 | floor)K"
                                    else "\(.)" end) + " tokens" +
                                (if (.prompts | length) > 0 then
                                    "\n" + ([.prompts[:2][] | "  💬 _" + .[0:60] +
                                        (if length > 60 then "…" else "" end) + "_"] | join("\n"))
                                 else "" end)
                            ] | join("\n\n")
                        ),
                        inline: false
                    }
                ]
                # Overall summary
                + [{
                    name: "📊 Overall summary",
                    value: (
                        "Projects **" + ([.[].project] | unique | length | tostring) + "**" +
                        " · Max tokens **" + ([.[].total_tokens] | max |
                            if . >= 1000000 then "\(. / 1000000 * 10 | floor / 10)M"
                            elif . >= 1000 then "\(. / 1000 | floor)K"
                            else "\(.)" end) + "**" +
                        " · Snapshots **" + (length | tostring) + "**"
                    ),
                    inline: false
                }]
            ),
            footer: {text: $footer},
            timestamp: $ts
        }]
    }')

    send_discord "${payload}"
    echo ""
    printf "  ${C_GREEN}✅${C_RESET} Report sent to Discord.\n\n"
}

# ── Command: cleanup ────────────────────────────────────────────────
cmd_cleanup() {
    require_jq || return 1

    # Cleanup threshold: cleanup_threshold_minutes (default 30 min)
    # Separate from idle_threshold_minutes (debounce)
    local threshold_min
    threshold_min=$(to_int "$(get_config '.cleanup_threshold_minutes')" 30)
    local threshold=$(( threshold_min * 60 ))

    with_state_lock _cleanup_impl "${threshold}"
}

_cleanup_impl() {
    local threshold="$1"
    local now
    now=$(date '+%s')

    local state
    state=$(get_state)
    local cleaned=0

    while IFS='|' read -r sid last_activity project; do
        [[ -z "${sid}" ]] && continue
        local elapsed=$(( now - last_activity ))
        if (( elapsed > threshold )); then
            state=$(remove_session_from_state "${state}" "${sid}" "${project}")
            cleaned=$((cleaned + 1))
            log "INFO" "cleanup: ${project} (${sid})"
        fi
    done < <(echo "${state}" | jq -r '.sessions | to_entries[] | "\(.key)|\(.value.last_activity)|\(.value.project)"')

    save_state "${state}"
    if (( cleaned > 0 )); then
        printf "  ${C_GREEN}✅${C_RESET} ${cleaned} session(s) cleaned up\n"
    else
        printf "  ${C_DIM}No sessions to clean up.${C_RESET}\n"
    fi
}

# ── Command: resume (resume a session) ──────────────────────────────────────
cmd_resume() {
    require_jq || return 1

    local filter="${1:-}"
    local state
    state=$(get_state)
    local now
    now=$(date '+%s')

    # Collect active/idle sessions
    local sids=() projects=() cwds=() statuses=() started_ats=() last_activities=()

    while IFS='|' read -r sid project cwd status started_at last_activity; do
        [[ -z "${sid}" ]] && continue
        # Only active or idle sessions
        [[ "${status}" != "active" && "${status}" != "idle" ]] && continue
        sids+=("${sid}")
        projects+=("${project}")
        cwds+=("${cwd}")
        statuses+=("${status}")
        started_ats+=("${started_at}")
        last_activities+=("${last_activity}")
    done < <(echo "${state}" | jq -r '
        .sessions | to_entries | sort_by(
            if .value.status == "active" then 0 else 1 end
        )[] |
        "\(.key)|\(.value.project)|\(.value.cwd)|\(.value.status)|\(.value.started_at)|\(.value.last_activity)"
    ')

    if (( ${#sids[@]} == 0 )); then
        echo ""
        printf "  ${C_DIM}No sessions available to resume.${C_RESET}\n"
        printf "  ${C_DIM}Only active or idle sessions can be resumed.${C_RESET}\n"
        echo ""
        return 0
    fi

    # Project name filter (partial match)
    if [[ -n "${filter}" ]]; then
        local matched_idx=-1
        local match_count=0
        for i in "${!projects[@]}"; do
            if [[ "${projects[$i]}" == *"${filter}"* ]]; then
                matched_idx=$i
                match_count=$((match_count + 1))
            fi
        done

        if (( match_count == 0 )); then
            printf "  ${C_RED}No matching session:${C_RESET} ${filter}\n"
            return 1
        elif (( match_count == 1 )); then
            _resume_session "${sids[$matched_idx]}" "${projects[$matched_idx]}" "${cwds[$matched_idx]}"
            return $?
        fi
        # Multiple matches: show list (continue below)
    fi

    # Interactive session selection
    echo ""
    printf "  ${C_BOLD}${C_CYAN}Resume session${C_RESET}\n"
    printf "  ${C_DIM}────────────────────────────────────────${C_RESET}\n"
    echo ""

    for i in "${!sids[@]}"; do
        # Show only matching entries if filter is set
        if [[ -n "${filter}" ]] && [[ "${projects[$i]}" != *"${filter}"* ]]; then
            continue
        fi

        local icon color
        case "${statuses[$i]}" in
            active) icon="●"; color="${C_GREEN}" ;;
            idle)   icon="◐"; color="${C_YELLOW}" ;;
            *)      icon="○"; color="${C_DIM}" ;;
        esac

        # Elapsed time
        local last_act
        last_act=$(to_int "${last_activities[$i]}" 0)
        local elapsed_str="--"
        if (( last_act > 0 )); then
            local elapsed=$(( now - last_act ))
            if (( elapsed < 60 )); then
                elapsed_str="just now"
            elif (( elapsed < 3600 )); then
                elapsed_str="$(( elapsed / 60 ))m ago"
            elif (( elapsed < 86400 )); then
                elapsed_str="$(( elapsed / 3600 ))h ago"
            else
                elapsed_str="$(( elapsed / 86400 ))d ago"
            fi
        fi

        # Running time
        local started
        started=$(to_int "${started_ats[$i]}" 0)
        local duration_str=""
        if (( started > 0 )); then
            duration_str=$(format_duration $(( now - started )))
        fi

        printf "  ${C_BOLD}%2d${C_RESET}  ${color}${icon}${C_RESET} %-18s ${C_DIM}%s${C_RESET}" "$((i + 1))" "${projects[$i]}" "${elapsed_str}"
        if [[ -n "${duration_str}" ]]; then
            printf "  ${C_DIM}(${duration_str})${C_RESET}"
        fi
        echo ""

        local short_cwd
        short_cwd=$(shorten_path "${cwds[$i]}" 44)
        printf "      ${C_DIM}${short_cwd}${C_RESET}\n"
    done

    echo ""
    printf "  Select number (q=cancel): "
    read -r selection

    if [[ "${selection}" == "q" || -z "${selection}" ]]; then
        printf "  ${C_DIM}Cancelled${C_RESET}\n"
        return 0
    fi

    if ! [[ "${selection}" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > ${#sids[@]} )); then
        printf "  ${C_RED}Invalid number.${C_RESET}\n"
        return 1
    fi

    local idx=$((selection - 1))
    _resume_session "${sids[$idx]}" "${projects[$idx]}" "${cwds[$idx]}"
}

_resume_session() {
    local sid="$1" project="$2" cwd="$3"

    # Check directory exists
    if [[ -n "${cwd}" ]] && [[ ! -d "${cwd}" ]]; then
        printf "  ${C_RED}Directory does not exist:${C_RESET} ${cwd}\n"
        return 1
    fi

    echo ""
    printf "  ${C_GREEN}▶${C_RESET} ${C_BOLD}${project}${C_RESET} Resuming session...\n"

    if [[ "${sid}" == auto-* ]]; then
        # Auto-discovered session: use --continue
        printf "  ${C_DIM}cd ${cwd} && claude --continue${C_RESET}\n"
        echo ""
        cd "${cwd}" && exec claude --continue
    else
        # Hook-registered session: use --resume
        printf "  ${C_DIM}cd ${cwd} && claude --resume ${sid}${C_RESET}\n"
        echo ""
        cd "${cwd}" && exec claude --resume "${sid}"
    fi
}

# ── Command: bot (Discord Bot management) ───────────────────────────────────
cmd_bot() {
    local action="${1:-status}"
    local bot_dir="${TRACKER_DIR}/bot"
    local bot_pidfile="${TRACKER_DIR}/.bot.pid"

    case "${action}" in
        start)
            if [[ -f "${bot_pidfile}" ]]; then
                local old_pid
                old_pid=$(cat "${bot_pidfile}")
                if kill -0 "${old_pid}" 2>/dev/null; then
                    printf "  ${C_YELLOW}⚠${C_RESET} Bot is already running (PID ${old_pid})\n"
                    printf "  ${C_DIM}Stop: claude-tracker bot stop${C_RESET}\n"
                    return 0
                fi
                rm -f "${bot_pidfile}"
            fi

            if [[ ! -f "${bot_dir}/bot.js" ]]; then
                printf "  ${C_RED}❌${C_RESET} bot.js not found\n"
                return 1
            fi

            if [[ ! -d "${bot_dir}/node_modules" ]]; then
                printf "  ${C_DIM}Installing dependencies...${C_RESET}\n"
                (cd "${bot_dir}" && npm install --silent 2>&1) || {
                    printf "  ${C_RED}❌${C_RESET} npm install failed\n"
                    return 1
                }
            fi

            local bot_token
            bot_token=$(get_config '.bot_token')
            if [[ -z "${bot_token}" ]]; then
                printf "  ${C_RED}❌${C_RESET} bot_token is not configured\n"
                printf "  ${C_DIM}Set: claude-tracker config bot-token <TOKEN>${C_RESET}\n"
                return 1
            fi

            # Background execution
            node "${bot_dir}/bot.js" >> "${TRACKER_DIR}/bot.log" 2>&1 &
            local bot_pid=$!
            echo "${bot_pid}" > "${bot_pidfile}"

            sleep 2
            if kill -0 "${bot_pid}" 2>/dev/null; then
                printf "  ${C_GREEN}✅${C_RESET} Bot started (PID ${bot_pid})\n"
                printf "  ${C_DIM}Stop: claude-tracker bot stop${C_RESET}\n"
                printf "  ${C_DIM}Log: tail -f ${TRACKER_DIR}/bot.log${C_RESET}\n"
            else
                printf "  ${C_RED}❌${C_RESET} Bot failed to start\n"
                printf "  ${C_DIM}Check log: cat ${TRACKER_DIR}/bot.log${C_RESET}\n"
                rm -f "${bot_pidfile}"
                return 1
            fi
            ;;

        stop)
            if [[ -f "${bot_pidfile}" ]]; then
                local pid
                pid=$(cat "${bot_pidfile}")
                if kill -0 "${pid}" 2>/dev/null; then
                    kill "${pid}" 2>/dev/null
                    sleep 1
                    kill -9 "${pid}" 2>/dev/null || true
                    rm -f "${bot_pidfile}"
                    printf "  ${C_GREEN}✅${C_RESET} Bot stopped\n"
                else
                    rm -f "${bot_pidfile}"
                    printf "  ${C_DIM}Bot is already stopped.${C_RESET}\n"
                fi
            else
                printf "  ${C_DIM}No bot is running.${C_RESET}\n"
            fi
            ;;

        status|*)
            if [[ -f "${bot_pidfile}" ]]; then
                local pid
                pid=$(cat "${bot_pidfile}")
                if kill -0 "${pid}" 2>/dev/null; then
                    printf "  ${C_GREEN}●${C_RESET} Bot running (PID ${pid})\n"
                else
                    rm -f "${bot_pidfile}"
                    printf "  ${C_RED}●${C_RESET} Bot stopped (PID file cleaned)\n"
                fi
            else
                printf "  ${C_DIM}●${C_RESET} Bot not running\n"
                printf "  ${C_DIM}Start: claude-tracker bot start${C_RESET}\n"
            fi
            ;;
    esac
}

# ── Interactive alias selection ─────────────────────────────────────────────
_config_alias_interactive() {
    local state
    state=$(get_state)

    local projects=()
    local cwds=()
    local statuses=()
    local aliases=()

    while IFS='|' read -r name status cwd; do
        [[ -z "${name}" ]] && continue
        projects+=("${name}")
        statuses+=("${status}")
        cwds+=("${cwd}")
        # Check for existing alias
        local existing_alias
        existing_alias=$(jq -r --arg d "${cwd}" '.project_aliases[$d] // empty' "${CONFIG_FILE}" 2>/dev/null || echo "")
        aliases+=("${existing_alias}")
    done < <(echo "${state}" | jq -r '
        .projects | to_entries | sort_by(
            if .value.status == "active" then 0
            elif .value.status == "idle" then 1
            else 2 end
        )[] |
        "\(.key)|\(.value.status // "unknown")|\(.value.cwd // "")"
    ')

    if (( ${#projects[@]} == 0 )); then
        printf "  ${C_DIM}No registered projects.${C_RESET}\n"
        return 1
    fi

    echo ""
    printf "  ${C_BOLD}${C_CYAN}Project list${C_RESET}\n"
    printf "  ${C_DIM}────────────────────────────────────────${C_RESET}\n"
    echo ""

    for i in "${!projects[@]}"; do
        local icon color
        case "${statuses[$i]}" in
            active)   icon="●"; color="${C_GREEN}" ;;
            idle)     icon="◐"; color="${C_YELLOW}" ;;
            *)        icon="○"; color="${C_DIM}" ;;
        esac

        local alias_info=""
        if [[ -n "${aliases[$i]}" ]]; then
            alias_info=" ${C_CYAN}→ ${aliases[$i]}${C_RESET}"
        fi

        printf "  ${C_BOLD}%2d${C_RESET}  ${color}${icon}${C_RESET} %s${alias_info}\n" "$((i + 1))" "${projects[$i]}"
        printf "      ${C_DIM}%s${C_RESET}\n" "${cwds[$i]}"
    done

    echo ""
    printf "  Select number (q=cancel): "
    read -r selection

    if [[ "${selection}" == "q" || -z "${selection}" ]]; then
        printf "  ${C_DIM}Cancelled${C_RESET}\n"
        return 0
    fi

    if ! [[ "${selection}" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > ${#projects[@]} )); then
        printf "  ${C_RED}Invalid number.${C_RESET}\n"
        return 1
    fi

    local idx=$((selection - 1))
    local selected_cwd="${cwds[$idx]}"
    local selected_name="${projects[$idx]}"

    printf "  Enter alias (${C_DIM}current: ${selected_name}${C_RESET}): "
    read -r new_alias

    if [[ -z "${new_alias}" ]]; then
        printf "  ${C_DIM}Cancelled${C_RESET}\n"
        return 0
    fi

    local config
    config=$(cat "${CONFIG_FILE}")
    safe_write_json "${CONFIG_FILE}" \
        "$(echo "${config}" | jq --arg dir "${selected_cwd}" --arg name "${new_alias}" '.project_aliases[$dir] = $name')"
    printf "  ${C_GREEN}✅${C_RESET} ${C_BOLD}${new_alias}${C_RESET} ← ${C_DIM}${selected_cwd}${C_RESET}\n"
}

# ── Path normalization helper ────────────────────────────────────────────────
_resolve_path() {
    local dir="$1"

    if [[ -z "${dir}" ]]; then
        echo ""
        return
    fi

    # "." → current directory
    if [[ "${dir}" == "." ]]; then
        pwd
        return
    fi

    # ~ expansion
    if [[ "${dir}" == "~"* ]]; then
        dir="${HOME}${dir:1}"
    fi

    # Windows absolute paths (C:/ etc.) are used as-is
    if [[ "${dir}" =~ ^[A-Za-z]:[\\/] ]]; then
        # Normalize backslashes to forward slashes
        echo "${dir}" | sed 's|\\|/|g'
        return
    fi

    # Relative path → absolute path
    if [[ "${dir}" != /* ]]; then
        if [[ -d "${dir}" ]]; then
            (cd "${dir}" && pwd)
            return
        fi
    fi

    echo "${dir}"
}

# ── Command: config ─────────────────────────────────────────────────────────
cmd_config() {
    require_jq || return 1

    local action="${1:-show}"

    case "${action}" in
        webhook)
            local url="${2:-}"
            if [[ -z "${url}" ]]; then
                echo "Usage: claude-tracker config webhook <URL>" >&2
                return 1
            fi
            local config
            config=$(cat "${CONFIG_FILE}")
            safe_write_json "${CONFIG_FILE}" \
                "$(echo "${config}" | jq --arg url "${url}" '.discord_webhook_url = $url')"
            printf "  ${C_GREEN}✅${C_RESET} Discord Webhook URL configured\n"
            printf "  ${C_DIM}Test: claude-tracker test${C_RESET}\n"
            ;;
        alias)
            local dir="${2:-}"
            local name="${3:-}"
            # No arguments → interactive mode
            if [[ -z "${dir}" ]]; then
                _config_alias_interactive
                return $?
            fi
            if [[ -z "${name}" ]]; then
                printf "  Usage: claude-tracker config alias <path> <alias>\n" >&2
                printf "         claude-tracker config alias ${C_DIM}(interactive)${C_RESET}\n" >&2
                printf "  Example: claude-tracker config alias . myproject\n" >&2
                return 1
            fi
            # Normalize path
            local resolved_dir
            resolved_dir=$(_resolve_path "${dir}")
            if [[ "${resolved_dir}" != "${dir}" ]]; then
                printf "  ${C_DIM}Path: ${dir} → ${resolved_dir}${C_RESET}\n"
            fi
            local config
            config=$(cat "${CONFIG_FILE}")
            safe_write_json "${CONFIG_FILE}" \
                "$(echo "${config}" | jq --arg dir "${resolved_dir}" --arg name "${name}" '.project_aliases[$dir] = $name')"
            printf "  ${C_GREEN}✅${C_RESET} Project alias set: ${C_BOLD}${name}${C_RESET} ← ${C_DIM}${resolved_dir}${C_RESET}\n"
            ;;
        show)
            echo ""
            printf "  ${C_BOLD}${C_CYAN}⚙️  Current configuration${C_RESET}\n"
            printf "  ${C_DIM}────────────────────────────────────────${C_RESET}\n"
            echo ""

            local wh_status
            wh_status=$(get_config '.discord_webhook_url')
            if [[ -n "${wh_status}" ]]; then
                printf "  Discord Webhook  ${C_GREEN}✓ configured${C_RESET}\n"
            else
                printf "  Discord Webhook  ${C_RED}✗ not set${C_RESET}\n"
            fi

            local dash_wh
            dash_wh=$(get_config '.dashboard_channel_webhook')
            if [[ -n "${dash_wh}" ]]; then
                printf "  Dashboard Webhook ${C_GREEN}✓ configured${C_RESET}\n"
            else
                printf "  Dashboard Webhook ${C_DIM}○ not set (optional)${C_RESET}\n"
            fi

            echo ""
            printf "  ${C_BOLD}Notification settings${C_RESET}\n"
            local notif_keys=("on_start:Start" "on_complete:Complete" "on_error:Error" "on_idle:Idle")
            for nk in "${notif_keys[@]}"; do
                local key="${nk%%:*}"
                local label="${nk##*:}"
                local val
                val=$(get_config ".notification.${key}")
                if [[ "${val}" == "true" ]]; then
                    printf "    ${C_GREEN}✓${C_RESET} ${label}\n"
                else
                    printf "    ${C_DIM}✗ ${label}${C_RESET}\n"
                fi
            done

            local idle_min
            idle_min=$(get_config '.notification.idle_threshold_minutes')
            printf "    Debounce: ${C_BOLD}${idle_min:-10}min${C_RESET}\n"

            echo ""
            local alias_count
            alias_count=$(jq '.project_aliases | length' "${CONFIG_FILE}" 2>/dev/null || echo 0)
            if (( alias_count > 0 )); then
                printf "  ${C_BOLD}Project aliases${C_RESET} (${alias_count})\n"
                jq -r '.project_aliases | to_entries[] | "    \(.value)  ← \(.key)"' "${CONFIG_FILE}" 2>/dev/null
            else
                printf "  ${C_DIM}Project aliases: none${C_RESET}\n"
            fi

            echo ""
            local bt
            bt=$(get_config '.bot_token')
            if [[ -n "${bt}" ]]; then
                printf "  Bot Token        ${C_GREEN}✓ configured${C_RESET}\n"
            else
                printf "  Bot Token        ${C_DIM}○ not set${C_RESET}\n"
            fi

            echo ""
            printf "  ${C_DIM}Toggle notifications: claude-tracker config notify <key> <true|false>${C_RESET}\n"
            printf "  ${C_DIM}Full edit: \$EDITOR ${CONFIG_FILE}${C_RESET}\n"
            echo ""
            ;;
        bot-token)
            local token="${2:-}"
            if [[ -z "${token}" ]]; then
                echo "Usage: claude-tracker config bot-token <TOKEN>" >&2
                return 1
            fi
            local config
            config=$(cat "${CONFIG_FILE}")
            safe_write_json "${CONFIG_FILE}" \
                "$(echo "${config}" | jq --arg t "${token}" '.bot_token = $t')"
            printf "  ${C_GREEN}✅${C_RESET} Bot Token configured\n"
            printf "  ${C_DIM}Start bot: claude-tracker bot start${C_RESET}\n"
            ;;
        notify)
            local nkey="${2:-}"
            local nval="${3:-}"
            if [[ -z "${nkey}" || -z "${nval}" ]]; then
                echo ""
                printf "  Usage: claude-tracker config notify ${C_DIM}<key> <true|false>${C_RESET}\n"
                echo ""
                printf "  Available keys:\n"
                printf "    on_start     session start notification\n"
                printf "    on_complete  task complete notification\n"
                printf "    on_error     error notification\n"
                printf "    on_idle      idle notification\n"
                echo ""
                return 1
            fi
            if [[ "${nval}" != "true" && "${nval}" != "false" ]]; then
                printf "  ${C_RED}✗${C_RESET} Value must be true or false.\n"
                return 1
            fi
            # Validate allowed keys
            case "${nkey}" in
                on_start|on_complete|on_error|on_idle) ;;
                *)
                    printf "  ${C_RED}✗${C_RESET} Unknown key: ${nkey}\n"
                    printf "  ${C_DIM}Valid keys: on_start, on_complete, on_error, on_idle${C_RESET}\n"
                    return 1
                    ;;
            esac
            local config
            config=$(cat "${CONFIG_FILE}")
            safe_write_json "${CONFIG_FILE}" \
                "$(echo "${config}" | jq --arg k "${nkey}" --argjson v "${nval}" '.notification[$k] = $v')"
            printf "  ${C_GREEN}✅${C_RESET} notification.${nkey} = ${nval}\n"
            ;;
        *)
            echo "Usage: claude-tracker config [webhook|alias|notify|show]" >&2
            ;;
    esac
}

# ── Command: uninstall ──────────────────────────────────────────────
cmd_uninstall() {
    echo ""
    printf "  ${C_BOLD}${C_RED}⚠️  Uninstalling Claude Process Tracker${C_RESET}\n"
    echo ""
    echo "  The following will be removed:"
    printf "    ${C_DIM}~/.claude-tracker/${C_RESET} (config, state, logs)\n"
    printf "    tracker hooks from ${C_DIM}~/.claude/settings.json${C_RESET}\n"
    echo ""
    read -r -p "  Continue? [y/N] " response
    if [[ ! "${response}" =~ ^[Yy]$ ]]; then
        echo "  Cancelled."
        return 0
    fi

    local settings="${HOME}/.claude/settings.json"
    if [[ -f "${settings}" ]] && command -v jq &>/dev/null; then
        local cleaned
        cleaned=$(jq '
            .hooks.SessionStart = [.hooks.SessionStart[]? | select(.hooks[]?.command | test("claude-tracker") | not)] |
            .hooks.Stop = [.hooks.Stop[]? | select(.hooks[]?.command | test("claude-tracker") | not)] |
            .hooks.SessionEnd = [.hooks.SessionEnd[]? | select(.hooks[]?.command | test("claude-tracker") | not)] |
            if .hooks.SessionStart == [] then del(.hooks.SessionStart) else . end |
            if .hooks.Stop == [] then del(.hooks.Stop) else . end |
            if .hooks.SessionEnd == [] then del(.hooks.SessionEnd) else . end |
            if .hooks == {} then del(.hooks) else . end
        ' "${settings}" 2>/dev/null)

        if [[ -n "${cleaned}" ]]; then
            safe_write_json "${settings}" "${cleaned}"
            printf "  ${C_GREEN}✅${C_RESET} Claude Code hooks removed\n"
        fi
    fi

    rm -rf "${TRACKER_DIR}"
    printf "  ${C_GREEN}✅${C_RESET} ~/.claude-tracker/ removed\n"
    echo ""
    printf "  ${C_DIM}Manually remove claude-tracker from your PATH:${C_RESET}\n"
    printf "  ${C_DIM}  Delete the relevant line from ~/.zshrc or ~/.bashrc${C_RESET}\n"
    echo ""
}

# ── Command: upgrade (self-update from GitHub) ───────────────────────────────
cmd_upgrade() {
    local REPO_URL="https://raw.githubusercontent.com/criel2019/claude-tools/master/claude-tracker.sh"
    local INSTALL_DIR="${TRACKER_DIR}"
    local BIN="${INSTALL_DIR}/bin/claude-tracker"

    echo ""
    printf "  ${C_BOLD}Updating Claude Process Tracker from GitHub...${C_RESET}\n"
    echo ""

    if ! command -v curl &>/dev/null; then
        printf "  ${C_RED}✗${C_RESET} curl is required for updates.\n"
        return 1
    fi

    local tmpfile
    tmpfile=$(mktemp)
    trap 'rm -f "${tmpfile}"' EXIT

    printf "  Downloading latest version...\n"
    if ! curl -fsSL "${REPO_URL}" -o "${tmpfile}"; then
        printf "  ${C_RED}✗${C_RESET} Download failed. Check your internet connection.\n"
        return 1
    fi

    # Sanity check — downloaded file should be a bash script
    if ! head -1 "${tmpfile}" | grep -q "bash"; then
        printf "  ${C_RED}✗${C_RESET} Downloaded file does not look like a bash script.\n"
        return 1
    fi

    # Backup current binary
    cp "${BIN}" "${BIN}.backup.$(date '+%Y%m%d%H%M%S')" 2>/dev/null || true

    # Install
    cp "${tmpfile}" "${BIN}"
    chmod +x "${BIN}"

    printf "  ${C_GREEN}✅${C_RESET} Update complete.\n"
    echo ""
    printf "  ${C_DIM}Installed to: ${BIN}${C_RESET}\n"
    printf "  ${C_DIM}Old binary backed up as ${BIN}.backup.*${C_RESET}\n"
    echo ""
}

# ── Command: watch (real-time monitoring) ────────────────────────────────────
cmd_watch() {
    local interval="${1:-5}"

    trap 'printf "\n  ${C_DIM}Monitoring stopped${C_RESET}\n\n"; exit 0' INT
    printf "  ${C_BOLD}Real-time monitoring${C_RESET} ${C_DIM}(${interval}s interval, Ctrl+C to stop)${C_RESET}\n"

    while true; do
        printf '\033[2J\033[H'  # Clear screen (preserve scrollback)
        cmd_status
        sleep "${interval}"
    done
}

# ── Command: prompt (UserPromptSubmit hook) ──────────────────────────────────
# Called on every user prompt → transitions idle → active.
# Saves prompt content to last-prompt.txt for error recovery.
cmd_prompt() {
    trap 'exit 0' ERR

    require_jq || exit 0

    local input
    input=$(read_stdin_json) || exit 0

    local session_id cwd transcript_path
    local _fields
    _fields=$(printf '%s\n' "${input}" | jq -r '"\(.session_id // "")\t\(.cwd // "")\t\(.transcript_path // "")"')
    IFS=$'\t' read -r session_id cwd transcript_path <<< "${_fields}"
    [[ -z "${session_id}" ]] && exit 0

    # Save user prompt content (for error recovery)
    _save_last_prompt "${input}"

    # Auto-register if session is missing (recovery from SessionStart hook failure)
    local exists
    exists=$(jq -r --arg sid "${session_id}" 'if .sessions[$sid] != null then "yes" else "no" end' "${STATE_FILE}" 2>/dev/null)
    if [[ "${exists}" != "yes" ]]; then
        log "INFO" "prompt:auto-register ${session_id}"
        local project_name
        project_name=$(get_project_name "${cwd}")
        local now
        now=$(date '+%s')
        local claude_pid
        claude_pid=$(_find_claude_pid)
        with_state_lock _register_impl "${session_id}" "${project_name}" "${cwd}" "${now}" "${transcript_path}" "${claude_pid}" || exit 0
    fi

    with_state_lock _prompt_impl "${session_id}" || exit 0
}

# Save user prompt to last-prompt.txt (keep up to 5 entries)
# Called from hook path, so minimize I/O: use basename instead of get_project_name.
_save_last_prompt() {
    local input="$1"
    local prompt_text
    prompt_text=$(printf '%s\n' "${input}" | jq -r '.prompt // .message // ""' 2>/dev/null) || return 0
    [[ -z "${prompt_text}" || "${prompt_text}" == "null" ]] && return 0

    local recovery_file="${TRACKER_DIR}/last-prompt.txt"
    local cwd
    cwd=$(printf '%s\n' "${input}" | jq -r '.cwd // ""' 2>/dev/null)
    local label="${cwd##*/}"  # basename — no file I/O
    [[ -z "${label}" ]] && label="unknown"

    local new_entry
    new_entry="$(printf '── %s [%s] ──\n%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${label}" "${prompt_text}")"

    if [[ -f "${recovery_file}" ]]; then
        # Keep last 4 entries separated by (──) delimiter + new entry = 5 total
        printf '%s\n\n%s' "${new_entry}" "$(cat "${recovery_file}" 2>/dev/null)" \
            | awk '/^── [0-9]{4}-/{count++} count>5{exit} {print}' \
            > "${recovery_file}.tmp.$$" \
            && mv "${recovery_file}.tmp.$$" "${recovery_file}"
    else
        echo "${new_entry}" > "${recovery_file}"
    fi
}

_prompt_impl() {
    local session_id="$1"
    local now
    now=$(date '+%s')

    local state
    state=$(get_state)

    # Check session exists
    local exists
    exists=$(echo "${state}" | jq -r --arg sid "${session_id}" '
        if .sessions[$sid] != null then "yes" else "no" end
    ')
    [[ "${exists}" != "yes" ]] && return 0

    # Transition idle → active + update last_activity
    # Reset last_notify on idle→active so the next Stop always sends a completion notification
    state=$(echo "${state}" | jq \
        --arg sid "${session_id}" \
        --argjson now "${now}" \
        '(.sessions[$sid].status) as $prev |
         .sessions[$sid].status = "active" |
         .sessions[$sid].last_activity = $now |
         (if $prev == "idle" then .sessions[$sid].last_notify = 0 else . end) |
         .projects[.sessions[$sid].project].status = "active" |
         .projects[.sessions[$sid].project].last_activity = $now')

    save_state "${state}"
    log "INFO" "session:prompt $(echo "${state}" | jq -r --arg sid "${session_id}" '.sessions[$sid].project')"
}

# ── Command: monitor (background polling daemon) ─────────────────────────────
# Periodically checks actual session status and corrects state.
# 1) auto-discovered sessions: active/idle by CWD file mtime
# 2) hook-registered sessions: only PID liveness check (trust hook status)
#    - PID alive → keep status set by hook
#    - PID dead  → assume crash, clean up session + notify
# 3) idle for N+ minutes → send Discord idle notification
cmd_monitor() {
    require_jq || return 1

    local interval="${1:-60}"

    local pidfile="${TRACKER_DIR}/.monitor.pid"

    # Handle stop command (before checking if already running)
    if [[ "${interval}" == "stop" ]]; then
        if [[ -f "${pidfile}" ]]; then
            local old_pid
            old_pid=$(cat "${pidfile}" 2>/dev/null || echo "")
            if [[ -n "${old_pid}" ]]; then
                kill "${old_pid}" 2>/dev/null || true
                rm -f "${pidfile}"
                printf "  ${C_GREEN}✅${C_RESET} Monitor stopped\n"
            fi
        else
            printf "  ${C_DIM}No monitor is running.${C_RESET}\n"
        fi
        return 0
    fi

    # Check if already running
    if [[ -f "${pidfile}" ]]; then
        local old_pid
        old_pid=$(cat "${pidfile}" 2>/dev/null || echo "")
        if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
            printf "  ${C_YELLOW}⚠${C_RESET} Monitor is already running (PID ${old_pid})\n"
            printf "  ${C_DIM}Stop: claude-tracker monitor stop${C_RESET}\n"
            return 0
        fi
        rm -f "${pidfile}"
    fi

    # Run in background
    _monitor_loop "${interval}" &
    local monitor_pid=$!
    echo "${monitor_pid}" > "${pidfile}"

    printf "  ${C_GREEN}✅${C_RESET} Monitor started (PID ${monitor_pid}, ${interval}s interval)\n"
    printf "  ${C_DIM}Stop: claude-tracker monitor stop${C_RESET}\n"
    printf "  ${C_DIM}Log: tail -f ${LOG_FILE}${C_RESET}\n"
}

_monitor_loop() {
    local interval="$1"
    local idle_threshold_min
    idle_threshold_min=$(to_int "$(get_config '.notification.idle_threshold_minutes')" 10)
    local idle_threshold_sec=$(( idle_threshold_min * 60 ))

    # Token snapshot interval (30 min = 1800s)
    local snapshot_interval=1800
    local last_snapshot=0

    log "INFO" "monitor:start interval=${interval}s idle=${idle_threshold_min}m snapshot=${snapshot_interval}s"

    # File to prevent duplicate idle notifications
    local notified_idle_file="${TRACKER_DIR}/.monitor_notified"
    : > "${notified_idle_file}"

    while true; do
        sleep "${interval}"

        command -v jq &>/dev/null || continue
        [[ -f "${STATE_FILE}" ]] || continue

        local now
        now=$(date '+%s')

        # ── Stage 1: Process-independent discovery (find -mmin, fast) ──
        local active_window=120  # 2 minutes (threshold for auto-discovered session active/idle detection)
        _monitor_discover_and_save "${now}" "${active_window}"

        # ── Stage 2: PID-based liveness check for hook-registered sessions ──
        # Trust hook-set status (active/idle); only detect crashes via PID.
        # Discord notifications are sent outside the lock to minimize lock hold time.
        local _pid_notifications=""
        with_state_lock _monitor_pid_check "${now}" "${idle_threshold_sec}" "${notified_idle_file}" 2>/dev/null || true

        # Send notifications outside the lock (network I/O)
        if [[ -n "${_pid_notifications}" ]]; then
            while IFS='|' read -r ntype nproj narg1 narg2; do
                [[ -z "${ntype}" ]] && continue
                case "${ntype}" in
                    crash)
                        send_embed "💀 Crash detected" 15158332 "" \
                            "Project" "\`${nproj}\`" \
                            "Reason" "Process disappeared (PID ${narg1})" \
                            "Duration" "${narg2}"
                        ;;
                    idle)
                        send_embed "💤 Idle session" 16776960 "on_idle" \
                            "Project" "\`${nproj}\`" \
                            "Idle for" "${narg1}" \
                            "Status" "Waiting for prompt"
                        ;;
                esac
            done <<< "${_pid_notifications}"
        fi

        # ── Stage 3: Collect live token usage ──
        _monitor_update_live_tokens

        # ── Stage 4: Token history snapshot (every 30 minutes) ──
        if (( now - last_snapshot >= snapshot_interval )); then
            write_token_snapshot
            last_snapshot="${now}"
        fi

    done
}

_monitor_save_state() {
    local new_state="$1"
    save_state "${new_state}"
}

# ── PID-based session liveness check (runs inside lock) ─────────────────────
# Appends notification queue to parent _monitor_loop's _pid_notifications var.
# Actual notification sending (network I/O) happens outside the lock.
_monitor_pid_check() {
    local now="$1" idle_threshold_sec="$2" notified_idle_file="$3"

    local state
    state=$(get_state)
    local state_changed=false

    while IFS='|' read -r sid proj status last_activity tp session_pid; do
        [[ -z "${sid}" ]] && continue

        local current_last_activity
        current_last_activity=$(to_int "${last_activity}" 0)

        # No transcript path → not hook-registered; handled by stage 1 (skip)
        if [[ -z "${tp}" ]]; then
            continue
        fi

        # ── PID liveness check ──
        local pid_val
        pid_val=$(to_int "${session_pid}" 0)

        if (( pid_val > 0 )) && ! _is_win_pid_alive "${pid_val}"; then
            # Process dead → crash (SessionEnd hook was not called)
            local started_at
            started_at=$(echo "${state}" | jq -r --arg sid "${sid}" '.sessions[$sid].started_at // 0')
            started_at=$(to_int "${started_at}" 0)
            local duration_sec=$(( now - started_at ))
            local duration
            duration=$(format_duration "${duration_sec}")

            state=$(remove_session_from_state "${state}" "${sid}" "${proj}")
            state_changed=true

            # Also remove from idle notification file
            grep -vFx "${sid}" "${notified_idle_file}" > "${notified_idle_file}.tmp" \
                && mv "${notified_idle_file}.tmp" "${notified_idle_file}" || true

            # Add to notification queue (sent outside lock)
            _pid_notifications+="crash|${proj}|${pid_val}|${duration}"$'\n'
            log "WARN" "monitor:crash ${proj} (PID ${pid_val} dead, session ${sid})"
            continue
        fi

        # ── PID missing or process alive → trust hook status ──

        # ── Idle notification (based on hook-set status) ──
        if [[ "${status}" == "idle" ]]; then
            local idle_elapsed=$(( now - current_last_activity ))

            if (( idle_elapsed > idle_threshold_sec )); then
                if ! grep -qFx "${sid}" "${notified_idle_file}" 2>/dev/null; then
                    echo "${sid}" >> "${notified_idle_file}"
                    _pid_notifications+="idle|${proj}|$(format_duration "${idle_elapsed}")|"$'\n'
                    log "INFO" "monitor:idle_notify ${proj} ($(format_duration "${idle_elapsed}"))"
                fi
            fi
        fi

        if [[ "${status}" == "active" ]]; then
            grep -vFx "${sid}" "${notified_idle_file}" > "${notified_idle_file}.tmp" \
                && mv "${notified_idle_file}.tmp" "${notified_idle_file}" || true
        fi

    done < <(echo "${state}" | jq -r '
        .sessions | to_entries[] |
        "\(.key)|\(.value.project)|\(.value.status)|\(.value.last_activity // 0)|\(.value.transcript_path // "")|\(.value.pid // 0)"
    ')

    if [[ "${state_changed}" == "true" ]]; then
        save_state "${state}"
    fi
}

# ── Live token collection (each polling cycle) ───────────────────────────────
_monitor_update_live_tokens() {
    local state
    state=$(get_state)

    local updated=false
    while IFS='|' read -r sid cwd; do
        [[ -z "${sid}" || -z "${cwd}" ]] && continue

        local tokens
        tokens=$(get_live_tokens "${cwd}" 2>/dev/null)
        [[ -z "${tokens}" || "${tokens}" == "{}" ]] && continue

        local input output total
        input=$(echo "${tokens}" | jq -r '.input // 0' 2>/dev/null)
        output=$(echo "${tokens}" | jq -r '.output // 0' 2>/dev/null)
        total=$(echo "${tokens}" | jq -r '.total // 0' 2>/dev/null)

        (( total == 0 )) && continue

        state=$(echo "${state}" | jq \
            --arg sid "${sid}" \
            --argjson inp "${input}" \
            --argjson out "${output}" \
            --argjson tot "${total}" \
            '.sessions[$sid].live_input_tokens = $inp |
             .sessions[$sid].live_output_tokens = $out |
             .sessions[$sid].live_total_tokens = $tot')
        updated=true
    done < <(echo "${state}" | jq -r '.sessions | to_entries[] | "\(.key)|\(.value.cwd)"')

    if [[ "${updated}" == "true" ]]; then
        with_state_lock _monitor_save_state "${state}" 2>/dev/null || true
    fi
}

# ── Process discovery + immediate save ──────────────────────────────────────
# Writes directly to state.json instead of returning via echo.
# Avoids subshell pipe issues.
_monitor_discover_and_save() {
    local now="$1"
    local active_window="$2"

    # 2-stage scan:
    # 1) Files modified within last 2 minutes → actively working (active) + live agent count
    # 2) All CWD files → all open projects (including idle)
    #    No time limit since we need to be able to send to all running processes
    local active_projects
    active_projects=$(find /tmp -maxdepth 1 -name "claude-*-cwd" -mmin -2 -exec cat {} + 2>/dev/null | sort -u) || true

    # Live agent count: count only files modified within last 2 minutes (exclude stale)
    local active_scan
    active_scan=$(find /tmp -maxdepth 1 -name "claude-*-cwd" -mmin -2 -exec cat {} + 2>/dev/null | sort | uniq -c | sort -rn) || true

    # Full project list: all CWD files (existence only, no count)
    local raw_scan
    raw_scan=$(find /tmp -maxdepth 1 -name "claude-*-cwd" -exec cat {} + 2>/dev/null | sort -u | awk '{print "1 " $0}') || true

    [[ -z "${raw_scan}" ]] && return 0

    # Filter out parent directories: remove A if it is a parent of B
    # e.g. /Users/Desktop is a parent of /Users/Desktop/Claude Tools → remove it
    # Use sed to strip leading count+space (paths may contain spaces)
    local all_cwds
    all_cwds=$(echo "${raw_scan}" | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//')
    local scan_data=""
    while read -r count cwd; do
        [[ -z "${cwd}" ]] && continue
        local is_parent=false
        while read -r other_cwd; do
            [[ -z "${other_cwd}" || "${other_cwd}" == "${cwd}" ]] && continue
            # If cwd is a prefix of other_cwd, then cwd is a parent directory
            if [[ "${other_cwd}" == "${cwd}/"* ]]; then
                is_parent=true
                break
            fi
        done <<< "${all_cwds}"
        if [[ "${is_parent}" == "false" ]]; then
            scan_data+="${count} ${cwd}"$'\n'
        fi
    done <<< "${raw_scan}"

    [[ -z "${scan_data}" ]] && return 0

    # Acquire lock then modify state directly
    with_state_lock _monitor_discover_locked "${now}" "${scan_data}" "${active_projects}" "${active_scan}"
}

_monitor_discover_locked() {
    local now="$1"
    local scan_data="$2"
    local active_projects="${3:-}"
    local active_scan="${4:-}"
    local state
    state=$(get_state)
    local changed=false

    # Reset agent_count to 0 for auto_discovered sessions at the start of each cycle
    state=$(echo "${state}" | jq '
        .sessions |= with_entries(
            if .value.auto_discovered then .value.agent_count = 0 else . end
        )
    ')

    while read -r count cwd; do
        [[ -z "${cwd}" ]] && continue
        local project_name
        project_name=$(get_project_name "${cwd}")

        # Active determination: CWD in last 2 minutes → actually working
        local new_status="idle"
        if [[ -n "${active_projects}" ]] && echo "${active_projects}" | grep -qF "${cwd}"; then
            new_status="active"
        fi

        # Actual agent count: number of recent files for this CWD in active_scan
        local real_agents=0
        if [[ -n "${active_scan}" ]]; then
            real_agents=$(echo "${active_scan}" | grep -F "${cwd}" | awk '{print $1}' | head -1)
            real_agents=${real_agents:-0}
        fi
        count="${real_agents}"

        # Check if this project already has a session in state.json
        # Reuse only auto_discovered sessions (hook-registered sessions have separate UUIDs)
        # Search by project name since CWD format may differ (C:/ vs /c/)
        local existing_sid
        existing_sid=$(echo "${state}" | jq -r --arg proj "${project_name}" '
            [.sessions | to_entries[] |
             select(.value.project == $proj and .value.auto_discovered == true)] |
            first | .key // ""
        ' 2>/dev/null)

        if [[ -z "${existing_sid}" || "${existing_sid}" == "null" ]]; then
            # New session discovered: auto-register
            local auto_sid="auto-$(printf '%04x%04x' $((RANDOM)) $((RANDOM)))-$(date +%s | tail -c 5)"
            state=$(echo "${state}" | jq \
                --arg sid "${auto_sid}" \
                --arg proj "${project_name}" \
                --arg cwd "${cwd}" \
                --argjson now "${now}" \
                --argjson agents "${count}" \
                --arg status "${new_status}" \
                '.sessions[$sid] = {
                    project: $proj, cwd: $cwd, status: $status,
                    started_at: $now, last_activity: $now,
                    stop_count: 0, transcript_path: "",
                    auto_discovered: true, agent_count: $agents
                } |
                .projects[$proj] = ((.projects[$proj] // {}) * {
                    cwd: $cwd, active_session: $sid,
                    status: $status, last_activity: $now
                })')
            changed=true
            log "INFO" "monitor:discover ${project_name} (${auto_sid}, ${count} agents, ${new_status})"

            local active_total
            active_total=$(echo "${state}" | jq '[.sessions[] | select(.status == "active")] | length' 2>/dev/null || echo "?")
            send_embed "🔍 Session discovered" 5763719 "on_start" \
                "Project" "\`${project_name}\`" \
                "Status" "${new_status}" \
                "Concurrent" "${active_total}" \
                "Agents" "${count}"
        else
            # Existing session: update status + agent_count (merge if same project, different path)
            local current_status
            current_status=$(echo "${state}" | jq -r --arg sid "${existing_sid}" '.sessions[$sid].status // ""')
            # Keep active if at least one source reports active
            if [[ "${current_status}" == "active" && "${new_status}" == "idle" ]]; then
                new_status="active"
            fi
            # Update CWD if it actually exists (replace with a valid path)
            local update_cwd="false"
            local current_cwd
            current_cwd=$(echo "${state}" | jq -r --arg sid "${existing_sid}" '.sessions[$sid].cwd // ""')
            if [[ -d "${cwd}" && ! -d "${current_cwd}" ]]; then
                update_cwd="true"
            fi
            state=$(echo "${state}" | jq \
                --arg sid "${existing_sid}" \
                --arg ns "${new_status}" \
                --argjson now "${now}" \
                --argjson agents "${count}" \
                --arg newcwd "${cwd}" \
                --argjson ucwd "${update_cwd}" \
                '.sessions[$sid].status = $ns |
                 .sessions[$sid].last_activity = $now |
                 .sessions[$sid].agent_count = $agents |
                 .projects[.sessions[$sid].project].status = $ns |
                 .projects[.sessions[$sid].project].last_activity = $now |
                 if $ucwd then .sessions[$sid].cwd = $newcwd | .projects[.sessions[$sid].project].cwd = $newcwd else . end')
            if [[ "${current_status}" != "${new_status}" ]]; then
                changed=true
                log "INFO" "monitor:sync ${project_name} ${current_status}→${new_status}"
            fi
        fi
    done <<< "${scan_data}"

    # Remove auto_discovered sessions that no longer appear in the scan (process gone)
    # Compare by project name since CWD format may differ (C:/ vs /c/)
    local scanned_proj_names_json
    scanned_proj_names_json=$(echo "${scan_data}" | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//' | while read -r p; do
        [[ -z "${p}" ]] && continue
        get_project_name "${p}"
    done | sort -u | jq -R -s 'split("\n") | map(select(length > 0))')
    local before_count
    before_count=$(echo "${state}" | jq '.sessions | length')
    state=$(echo "${state}" | jq --argjson scanned "${scanned_proj_names_json}" '
        # Remove auto_discovered sessions whose project name no longer appears in scan
        .sessions |= with_entries(
            select(
                (.value.auto_discovered == true and (.value.project as $proj | $scanned | index($proj) | not))
                | not
            )
        ) |
        # Remove projects with no remaining sessions
        (.sessions | [.[].project] | unique) as $active |
        .projects |= with_entries(select(.key as $k | $active | index($k)))
    ')
    local after_count
    after_count=$(echo "${state}" | jq '.sessions | length')
    if (( before_count != after_count )); then
        changed=true
        log "INFO" "monitor:cleanup removed $(( before_count - after_count )) stale sessions (${before_count}→${after_count})"
    fi

    # Always save (to update last_activity)
    save_state "${state}"
    if [[ "${changed}" == "true" ]]; then
        log "INFO" "monitor:state_saved ($(echo "${state}" | jq '.sessions | length') sessions)"
    fi
}

# ── Process-independent discovery ───────────────────────────────────────────
# Scans /tmp/claude-*-cwd files to auto-discover running Claude Code sessions.
# Tracks all instances even without hook registration.
#
# Performance:
#   - find -mmin to scan only recent files (avoids scanning hundreds of files)
#   - sort | uniq -c pipeline to group CWDs (minimizes bash loops)

# ── Command: history (per-project stats) ────────────────────────────────────
cmd_history() {
    require_jq || return 1

    echo ""
    printf "  ${C_BOLD}${C_CYAN}📊 Session log${C_RESET}\n"
    printf "  ${C_DIM}────────────────────────────────────────${C_RESET}\n"
    echo ""

    if [[ ! -f "${LOG_FILE}" ]]; then
        printf "  ${C_DIM}No log yet.${C_RESET}\n\n"
        return
    fi

    # Session count per project
    printf "  ${C_BOLD}Activity by project${C_RESET}\n\n"

    local projects
    projects=$(grep -E 'session:(register|stop|end) ' "${LOG_FILE}" 2>/dev/null \
        | sed 's/.*session:[a-z]* //' | awk '{print $1}' \
        | sort | uniq -c | sort -rn)

    if [[ -z "${projects}" ]]; then
        printf "  ${C_DIM}No recorded activity.${C_RESET}\n\n"
        return
    fi

    while read -r count name; do
        local bar_len=$(( count > 30 ? 30 : count ))
        local bar=""
        for (( i=0; i<bar_len; i++ )); do bar+="█"; done

        printf "  %-18s ${C_CYAN}%s${C_RESET} ${C_DIM}%d event(s)${C_RESET}\n" "${name}" "${bar}" "${count}"
    done <<< "${projects}"

    echo ""

    # Last 10 events
    printf "  ${C_BOLD}Recent events${C_RESET}\n\n"

    tail -n 20 "${LOG_FILE}" | grep -E 'session:(register|stop|end)|notify:' | tail -n 10 | while IFS= read -r line; do
        local ts
        ts=$(echo "${line}" | sed 's/^\[\([^]]*\)\].*/\1/')
        local event_icon="  "

        if echo "${line}" | grep -q 'session:register'; then
            event_icon="${C_GREEN}▶${C_RESET}"
        elif echo "${line}" | grep -q 'session:stop'; then
            event_icon="${C_YELLOW}⏸${C_RESET}"
        elif echo "${line}" | grep -q 'session:end'; then
            event_icon="${C_RED}■${C_RESET}"
        fi

        local detail
        detail=$(echo "${line}" | sed 's/.*] //')
        printf "  ${event_icon} ${C_DIM}${ts}${C_RESET}  ${detail}\n"
    done

    echo ""
}

# ── Command: usage (token usage stats) ───────────────────────────────────────
cmd_usage() {
    require_jq || return 1

    local period="${1:-today}"

    echo ""
    printf "  ${C_BOLD}${C_CYAN}📈 Token usage${C_RESET}\n"
    printf "  ${C_DIM}────────────────────────────────────────${C_RESET}\n"

    if [[ ! -f "${USAGE_LOG}" ]]; then
        echo ""
        printf "  ${C_DIM}No usage records yet.${C_RESET}\n"
        printf "  ${C_DIM}Records are saved automatically when a Claude Code session ends.${C_RESET}\n\n"
        return
    fi

    # Period filter
    local date_filter=""
    local period_label=""
    local now_ts
    now_ts=$(date '+%s')
    case "${period}" in
        today|t)
            date_filter=$(date '+%Y-%m-%d')
            period_label="Today"
            ;;
        week|w)
            date_filter=$(date -d '7 days ago' '+%Y-%m-%d' 2>/dev/null || date -v-7d '+%Y-%m-%d' 2>/dev/null || echo "")
            period_label="Last 7 days"
            ;;
        month|m)
            date_filter=$(date -d '30 days ago' '+%Y-%m-%d' 2>/dev/null || date -v-30d '+%Y-%m-%d' 2>/dev/null || echo "")
            period_label="Last 30 days"
            ;;
        all|a)
            date_filter=""
            period_label="All time"
            ;;
        *)
            # Direct date input (YYYY-MM-DD)
            date_filter="${period}"
            period_label="Since ${period}"
            ;;
    esac

    # Filter + aggregate usage.jsonl
    local stats
    if [[ -n "${date_filter}" ]]; then
        stats=$(jq -s --arg since "${date_filter}" '
            [.[] | select(.timestamp >= $since)] |
            {
                sessions: length,
                total_input: (map(.input_tokens) | add // 0),
                total_output: (map(.output_tokens) | add // 0),
                total_cache_create: (map(.cache_creation_tokens) | add // 0),
                total_cache_read: (map(.cache_read_tokens) | add // 0),
                total_tokens: (map(.total_tokens) | add // 0),
                total_cost: (map(.total_cost_usd) | add // 0),
                total_duration: (map(.duration_sec) | add // 0),
                by_project: (group_by(.project) | map({
                    project: .[0].project,
                    sessions: length,
                    tokens: (map(.total_tokens) | add // 0),
                    cost: (map(.total_cost_usd) | add // 0),
                    input: (map(.input_tokens) | add // 0),
                    output: (map(.output_tokens) | add // 0)
                }) | sort_by(-.tokens)),
                recent_prompts: (sort_by(.timestamp) | .[-10:] | map({
                    project: .project,
                    ts: .timestamp,
                    tokens: .total_tokens,
                    prompts: .prompts
                }))
            }
        ' "${USAGE_LOG}" 2>/dev/null)
    else
        stats=$(jq -s '
            {
                sessions: length,
                total_input: (map(.input_tokens) | add // 0),
                total_output: (map(.output_tokens) | add // 0),
                total_cache_create: (map(.cache_creation_tokens) | add // 0),
                total_cache_read: (map(.cache_read_tokens) | add // 0),
                total_tokens: (map(.total_tokens) | add // 0),
                total_cost: (map(.total_cost_usd) | add // 0),
                total_duration: (map(.duration_sec) | add // 0),
                by_project: (group_by(.project) | map({
                    project: .[0].project,
                    sessions: length,
                    tokens: (map(.total_tokens) | add // 0),
                    cost: (map(.total_cost_usd) | add // 0),
                    input: (map(.input_tokens) | add // 0),
                    output: (map(.output_tokens) | add // 0)
                }) | sort_by(-.tokens)),
                recent_prompts: (sort_by(.timestamp) | .[-10:] | map({
                    project: .project,
                    ts: .timestamp,
                    tokens: .total_tokens,
                    prompts: .prompts
                }))
            }
        ' "${USAGE_LOG}" 2>/dev/null)
    fi

    if [[ -z "${stats}" || "${stats}" == "null" ]]; then
        printf "\n  ${C_DIM}No records for this period.${C_RESET}\n\n"
        return
    fi

    local sessions total_input total_output total_cache_create total_cache_read total_tokens total_cost total_duration
    sessions=$(echo "${stats}" | jq -r '.sessions')
    total_input=$(echo "${stats}" | jq -r '.total_input')
    total_output=$(echo "${stats}" | jq -r '.total_output')
    total_cache_create=$(echo "${stats}" | jq -r '.total_cache_create')
    total_cache_read=$(echo "${stats}" | jq -r '.total_cache_read')
    total_tokens=$(echo "${stats}" | jq -r '.total_tokens')
    total_cost=$(echo "${stats}" | jq -r '.total_cost')
    total_duration=$(echo "${stats}" | jq -r '.total_duration')

    # ── Summary ──
    echo ""
    printf "  ${C_BOLD}${period_label}${C_RESET} ${C_DIM}(${sessions} session(s), $(format_duration "$(to_int "${total_duration}" 0)"))${C_RESET}\n"
    echo ""
    printf "  ⬇ Input    ${C_BOLD}$(format_tokens "${total_input}")${C_RESET}\n"
    printf "  ⬆ Output   ${C_BOLD}$(format_tokens "${total_output}")${C_RESET}\n"
    printf "  💾 Cache    ${C_DIM}create $(format_tokens "${total_cache_create}") · read $(format_tokens "${total_cache_read}")${C_RESET}\n"
    printf "  ── Total   ${C_BOLD}${C_CYAN}$(format_tokens "${total_tokens}")${C_RESET}"
    if [[ "${total_cost}" != "0" && "${total_cost}" != "null" ]]; then
        printf " ${C_DIM}(\$$(printf '%.3f' "${total_cost}" 2>/dev/null || echo "${total_cost}"))${C_RESET}"
    fi
    echo ""

    # Average per session
    if (( sessions > 0 )); then
        local avg_tokens=$(( $(to_int "${total_tokens}" 0) / sessions ))
        printf "  ${C_DIM}Avg per session: $(format_tokens "${avg_tokens}")${C_RESET}\n"
    fi

    # ── By project ──
    echo ""
    printf "  ${C_BOLD}By project${C_RESET}\n\n"

    echo "${stats}" | jq -r '.by_project[:10][] | "\(.project)|\(.sessions)|\(.tokens)|\(.input)|\(.output)|\(.cost)"' 2>/dev/null \
    | while IFS='|' read -r proj sess tok inp outp cost; do
        [[ -z "${proj}" ]] && continue
        local cost_str=""
        if [[ "${cost}" != "0" && "${cost}" != "null" ]]; then
            cost_str=" ${C_DIM}\$$(printf '%.3f' "${cost}" 2>/dev/null || echo "${cost}")${C_RESET}"
        fi
        printf "  %-16s " "${proj}"
        printf "${C_CYAN}$(format_tokens "${tok}")${C_RESET}"
        printf " ${C_DIM}(⬇$(format_tokens "${inp}") ⬆$(format_tokens "${outp}"))${C_RESET}"
        printf " ${C_DIM}${sess}s${C_RESET}"
        printf "${cost_str}\n"
    done

    # ── Recent prompts ──
    echo ""
    printf "  ${C_BOLD}Recent prompts${C_RESET}\n\n"

    echo "${stats}" | jq -r '
        .recent_prompts[] |
        .prompts // [] | .[] |
        select(length > 0)
    ' 2>/dev/null | tail -10 | while IFS= read -r prompt; do
        [[ -z "${prompt}" ]] && continue
        # Truncate to 60 chars for display
        local display="${prompt}"
        if (( ${#display} > 60 )); then
            display="${display:0:57}..."
        fi
        printf "  ${C_DIM}•${C_RESET} ${display}\n"
    done

    echo ""
    printf "  ${C_DIM}Period: today(t) week(w) month(m) all(a) YYYY-MM-DD${C_RESET}\n"
    echo ""
}

# ── Command: test (webhook connection test) ──────────────────────────────────
cmd_test() {
    require_jq || return 1

    local webhook_url
    webhook_url=$(get_config '.discord_webhook_url')

    echo ""
    printf "  ${C_BOLD}🔧 Connection test${C_RESET}\n"
    printf "  ${C_DIM}────────────────────────────────────────${C_RESET}\n"
    echo ""

    # Check jq
    printf "  jq          "
    if command -v jq &>/dev/null; then
        printf "${C_GREEN}✓${C_RESET} $(jq --version 2>&1)\n"
    else
        printf "${C_RED}✗${C_RESET} not installed\n"
    fi

    # Check curl
    printf "  curl        "
    if command -v curl &>/dev/null; then
        printf "${C_GREEN}✓${C_RESET} installed\n"
    else
        printf "${C_RED}✗${C_RESET} not installed\n"
    fi

    # Check flock
    printf "  flock       "
    if command -v flock &>/dev/null; then
        printf "${C_GREEN}✓${C_RESET} installed (Linux locking)\n"
    else
        printf "${C_YELLOW}○${C_RESET} not installed (using mkdir locking)\n"
    fi

    # Check state.json
    printf "  state.json  "
    if [[ -f "${STATE_FILE}" ]] && jq empty "${STATE_FILE}" 2>/dev/null; then
        local sess_count
        sess_count=$(jq '.sessions | length' "${STATE_FILE}")
        printf "${C_GREEN}✓${C_RESET} valid (${sess_count} session(s))\n"
    else
        printf "${C_RED}✗${C_RESET} missing or invalid\n"
    fi

    # Check webhook
    printf "  webhook     "
    if [[ -z "${webhook_url}" ]]; then
        printf "${C_RED}✗${C_RESET} not configured\n"
        echo ""
        printf "  ${C_DIM}Set: claude-tracker config webhook <URL>${C_RESET}\n"
    else
        # Actual send test
        local test_payload
        test_payload=$(jq -n \
            --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
            '{embeds: [{
                title: "🔧 Connection test",
                description: "Claude Process Tracker connected successfully!",
                color: 5793266,
                footer: {text: "Test message"},
                timestamp: $ts
            }]}')

        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
            --max-time "${CURL_MAX_TIME}" \
            -H "Content-Type: application/json" \
            -X POST \
            -d "${test_payload}" \
            "${webhook_url}" 2>/dev/null) || http_code="000"

        if [[ "${http_code}" == "204" || "${http_code}" == "200" ]]; then
            printf "${C_GREEN}✓${C_RESET} sent (HTTP ${http_code})\n"
            echo ""
            printf "  ${C_GREEN}Check your Discord channel!${C_RESET}\n"
        else
            printf "${C_RED}✗${C_RESET} failed (HTTP ${http_code})\n"
            echo ""
            printf "  ${C_DIM}Check your URL: claude-tracker config show${C_RESET}\n"
        fi
    fi

    # Check hook registration
    echo ""
    printf "  hooks       "
    local settings="${HOME}/.claude/settings.json"
    if [[ -f "${settings}" ]] && jq -e '.hooks.SessionStart[]?.hooks[]?.command | test("claude-tracker")' "${settings}" >/dev/null 2>&1; then
        printf "${C_GREEN}✓${C_RESET} registered in Claude Code\n"
    else
        printf "${C_RED}✗${C_RESET} not registered\n"
        printf "  ${C_DIM}Run install.sh again${C_RESET}\n"
    fi

    echo ""
}

# ── Command: last-prompt (recover last input prompt) ───────────────────────
cmd_last_prompt() {
    local recovery_file="${TRACKER_DIR}/last-prompt.txt"
    if [[ ! -f "${recovery_file}" ]]; then
        echo ""
        printf "  ${C_DIM}No saved prompts.${C_RESET}\n"
        echo ""
        return 0
    fi

    echo ""
    printf "  ${C_BOLD}${C_CYAN}📋 Last input prompt${C_RESET}\n"
    printf "  ${C_DIM}────────────────────────────────────────────────${C_RESET}\n"
    echo ""
    cat "${recovery_file}"
    echo ""
    printf "  ${C_DIM}File: ${recovery_file}${C_RESET}\n"
    printf "  ${C_DIM}Copy to clipboard: cat ${recovery_file}${C_RESET}\n"
    echo ""
}

# ── Command: reset (reset state) ────────────────────────────────────────────
cmd_reset() {
    echo ""
    printf "  ${C_BOLD}${C_YELLOW}⚠️  Reset state${C_RESET}\n"
    printf "  ${C_DIM}Resets state.json. Configuration is preserved.${C_RESET}\n"
    echo ""
    read -r -p "  Continue? [y/N] " response
    if [[ ! "${response}" =~ ^[Yy]$ ]]; then
        echo "  Cancelled."
        return 0
    fi

    echo '{"sessions": {}, "projects": {}}' > "${STATE_FILE}"
    printf "  ${C_GREEN}✅${C_RESET} State reset.\n\n"
}

# ── Main ────────────────────────────────────────────────────────────────────
init_tracker

COMMAND="${1:-help}"
shift 2>/dev/null || true

case "${COMMAND}" in
    register)   cmd_register ;;
    update)     cmd_update ;;
    prompt)     cmd_prompt ;;
    end)        cmd_end ;;
    s|status)   cmd_status ;;
    scan)       cmd_scan ;;
    d|dashboard) cmd_dashboard ;;
    r|report)   cmd_report "$@" ;;
    snapshot)   write_token_snapshot && printf "  ✅ Snapshot recorded\n" ;;
    w|watch)    cmd_watch "$@" ;;
    m|monitor)  cmd_monitor "$@" ;;
    h|history)  cmd_history ;;
    u|usage)    cmd_usage "$@" ;;
    t|test)     cmd_test ;;
    cleanup)    cmd_cleanup ;;
    resume)     cmd_resume "$@" ;;
    last-prompt|lp) cmd_last_prompt ;;
    bot)        cmd_bot "$@" ;;
    config)     cmd_config "$@" ;;
    reset)      cmd_reset ;;
    upgrade)    cmd_upgrade ;;
    uninstall)  cmd_uninstall ;;
    help)
        echo ""
        printf "  ${C_BOLD}${C_CYAN}🤖 Claude Process Tracker${C_RESET} ${C_DIM}v2.2${C_RESET}\n"
        printf "  ${C_DIM}────────────────────────────────────────────────${C_RESET}\n"
        echo ""
        printf "  ${C_BOLD}Usage${C_RESET}    claude-tracker ${C_DIM}<command>${C_RESET}\n"
        echo ""
        printf "  ${C_BOLD}Monitor${C_RESET}\n"
        printf "    ${C_GREEN}s${C_RESET}  status       all project status\n"
        printf "    ${C_GREEN}w${C_RESET}  watch ${C_DIM}[s]${C_RESET}     real-time monitor (default 5s)\n"
        printf "    ${C_GREEN}m${C_RESET}  monitor ${C_DIM}[s|stop]${C_RESET} background polling (default 60s)\n"
        printf "    ${C_GREEN}h${C_RESET}  history      per-project stats & recent events\n"
        printf "    ${C_GREEN}u${C_RESET}  usage ${C_DIM}[period]${C_RESET} token usage (today/week/month/all)\n"
        printf "    ${C_GREEN}d${C_RESET}  dashboard    send dashboard to Discord\n"
        printf "    ${C_GREEN}r${C_RESET}  report ${C_DIM}[date|send]${C_RESET} token history (30-min snapshots)\n"
        printf "       snapshot          record snapshot immediately\n"
        echo ""
        printf "  ${C_BOLD}Sessions${C_RESET}\n"
        printf "    ${C_CYAN}resume${C_RESET} ${C_DIM}[project]${C_RESET}  resume session (interactive or name search)\n"
        printf "    ${C_CYAN}lp${C_RESET}     last-prompt   recover last prompt (for error recovery)\n"
        echo ""
        printf "  ${C_BOLD}Management${C_RESET}\n"
        printf "    ${C_CYAN}bot${C_RESET}     start|stop|status Discord bot management\n"
        printf "    ${C_CYAN}config${C_RESET}  show              show current config\n"
        printf "    ${C_CYAN}config${C_RESET}  webhook ${C_DIM}<URL>${C_RESET}      set Discord Webhook\n"
        printf "    ${C_CYAN}config${C_RESET}  bot-token ${C_DIM}<TOKEN>${C_RESET}  set Discord bot token\n"
        printf "    ${C_CYAN}config${C_RESET}  alias ${C_DIM}[path] [name]${C_RESET}  project alias (supports ., interactive)\n"
        printf "    ${C_CYAN}config${C_RESET}  notify ${C_DIM}<key> <bool>${C_RESET}  toggle notification\n"
        printf "    ${C_YELLOW}cleanup${C_RESET}                   clean up dead sessions\n"
        printf "    ${C_YELLOW}reset${C_RESET}                     reset state\n"
        printf "    ${C_CYAN}upgrade${C_RESET}                   update to latest version from GitHub\n"
        printf "    ${C_RED}uninstall${C_RESET}                 remove tracker\n"
        echo ""
        printf "  ${C_BOLD}Diagnostics${C_RESET}\n"
        printf "    ${C_GREEN}t${C_RESET}  test         connection & config diagnostics\n"
        echo ""
        printf "  ${C_DIM}Config: ${CONFIG_FILE}${C_RESET}\n"
        printf "  ${C_DIM}Log: ${LOG_FILE}${C_RESET}\n"
        echo ""
        ;;
    *)
        echo ""
        printf "  ${C_RED}Unknown command:${C_RESET} ${COMMAND}\n"
        echo ""

        # Suggest similar commands
        _suggestions=""
        _known_cmds="status watch monitor history usage dashboard report resume cleanup config reset upgrade test uninstall help"
        _first_char="${COMMAND:0:1}"
        for _cmd in ${_known_cmds}; do
            if [[ "${_cmd:0:1}" == "${_first_char}" ]] || [[ "${_cmd}" == *"${COMMAND}"* ]]; then
                _suggestions="${_suggestions} ${_cmd}"
            fi
        done

        if [[ -n "${_suggestions}" ]]; then
            printf "  Did you mean:${C_BOLD}${_suggestions}${C_RESET}?\n"
        fi
        printf "  ${C_DIM}Help: claude-tracker help${C_RESET}\n"
        echo ""
        ;;
esac
