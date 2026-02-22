#!/usr/bin/env bash
# ============================================================================
# Claude Process Tracker v2.2 — Discord 알림 + 프로세스 모니터링
# ============================================================================
# Claude Code Hook에서 자동 호출되어 프로세스를 추적하고 Discord에 알림을 보냄
#
# 사용법:
#   claude-tracker <command> [options]
#
# Commands (Hook 자동):
#   register    — 새 세션 등록 (SessionStart hook)
#   update      — 상태 업데이트 (Stop hook, 디바운싱 적용)
#   end         — 세션 종료 (SessionEnd hook)
#
# Commands (수동):
#   s|status    — 전체 프로젝트 현황 (ANSI 색상)
#   d|dashboard — Discord에 대시보드 embed 전송
#   w|watch     — 실시간 모니터링
#   h|history   — 프로젝트별 통계 & 최근 이벤트
#   t|test      — 연결 & 설정 진단
#   cleanup     — 죽은 세션 정리
#   config      — 설정 관리 (webhook, alias, notify, show)
#   reset       — 상태 초기화
#   uninstall   — 트래커 제거
#
# 안전성:
#   - Hook 커맨드: trap으로 항상 exit 0 (Claude Code 영향 없음)
#   - flock/mkdir 기반 파일 잠금 (Linux/macOS 모두 지원)
#   - jq --arg로 JSON 인젝션 방지
#   - PID 기반 안전한 파일 쓰기 (원자적 mv)
#   - Stop hook 디바운싱 (과다 알림 방지)
# ============================================================================

# 기본 옵션: 수동 커맨드용. Hook 커맨드에서는 trap으로 안전하게 처리.
set -uo pipefail

# Hook 환경에서 jq를 못 찾는 경우 대비: PATH 강제 추가
export PATH="${HOME}/bin:/usr/bin:/usr/local/bin:${PATH}"

# ── 상수 ──────────────────────────────────────────────────────────────────
readonly TRACKER_DIR="${HOME}/.claude-tracker"
readonly STATE_FILE="${TRACKER_DIR}/state.json"
readonly CONFIG_FILE="${TRACKER_DIR}/config.json"
readonly LOG_FILE="${TRACKER_DIR}/tracker.log"
readonly USAGE_LOG="${TRACKER_DIR}/usage.jsonl"
readonly LOCK_FILE="${TRACKER_DIR}/.state.lock"
readonly TOKEN_HISTORY="${TRACKER_DIR}/token-history.jsonl"
readonly CURL_CONNECT_TIMEOUT=5
readonly CURL_MAX_TIME=10
readonly LOG_MAX_BYTES=1048576           # 1MB — 로그 파일 로테이션 기준
readonly TOKEN_HISTORY_MAX_BYTES=10485760  # 10MB — 토큰 히스토리 로테이션 기준
readonly USAGE_LOG_MAX_BYTES=5242880      # 5MB — 사용량 로그 로테이션 기준
readonly ACTIVE_WINDOW_SEC=120            # 2분 — auto-discovered 세션 active/idle 판별
readonly SNAPSHOT_INTERVAL_SEC=1800       # 30분 — 토큰 히스토리 스냅샷 간격

# ── ANSI 색상 (터미널 UX) ────────────────────────────────────────────────
# stdout이 터미널이면 색상 활성화, 파이프/리다이렉트면 비활성화.
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

# ── 초기화 ────────────────────────────────────────────────────────────────
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
        if (( log_size > LOG_MAX_BYTES )); then
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
        echo "[SETUP] config.json 생성됨: ${CONFIG_FILE}" >&2
        echo "[SETUP] Discord Webhook URL을 설정하세요:" >&2
        echo "  claude-tracker config webhook <URL>" >&2
    fi
}

# ── 로깅 ──────────────────────────────────────────────────────────────────
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*" >> "${LOG_FILE}" 2>/dev/null || true
}

# ── jq 가용성 체크 ───────────────────────────────────────────────────────
require_jq() {
    if command -v jq &>/dev/null; then
        return 0
    fi
    log "ERROR" "jq not found (PATH=${PATH})"
    echo "ERROR: jq가 설치되어 있지 않습니다." >&2
    return 1
}

# ── Windows PID 유틸리티 ──────────────────────────────────────────────────
# Git Bash(MSYS2)에서는 kill -0이 Windows PID를 인식 못함.
# tasklist로 Windows PID 생존을 확인하고, wmic으로 부모 체인을 탐색.

# Windows PID가 살아있는지 확인 (tasklist 기반)
_is_win_pid_alive() {
    local pid="$1"
    (( pid > 0 )) || return 1
    tasklist //FI "PID eq ${pid}" //NH < /dev/null 2>/dev/null | grep -q "[0-9]"
}

# 부모 프로세스 체인을 타고 올라가 claude.exe PID를 찾음
# Hook 실행 중에 호출해야 부모 체인이 살아있음
# 실행 중인 claude.exe PID 중 아직 할당되지 않은 것을 반환.
# MSYS2에서는 부모 체인 탐색이 불가 (shim이 즉시 종료)하므로
# tasklist에서 전체 claude.exe PID를 구하고, state.json에서 이미 할당된 PID를 제외.
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

# ── PID 기반 생존 필터 ───────────────────────────────────────────────────
# state에서 PID가 죽은 세션을 제거한 결과를 반환 (메모리만, 저장 안 함)
# PID가 0이거나 없는 세션(auto-discovered 등)도 제거됨
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
            # active_session이 죽은 세션이면 같은 프로젝트의 살아있는 세션으로 교체
            # 주의: with_entries 내부에서 .sessions 접근 불가 → 미리 캡처
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

# ── JSON 헬퍼 ─────────────────────────────────────────────────────────────
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

# 숫자 안전 추출: 비숫자는 기본값으로 대체
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

# 안전한 파일 쓰기: PID 기반 tmp + 실패 시 cleanup
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

# stdin에서 JSON을 안전하게 읽기
read_stdin_json() {
    # bash 변수/파이프 대신 temp file로 직접 전달 (Windows 환경 호환)
    local tmp_json="${TRACKER_DIR}/.stdin_tmp.$$"
    cat > "${tmp_json}" 2>/dev/null

    if [[ ! -s "${tmp_json}" ]]; then
        log "WARN" "stdin empty"
        rm -f "${tmp_json}"
        return 1
    fi

    # \r 제거 (Windows line ending)
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

# ── 파일 잠금────────────────────────────────────────────
# state.json 동시 접근 방지.
# Linux: flock, macOS/BSD: mkdir 기반 원자적 잠금 (POSIX 보장).
with_state_lock() {
    local lock_timeout=5

    if command -v flock &>/dev/null; then
        # Linux: flock 사용
        (
            flock -w "${lock_timeout}" 200 || {
                log "ERROR" "flock timeout (${lock_timeout}s)"
                return 1
            }
            "$@"
        ) 200>"${LOCK_FILE}"
    else
        # macOS/BSD: mkdir 기반 원자적 잠금
        # mkdir은 POSIX에서 원자적 연산으로 보장됨.
        local lock_dir="${LOCK_FILE}.d"
        local deadline=$(( $(date '+%s') + lock_timeout ))

        while ! mkdir "${lock_dir}" 2>/dev/null; do
            if (( $(date '+%s') >= deadline )); then
                # stale lock 체크: lock 소유 프로세스가 죽었으면 해제
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

        # PID 기록 (stale lock 감지용)
        echo $$ > "${lock_dir}/pid" 2>/dev/null

        # FIX: trap으로 시그널(SIGINT/SIGTERM) 시에도 lock 해제 보장
        local _lock_cleanup_done=false
        _release_lock() {
            if [[ "${_lock_cleanup_done}" == "false" ]]; then
                _lock_cleanup_done=true
                rm -rf "${lock_dir}"
            fi
        }
        trap '_release_lock' EXIT INT TERM

        "$@"
        local rc=$?
        _release_lock
        trap - EXIT INT TERM
        return ${rc}
    fi
}

# ── 프로젝트 이름 추출 ───────────────────────────────────────────────────
# 우선순위: config alias > 메타데이터 자동 감지 > basename
_detect_project_name_from_metadata() {
    local dir="$1"

    # package.json → name 필드
    if [[ -f "${dir}/package.json" ]]; then
        local pkg_name
        pkg_name=$(jq -r '.name // empty' "${dir}/package.json" 2>/dev/null)
        if [[ -n "${pkg_name}" ]]; then
            echo "${pkg_name}"
            return
        fi
    fi

    # .git remote → 리포지토리명 추출
    if [[ -d "${dir}/.git" ]]; then
        local remote_url
        remote_url=$(git -C "${dir}" remote get-url origin 2>/dev/null || echo "")
        if [[ -n "${remote_url}" ]]; then
            # https://github.com/user/repo.git 또는 git@github.com:user/repo.git
            local repo_name
            repo_name=$(echo "${remote_url}" | sed 's/\.git$//' | sed 's|.*/||')
            if [[ -n "${repo_name}" ]]; then
                echo "${repo_name}"
                return
            fi
        fi
    fi

    # pyproject.toml → name 필드
    if [[ -f "${dir}/pyproject.toml" ]]; then
        local py_name
        py_name=$(grep -m1 '^name\s*=' "${dir}/pyproject.toml" 2>/dev/null | sed 's/^name\s*=\s*["'"'"']\(.*\)["'"'"']/\1/')
        if [[ -n "${py_name}" ]]; then
            echo "${py_name}"
            return
        fi
    fi

    # Cargo.toml → name 필드
    if [[ -f "${dir}/Cargo.toml" ]]; then
        local cargo_name
        cargo_name=$(grep -m1 '^name\s*=' "${dir}/Cargo.toml" 2>/dev/null | sed 's/^name\s*=\s*["'"'"']\(.*\)["'"'"']/\1/')
        if [[ -n "${cargo_name}" ]]; then
            echo "${cargo_name}"
            return
        fi
    fi

    # go.mod → module 경로의 마지막 세그먼트
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

    # 메타데이터 자동 감지 시도
    local detected
    detected=$(_detect_project_name_from_metadata "${dir}" 2>/dev/null) || true
    if [[ -n "${detected}" ]]; then
        echo "${detected}"
        return
    fi

    basename "${dir}"
}

# ── 시간 포맷팅 ──────────────────────────────────────────────────────────
format_duration() {
    local seconds
    seconds=$(to_int "${1:-0}" 0)

    if (( seconds < 0 )); then
        seconds=0
    fi

    if (( seconds < 60 )); then
        echo "${seconds}초"
    elif (( seconds < 3600 )); then
        echo "$(( seconds / 60 ))분 $(( seconds % 60 ))초"
    else
        echo "$(( seconds / 3600 ))시간 $(( seconds % 3600 / 60 ))분"
    fi
}

# ── 경로 축약 ────────────────────────────────────────────────────────────
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

# ── 종료 사유 한국어 변환 ────────────────────────────────────────────────
localize_reason() {
    case "$1" in
        clear)                       echo "세션 초기화 (/clear)" ;;
        logout)                      echo "로그아웃" ;;
        prompt_input_exit)           echo "사용자 종료 (Ctrl+C)" ;;
        bypass_permissions_disabled) echo "권한 모드 변경" ;;
        context_compact)             echo "컨텍스트 압축 (자동 재시작)" ;;
        session_replaced)            echo "세션 교체 (프로세스 유지)" ;;
        process_exit)                echo "프로세스 종료" ;;
        unknown)                     echo "알 수 없음" ;;
        other)                       echo "기타" ;;
        *)                           echo "$1" ;;
    esac
}

