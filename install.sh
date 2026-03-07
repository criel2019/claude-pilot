#!/usr/bin/env bash
# ============================================================================
# Claude Process Tracker — 설치 스크립트
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.claude-tracker"
BIN_DIR="${INSTALL_DIR}/bin"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║       🤖 Claude Process Tracker — 설치                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── 1. 의존성 확인 ───────────────────────────────────────────────────────
echo "1️⃣  의존성 확인..."

if ! command -v jq &>/dev/null; then
    echo "   ❌ jq가 설치되어 있지 않습니다."
    echo ""
    echo "   설치 방법:"
    echo "     macOS:  brew install jq"
    echo "     Ubuntu: sudo apt install jq"
    echo "     Windows (scoop): scoop install jq"
    exit 1
fi
echo "   ✅ jq 확인"

if ! command -v curl &>/dev/null; then
    echo "   ❌ curl이 설치되어 있지 않습니다."
    exit 1
fi
echo "   ✅ curl 확인"

# bash 버전 확인 [R2-5.2]
if (( BASH_VERSINFO[0] < 4 )); then
    echo "   ⚠️  bash ${BASH_VERSION} 감지. bash 4.0+ 권장."
    echo "     macOS: brew install bash"
    echo "     계속 진행하지만 일부 기능에 문제가 있을 수 있습니다."
fi

# ── 2. 디렉토리 생성 ─────────────────────────────────────────────────────
echo ""
echo "2️⃣  설치 디렉토리 생성..."
mkdir -p "${BIN_DIR}"
echo "   ✅ ${INSTALL_DIR}"

# ── 3. 스크립트 복사 ─────────────────────────────────────────────────────
echo ""
echo "3️⃣  스크립트 설치..."
cp "${SCRIPT_DIR}/claude-tracker.sh" "${BIN_DIR}/claude-tracker"
chmod +x "${BIN_DIR}/claude-tracker"
echo "   ✅ claude-tracker → ${BIN_DIR}/claude-tracker"

# ── 4. Claude Code 설정에 hooks 추가 ────────────────────────────────────
echo ""
echo "4️⃣  Claude Code hook 설정..."

mkdir -p "${HOME}/.claude"

