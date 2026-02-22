# 🤖 Claude Process Tracker

Claude Code 세션을 자동으로 추적하고 Discord에 알림을 보내는 도구.
여러 프로젝트 인스턴스를 동시에 관리하며, 놀고 있는 인스턴스를 찾아 작업을 지시할 수 있도록 돕습니다.

## 설치

```bash
chmod +x install.sh
./install.sh
```

## 파일 구조

```
claude-tracker.sh       메인 스크립트 (~1950줄)
install.sh              설치 및 hook 등록 자동화
hooks-settings.json     Claude Code settings.json에 병합할 hook 정의
```

설치 후 생성되는 파일:

```
~/.claude-tracker/
  ├── bin/claude-tracker   실행 파일
  ├── config.json          설정 (webhook, alias, 알림 토글)
  ├── state.json           세션/프로젝트 실시간 상태
  ├── tracker.log          이벤트 로그
  └── usage.jsonl          토큰 사용량 기록 (세션 종료 시 자동)
```

## Hook 흐름

```
SessionStart       → register → active 등록 + 🟢 Discord 알림
UserPromptSubmit   → prompt   → idle→active 전환 (실시간)
Stop               → update   → active→idle + 디바운싱된 ✅ 알림
SessionEnd         → end      → 세션 제거 + 토큰 기록 + 🔴 알림
```

## 커맨드

### 조회

| 커맨드 | 축약 | 설명 |
|--------|------|------|
| `status` | `s` | 전체 프로젝트 현황 (ANSI 터미널) |
| `watch [초]` | `w` | 실시간 모니터링 (기본 5초, Ctrl+C 종료) |
| `monitor [초|stop]` | `m` | 백그라운드 폴링 데몬 (기본 60초) |
| `history` | `h` | 프로젝트별 통계 & 최근 이벤트 |
| `usage [기간]` | `u` | 토큰 사용량 통계 |
| `dashboard` | `d` | Discord에 대시보드 embed 전송 |

### 관리

| 커맨드 | 설명 |
|--------|------|
| `config show` | 현재 설정 보기 |
| `config webhook <URL>` | Discord Webhook URL 설정 |
| `config alias <경로> <별칭>` | 프로젝트 별칭 |
| `config notify <키> <bool>` | 알림 토글 (on_start/on_complete/on_error/on_idle) |
| `cleanup` | 비활성 세션 정리 |
| `reset` | state.json 초기화 |
| `test` | 연결 & 설정 진단 |
| `uninstall` | 트래커 완전 제거 |

## 모니터링

### monitor (백그라운드 폴링)

```bash
claude-tracker monitor       # 60초 간격으로 시작
claude-tracker monitor 30    # 30초 간격
claude-tracker monitor stop  # 중지
```

매 주기마다:
- 각 세션의 transcript 파일 mtime을 확인하여 state 동기화
- transcript 변경 < 2분 → active / 그 외 → idle
- transcript 파일 삭제됨 → dead 세션 자동 제거
- idle이 설정 시간 초과 → Discord "💤 유휴 세션" 알림

### usage (토큰 통계)

```bash
claude-tracker usage          # 오늘
claude-tracker usage week     # 최근 7일
claude-tracker usage month    # 최근 30일
claude-tracker usage all      # 전체
claude-tracker usage 2026-02-01  # 특정 날짜 이후
```

세션 종료 시 transcript JSONL에서 자동 추출하는 정보:
- input/output/cache 토큰 수
- costUSD (API 사용 시)
- 사용 모델
- 사용자 프롬프트 최근 5개

## 의존성

- **jq** (필수) — JSON 처리
- **curl** (필수) — Discord webhook
- **bash 4.0+** (권장) — macOS는 `brew install bash`
- **flock** (선택) — 있으면 사용, 없으면 mkdir 기반 잠금