# ── Transcript 토큰 사용량 파싱 ──────────────────────────────────────────
# Claude Code transcript JSONL에서 누적 토큰과 비용 추출.
# 각 라인에 message.usage (input_tokens, output_tokens, cache_*) + costUSD 존재.
# 사용자 프롬프트(type=user)도 추출하여 질문 요약 로그에 활용.
parse_transcript_usage() {
    local transcript_path="$1"

    if [[ ! -f "${transcript_path}" ]]; then
        echo "{}"
        return
    fi

    # 단일 jq 호출로 전체 집계
    # - 토큰: input/output/cache_creation/cache_read 합산
    # - 비용: costUSD 합산
    # - 모델: 마지막 사용 모델
    # - 사용자 질문: type=user인 메시지 중 마지막 3개
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
            # 토큰 집계 (sidechain, error 제외)
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
            # 비용 집계
            | if ($line.costUSD != null) and ($line.costUSD > 0)
              then .total_cost_usd += $line.costUSD
              else . end
            # 사용자 프롬프트 수집
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

# ── CWD → 최신 transcript jsonl 경로 해석 ──────────────────────────────
# CWD 경로에서 Claude projects 디렉토리 내 최신 jsonl 파일을 찾아 반환.
# 못 찾으면 빈 문자열 반환.
_resolve_latest_transcript() {
    local cwd="$1"
    local dir_name
    dir_name=$(echo "${cwd}" | sed 's/[^A-Za-z0-9._-]/-/g')
    local proj_dir="${HOME}/.claude/projects/${dir_name}"

    [[ -d "${proj_dir}" ]] || return 1

    local latest_jsonl
    latest_jsonl=$(ls -t "${proj_dir}"/*.jsonl 2>/dev/null | head -1)
    [[ -z "${latest_jsonl}" ]] && return 1

    echo "${latest_jsonl}"
}

# ── 실시간 토큰 사용량 (실행 중 세션) ──────────────────────────────────
# CWD 경로에서 현재 활성 transcript를 찾아 토큰 합산
get_live_tokens() {
    local cwd="$1"

    local latest_jsonl
    latest_jsonl=$(_resolve_latest_transcript "${cwd}") || { echo "{}"; return; }

    # grep으로 usage 줄만 추출 → jq로 합산 (대용량 파일에서도 빠름)
    grep '"usage"' "${latest_jsonl}" 2>/dev/null | jq -s '
        reduce .[] as $line ({input: 0, output: 0};
            .input += ($line.message.usage.input_tokens // 0) |
            .output += ($line.message.usage.output_tokens // 0)
        ) | .total = .input + .output
    ' 2>/dev/null || echo "{}"
}

# ── 세션 스냅샷 (토큰 + 사용자 프롬프트) ──────────────────────────────
# transcript에서 토큰 합산 + 최근 사용자 프롬프트 추출
get_session_snapshot() {
    local cwd="$1"

    local latest_jsonl
    latest_jsonl=$(_resolve_latest_transcript "${cwd}") || { echo "{}"; return; }

    # 1) 토큰 집계 (usage 줄만)
    local token_data
    token_data=$(grep '"usage"' "${latest_jsonl}" 2>/dev/null | jq -s '
        reduce .[] as $line ({input: 0, output: 0};
            .input += ($line.message.usage.input_tokens // 0) |
            .output += ($line.message.usage.output_tokens // 0)
        ) | .total = .input + .output
    ' 2>/dev/null) || token_data='{"input":0,"output":0,"total":0}'

    # 2) 사용자 프롬프트 추출
    # userType=external인 실제 사용자 입력만 추출 (시스템/tool 메시지 제외)
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

    # 합침
    echo "${token_data}" | jq --argjson prompts "${prompts}" '. + {prompts: $prompts}' 2>/dev/null || echo "{}"
}

# ── 토큰 히스토리 스냅샷 기록 ────────────────────────────────────────
# 30분마다 호출: 각 프로젝트의 토큰 + 프롬프트 요약을 token-history.jsonl에 저장
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

    # 로테이션: 10MB 초과 시 최근 2000줄 유지
    if [[ -f "${TOKEN_HISTORY}" ]]; then
        local fsize
        fsize=$(wc -c < "${TOKEN_HISTORY}" 2>/dev/null || echo 0)
        if (( fsize > TOKEN_HISTORY_MAX_BYTES )); then
            tail -n 2000 "${TOKEN_HISTORY}" > "${TOKEN_HISTORY}.tmp.$$" && mv "${TOKEN_HISTORY}.tmp.$$" "${TOKEN_HISTORY}"
        fi
    fi

    log "INFO" "snapshot:written $(date '+%H:%M')"
}

# ── 토큰 사용량 포맷팅 ──────────────────────────────────────────────────
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

# ── 사용량 로그 기록 (JSONL) ─────────────────────────────────────────────
# usage.jsonl에 세션별 토큰/비용/질문 기록.
# 나중에 cmd_usage에서 집계용으로 사용.

# FIX: 기존 log_usage는 내부에서 parse_transcript_usage를 호출하지만,
# cmd_end에서도 별도로 호출하여 이중 파싱이 발생함.
# log_usage_from_parsed: 이미 파싱된 usage JSON을 직접 받아 기록.
_log_usage_entry() {
    local project="$1"
    local session_id="$2"
    local duration_sec="$3"
    local usage="$4"

    if [[ -z "${usage}" || "${usage}" == "{}" ]]; then
        log "WARN" "usage: 파싱 데이터 없음"
        return
    fi

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

    # usage.jsonl 로테이션: 5MB 초과 시 최근 1000줄 유지
    if [[ -f "${USAGE_LOG}" ]]; then
        local usage_size
        usage_size=$(wc -c < "${USAGE_LOG}" 2>/dev/null || echo 0)
        if (( usage_size > USAGE_LOG_MAX_BYTES )); then
            tail -n 1000 "${USAGE_LOG}" > "${USAGE_LOG}.tmp.$$" && mv "${USAGE_LOG}.tmp.$$" "${USAGE_LOG}"
        fi
    fi
}

log_usage_from_parsed() {
    local project="$1"
    local session_id="$2"
    local duration_sec="$3"
    local usage="$4"
    _log_usage_entry "${project}" "${session_id}" "${duration_sec}" "${usage}"
}

log_usage() {
    local project="$1"
    local session_id="$2"
    local duration_sec="$3"
    local transcript_path="$4"

    local usage
    usage=$(parse_transcript_usage "${transcript_path}")
    _log_usage_entry "${project}" "${session_id}" "${duration_sec}" "${usage}"
}


# ── Discord: 전송 ────────────────────────────────────────────────────────
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


    # 임시 파일 기반 전송 (Windows curl 인코딩 문제 회피)
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
        return 0  # 알림 실패가 전체를 멈추면 안 됨
    }

    rm -f "${tmp_payload}"

    if [[ "${http_code}" -ge 400 ]]; then
        log "WARN" "Discord returned HTTP ${http_code}"
    fi
}

# ── Discord: 안전한 알림 빌더──────────────────────
# jq 한 번 호출로 전체 payload를 빌드. 인젝션 원천 차단.
send_embed() {
    local title="$1"
    local color="$2"
    local notify_key="$3"
    shift 3

    # 알림 활성화 확인 (notify_key가 비어있으면 항상 전송)
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

    send_embed "🟢 세션 시작" 5763719 "on_start" \
        "프로젝트" "\`${project}\`" \
        "동시 실행" "${active_total}개 프로젝트" \
        "경로" "\`${short_cwd}\`" --noinline
    log "INFO" "notify:start ${project}"
}

notify_complete() {
    local project="$1" session_id="$2" duration="$3"

    send_embed "✅ 작업 완료" 3066993 "on_complete" \
        "프로젝트" "\`${project}\`" \
        "소요 시간" "${duration}"
    log "INFO" "notify:complete ${project}"
}

# 종료 사유에 따른 알림 스타일 반환 (emoji|title|color)
_get_end_notification_style() {
    local reason="$1"
    local emoji="🔴" title="세션 종료" color=15158332
    case "${reason}" in
        clear)                       emoji="🧹"; title="세션 클리어";       color=10070709 ;;
        logout)                      emoji="👋"; title="로그아웃";          color=10070709 ;;
        prompt_input_exit)           emoji="⏸️";  title="사용자 종료";       color=16776960 ;;
        bypass_permissions_disabled) emoji="🔒"; title="권한 모드 변경";     color=16744576 ;;
        context_compact)             emoji="🔄"; title="컨텍스트 압축";      color=3447003 ;;
        session_replaced)            emoji="🔁"; title="세션 교체";          color=3447003 ;;
        process_exit)                emoji="💀"; title="프로세스 종료";       color=15158332 ;;
    esac
    echo "${emoji}|${title}|${color}"
}

notify_end() {
    local project="$1" session_id="$2" reason="$3" duration="$4"

    local style emoji title color
    style=$(_get_end_notification_style "${reason}")
    IFS='|' read -r emoji title color <<< "${style}"

    send_embed "${emoji} ${title}" "${color}" "" \
        "프로젝트" "\`${project}\`" \
        "종료 사유" "$(localize_reason "${reason}")" \
        "세션 시간" "${duration}"
    log "INFO" "notify:end ${project} (${reason})"
}

notify_end_with_tokens() {
    local project="$1" session_id="$2" reason="$3" duration="$4"
    local input_t="$5" output_t="$6" total_t="$7" cost_str="${8:-}"

    local style emoji title color
    style=$(_get_end_notification_style "${reason}")
    IFS='|' read -r emoji title color <<< "${style}"

    send_embed "${emoji} ${title}" "${color}" "" \
        "프로젝트" "\`${project}\`" \
        "종료 사유" "$(localize_reason "${reason}")" \
        "세션 시간" "${duration}" \
        "토큰" "⬇${input_t} ⬆${output_t} = ${total_t}${cost_str}"
    log "INFO" "notify:end ${project} (${reason}, tokens=${total_t})"
}

# ── 세션 제거 공통 함수 ──────────────────────────────────────────
# 같은 프로젝트의 다른 세션이 남아있으면 그쪽으로 active_session을 이전.
remove_session_from_state() {
    local state="$1" session_id="$2" project_name="$3"

    echo "${state}" | jq \
        --arg sid "${session_id}" \
        --arg proj "${project_name}" \
        'del(.sessions[$sid]) |
         if .projects[$proj].active_session == $sid then
            # 같은 프로젝트에 남아있는 다른 세션 찾기
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

# ── 커맨드: register (SessionStart hook) ─────────────────────────────────
# Hook 커맨드는 trap으로 항상 exit 0 보장
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

    # Windows PID 체인을 타고 올라가 claude.exe PID를 찾음.
    # Git Bash에서 $PPID는 MSYS PID이므로 kill -0으로 Windows 프로세스를 추적할 수 없음.
    # wmic으로 부모 체인을 탐색하여 실제 claude.exe의 Windows PID를 기록.
    local claude_pid
    claude_pid=$(_find_claude_pid)

    if with_state_lock _register_impl "${session_id}" "${project_name}" "${cwd}" "${now}" "${transcript_path}" "${claude_pid}"; then
        notify_start "${project_name}" "${session_id}" "${cwd}"
        log "INFO" "session:register ${project_name} (${session_id})"
        # SessionStart: stdout → Claude context
        echo "📊 프로젝트 트래커 활성화됨: ${project_name}"
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

# ── 커맨드: update (Stop hook) ───────────────────────────────────────────
# Stop hook은 매 응답 완료 시 호출되므로 디바운싱 적용.
# config의 idle_threshold_minutes를 쿨다운으로 활용 (기본 10분).
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

    # 세션이 미등록이면 자동 등록 (SessionStart hook 실패 시 복구)
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

    # 디바운싱
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

# ── 커맨드: end (SessionEnd hook) ────────────────────────────────────────
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

    # "other" reason 구체화: 컨텍스트로 추론
    if [[ "${reason}" == "other" ]]; then
        # source 필드가 있으면 활용 (compact 등)
        if [[ "${source_field}" == "compact" ]]; then
            reason="context_compact"
        else
            # PID 확인: 프로세스가 아직 살아있으면 세션 교체, 죽었으면 비정상 종료
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

        # 토큰 사용량 기록
        if [[ -n "${transcript_path}" ]]; then
            # FIX: parse_transcript_usage 이중 호출 제거 — 한 번 파싱 후 재사용
            local usage_summary
            usage_summary=$(parse_transcript_usage "${transcript_path}")
            log_usage_from_parsed "${project_name}" "${session_id}" "${duration_sec}" "${usage_summary}"
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

    # 단일 jq로 세션 정보 추출 (transcript_path 포함)
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

    local duration="알 수 없음"
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

# ── 커맨드: scan (즉시 프로세스 스캔 → state 갱신) ─────────────────────
cmd_scan() {
    require_jq || return 1
    local now
    now=$(date '+%s')
    _monitor_discover_and_save "${now}" "${ACTIVE_WINDOW_SEC}"
    _monitor_update_live_tokens 2>/dev/null || true
}

# ── 커맨드: status ──────────────────────────────────────────────────────
# PID 기반: 살아있는 프로세스만 표시.
#   ● 초록 = hook 등록 + active + PID 살아있음
#   ◐ 노랑 = hook 등록 + idle   + PID 살아있음
#   PID 죽음 = 표시하지 않음
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
        printf "  ${C_DIM}실행 중인 인스턴스가 없습니다.${C_RESET}\n"
        echo ""
        return
    fi

    echo ""
    if (( active_count > 0 )); then
        printf "  ${C_BG_GREEN}${C_WHITE}${C_BOLD} ${active_count} 활성 ${C_RESET}"
    fi
    if (( idle_count > 0 )); then
        printf "  ${C_BG_YELLOW}${C_WHITE}${C_BOLD} ${idle_count} 대기 ${C_RESET}"
    fi
    echo ""

    echo ""
    printf "  ${C_DIM}%-2s %-18s %-12s %-8s${C_RESET}\n" "" "프로젝트" "마지막 활동" "작업"
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
                time_str="방금"; time_color="${C_GREEN}"
            elif (( elapsed < 3600 )); then
                time_str="$(( elapsed / 60 ))분 전"; time_color="${C_GREEN}"
            elif (( elapsed < 86400 )); then
                time_str="$(( elapsed / 3600 ))시간 전"; time_color="${C_YELLOW}"
            else
                time_str="$(( elapsed / 86400 ))일 전"; time_color="${C_RED}"
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
        # 같은 프로젝트에 여러 세션이면 세션 수 표시
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
        printf "%-6s\n" "${stop_count}회"

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

# ── 커맨드: dashboard ────────────────────────────────────────────
# jq로 한 번에 embed 전체를 빌드 (수동 문자열 연결 제거)
cmd_dashboard() {
    require_jq || return 1

    local state
    state=$(_filter_alive_sessions "$(get_state)")

    # 오늘자 토큰 사용량 집계 (usage.jsonl에서)
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
            description: ("`" + ($now | strftime("%Y-%m-%d %H:%M:%S")) + "` 기준 실시간 현황"),
            color: (if ([.sessions[] | select(.status == "active")] | length) > 0
                    then 3066993 else 16776960 end),
            fields: (
                # ── 프로젝트별 상태 ──
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
                        (if .status == "active" then "**작업 중**"
                         else "대기" end)
                        + " · 에이전트 " + (.agents | tostring) + "개"
                        + "\n"
                        + (if .last == 0 then "⏱ --"
                           else (($now - .last) |
                                 if . < 60 then "⏱ \(.)초 전"
                                 elif . < 3600 then "⏱ \(./60|floor)분 전"
                                 else "⏱ \(./3600|floor)시간 전" end)
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

                # ── 빈 필드 (3열 정렬용) ──
                + (if (([.sessions | to_entries | length] | .[0]) % 3 == 2) then
                    [{name: "\u200b", value: "\u200b", inline: true}]
                   else [] end)

                # ── 구분선 ──
                + [{name: "\u200b", value: "━━━━━━━━━━━━━━━━━━━━", inline: false}]

                # ── 현황 요약 ──
                + [{
                    name: "📊 현황",
                    value: (
                        "🟢 작업 중 **" + ([.sessions[] | select(.status == "active")] | length | tostring) + "**"
                        + " · 🟡 대기 **" + ([.sessions[] | select(.status == "idle")] | length | tostring) + "**"
                        + " · 전체 **" + (.projects | length | tostring) + "**개 프로젝트"
                        + "\n에이전트 총 **" + ([.sessions[].agent_count // 0] | add // 0 | tostring) + "**개"
                    ),
                    inline: false
                }]

                # ── 실시간 토큰 (활성 세션) ──
                + (
                    ([.sessions[] | .live_total_tokens // 0] | add // 0) as $live_total |
                    ([.sessions[] | .live_input_tokens // 0] | add // 0) as $live_input |
                    ([.sessions[] | .live_output_tokens // 0] | add // 0) as $live_output |
                    if $live_total > 0 then
                    [{
                        name: "🔤 실시간 토큰 (활성 세션)",
                        value: (
                            "입력 **" + ($live_input |
                                if . >= 1000000 then "\(. / 1000000 * 10 | floor / 10)M"
                                elif . >= 1000 then "\(. / 1000 | floor)K"
                                else "\(.)" end) + "**"
                            + " · 출력 **" + ($live_output |
                                if . >= 1000000 then "\(. / 1000000 * 10 | floor / 10)M"
                                elif . >= 1000 then "\(. / 1000 | floor)K"
                                else "\(.)" end) + "**"
                            + " · 합계 **" + ($live_total |
                                if . >= 1000000 then "\(. / 1000000 * 10 | floor / 10)M"
                                elif . >= 1000 then "\(. / 1000 | floor)K"
                                else "\(.)" end) + "**"
                        ),
                        inline: false
                    }]
                    else [] end
                )

                # ── 완료된 세션 토큰 (오늘) ──
                + (if ($usage.total_tokens // 0) > 0 then
                    [{
                        name: "💰 완료 세션 토큰 (오늘)",
                        value: (
                            "입력 **" + (($usage.total_input // 0) |
                                if . >= 1000000 then "\(. / 1000000 * 10 | floor / 10)M"
                                elif . >= 1000 then "\(. / 1000 | floor)K"
                                else "\(.)" end) + "**"
                            + " · 출력 **" + (($usage.total_output // 0) |
                                if . >= 1000000 then "\(. / 1000000 * 10 | floor / 10)M"
                                elif . >= 1000 then "\(. / 1000 | floor)K"
                                else "\(.)" end) + "**"
                            + " · 합계 **" + (($usage.total_tokens // 0) |
                                if . >= 1000000 then "\(. / 1000000 * 10 | floor / 10)M"
                                elif . >= 1000 then "\(. / 1000 | floor)K"
                                else "\(.)" end) + "**"
                            + "\n💵 $" + (($usage.total_cost // 0) * 100 | floor / 100 | tostring)
                            + " · " + (($usage.sessions // 0) | tostring) + "개 세션 완료"
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
    printf "  ${C_GREEN}✅${C_RESET} 대시보드가 Discord에 전송되었습니다.\n\n"
}

# ── 커맨드: report (토큰 히스토리 조회 / Discord 전송) ─────────────
# report [날짜|today|week|send]
#   report          — 오늘 기록 조회
#   report 2026-02-13 — 특정 날짜
#   report week     — 최근 7일
#   report send     — 오늘 기록 Discord 전송
cmd_report() {
    require_jq || return 1

    local arg="${1:-today}"

    if [[ ! -f "${TOKEN_HISTORY}" ]]; then
        echo ""
        printf "  ${C_DIM}토큰 히스토리가 없습니다.${C_RESET}\n"
        printf "  ${C_DIM}모니터가 30분마다 자동으로 기록합니다.${C_RESET}\n\n"
        return
    fi

    # Discord 전송 모드
    if [[ "${arg}" == "send" ]]; then
        _report_send "${2:-today}"
        return
    fi

    # 날짜 필터 결정
    local date_filter period_label=""
    date_filter=$(_resolve_date_filter "${arg}")
    case "${arg}" in
        today|t) period_label="오늘 (${date_filter})" ;;
        week|w)  period_label="최근 7일" ;;
        all|a)   period_label="전체" ;;
        *)       period_label="${arg} 이후" ;;
    esac

    echo ""
    printf "  ${C_BOLD}${C_CYAN}📋 토큰 히스토리${C_RESET} ${C_DIM}— ${period_label}${C_RESET}\n"
    printf "  ${C_DIM}────────────────────────────────────────${C_RESET}\n\n"

    # 데이터 집계: 날짜별 > 프로젝트별 토큰 + 프롬프트
    local report
    if [[ -n "${date_filter}" ]]; then
        report=$(jq -s --arg since "${date_filter}" '
            [.[] | select(.date >= $since)]
        ' "${TOKEN_HISTORY}" 2>/dev/null)
    else
        report=$(jq -s '.' "${TOKEN_HISTORY}" 2>/dev/null)
    fi

    if [[ -z "${report}" || "${report}" == "[]" ]]; then
        printf "  ${C_DIM}해당 기간에 기록이 없습니다.${C_RESET}\n\n"
        return
    fi

    # 날짜별 그룹핑 → 프로젝트별 최대 토큰 정렬
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
            "  토큰: " + (.max_tokens |
                if . >= 1000000 then "\(. / 1000000 * 10 | floor / 10)M"
                elif . >= 1000 then "\(. / 1000 | floor)K"
                else "\(.)" end) +
            " (스냅샷 " + (.snapshots | tostring) + "회)",
            (.prompts[:3][] |
                "      💬 " + (.[0:80]) +
                (if length > 80 then "…" else "" end)
            )
        ),
        ""
    ' 2>/dev/null

    echo ""
    printf "  ${C_DIM}Discord 전송: claude-tracker report send${C_RESET}\n\n"
}

# 기간 문자열 → 날짜 필터 변환 (report 및 _report_send 공용)
_resolve_date_filter() {
    local arg="${1:-today}"
    case "${arg}" in
        today|t)  date '+%Y-%m-%d' ;;
        week|w)   date -d '7 days ago' '+%Y-%m-%d' 2>/dev/null || date -v-7d '+%Y-%m-%d' 2>/dev/null || echo "" ;;
        month|m)  date -d '30 days ago' '+%Y-%m-%d' 2>/dev/null || date -v-30d '+%Y-%m-%d' 2>/dev/null || echo "" ;;
        all|a)    echo "" ;;
        *)        echo "${arg}" ;;
    esac
}

# report를 Discord embed로 전송
_report_send() {
    local period="${1:-today}"
    local date_filter
    date_filter=$(_resolve_date_filter "${period}")

    local data
    if [[ -n "${date_filter}" ]]; then
        data=$(jq -s --arg since "${date_filter}" '[.[] | select(.date >= $since)]' "${TOKEN_HISTORY}" 2>/dev/null)
    else
        data=$(jq -s '.' "${TOKEN_HISTORY}" 2>/dev/null)
    fi

    if [[ -z "${data}" || "${data}" == "[]" ]]; then
        printf "  ${C_DIM}전송할 기록이 없습니다.${C_RESET}\n"
        return
    fi

    local payload
    payload=$(echo "${data}" | jq \
        --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg footer "Claude Process Tracker" \
        --arg title "📋 토큰 히스토리 리포트" \
    '{
        embeds: [{
            title: $title,
            color: 3447003,
            fields: (
                # 날짜별 그룹 → 프로젝트별 집계
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
                # 전체 요약
                + [{
                    name: "📊 전체 요약",
                    value: (
                        "프로젝트 **" + ([.[].project] | unique | length | tostring) + "**개" +
                        " · 최대 토큰 **" + ([.[].total_tokens] | max |
                            if . >= 1000000 then "\(. / 1000000 * 10 | floor / 10)M"
                            elif . >= 1000 then "\(. / 1000 | floor)K"
                            else "\(.)" end) + "**" +
                        " · 스냅샷 **" + (length | tostring) + "**회"
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
    printf "  ${C_GREEN}✅${C_RESET} 리포트가 Discord에 전송되었습니다.\n\n"
}

# ── 커맨드: cleanup ──────────────────────────────────────────────
cmd_cleanup() {
    require_jq || return 1

    # cleanup 임계값: cleanup_threshold_minutes (기본 30분)
    # idle_threshold_minutes(디바운싱)와 별도
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
        printf "  ${C_GREEN}✅${C_RESET} ${cleaned}개 세션 정리됨\n"
    else
        printf "  ${C_DIM}정리할 세션이 없습니다.${C_RESET}\n"
    fi
}

# ── 커맨드: resume (세션 재개) ─────────────────────────────────────────
cmd_resume() {
    require_jq || return 1

    local filter="${1:-}"
    local state
    state=$(get_state)
    local now
    now=$(date '+%s')

    # 활성/유휴 세션 수집
    local sids=() projects=() cwds=() statuses=() started_ats=() last_activities=()

    while IFS='|' read -r sid project cwd status started_at last_activity; do
        [[ -z "${sid}" ]] && continue
        # active 또는 idle 세션만
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
        printf "  ${C_DIM}재개할 수 있는 세션이 없습니다.${C_RESET}\n"
        printf "  ${C_DIM}활성 또는 대기 중인 세션만 재개할 수 있습니다.${C_RESET}\n"
        echo ""
        return 0
    fi

    # 프로젝트명 필터 (부분 일치)
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
            printf "  ${C_RED}일치하는 세션이 없습니다:${C_RESET} ${filter}\n"
            return 1
        elif (( match_count == 1 )); then
            _resume_session "${sids[$matched_idx]}" "${projects[$matched_idx]}" "${cwds[$matched_idx]}"
            return $?
        fi
        # 여러 개 일치 시 목록 표시 (아래로 계속)
    fi

    # 대화형 세션 선택
    echo ""
    printf "  ${C_BOLD}${C_CYAN}세션 재개${C_RESET}\n"
    printf "  ${C_DIM}────────────────────────────────────────${C_RESET}\n"
    echo ""

    for i in "${!sids[@]}"; do
        # 필터가 있으면 일치하는 것만 표시
        if [[ -n "${filter}" ]] && [[ "${projects[$i]}" != *"${filter}"* ]]; then
            continue
        fi

        local icon color
        case "${statuses[$i]}" in
            active) icon="●"; color="${C_GREEN}" ;;
            idle)   icon="◐"; color="${C_YELLOW}" ;;
            *)      icon="○"; color="${C_DIM}" ;;
        esac

        # 경과 시간
        local last_act
        last_act=$(to_int "${last_activities[$i]}" 0)
        local elapsed_str="--"
        if (( last_act > 0 )); then
            local elapsed=$(( now - last_act ))
            if (( elapsed < 60 )); then
                elapsed_str="방금"
            elif (( elapsed < 3600 )); then
                elapsed_str="$(( elapsed / 60 ))분 전"
            elif (( elapsed < 86400 )); then
                elapsed_str="$(( elapsed / 3600 ))시간 전"
            else
                elapsed_str="$(( elapsed / 86400 ))일 전"
            fi
        fi

        # 실행 시간
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
    printf "  번호 선택 (q=취소): "
    read -r selection

    if [[ "${selection}" == "q" || -z "${selection}" ]]; then
        printf "  ${C_DIM}취소됨${C_RESET}\n"
        return 0
    fi

    if ! [[ "${selection}" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > ${#sids[@]} )); then
        printf "  ${C_RED}잘못된 번호입니다.${C_RESET}\n"
        return 1
    fi

    local idx=$((selection - 1))
    _resume_session "${sids[$idx]}" "${projects[$idx]}" "${cwds[$idx]}"
}

_resume_session() {
    local sid="$1" project="$2" cwd="$3"

    # 디렉토리 존재 확인
    if [[ -n "${cwd}" ]] && [[ ! -d "${cwd}" ]]; then
        printf "  ${C_RED}디렉토리가 존재하지 않습니다:${C_RESET} ${cwd}\n"
        return 1
    fi

    echo ""
    printf "  ${C_GREEN}▶${C_RESET} ${C_BOLD}${project}${C_RESET} 세션 재개 중...\n"

    if [[ "${sid}" == auto-* ]]; then
        # Auto-discovered 세션: --continue 사용
        printf "  ${C_DIM}cd ${cwd} && claude --continue${C_RESET}\n"
        echo ""
        cd "${cwd}" && exec claude --continue
    else
        # Hook 등록 세션: --resume 사용
        printf "  ${C_DIM}cd ${cwd} && claude --resume ${sid}${C_RESET}\n"
        echo ""
        cd "${cwd}" && exec claude --resume "${sid}"
    fi
}

# ── 커맨드: bot (Discord Bot 관리) ────────────────────────────────────
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
                    printf "  ${C_YELLOW}⚠${C_RESET} 봇이 이미 실행 중입니다 (PID ${old_pid})\n"
                    printf "  ${C_DIM}중지: claude-tracker bot stop${C_RESET}\n"
                    return 0
                fi
                rm -f "${bot_pidfile}"
            fi

            if [[ ! -f "${bot_dir}/bot.js" ]]; then
                printf "  ${C_RED}❌${C_RESET} bot.js를 찾을 수 없습니다\n"
                return 1
            fi

            if [[ ! -d "${bot_dir}/node_modules" ]]; then
                printf "  ${C_DIM}의존성 설치 중...${C_RESET}\n"
                (cd "${bot_dir}" && npm install --silent 2>&1) || {
                    printf "  ${C_RED}❌${C_RESET} npm install 실패\n"
                    return 1
                }
            fi

            local bot_token
            bot_token=$(get_config '.bot_token')
            if [[ -z "${bot_token}" ]]; then
                printf "  ${C_RED}❌${C_RESET} bot_token이 설정되지 않았습니다\n"
                printf "  ${C_DIM}설정: claude-tracker config bot-token <TOKEN>${C_RESET}\n"
                return 1
            fi

            # 백그라운드 실행
            node "${bot_dir}/bot.js" >> "${TRACKER_DIR}/bot.log" 2>&1 &
            local bot_pid=$!
            echo "${bot_pid}" > "${bot_pidfile}"

            sleep 2
            if kill -0 "${bot_pid}" 2>/dev/null; then
                printf "  ${C_GREEN}✅${C_RESET} 봇 시작 (PID ${bot_pid})\n"
                printf "  ${C_DIM}중지: claude-tracker bot stop${C_RESET}\n"
                printf "  ${C_DIM}로그: tail -f ${TRACKER_DIR}/bot.log${C_RESET}\n"
            else
                printf "  ${C_RED}❌${C_RESET} 봇 시작 실패\n"
                printf "  ${C_DIM}로그 확인: cat ${TRACKER_DIR}/bot.log${C_RESET}\n"
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
                    printf "  ${C_GREEN}✅${C_RESET} 봇 중지됨\n"
                else
                    rm -f "${bot_pidfile}"
                    printf "  ${C_DIM}봇이 이미 중지되어 있습니다.${C_RESET}\n"
                fi
            else
                printf "  ${C_DIM}실행 중인 봇이 없습니다.${C_RESET}\n"
            fi
            ;;

        status|*)
            if [[ -f "${bot_pidfile}" ]]; then
                local pid
                pid=$(cat "${bot_pidfile}")
                if kill -0 "${pid}" 2>/dev/null; then
                    printf "  ${C_GREEN}●${C_RESET} 봇 실행 중 (PID ${pid})\n"
                else
                    rm -f "${bot_pidfile}"
                    printf "  ${C_RED}●${C_RESET} 봇 중지됨 (PID 파일 정리)\n"
                fi
            else
                printf "  ${C_DIM}●${C_RESET} 봇 미실행\n"
                printf "  ${C_DIM}시작: claude-tracker bot start${C_RESET}\n"
            fi
            ;;
    esac
}

# ── 인터랙티브 alias 선택 ──────────────────────────────────────────────
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
        # 기존 alias 확인
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
        printf "  ${C_DIM}등록된 프로젝트가 없습니다.${C_RESET}\n"
        return 1
    fi

    echo ""
    printf "  ${C_BOLD}${C_CYAN}프로젝트 목록${C_RESET}\n"
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
    printf "  번호 선택 (q=취소): "
    read -r selection

    if [[ "${selection}" == "q" || -z "${selection}" ]]; then
        printf "  ${C_DIM}취소됨${C_RESET}\n"
        return 0
    fi

    if ! [[ "${selection}" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > ${#projects[@]} )); then
        printf "  ${C_RED}잘못된 번호입니다.${C_RESET}\n"
        return 1
    fi

    local idx=$((selection - 1))
    local selected_cwd="${cwds[$idx]}"
    local selected_name="${projects[$idx]}"

    printf "  별칭 입력 (${C_DIM}현재: ${selected_name}${C_RESET}): "
    read -r new_alias

    if [[ -z "${new_alias}" ]]; then
        printf "  ${C_DIM}취소됨${C_RESET}\n"
        return 0
    fi

    local config
    config=$(cat "${CONFIG_FILE}")
    safe_write_json "${CONFIG_FILE}" \
        "$(echo "${config}" | jq --arg dir "${selected_cwd}" --arg name "${new_alias}" '.project_aliases[$dir] = $name')"
    printf "  ${C_GREEN}✅${C_RESET} ${C_BOLD}${new_alias}${C_RESET} ← ${C_DIM}${selected_cwd}${C_RESET}\n"
}

# ── 경로 정규화 헬퍼 ──────────────────────────────────────────────────
_resolve_path() {
    local dir="$1"

    if [[ -z "${dir}" ]]; then
        echo ""
        return
    fi

    # "." → 현재 디렉토리
    if [[ "${dir}" == "." ]]; then
        pwd
        return
    fi

    # ~ 확장
    if [[ "${dir}" == "~"* ]]; then
        dir="${HOME}${dir:1}"
    fi

    # Windows 절대 경로 (C:/ 등)는 그대로 사용
    if [[ "${dir}" =~ ^[A-Za-z]:[\\/] ]]; then
        # 백슬래시 → 슬래시 정규화
        echo "${dir}" | sed 's|\\|/|g'
        return
    fi

    # 상대경로 → 절대경로
    if [[ "${dir}" != /* ]]; then
        if [[ -d "${dir}" ]]; then
            (cd "${dir}" && pwd)
            return
        fi
    fi

    echo "${dir}"
}

# ── 커맨드: config ──────────────────────────────────────────────────────
cmd_config() {
    require_jq || return 1

    local action="${1:-show}"

    case "${action}" in
        webhook)
            local url="${2:-}"
            if [[ -z "${url}" ]]; then
                echo "사용법: claude-tracker config webhook <URL>" >&2
                return 1
            fi
            local config
            config=$(cat "${CONFIG_FILE}")
            safe_write_json "${CONFIG_FILE}" \
                "$(echo "${config}" | jq --arg url "${url}" '.discord_webhook_url = $url')"
            printf "  ${C_GREEN}✅${C_RESET} Discord Webhook URL 설정 완료\n"
            printf "  ${C_DIM}테스트: claude-tracker test${C_RESET}\n"
            ;;
        alias)
            local dir="${2:-}"
            local name="${3:-}"
            # 인수 없이 호출 → 인터랙티브 모드
            if [[ -z "${dir}" ]]; then
                _config_alias_interactive
                return $?
            fi
            if [[ -z "${name}" ]]; then
                printf "  사용법: claude-tracker config alias <경로> <별칭>\n" >&2
                printf "         claude-tracker config alias ${C_DIM}(인터랙티브)${C_RESET}\n" >&2
                printf "  예시: claude-tracker config alias . 내프로젝트\n" >&2
                return 1
            fi
            # 경로 정규화
            local resolved_dir
            resolved_dir=$(_resolve_path "${dir}")
            if [[ "${resolved_dir}" != "${dir}" ]]; then
                printf "  ${C_DIM}경로: ${dir} → ${resolved_dir}${C_RESET}\n"
            fi
            local config
            config=$(cat "${CONFIG_FILE}")
            safe_write_json "${CONFIG_FILE}" \
                "$(echo "${config}" | jq --arg dir "${resolved_dir}" --arg name "${name}" '.project_aliases[$dir] = $name')"
            printf "  ${C_GREEN}✅${C_RESET} 프로젝트 alias 설정: ${C_BOLD}${name}${C_RESET} ← ${C_DIM}${resolved_dir}${C_RESET}\n"
            ;;
        show)
            echo ""
            printf "  ${C_BOLD}${C_CYAN}⚙️  현재 설정${C_RESET}\n"
            printf "  ${C_DIM}────────────────────────────────────────${C_RESET}\n"
            echo ""

            local wh_status
            wh_status=$(get_config '.discord_webhook_url')
            if [[ -n "${wh_status}" ]]; then
                printf "  Discord Webhook  ${C_GREEN}✓ 설정됨${C_RESET}\n"
            else
                printf "  Discord Webhook  ${C_RED}✗ 미설정${C_RESET}\n"
            fi

            local dash_wh
            dash_wh=$(get_config '.dashboard_channel_webhook')
            if [[ -n "${dash_wh}" ]]; then
                printf "  대시보드 Webhook ${C_GREEN}✓ 설정됨${C_RESET}\n"
            else
                printf "  대시보드 Webhook ${C_DIM}○ 미설정 (선택)${C_RESET}\n"
            fi

            echo ""
            printf "  ${C_BOLD}알림 설정${C_RESET}\n"
            local notif_keys=("on_start:시작" "on_complete:완료" "on_error:에러" "on_idle:유휴")
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
            printf "    디바운싱: ${C_BOLD}${idle_min:-10}분${C_RESET}\n"

            echo ""
            local alias_count
            alias_count=$(jq '.project_aliases | length' "${CONFIG_FILE}" 2>/dev/null || echo 0)
            if (( alias_count > 0 )); then
                printf "  ${C_BOLD}프로젝트 별칭${C_RESET} (${alias_count}개)\n"
                jq -r '.project_aliases | to_entries[] | "    \(.value)  ← \(.key)"' "${CONFIG_FILE}" 2>/dev/null
            else
                printf "  ${C_DIM}프로젝트 별칭: 없음${C_RESET}\n"
            fi

            echo ""
            local bt
            bt=$(get_config '.bot_token')
            if [[ -n "${bt}" ]]; then
                printf "  Bot Token        ${C_GREEN}✓ 설정됨${C_RESET}\n"
            else
                printf "  Bot Token        ${C_DIM}○ 미설정${C_RESET}\n"
            fi

            echo ""
            printf "  ${C_DIM}알림 변경: claude-tracker config notify <키> <true|false>${C_RESET}\n"
            printf "  ${C_DIM}전체 편집: \$EDITOR ${CONFIG_FILE}${C_RESET}\n"
            echo ""
            ;;
        bot-token)
            local token="${2:-}"
            if [[ -z "${token}" ]]; then
                echo "사용법: claude-tracker config bot-token <TOKEN>" >&2
                return 1
            fi
            local config
            config=$(cat "${CONFIG_FILE}")
            safe_write_json "${CONFIG_FILE}" \
                "$(echo "${config}" | jq --arg t "${token}" '.bot_token = $t')"
            printf "  ${C_GREEN}✅${C_RESET} Bot Token 설정 완료\n"
            printf "  ${C_DIM}봇 시작: claude-tracker bot start${C_RESET}\n"
            ;;
        notify)
            local nkey="${2:-}"
            local nval="${3:-}"
            if [[ -z "${nkey}" || -z "${nval}" ]]; then
                echo ""
                printf "  사용법: claude-tracker config notify ${C_DIM}<키> <true|false>${C_RESET}\n"
                echo ""
                printf "  사용 가능한 키:\n"
                printf "    on_start     세션 시작 알림\n"
                printf "    on_complete  작업 완료 알림\n"
                printf "    on_error     에러 알림\n"
                printf "    on_idle      유휴 알림\n"
                echo ""
                return 1
            fi
            if [[ "${nval}" != "true" && "${nval}" != "false" ]]; then
                printf "  ${C_RED}✗${C_RESET} 값은 true 또는 false여야 합니다.\n"
                return 1
            fi
            # 허용 키 검증
            case "${nkey}" in
                on_start|on_complete|on_error|on_idle) ;;
                *)
                    printf "  ${C_RED}✗${C_RESET} 알 수 없는 키: ${nkey}\n"
                    printf "  ${C_DIM}허용 키: on_start, on_complete, on_error, on_idle${C_RESET}\n"
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
            echo "사용법: claude-tracker config [webhook|alias|notify|show]" >&2
            ;;
    esac
}

# ── 커맨드: uninstall ────────────────────────────────────────────
cmd_uninstall() {
    echo ""
    printf "  ${C_BOLD}${C_RED}⚠️  Claude Process Tracker 제거${C_RESET}\n"
    echo ""
    echo "  제거 항목:"
    printf "    ${C_DIM}~/.claude-tracker/${C_RESET} (설정, 상태, 로그)\n"
    printf "    ${C_DIM}~/.claude/settings.json${C_RESET} 에서 tracker hook 제거\n"
    echo ""
    read -r -p "  계속하시겠습니까? [y/N] " response
    if [[ ! "${response}" =~ ^[Yy]$ ]]; then
        echo "  취소됨."
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
            printf "  ${C_GREEN}✅${C_RESET} Claude Code hooks 제거됨\n"
        fi
    fi

    rm -rf "${TRACKER_DIR}"
    printf "  ${C_GREEN}✅${C_RESET} ~/.claude-tracker/ 제거됨\n"
    echo ""
    printf "  ${C_DIM}PATH에서 claude-tracker를 수동으로 제거하세요:${C_RESET}\n"
    printf "  ${C_DIM}  ~/.zshrc 또는 ~/.bashrc 에서 관련 줄 삭제${C_RESET}\n"
    echo ""
}

# ── 커맨드: watch (실시간 모니터링) ─────────────────────────────────────
cmd_watch() {
    local interval="${1:-5}"

    trap 'printf "\n  ${C_DIM}모니터링 종료${C_RESET}\n\n"; exit 0' INT
    printf "  ${C_BOLD}실시간 모니터링${C_RESET} ${C_DIM}(${interval}초 간격, Ctrl+C 종료)${C_RESET}\n"

    while true; do
        printf '\033[2J\033[H'  # 화면 클리어 (스크롤백 유지)
        cmd_status
        sleep "${interval}"
    done
}

# ── 커맨드: prompt (UserPromptSubmit hook) ──────────────────────────────
# 사용자가 프롬프트를 입력할 때마다 호출 → idle → active 전환.
# 프롬프트 내용을 last-prompt.txt에 저장 → 에러 시 복구 가능.
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

    # 사용자 프롬프트 내용 저장 (에러 시 복구용)
    _save_last_prompt "${input}"

    # 세션이 미등록이면 자동 등록 (SessionStart hook 실패 시 복구)
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

# 사용자 프롬프트를 last-prompt.txt에 저장 (최대 5개 보관)
# Hook 경로에서 호출되므로 I/O를 최소화: get_project_name 대신 basename 사용.
_save_last_prompt() {
    local input="$1"
    local prompt_text
    prompt_text=$(printf '%s\n' "${input}" | jq -r '.prompt // .message // ""' 2>/dev/null) || return 0
    [[ -z "${prompt_text}" || "${prompt_text}" == "null" ]] && return 0

    local recovery_file="${TRACKER_DIR}/last-prompt.txt"
    local cwd
    cwd=$(printf '%s\n' "${input}" | jq -r '.cwd // ""' 2>/dev/null)
    local label="${cwd##*/}"  # basename — 파일 I/O 없음
    [[ -z "${label}" ]] && label="unknown"

    local new_entry
    new_entry="$(printf '── %s [%s] ──\n%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${label}" "${prompt_text}")"

    if [[ -f "${recovery_file}" ]]; then
        # 구분자(──)로 나누어 최근 4개만 유지 + 새 항목 = 5개
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

    # 세션 존재 확인
    local exists
    exists=$(echo "${state}" | jq -r --arg sid "${session_id}" '
        if .sessions[$sid] != null then "yes" else "no" end
    ')
    [[ "${exists}" != "yes" ]] && return 0

    # idle → active 전환 + last_activity 갱신
    # idle→active 전환 시 last_notify 리셋 → 다음 Stop에서 반드시 완료 알림 발송
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

# ── 커맨드: monitor (백그라운드 폴링 데몬) ─────────────────────────────
# 주기적으로 각 세션의 실제 상태를 확인하여 보정.
# 1) auto-discovered 세션: cwd 파일 mtime 기반 active/idle 판별
# 2) hook 등록 세션: PID 생존 확인만 수행 (Hook 상태 신뢰)
#    - PID 살아있음 → Hook이 설정한 status 유지
#    - PID 죽음 → 비정상 종료로 판단, 세션 정리 + 알림
# 3) idle 상태가 N분 초과 → Discord "놀고 있음" 알림
cmd_monitor() {
    require_jq || return 1

    local interval="${1:-60}"

    local pidfile="${TRACKER_DIR}/.monitor.pid"

    # stop 명령 (이미 실행 중인지 확인하기 전에 처리)
    if [[ "${interval}" == "stop" ]]; then
        if [[ -f "${pidfile}" ]]; then
            local old_pid
            old_pid=$(cat "${pidfile}" 2>/dev/null || echo "")
            if [[ -n "${old_pid}" ]]; then
                kill "${old_pid}" 2>/dev/null || true
                rm -f "${pidfile}"
                printf "  ${C_GREEN}✅${C_RESET} 모니터 중지됨\n"
            fi
        else
            printf "  ${C_DIM}실행 중인 모니터가 없습니다.${C_RESET}\n"
        fi
        return 0
    fi

    # 이미 실행 중인지 확인
    if [[ -f "${pidfile}" ]]; then
        local old_pid
        old_pid=$(cat "${pidfile}" 2>/dev/null || echo "")
        if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
            printf "  ${C_YELLOW}⚠${C_RESET} 모니터가 이미 실행 중입니다 (PID ${old_pid})\n"
            printf "  ${C_DIM}중지: claude-tracker monitor stop${C_RESET}\n"
            return 0
        fi
        rm -f "${pidfile}"
    fi

    # 백그라운드 실행
    _monitor_loop "${interval}" &
    local monitor_pid=$!
    echo "${monitor_pid}" > "${pidfile}"

    printf "  ${C_GREEN}✅${C_RESET} 모니터 시작 (PID ${monitor_pid}, ${interval}초 간격)\n"
    printf "  ${C_DIM}중지: claude-tracker monitor stop${C_RESET}\n"
    printf "  ${C_DIM}로그: tail -f ${LOG_FILE}${C_RESET}\n"
}

_monitor_loop() {
    local interval="$1"
    local idle_threshold_min
    idle_threshold_min=$(to_int "$(get_config '.notification.idle_threshold_minutes')" 10)
    local idle_threshold_sec=$(( idle_threshold_min * 60 ))

    local last_snapshot=0

    log "INFO" "monitor:start interval=${interval}s idle=${idle_threshold_min}m snapshot=${SNAPSHOT_INTERVAL_SEC}s"

    # 중복 idle 알림 방지 파일
    local notified_idle_file="${TRACKER_DIR}/.monitor_notified"
    : > "${notified_idle_file}"

    while true; do
        sleep "${interval}"

        command -v jq &>/dev/null || continue
        [[ -f "${STATE_FILE}" ]] || continue

        local now
        now=$(date '+%s')

        # ── 1단계: 프로세스 독립 탐지 (find -mmin 기반, 빠름) ──
        _monitor_discover_and_save "${now}" "${ACTIVE_WINDOW_SEC}"

        # ── 2단계: hook 등록 세션의 PID 기반 생존 확인 ──
        # Hook이 설정한 status(active/idle)를 신뢰하고, PID로 비정상 종료만 감지.
        # 알림(Discord)은 락 밖에서 처리하여 락 점유 시간 최소화.
        local _pid_notifications=""
        with_state_lock _monitor_pid_check "${now}" "${idle_threshold_sec}" "${notified_idle_file}" 2>/dev/null || true

        # 락 밖에서 알림 전송 (네트워크 I/O)
        if [[ -n "${_pid_notifications}" ]]; then
            while IFS='|' read -r ntype nproj narg1 narg2; do
                [[ -z "${ntype}" ]] && continue
                case "${ntype}" in
                    crash)
                        send_embed "💀 비정상 종료 감지" 15158332 "" \
                            "프로젝트" "\`${nproj}\`" \
                            "종료 사유" "프로세스 사라짐 (PID ${narg1})" \
                            "세션 시간" "${narg2}"
                        ;;
                    idle)
                        send_embed "💤 유휴 세션" 16776960 "on_idle" \
                            "프로젝트" "\`${nproj}\`" \
                            "유휴 시간" "${narg1}" \
                            "상태" "프롬프트 대기 중"
                        ;;
                esac
            done <<< "${_pid_notifications}"
        fi

        # ── 3단계: 실시간 토큰 사용량 수집 ──
        _monitor_update_live_tokens

        # ── 4단계: 토큰 히스토리 스냅샷 (30분마다) ──
        if (( now - last_snapshot >= SNAPSHOT_INTERVAL_SEC )); then
            write_token_snapshot
            last_snapshot="${now}"
        fi

    done
}