if [[ -f "${CLAUDE_SETTINGS}" ]]; then
    # 기존 설정이 있으면 hooks 병합
    echo "   기존 settings.json 발견."
    
    # [R2-5.1] 이미 tracker hook이 있는지 확인
    if jq -e '.hooks.SessionStart[]?.hooks[]?.command | test("claude-tracker")' "${CLAUDE_SETTINGS}" >/dev/null 2>&1; then
        echo "   ✅ tracker hooks 이미 설치됨 (건너뜀)"
    else
        # 백업
        cp "${CLAUDE_SETTINGS}" "${CLAUDE_SETTINGS}.backup.$(date '+%Y%m%d%H%M%S')"
        echo "   ✅ 백업 생성됨"
        
        # [R2-5.1] 기존 배열에 append (대체가 아닌 추가)
        # __TRACKER_BIN__ 플레이스홀더를 실제 설치 경로로 치환
        # Windows Git Bash: /c/Users/... → C:/Users/... 형식으로 변환
        TRACKER_BIN_WIN=$(echo "${BIN_DIR}/claude-tracker" | sed 's|^/\([a-zA-Z]\)/|\1:/|')
        local_hooks=$(sed "s|__TRACKER_BIN__|${TRACKER_BIN_WIN}|g" "${SCRIPT_DIR}/hooks-settings.json")

        merged=$(jq --argjson new_hooks "$(echo "${local_hooks}" | jq '.hooks')" '
            .hooks.SessionStart = ((.hooks.SessionStart // []) + $new_hooks.SessionStart) |
            
            .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) + $new_hooks.UserPromptSubmit) |
            .hooks.Stop = ((.hooks.Stop // []) + $new_hooks.Stop) |
            .hooks.SessionEnd = ((.hooks.SessionEnd // []) + $new_hooks.SessionEnd)
        ' "${CLAUDE_SETTINGS}")
        
        echo "${merged}" | jq '.' > "${CLAUDE_SETTINGS}"
        echo "   ✅ hooks 추가 완료"
    fi
else
    # 새로 생성 — __TRACKER_BIN__ 플레이스홀더를 실제 경로로 치환 후 저장
    TRACKER_BIN_WIN=$(echo "${BIN_DIR}/claude-tracker" | sed 's|^/\([a-zA-Z]\)/|\1:/|')
    sed "s|__TRACKER_BIN__|${TRACKER_BIN_WIN}|g" "${SCRIPT_DIR}/hooks-settings.json" > "${CLAUDE_SETTINGS}"
    echo "   ✅ settings.json 생성됨"
fi

# ── 5. 초기 설정 파일 생성 ───────────────────────────────────────────────
echo ""
echo "5️⃣  초기 설정..."

# tracker를 한 번 실행해서 config 파일 생성
"${BIN_DIR}/claude-tracker" help > /dev/null 2>&1

echo "   ✅ config.json 생성됨"

# ── 6. PATH 등록 안내 ────────────────────────────────────────────────────
echo ""
echo "6️⃣  PATH 등록 (선택사항)..."
echo ""

# 셸 감지
SHELL_NAME=$(basename "${SHELL:-bash}")
RC_FILE=""
case "${SHELL_NAME}" in
    zsh)  RC_FILE="${HOME}/.zshrc" ;;
    bash) RC_FILE="${HOME}/.bashrc" ;;
    fish) RC_FILE="${HOME}/.config/fish/config.fish" ;;
esac

if [[ -n "${RC_FILE}" ]]; then
    # 이미 PATH에 있는지 확인
    if grep -q "claude-tracker" "${RC_FILE}" 2>/dev/null; then
        echo "   ✅ PATH에 이미 등록됨"
    else
        echo "   다음 줄을 ${RC_FILE}에 추가하시겠습니까?"
        echo ""
        if [[ "${SHELL_NAME}" == "fish" ]]; then
            echo "     fish_add_path ${BIN_DIR}"
        else
            echo "     export PATH=\"\${PATH}:${BIN_DIR}\""
        fi
        echo ""
        read -r -p "   추가하시겠습니까? [y/N] " response
        if [[ "${response}" =~ ^[Yy]$ ]]; then
            if [[ "${SHELL_NAME}" == "fish" ]]; then
                echo "fish_add_path ${BIN_DIR}" >> "${RC_FILE}"
            else
                echo "export PATH=\"\${PATH}:${BIN_DIR}\"" >> "${RC_FILE}"
            fi
            echo "   ✅ PATH 추가됨. 셸을 재시작하거나 source ${RC_FILE} 실행"
        fi
    fi
fi

# ── 7. Discord Webhook 설정 ─────────────────────────────────────────────
echo ""
echo "7️⃣  Discord Webhook 설정 (claude-tracker 알림용)..."
echo ""
echo "   Discord 채널에서 Webhook URL을 생성하세요:"
echo "   채널 설정 → 연동 → 웹훅 → 새 웹후크"
echo ""
read -r -p "   Webhook URL (나중에 설정하려면 Enter): " webhook_url

if [[ -n "${webhook_url}" ]]; then
    "${BIN_DIR}/claude-tracker" config webhook "${webhook_url}"
fi

# ── 8. Discord Bot Token 설정 ────────────────────────────────────────────
echo ""
echo "8️⃣  Discord Bot 토큰 설정..."
echo ""
echo "   Discord Developer Portal에서 봇을 생성하고 토큰을 발급받으세요:"
echo "   https://discord.com/developers/applications"
echo "   → New Application → Bot → Reset Token"
echo "   (Message Content Intent도 활성화하세요)"
echo ""
read -r -p "   Bot Token (나중에 설정하려면 Enter): " bot_token

CONFIG_FILE="${INSTALL_DIR}/config.json"
if [[ -n "${bot_token}" ]]; then
    if [[ -f "${CONFIG_FILE}" ]]; then
        tmp=$(jq --arg v "${bot_token}" '.bot_token = $v' "${CONFIG_FILE}")
        echo "${tmp}" > "${CONFIG_FILE}"
    else
        jq -n --arg v "${bot_token}" '{"bot_token": $v}' > "${CONFIG_FILE}"
    fi
    echo "   ✅ bot_token 저장됨"
else
    echo "   ⚠️  나중에 ~/.claude-tracker/config.json에 bot_token을 직접 추가하세요."
fi

# ── 9. 기본 작업 디렉토리 설정 ──────────────────────────────────────────
echo ""
echo "9️⃣  기본 작업 디렉토리 설정..."
echo ""
echo "   /send에서 프로젝트를 지정하지 않을 때 Claude가 열리는 폴더입니다."
if [[ -n "${USERPROFILE:-}" ]]; then
    echo "   예: ${USERPROFILE}\\Projects"
else
    echo "   예: ${HOME}/projects"
fi
echo ""
read -r -p "   기본 작업 디렉토리 (Enter=홈 디렉토리 사용): " default_cwd

if [[ -n "${default_cwd}" ]]; then
    if [[ -f "${CONFIG_FILE}" ]]; then
        tmp=$(jq --arg v "${default_cwd}" '.default_cwd = $v' "${CONFIG_FILE}")
        echo "${tmp}" > "${CONFIG_FILE}"
    else
        jq -n --arg v "${default_cwd}" '{"default_cwd": $v}' > "${CONFIG_FILE}"
    fi
    echo "   ✅ default_cwd 저장됨"
else
    echo "   ℹ️  홈 디렉토리를 기본값으로 사용합니다."
fi

# ── 완료 ──────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                    ✅ 설치 완료!                        ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  ⚠️  Claude Code를 재시작해야 훅이 적용됩니다.          ║"
echo "║                                                          ║"
echo "║  다음 단계:                                              ║"
echo "║    1. Claude Code 재시작                                 ║"
echo "║    2. npm install        (봇 디렉토리에서)               ║"
echo "║    3. node bot.js        (봇 실행)                       ║"
echo "║       Windows: start-bot.vbs 더블클릭                    ║"
echo "║                                                          ║"
echo "║  설정 파일: ~/.claude-tracker/config.json                ║"
echo "║    bot_token    Discord 봇 토큰 (필수)                   ║"
echo "║    default_cwd  기본 작업 디렉토리                       ║"
echo "║    webhook      Discord 알림 Webhook URL                 ║"
echo "║    allowed_users  허용할 Discord 사용자 ID 목록          ║"
echo "║                   (비워두면 서버 전체 허용)              ║"
echo "║                                                          ║"
echo "║  claude-tracker 커맨드:                                  ║"
echo "║    status    현황 보기                                    ║"
echo "║    usage     토큰 사용량 통계                             ║"
echo "║    monitor   백그라운드 폴링 시작                        ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "Claude Code를 재시작하면 자동 추적이 시작됩니다! 🚀"