_monitor_save_state() {
    local new_state="$1"
    save_state "${new_state}"
}

# ── PID 기반 세션 생존 확인 (락 안에서 실행) ─────────────────────────────
# 부모 _monitor_loop의 _pid_notifications 변수에 알림 대기열을 기록.
# 알림 전송(네트워크 I/O)은 락 밖에서 처리.
_monitor_pid_check() {
    local now="$1" idle_threshold_sec="$2" notified_idle_file="$3"

    local state
    state=$(get_state)
    local state_changed=false

    while IFS='|' read -r sid proj status last_activity tp session_pid; do
        [[ -z "${sid}" ]] && continue

        local current_last_activity
        current_last_activity=$(to_int "${last_activity}" 0)

        # transcript 경로가 없으면 hook 미등록 세션 → 1단계에서 처리됨 (스킵)
        if [[ -z "${tp}" ]]; then
            continue
        fi

        # ── PID 생존 확인 ──
        local pid_val
        pid_val=$(to_int "${session_pid}" 0)

        if (( pid_val > 0 )) && ! _is_win_pid_alive "${pid_val}"; then
            # 프로세스 죽음 → SessionEnd hook이 안 날아온 비정상 종료
            local started_at
            started_at=$(echo "${state}" | jq -r --arg sid "${sid}" '.sessions[$sid].started_at // 0')
            started_at=$(to_int "${started_at}" 0)
            local duration_sec=$(( now - started_at ))
            local duration
            duration=$(format_duration "${duration_sec}")

            state=$(remove_session_from_state "${state}" "${sid}" "${proj}")
            state_changed=true

            # idle 알림 파일에서도 제거
            grep -vFx "${sid}" "${notified_idle_file}" > "${notified_idle_file}.tmp" \
                && mv "${notified_idle_file}.tmp" "${notified_idle_file}" || true

            # 알림 대기열에 추가 (락 밖에서 전송)
            _pid_notifications+="crash|${proj}|${pid_val}|${duration}"$'\n'
            log "WARN" "monitor:crash ${proj} (PID ${pid_val} dead, session ${sid})"
            continue
        fi

        # ── PID 없거나 프로세스 살아있음 → Hook 상태 신뢰 ──

        # ── idle 알림 (Hook이 설정한 status 기준) ──
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

# ── 실시간 토큰 수집 (매 폴링 사이클) ──────────────────────────────────
_monitor_update_live_tokens() {
    # FIX: 먼저 토큰 데이터를 수집하고, lock 안에서 state read-modify-write를 atomic하게 수행
    # (기존: lock 밖에서 읽고 안에서 쓰기 → TOCTOU 레이스 컨디션)

    # 1단계: lock 밖에서 세션 목록만 빠르게 가져옴 (읽기 전용, 레이스 허용)
    local session_cwds
    session_cwds=$(get_state | jq -r '.sessions | to_entries[] | "\(.key)|\(.value.cwd)"' 2>/dev/null) || return 0
    [[ -z "${session_cwds}" ]] && return 0

    # 2단계: lock 밖에서 토큰 데이터 수집 (I/O 작업, lock 불필요)
    local token_updates=""
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
        token_updates+="${sid}|${input}|${output}|${total}"$'\n'
    done <<< "${session_cwds}"

    [[ -z "${token_updates}" ]] && return 0

    # 3단계: lock 안에서 state 읽기 → 수정 → 쓰기 (atomic)
    with_state_lock _monitor_apply_token_updates "${token_updates}" 2>/dev/null || true
}

_monitor_apply_token_updates() {
    local token_updates="$1"
    local state
    state=$(get_state)
    local updated=false

    while IFS='|' read -r sid input output total; do
        [[ -z "${sid}" ]] && continue
        state=$(echo "${state}" | jq \
            --arg sid "${sid}" \
            --argjson inp "${input}" \
            --argjson out "${output}" \
            --argjson tot "${total}" \
            'if .sessions[$sid] != null then
                .sessions[$sid].live_input_tokens = $inp |
                .sessions[$sid].live_output_tokens = $out |
                .sessions[$sid].live_total_tokens = $tot
             else . end')
        updated=true
    done <<< "${token_updates}"

    if [[ "${updated}" == "true" ]]; then
        save_state "${state}"
    fi
}

# ── 프로세스 탐지 + 즉시 저장 ──────────────────────────────────────────
# state를 echo로 반환하지 않고, 직접 state.json에 저장.
# 서브셸 파이프 문제를 회피.
_monitor_discover_and_save() {
    local now="$1"
    local active_window="$2"

    # 2단계 스캔:
    # 1) 최근 2분 이내 수정된 파일 → 실제 작업 중 (active) + 실시간 에이전트 수
    # 2) 전체 CWD 파일 → 열려 있는 모든 프로젝트 (idle 포함)
    #    켜져있는 프로세스를 /send로 명령할 수 있어야 하므로 시간 제한 없음
    local active_projects
    active_projects=$(find /tmp -maxdepth 1 -name "claude-*-cwd" -mmin -2 -exec cat {} + 2>/dev/null | sort -u) || true

    # 실시간 에이전트 수: 최근 2분 내 수정된 파일만 카운트 (종료된 잔여 파일 제외)
    local active_scan
    active_scan=$(find /tmp -maxdepth 1 -name "claude-*-cwd" -mmin -2 -exec cat {} + 2>/dev/null | sort | uniq -c | sort -rn) || true

    # 전체 프로젝트 목록: 모든 CWD 파일 (존재만 확인, 수는 세지 않음)
    local raw_scan
    raw_scan=$(find /tmp -maxdepth 1 -name "claude-*-cwd" -exec cat {} + 2>/dev/null | sort -u | awk '{print "1 " $0}') || true

    [[ -z "${raw_scan}" ]] && return 0

    # 부모 디렉토리 필터링: A가 B의 상위 경로이면 A를 제거
    # 예: /Users/Desktop 은 /Users/Desktop/Claude Tools 의 부모이므로 제거
    # sed로 앞쪽 숫자+공백 제거 (경로에 한글 공백이 있을 수 있음)
    local all_cwds
    all_cwds=$(echo "${raw_scan}" | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//')
    local scan_data=""
    while read -r count cwd; do
        [[ -z "${cwd}" ]] && continue
        local is_parent=false
        while read -r other_cwd; do
            [[ -z "${other_cwd}" || "${other_cwd}" == "${cwd}" ]] && continue
            # cwd가 other_cwd의 접두어이면 cwd는 부모 디렉토리
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

    # 알림 큐 초기화 (lock 전에 이전 잔여 파일 제거)
    rm -f "${TRACKER_DIR}/tmp/pending_notifications.tmp" 2>/dev/null

    # 잠금 후 state 직접 수정
    with_state_lock _monitor_discover_locked "${now}" "${scan_data}" "${active_projects}" "${active_scan}"

    # FIX: lock 해제 후 큐잉된 알림 전송 (lock 안에서 HTTP 호출 방지)
    local notify_file="${TRACKER_DIR}/tmp/pending_notifications.tmp"
    if [[ -f "${notify_file}" ]]; then
        while IFS='|' read -r _nf_proj _nf_status _nf_total _nf_agents; do
            [[ -z "${_nf_proj}" ]] && continue
            send_embed "🔍 세션 발견" 5763719 "on_start" \
                "프로젝트" "\`${_nf_proj}\`" \
                "상태" "${_nf_status}" \
                "동시 실행" "${_nf_total}개" \
                "에이전트" "${_nf_agents}개"
        done < "${notify_file}"
        rm -f "${notify_file}"
    fi
}

_monitor_discover_locked() {
    local now="$1"
    local scan_data="$2"
    local active_projects="${3:-}"
    local active_scan="${4:-}"
    local state
    state=$(get_state)
    local changed=false

    # 매 사이클 시작 시 auto_discovered 세션의 agent_count를 0으로 리셋
    state=$(echo "${state}" | jq '
        .sessions |= with_entries(
            if .value.auto_discovered then .value.agent_count = 0 else . end
        )
    ')

    while read -r count cwd; do
        [[ -z "${cwd}" ]] && continue
        local project_name
        project_name=$(get_project_name "${cwd}")

        # active 판단: 최근 2분 내 CWD가 있으면 실제 작업 중
        local new_status="idle"
        if [[ -n "${active_projects}" ]] && echo "${active_projects}" | grep -qF "${cwd}"; then
            new_status="active"
        fi

        # 실제 에이전트 수: active_scan에서 이 CWD의 최근 2분 내 파일 수
        local real_agents=0
        if [[ -n "${active_scan}" ]]; then
            real_agents=$(echo "${active_scan}" | grep -F "${cwd}" | awk '{print $1}' | head -1)
            real_agents=${real_agents:-0}
        fi
        count="${real_agents}"

        # state.json에 이 프로젝트의 기존 세션이 있는지 확인
        # auto_discovered 세션만 재사용 (hook 등록 세션은 별도 UUID로 관리)
        # CWD 경로 형식이 C:/ vs /c/ 로 다를 수 있으므로 프로젝트명으로 검색
        local existing_sid
        existing_sid=$(echo "${state}" | jq -r --arg proj "${project_name}" '
            [.sessions | to_entries[] |
             select(.value.project == $proj and .value.auto_discovered == true)] |
            first | .key // ""
        ' 2>/dev/null)

        if [[ -z "${existing_sid}" || "${existing_sid}" == "null" ]]; then
            # 새 세션 발견: 자동 등록
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

            # FIX: lock 안에서 Discord HTTP 호출 대신 알림 큐에 추가 (lock 해제 후 전송)
            local active_total
            active_total=$(echo "${state}" | jq '[.sessions[] | select(.status == "active")] | length' 2>/dev/null || echo "?")
            mkdir -p "${TRACKER_DIR}/tmp" 2>/dev/null
            echo "${project_name}|${new_status}|${active_total}|${count}" >> "${TRACKER_DIR}/tmp/pending_notifications.tmp"
        else
            # 기존 세션: 상태 + agent_count 갱신 (같은 프로젝트의 다른 경로면 합산)
            local current_status
            current_status=$(echo "${state}" | jq -r --arg sid "${existing_sid}" '.sessions[$sid].status // ""')
            # active가 하나라도 있으면 active 유지
            if [[ "${current_status}" == "active" && "${new_status}" == "idle" ]]; then
                new_status="active"
            fi
            # CWD가 실제 존재하는 경로면 갱신 (존재하지 않는 Steam 경로 등 대체)
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

    # 스캔에 나타나지 않은 auto_discovered 세션 제거 (CWD 파일이 없어진 프로세스)
    # 프로젝트 이름으로 비교 (CWD 경로 형식이 C:/ vs /c/ 로 다를 수 있으므로)
    local scanned_proj_names_json
    scanned_proj_names_json=$(echo "${scan_data}" | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//' | while read -r p; do
        [[ -z "${p}" ]] && continue
        get_project_name "${p}"
    done | sort -u | jq -R -s 'split("\n") | map(select(length > 0))')
    local before_count
    before_count=$(echo "${state}" | jq '.sessions | length')
    state=$(echo "${state}" | jq --argjson scanned "${scanned_proj_names_json}" '
        # 프로젝트 이름이 스캔 결과에 없는 auto_discovered 세션 제거
        .sessions |= with_entries(
            select(
                (.value.auto_discovered == true and (.value.project as $proj | $scanned | index($proj) | not))
                | not
            )
        ) |
        # 세션이 없는 프로젝트 제거
        (.sessions | [.[].project] | unique) as $active |
        .projects |= with_entries(select(.key as $k | $active | index($k)))
    ')
    local after_count
    after_count=$(echo "${state}" | jq '.sessions | length')
    if (( before_count != after_count )); then
        changed=true
        log "INFO" "monitor:cleanup removed $(( before_count - after_count )) stale sessions (${before_count}→${after_count})"
    fi

    # 항상 저장 (last_activity 갱신을 위해)
    save_state "${state}"
    if [[ "${changed}" == "true" ]]; then
        log "INFO" "monitor:state_saved ($(echo "${state}" | jq '.sessions | length') sessions)"
    fi
}

# ── 프로세스 독립 탐지 ─────────────────────────────────────────────────
# /tmp/claude-*-cwd 파일을 스캔하여 실행 중인 Claude Code 세션을 자동 발견.
# hook 등록 없이도 모든 인스턴스를 추적할 수 있음.
#
# 성능 최적화:
#   - find -mmin 으로 최근 파일만 탐색 (수백 개 파일 전체 스캔 방지)
#   - sort | uniq -c 파이프라인으로 CWD 그룹화 (bash 루프 최소화)

# ── 커맨드: history (프로젝트별 통계) ───────────────────────────────────
cmd_history() {
    require_jq || return 1

    echo ""
    printf "  ${C_BOLD}${C_CYAN}📊 세션 로그${C_RESET}\n"
    printf "  ${C_DIM}────────────────────────────────────────${C_RESET}\n"
    echo ""

    if [[ ! -f "${LOG_FILE}" ]]; then
        printf "  ${C_DIM}로그가 아직 없습니다.${C_RESET}\n\n"
        return
    fi

    # 프로젝트별 세션 수
    printf "  ${C_BOLD}프로젝트별 활동${C_RESET}\n\n"

    local projects
    projects=$(grep -E 'session:(register|stop|end) ' "${LOG_FILE}" 2>/dev/null \
        | sed 's/.*session:[a-z]* //' | awk '{print $1}' \
        | sort | uniq -c | sort -rn)

    if [[ -z "${projects}" ]]; then
        printf "  ${C_DIM}기록된 활동이 없습니다.${C_RESET}\n\n"
        return
    fi

    while read -r count name; do
        local bar_len=$(( count > 30 ? 30 : count ))
        local bar=""
        for (( i=0; i<bar_len; i++ )); do bar+="█"; done

        printf "  %-18s ${C_CYAN}%s${C_RESET} ${C_DIM}%d 이벤트${C_RESET}\n" "${name}" "${bar}" "${count}"
    done <<< "${projects}"

    echo ""

    # 최근 10개 이벤트
    printf "  ${C_BOLD}최근 이벤트${C_RESET}\n\n"

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

# ── 커맨드: usage (토큰 사용량 통계) ────────────────────────────────────
cmd_usage() {
    require_jq || return 1

    local period="${1:-today}"

    echo ""
    printf "  ${C_BOLD}${C_CYAN}📈 토큰 사용량${C_RESET}\n"
    printf "  ${C_DIM}────────────────────────────────────────${C_RESET}\n"

    if [[ ! -f "${USAGE_LOG}" ]]; then
        echo ""
        printf "  ${C_DIM}사용량 기록이 없습니다.${C_RESET}\n"
        printf "  ${C_DIM}Claude Code 세션을 종료하면 자동으로 기록됩니다.${C_RESET}\n\n"
        return
    fi

    # 기간 필터
    local date_filter period_label=""
    date_filter=$(_resolve_date_filter "${period}")
    case "${period}" in
        today|t)  period_label="오늘" ;;
        week|w)   period_label="최근 7일" ;;
        month|m)  period_label="최근 30일" ;;
        all|a)    period_label="전체" ;;
        *)        period_label="${period} 이후" ;;
    esac

    # usage.jsonl 필터링 + 집계
    # 날짜 필터 유무에 관계없이 동일한 집계 쿼리 사용
    # since가 빈 문자열이면 전체, 값이 있으면 해당 날짜 이후만 필터
    local stats
    stats=$(jq -s --arg since "${date_filter}" '
        [.[] | select($since == "" or .timestamp >= $since)] |
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

    if [[ -z "${stats}" || "${stats}" == "null" ]]; then
        printf "\n  ${C_DIM}해당 기간에 기록이 없습니다.${C_RESET}\n\n"
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

    # ── 요약 ──
    echo ""
    printf "  ${C_BOLD}${period_label}${C_RESET} ${C_DIM}(${sessions}개 세션, $(format_duration "$(to_int "${total_duration}" 0)"))${C_RESET}\n"
    echo ""
    printf "  ⬇ Input    ${C_BOLD}$(format_tokens "${total_input}")${C_RESET}\n"
    printf "  ⬆ Output   ${C_BOLD}$(format_tokens "${total_output}")${C_RESET}\n"
    printf "  💾 Cache    ${C_DIM}생성 $(format_tokens "${total_cache_create}") · 읽기 $(format_tokens "${total_cache_read}")${C_RESET}\n"
    printf "  ── 합계    ${C_BOLD}${C_CYAN}$(format_tokens "${total_tokens}")${C_RESET}"
    if [[ "${total_cost}" != "0" && "${total_cost}" != "null" ]]; then
        printf " ${C_DIM}(\$$(printf '%.3f' "${total_cost}" 2>/dev/null || echo "${total_cost}"))${C_RESET}"
    fi
    echo ""

    # 세션당 평균
    if (( sessions > 0 )); then
        local avg_tokens=$(( $(to_int "${total_tokens}" 0) / sessions ))
        printf "  ${C_DIM}세션당 평균: $(format_tokens "${avg_tokens}")${C_RESET}\n"
    fi

    # ── 프로젝트별 ──
    echo ""
    printf "  ${C_BOLD}프로젝트별${C_RESET}\n\n"

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
        printf " ${C_DIM}${sess}세션${C_RESET}"
        printf "${cost_str}\n"
    done

    # ── 최근 질문 ──
    echo ""
    printf "  ${C_BOLD}최근 질문${C_RESET}\n\n"

    echo "${stats}" | jq -r '
        .recent_prompts[] |
        .prompts // [] | .[] |
        select(length > 0)
    ' 2>/dev/null | tail -10 | while IFS= read -r prompt; do
        [[ -z "${prompt}" ]] && continue
        # 60자로 잘라서 표시
        local display="${prompt}"
        if (( ${#display} > 60 )); then
            display="${display:0:57}..."
        fi
        printf "  ${C_DIM}•${C_RESET} ${display}\n"
    done

    echo ""
    printf "  ${C_DIM}기간: today(t) week(w) month(m) all(a) YYYY-MM-DD${C_RESET}\n"
    echo ""
}

# ── 커맨드: test (webhook 연결 테스트) ──────────────────────────────────
cmd_test() {
    require_jq || return 1

    local webhook_url
    webhook_url=$(get_config '.discord_webhook_url')

    echo ""
    printf "  ${C_BOLD}🔧 연결 테스트${C_RESET}\n"
    printf "  ${C_DIM}────────────────────────────────────────${C_RESET}\n"
    echo ""

    # jq 확인
    printf "  jq          "
    if command -v jq &>/dev/null; then
        printf "${C_GREEN}✓${C_RESET} $(jq --version 2>&1)\n"
    else
        printf "${C_RED}✗${C_RESET} 미설치\n"
    fi

    # curl 확인
    printf "  curl        "
    if command -v curl &>/dev/null; then
        printf "${C_GREEN}✓${C_RESET} 설치됨\n"
    else
        printf "${C_RED}✗${C_RESET} 미설치\n"
    fi

    # flock 확인
    printf "  flock       "
    if command -v flock &>/dev/null; then
        printf "${C_GREEN}✓${C_RESET} 설치됨 (Linux 잠금)\n"
    else
        printf "${C_YELLOW}○${C_RESET} 미설치 (mkdir 잠금 사용)\n"
    fi

    # state.json 확인
    printf "  state.json  "
    if [[ -f "${STATE_FILE}" ]] && jq empty "${STATE_FILE}" 2>/dev/null; then
        local sess_count
        sess_count=$(jq '.sessions | length' "${STATE_FILE}")
        printf "${C_GREEN}✓${C_RESET} 유효 (세션 ${sess_count}개)\n"
    else
        printf "${C_RED}✗${C_RESET} 없거나 유효하지 않음\n"
    fi

    # webhook 확인
    printf "  webhook     "
    if [[ -z "${webhook_url}" ]]; then
        printf "${C_RED}✗${C_RESET} 미설정\n"
        echo ""
        printf "  ${C_DIM}설정: claude-tracker config webhook <URL>${C_RESET}\n"
    else
        # 실제 전송 테스트
        local test_payload
        test_payload=$(jq -n \
            --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
            '{embeds: [{
                title: "🔧 연결 테스트",
                description: "Claude Process Tracker가 정상적으로 연결되었습니다!",
                color: 5793266,
                footer: {text: "테스트 메시지"},
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
            printf "${C_GREEN}✓${C_RESET} 전송 성공 (HTTP ${http_code})\n"
            echo ""
            printf "  ${C_GREEN}Discord 채널을 확인하세요!${C_RESET}\n"
        else
            printf "${C_RED}✗${C_RESET} 실패 (HTTP ${http_code})\n"
            echo ""
            printf "  ${C_DIM}URL을 확인하세요: claude-tracker config show${C_RESET}\n"
        fi
    fi

    # hook 등록 확인
    echo ""
    printf "  hooks       "
    local settings="${HOME}/.claude/settings.json"
    if [[ -f "${settings}" ]] && jq -e '.hooks.SessionStart[]?.hooks[]?.command | test("claude-tracker")' "${settings}" >/dev/null 2>&1; then
        printf "${C_GREEN}✓${C_RESET} Claude Code에 등록됨\n"
    else
        printf "${C_RED}✗${C_RESET} 미등록\n"
        printf "  ${C_DIM}install.sh를 다시 실행하세요${C_RESET}\n"
    fi

    echo ""
}

# ── 커맨드: last-prompt (마지막 입력 프롬프트 복구) ───────────────────
cmd_last_prompt() {
    local recovery_file="${TRACKER_DIR}/last-prompt.txt"
    if [[ ! -f "${recovery_file}" ]]; then
        echo ""
        printf "  ${C_DIM}저장된 프롬프트가 없습니다.${C_RESET}\n"
        echo ""
        return 0
    fi

    echo ""
    printf "  ${C_BOLD}${C_CYAN}📋 마지막 입력 프롬프트${C_RESET}\n"
    printf "  ${C_DIM}────────────────────────────────────────────────${C_RESET}\n"
    echo ""
    cat "${recovery_file}"
    echo ""
    printf "  ${C_DIM}파일: ${recovery_file}${C_RESET}\n"
    printf "  ${C_DIM}클립보드 복사: cat ${recovery_file}${C_RESET}\n"
    echo ""
}

# ── 커맨드: reset (상태 초기화) ─────────────────────────────────────────
cmd_reset() {
    echo ""
    printf "  ${C_BOLD}${C_YELLOW}⚠️  상태 초기화${C_RESET}\n"
    printf "  ${C_DIM}state.json을 초기화합니다. 설정은 유지됩니다.${C_RESET}\n"
    echo ""
    read -r -p "  계속하시겠습니까? [y/N] " response
    if [[ ! "${response}" =~ ^[Yy]$ ]]; then
        echo "  취소됨."
        return 0
    fi

    echo '{"sessions": {}, "projects": {}}' > "${STATE_FILE}"
    printf "  ${C_GREEN}✅${C_RESET} 상태가 초기화되었습니다.\n\n"
}

# ── 메인 ──────────────────────────────────────────────────────────────────
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
    snapshot)   write_token_snapshot && printf "  ✅ 스냅샷 기록됨\n" ;;
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
    uninstall)  cmd_uninstall ;;
    help)
        echo ""
        printf "  ${C_BOLD}${C_CYAN}🤖 Claude Process Tracker${C_RESET} ${C_DIM}v2.2${C_RESET}\n"
        printf "  ${C_DIM}────────────────────────────────────────────────${C_RESET}\n"
        echo ""
        printf "  ${C_BOLD}사용법${C_RESET}  claude-tracker ${C_DIM}<command>${C_RESET}\n"
        echo ""
        printf "  ${C_BOLD}조회${C_RESET}\n"
        printf "    ${C_GREEN}s${C_RESET}  status       전체 프로젝트 현황\n"
        printf "    ${C_GREEN}w${C_RESET}  watch ${C_DIM}[초]${C_RESET}   실시간 모니터링 (기본 5초)\n"
        printf "    ${C_GREEN}m${C_RESET}  monitor ${C_DIM}[초|stop]${C_RESET} 백그라운드 폴링 (기본 60초)\n"
        printf "    ${C_GREEN}h${C_RESET}  history      프로젝트별 통계 & 최근 이벤트\n"
        printf "    ${C_GREEN}u${C_RESET}  usage ${C_DIM}[기간]${C_RESET}  토큰 사용량 (today/week/month/all)\n"
        printf "    ${C_GREEN}d${C_RESET}  dashboard    Discord에 대시보드 전송\n"
        printf "    ${C_GREEN}r${C_RESET}  report ${C_DIM}[날짜|send]${C_RESET} 토큰 히스토리 (30분 스냅샷)\n"
        printf "       snapshot          수동 스냅샷 즉시 기록\n"
        echo ""
        printf "  ${C_BOLD}세션${C_RESET}\n"
        printf "    ${C_CYAN}resume${C_RESET} ${C_DIM}[프로젝트]${C_RESET}  세션 재개 (대화형 선택 또는 이름 검색)\n"
        printf "    ${C_CYAN}lp${C_RESET}     last-prompt   마지막 입력 프롬프트 복구 (에러 시 복사용)\n"
        echo ""
        printf "  ${C_BOLD}관리${C_RESET}\n"
        printf "    ${C_CYAN}bot${C_RESET}     start|stop|status Discord 봇 관리\n"
        printf "    ${C_CYAN}config${C_RESET}  show              현재 설정\n"
        printf "    ${C_CYAN}config${C_RESET}  webhook ${C_DIM}<URL>${C_RESET}      Discord Webhook 설정\n"
        printf "    ${C_CYAN}config${C_RESET}  bot-token ${C_DIM}<TOKEN>${C_RESET}  Discord 봇 토큰\n"
        printf "    ${C_CYAN}config${C_RESET}  alias ${C_DIM}[경로] [별칭]${C_RESET} 프로젝트 별칭 (. 지원, 인터랙티브)\n"
        printf "    ${C_CYAN}config${C_RESET}  notify ${C_DIM}<키> <bool>${C_RESET}  알림 토글\n"
        printf "    ${C_YELLOW}cleanup${C_RESET}                   죽은 세션 정리\n"
        printf "    ${C_YELLOW}reset${C_RESET}                     상태 초기화\n"
        printf "    ${C_RED}uninstall${C_RESET}                 트래커 제거\n"
        echo ""
        printf "  ${C_BOLD}진단${C_RESET}\n"
        printf "    ${C_GREEN}t${C_RESET}  test         연결 & 설정 진단\n"
        echo ""
        printf "  ${C_DIM}설정: ${CONFIG_FILE}${C_RESET}\n"
        printf "  ${C_DIM}로그: ${LOG_FILE}${C_RESET}\n"
        echo ""
        ;;
    *)
        echo ""
        printf "  ${C_RED}알 수 없는 명령어:${C_RESET} ${COMMAND}\n"
        echo ""

        # 유사 명령어 제안
        _suggestions=""
        _known_cmds="status watch monitor history usage dashboard report resume cleanup config reset test uninstall help"
        _first_char="${COMMAND:0:1}"
        for _cmd in ${_known_cmds}; do
            if [[ "${_cmd:0:1}" == "${_first_char}" ]] || [[ "${_cmd}" == *"${COMMAND}"* ]]; then
                _suggestions="${_suggestions} ${_cmd}"
            fi
        done

        if [[ -n "${_suggestions}" ]]; then
            printf "  혹시:${C_BOLD}${_suggestions}${C_RESET} ?\n"
        fi
        printf "  ${C_DIM}도움말: claude-tracker help${C_RESET}\n"
        echo ""
        ;;
esac
