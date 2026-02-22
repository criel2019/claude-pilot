import {
  Client, GatewayIntentBits, REST, Routes,
  SlashCommandBuilder, EmbedBuilder, ActionRowBuilder,
  ButtonBuilder, ButtonStyle, StringSelectMenuBuilder,
  ModalBuilder, TextInputBuilder, TextInputStyle,
} from 'discord.js';
import { execFileSync, execFile, spawn } from 'child_process';
import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, unlinkSync } from 'fs';
import { join } from 'path';
import { randomUUID } from 'crypto';
import { fileURLToPath } from 'url';

// ── 설정 ──
const BOT_DIR = join(fileURLToPath(import.meta.url), '..');
const DEFAULT_PROJECT_NAME = '기본';
const DEFAULT_PROJECT_CWD = join(BOT_DIR, 'temp');
const TRACKER_DIR = join(process.env.HOME || process.env.USERPROFILE, '.claude-tracker');
const CONFIG_FILE = join(TRACKER_DIR, 'config.json');
const STATE_FILE = join(TRACKER_DIR, 'state.json');
const TOKEN_HISTORY = join(TRACKER_DIR, 'token-history.jsonl');
const TRACKER_BIN = join(TRACKER_DIR, 'bin', 'claude-tracker');

const SESSIONS_DIR = join(TRACKER_DIR, 'bot-sessions');
const SESSION_RETENTION_DAYS = 10;

const SEND_TIMEOUT = 14 * 60 * 1000; // 14분 (Discord 15분 interaction 만료에 1분 여유)
const MAX_HISTORY_MESSAGES = 100; // messageHistory 상한

// Embed 색상 상수
const COLOR = {
  SUCCESS: 0x2ECC71,
  WARNING: 0xF1C40F,
  ERROR: 0xE74C3C,
  TIMEOUT: 0xE67E22,
  INFO: 0x3498DB,
};

// Discord UI 제한 상수
const EMBED_MAX_CHARS = 3800;
const EMBED_TRIM_CHARS = 3700;
const EMBED_FIELD_MAX = 1024;
const THREAD_NAME_MAX = 100;
const THREAD_AUTO_ARCHIVE = 1440;
const SELECT_MAX_OPTIONS = 25;

// 이미지 첨부 지원
const TEMP_DIR = join(TRACKER_DIR, 'tmp');
const FAILED_PROMPTS_FILE = join(TRACKER_DIR, 'failed-prompts.jsonl');
const MAX_FAILED_PROMPTS = 20;
const IMAGE_EXTENSIONS = ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'];
const TEXT_EXTENSIONS = new Set(['txt', 'md', 'json', 'js', 'ts', 'py', 'css', 'html', 'sh', 'yaml', 'yml', 'log']);
const MAX_IMAGE_SIZE = 10 * 1024 * 1024; // 10MB

// 실패한 프롬프트 저장 (최대 MAX_FAILED_PROMPTS개, JSONL)
function saveFailedPrompt({ message, project, reason, user }) {
  try {
    const entry = JSON.stringify({
      timestamp: Date.now(),
      date: new Date().toISOString(),
      user: user || 'unknown',
      project: project || null,
      reason,
      message,
    });
    let lines = [];
    try { lines = readFileSync(FAILED_PROMPTS_FILE, 'utf8').trim().split('\n').filter(Boolean); } catch {}
    lines.push(entry);
    if (lines.length > MAX_FAILED_PROMPTS) lines = lines.slice(-MAX_FAILED_PROMPTS);
    writeFileSync(FAILED_PROMPTS_FILE, lines.join('\n') + '\n');
  } catch {}
}

// config 파일 TTL 캐시 (30초) — 매번 디스크 읽기 방지
let _configCache = null;
let _configCacheTime = 0;
const CONFIG_CACHE_TTL = 30_000;

function getConfig() {
  const now = Date.now();
  if (_configCache && now - _configCacheTime < CONFIG_CACHE_TTL) return _configCache;
  try {
    _configCache = JSON.parse(readFileSync(CONFIG_FILE, 'utf8'));
  } catch {
    _configCache = {};
  }
  _configCacheTime = now;
  return _configCache;
}

function invalidateConfigCache() {
  _configCache = null;
  _configCacheTime = 0;
}

// 세션의 Claude 프로세스가 실행 중인지 확인
function isSessionBusy(session) {
  return session?.proc && session.proc.exitCode === null;
}

// 오류 발생 시 히스토리에 에러 기록 (assistant 응답이 없는 user 메시지 보정)
function recordErrorInHistory(session) {
  const lastMsg = session.messageHistory[session.messageHistory.length - 1];
  if (lastMsg && lastMsg.role === 'user') {
    pushHistory(session, 'assistant', '[오류 발생 — 응답 없음]');
  }
  saveSession(session);
}

// messageHistory에 메시지 추가 + 상한 적용
function pushHistory(session, role, content) {
  session.messageHistory.push({ role, content, timestamp: Date.now() });
  if (session.messageHistory.length > MAX_HISTORY_MESSAGES) {
    session.messageHistory = session.messageHistory.slice(-MAX_HISTORY_MESSAGES);
  }
}

// 매 호출마다 config에서 동적으로 읽어 hot-reload 지원
function isUserAllowed(userId) {
  const cfg = getConfig();
  const allowed = cfg.allowed_users;
  if (!allowed || allowed.length === 0) return true;
  return allowed.map(String).includes(String(userId));
}

const BOT_TOKEN = getConfig().bot_token;
if (!BOT_TOKEN) {
  console.error('bot_token이 config.json에 없습니다.');
  console.error('설정: claude-tracker config bot-token <TOKEN>');
  process.exit(1);
}

// ── Phase 1.2: 세션 관리 ──
// channelId → session object
const activeSessions = new Map();

// ── Phase 1.3: 세션 영속화 함수 ──

function saveSession(session) {
  // proc, threadRef, starterMessageRef, lastThreadButtonMsg는 비영속 필드 → 제외
  const data = { ...session };
  delete data.proc;
  delete data.threadRef;
  delete data.starterMessageRef;
  delete data.lastThreadButtonMsg;
  const filePath = join(SESSIONS_DIR, `${data.id}.json`);
  writeFileSync(filePath, JSON.stringify(data, null, 2), 'utf8');
}

function loadAllSessions() {
  const files = readdirSync(SESSIONS_DIR).filter(f => f.endsWith('.json'));
  const sessions = [];
  for (const file of files) {
    try {
      const data = JSON.parse(readFileSync(join(SESSIONS_DIR, file), 'utf8'));
      sessions.push(data);
    } catch (e) {
      console.warn(`[load] 세션 파일 읽기 실패: ${file}`, e.message);
    }
  }
  return sessions;
}

function deleteSessionFile(sessionId) {
  const filePath = join(SESSIONS_DIR, `${sessionId}.json`);
  try { unlinkSync(filePath); } catch {}
}

// ── 슬래시 커맨드 정의 ──
const commands = [
  new SlashCommandBuilder().setName('status').setDescription('프로젝트 현황 조회'),
  new SlashCommandBuilder().setName('snapshot').setDescription('토큰 스냅샷 즉시 기록'),
  new SlashCommandBuilder().setName('report').setDescription('토큰 히스토리 리포트')
    .addStringOption(o => o.setName('period').setDescription('기간').addChoices(
      { name: '오늘', value: 'today' },
      { name: '최근 7일', value: 'week' },
      { name: '전체', value: 'all' },
    )),
  new SlashCommandBuilder().setName('dashboard').setDescription('대시보드 전송'),
  new SlashCommandBuilder().setName('send').setDescription('프로젝트에 명령 전송')
    .addStringOption(o => o.setName('message').setDescription('전송할 메시지/명령 (file 첨부 시 생략 가능)').setRequired(false))
    .addStringOption(o => o.setName('project').setDescription('프로젝트 이름').setAutocomplete(true))
    .addStringOption(o => o.setName('model').setDescription('모델 선택').addChoices(
      { name: 'Opus (기본, 강력)', value: 'opus' },
      { name: 'Sonnet (빠름)', value: 'sonnet' },
      { name: 'Haiku (경량)', value: 'haiku' },
    ))
    .addAttachmentOption(o => o.setName('file').setDescription('텍스트 파일 (.txt/.md) — 4000자 초과 내용 전송에 사용').setRequired(false))
    .addAttachmentOption(o => o.setName('image').setDescription('이미지 첨부').setRequired(false))
    .addAttachmentOption(o => o.setName('image2').setDescription('이미지 2').setRequired(false))
    .addAttachmentOption(o => o.setName('image3').setDescription('이미지 3').setRequired(false)),
  new SlashCommandBuilder().setName('project').setDescription('이 채널의 기본 프로젝트 설정'),
  new SlashCommandBuilder().setName('end').setDescription('현재 채널의 Claude 세션 종료'),
  new SlashCommandBuilder().setName('session').setDescription('현재 채널의 세션 정보 조회'),
  new SlashCommandBuilder().setName('sessions').setDescription('저장된 세션 목록 조회 / 불러오기'),
];

// ── 유틸 ──
function runTracker(...args) {
  try {
    return execFileSync('bash', [TRACKER_BIN, ...args], {
      encoding: 'utf8',
      timeout: 30000,
      env: { ...process.env, TERM: 'dumb' },
    });
  } catch (e) {
    return e.stdout || e.message;
  }
}

function runTrackerAsync(...args) {
  return new Promise((resolve) => {
    execFile('bash', [TRACKER_BIN, ...args], {
      encoding: 'utf8',
      timeout: 30000,
      env: { ...process.env, TERM: 'dumb' },
    }, (err, stdout) => {
      resolve(stdout || (err && err.message) || '');
    });
  });
}

function formatTokens(n) {
  if (n >= 1000000) return `${(n / 1000000).toFixed(1)}M`;
  if (n >= 1000) return `${Math.floor(n / 1000)}K`;
  return `${n}`;
}

// state.json 캐시 (5초 TTL) — 매번 디스크 읽기 방지
let _stateCache = null;
let _stateCacheTime = 0;
const STATE_CACHE_TTL = 5_000;

function getState() {
  const now = Date.now();
  if (_stateCache && now - _stateCacheTime < STATE_CACHE_TTL) return _stateCache;
  try { _stateCache = JSON.parse(readFileSync(STATE_FILE, 'utf8')); }
  catch {
    console.warn('[state] state.json 읽기 실패, 빈 상태 반환');
    _stateCache = { sessions: {}, projects: {} };
  }
  _stateCacheTime = now;
  return _stateCache;
}

function invalidateStateCache() {
  _stateCache = null;
  _stateCacheTime = 0;
}

// PID 체크를 배치로 — tasklist 한 번 호출로 모든 claude.exe PID 캐시 (10초 TTL)
let _alivePidCache = null;
let _alivePidCacheTime = 0;
const PID_CACHE_TTL = 10_000;

function getAlivePids() {
  const now = Date.now();
  if (_alivePidCache && now - _alivePidCacheTime < PID_CACHE_TTL) return _alivePidCache;
  try {
    const out = execFileSync('tasklist', ['/FI', 'IMAGENAME eq claude.exe', '/NH'], {
      encoding: 'utf8', timeout: 10000, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe']
    });
    _alivePidCache = new Set(
      [...out.matchAll(/\s+(\d+)\s/g)].map(m => parseInt(m[1]))
    );
  } catch {
    _alivePidCache = new Set();
  }
  _alivePidCacheTime = now;
  return _alivePidCache;
}

function isWinPidAlive(pid) {
  if (!pid || pid <= 0) return false;
  return getAlivePids().has(pid);
}

// auto_discovered 세션도 포함, 프로젝트 상태 결정 시 active가 idle보다 우선
function getAliveState() {
  const state = getState();
  const alive = {};
  const aliveProjects = {};
  const alivePids = getAlivePids();
  for (const [sid, s] of Object.entries(state.sessions || {})) {
    const pidAlive = s.pid && alivePids.has(s.pid);
    if (pidAlive || s.auto_discovered) {
      alive[sid] = s;
      if (s.project) {
        const proj = state.projects?.[s.project] || { status: s.status };
        const existing = aliveProjects[s.project];
        // active 상태가 idle보다 우선
        if (!existing || s.status === 'active') {
          aliveProjects[s.project] = proj;
        }
      }
    }
  }
  return { sessions: alive, projects: aliveProjects };
}

function getTokenHistory(since) {
  if (!existsSync(TOKEN_HISTORY)) return [];
  try {
    const lines = readFileSync(TOKEN_HISTORY, 'utf8').trim().split('\n').filter(Boolean);
    const entries = lines.map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
    if (since) return entries.filter(e => e.date >= since);
    return entries;
  } catch { return []; }
}

function findProjectCwd(projectName) {
  // 디폴트 프로젝트: 항상 사용 가능
  if (projectName === DEFAULT_PROJECT_NAME) {
    if (!existsSync(DEFAULT_PROJECT_CWD)) mkdirSync(DEFAULT_PROJECT_CWD, { recursive: true });
    return DEFAULT_PROJECT_CWD;
  }
  const state = getAliveState();
  const lower = projectName.toLowerCase();
  for (const s of Object.values(state.sessions || {})) {
    if (s.project === projectName) return s.cwd;
  }
  for (const s of Object.values(state.sessions || {})) {
    if (s.project.toLowerCase().includes(lower)) return s.cwd;
  }
  // 폴백: 과거 세션에서 기억한 CWD (컴퓨터에서 Claude가 꺼져 있어도 재시작 가능)
  const cfg = getConfig();
  if (cfg.known_projects?.[projectName]) return cfg.known_projects[projectName];
  return null;
}

function saveKnownProject(name, cwd) {
  const cfg = getConfig();
  if (!cfg.known_projects) cfg.known_projects = {};
  if (!cfg.known_projects[name]) {
    cfg.known_projects[name] = cwd;
    saveConfig(cfg);
  }
}

function isImageFile(filename) {
  if (!filename) return false;
  const dot = filename.lastIndexOf('.');
  if (dot === -1) return false;
  return IMAGE_EXTENSIONS.includes(filename.slice(dot).toLowerCase());
}

async function downloadAttachment(attachment) {
  if (attachment.size > MAX_IMAGE_SIZE) {
    throw new Error(`파일 크기 초과 (${(attachment.size / 1024 / 1024).toFixed(1)}MB > ${MAX_IMAGE_SIZE / 1024 / 1024}MB)`);
  }
  mkdirSync(TEMP_DIR, { recursive: true });
  const dot = attachment.name.lastIndexOf('.');
  const ext = dot !== -1 ? attachment.name.slice(dot) : '.bin';
  const filePath = join(TEMP_DIR, `${Date.now()}-${randomUUID().slice(0, 8)}${ext}`);
  const res = await fetch(attachment.proxyURL || attachment.url);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  writeFileSync(filePath, Buffer.from(await res.arrayBuffer()));
  return filePath;
}

function cleanupTempFile(filePath) {
  if (filePath) try { unlinkSync(filePath); } catch {}
}

function cleanupTempFiles(paths) {
  for (const p of paths) cleanupTempFile(p);
}

// Embed 텍스트 길이 초과 시 앞부분 생략
function trimEmbedText(text, fallback = '_(빈 응답)_') {
  if (!text) return fallback;
  return text.length > EMBED_MAX_CHARS ? '…' + text.slice(-EMBED_TRIM_CHARS) : text;
}

// 텍스트 파일 첨부 내용 fetch
async function fetchTextFile(attachment) {
  const res = await fetch(attachment.proxyURL || attachment.url);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.text();
}

// 세션 파일 로드 (없으면 예외 발생)
function loadSessionFile(sessionId) {
  return JSON.parse(readFileSync(join(SESSIONS_DIR, `${sessionId}.json`), 'utf8'));
}

// 채널 기본 프로젝트 저장
function setChannelDefaultProject(channelId, projectName) {
  const cfg = getConfig();
  if (!cfg.channel_defaults) cfg.channel_defaults = {};
  cfg.channel_defaults[channelId] = projectName;
  saveConfig(cfg);
}

// starterMessage 편집 진행 콜백 생성
function makeProgressUpdater(session) {
  return async (content, elapsed) => {
    if (!session.starterMessageRef) return;
    try {
      await session.starterMessageRef.edit({ embeds: [buildProgressEmbed(session, content, elapsed)] });
    } catch {}
  };
}

// 기본 세션 객체 생성 (proc/threadRef 등 비영속 필드 포함)
function createSessionObject({ channelId, channelName, projectName, cwd, model }) {
  return {
    id: randomUUID(),
    channelId,
    channelName: channelName || '',
    threadId: null,
    starterMessageId: null,
    projectName,
    cwd,
    model: model || 'opus',
    proc: null,
    createdAt: Date.now(),
    lastActivity: Date.now(),
    endedAt: null,
    turnCount: 0,
    messageHistory: [],
    tokenStats: { totalHistoryChars: 0, lastContextChars: 0, warningLevel: 'safe' },
    threadRef: null,
    starterMessageRef: null,
  };
}

// 세션에 연결된 Discord 스레드 생성
async function initSessionThread(session, starterMsg) {
  const threadName = session.channelName
    ? `[Claude] #${session.channelName} | ${session.projectName}`
    : `[Claude] ${session.projectName}`;
  try {
    const thread = await starterMsg.startThread({
      name: threadName.slice(0, THREAD_NAME_MAX),
      autoArchiveDuration: THREAD_AUTO_ARCHIVE,
    });
    session.threadId = thread.id;
    session.starterMessageId = starterMsg.id;
    session.threadRef = thread;
    session.starterMessageRef = starterMsg;
  } catch (e) {
    console.error('[thread] 스레드 생성 실패:', e.message);
    session.starterMessageRef = starterMsg;
  }
}

async function prepareImageAttachments(attachments) {
  const paths = [];
  for (const att of attachments) {
    try {
      paths.push(await downloadAttachment(att));
    } catch (e) {
      console.warn('[image] 다운로드 실패:', e.message);
    }
  }
  return paths;
}

function buildImagePrompt(baseText, imagePaths, overrideDisplayText) {
  if (imagePaths.length === 0) return { promptText: baseText, displayText: overrideDisplayText };
  const refs = imagePaths.map((p, i) => `${i + 1}. ${p}`).join('\n');
  const prefix = baseText ? baseText + '\n\n' : '';
  const displayBase = overrideDisplayText ?? (baseText || '');
  return {
    promptText: prefix + `[사용자가 이미지 ${imagePaths.length}개를 첨부했습니다. 다음 경로의 파일을 각각 읽어서 확인하세요:\n${refs}]`,
    displayText: (displayBase ? displayBase + '\n' : '') + `📎 _이미지 ${imagePaths.length}개 첨부됨_`,
  };
}

function saveConfig(cfg) {
  writeFileSync(CONFIG_FILE, JSON.stringify(cfg, null, 2), 'utf8');
  invalidateConfigCache();
}

// ── Phase 3.1: 토큰 통계 계산 ──

function updateTokenStats(session) {
  const totalChars = session.messageHistory.reduce((sum, m) => sum + m.content.length, 0);

  const cfg = getConfig();
  const thresholds = cfg.token_warning_thresholds || {
    caution: 20000,
    warning: 50000,
    critical: 100000,
  };

  let level = 'safe';
  if (totalChars > thresholds.critical) level = 'critical';
  else if (totalChars > thresholds.warning) level = 'warning';
  else if (totalChars > thresholds.caution) level = 'caution';

  session.tokenStats = {
    totalHistoryChars: totalChars,
    lastContextChars: 0,
    warningLevel: level,
  };
}

// ── Embed 헬퍼 ──

function buildProgressEmbed(session, content, elapsed) {
  return new EmbedBuilder()
    .setTitle(`⏳ ${session.projectName}`)
    .setColor(COLOR.WARNING)
    .setDescription(content)
    .setFooter({ text: `${session.model} · ${elapsed}s · 턴 ${session.turnCount + 1}` });
}

function buildResultEmbed(session, result) {
  const display = trimEmbedText(result.displayText);

  const color = result.timedOut ? COLOR.TIMEOUT
    : result.exitCode === 0 ? COLOR.SUCCESS
    : COLOR.ERROR;

  const embed = new EmbedBuilder()
    .setTitle(`${result.timedOut ? '⚠️' : '📨'} ${session.projectName}`)
    .setColor(color)
    .setDescription(display)
    .setTimestamp();

  const stats = session.tokenStats;
  if (stats) {
    if (stats.warningLevel === 'caution') {
      embed.addFields({ name: '🟡 컨텍스트 알림', value: `히스토리 ${(stats.totalHistoryChars / 1000).toFixed(0)}K자 — 증가 중`, inline: false });
    } else if (stats.warningLevel === 'warning') {
      embed.addFields({ name: '🟠 컨텍스트 경고', value: `히스토리 ${(stats.totalHistoryChars / 1000).toFixed(0)}K자 — 답변 품질 저하 가능. **새 세션 권장**`, inline: false });
    } else if (stats.warningLevel === 'critical') {
      embed.addFields({ name: '🔴 컨텍스트 위험', value: `히스토리 ${(stats.totalHistoryChars / 1000).toFixed(0)}K자 — 컨텍스트 오염 위험!\n**히스토리 정리를 강력 권장합니다.**`, inline: false });
    }

    embed.setFooter({ text: `${session.model} · ${result.elapsed}s · 턴 ${session.turnCount} · 📝 ${(stats.totalHistoryChars / 1000).toFixed(0)}K자` });
  } else {
    embed.setFooter({ text: `${session.model} · ${result.elapsed}s · 턴 ${session.turnCount}` });
  }

  return embed;
}

function buildErrorEmbed(session, errorMessage) {
  return new EmbedBuilder()
    .setTitle(`❌ ${session.projectName}`)
    .setColor(COLOR.ERROR)
    .setDescription(`오류: ${errorMessage.slice(0, 500)}`)
    .setTimestamp();
}

// 스레드 내 턴별 히스토리 embed
function buildTurnHistoryEmbed(session, userText, result) {
  const embed = new EmbedBuilder()
    .setTitle(`턴 ${session.turnCount}`)
    .setColor(result.exitCode === 0 ? COLOR.SUCCESS : COLOR.ERROR)
    .addFields({ name: '💬 요청', value: userText.slice(0, EMBED_FIELD_MAX), inline: false })
    .setDescription(trimEmbedText(result.displayText))
    .setFooter({ text: `${session.model} · ${result.elapsed}s` })
    .setTimestamp();
  return embed;
}

function buildSessionButtons(channelId) {
  return new ActionRowBuilder().addComponents(
    new ButtonBuilder()
      .setCustomId(`session_continue:${channelId}`)
      .setLabel('💬 이어서 대화')
      .setStyle(ButtonStyle.Primary),
    new ButtonBuilder()
      .setCustomId(`session_cleanup:${channelId}`)
      .setLabel('🗑️ 히스토리 정리')
      .setStyle(ButtonStyle.Secondary),
    new ButtonBuilder()
      .setCustomId(`session_end:${channelId}`)
      .setLabel('🔚 세션 종료')
      .setStyle(ButtonStyle.Danger),
  );
}

// ── 컨텍스트 빌더 ──
function buildContextBlock(messageHistory) {
  if (messageHistory.length === 0) return '';

  const cfg = getConfig();
  const MAX_RECENT_MESSAGES = (cfg.max_context_history_turns || 4) * 2;
  const MAX_SUMMARY_CHARS = 150;
  const MAX_CONTEXT_CHARS = cfg.max_context_chars || 50000;

  const lines = ['[Previous conversation context for continuity]'];

  const olderMessages = messageHistory.length > MAX_RECENT_MESSAGES
    ? messageHistory.slice(0, messageHistory.length - MAX_RECENT_MESSAGES)
    : [];
  const recentMessages = messageHistory.slice(-MAX_RECENT_MESSAGES);

  if (olderMessages.length > 0) {
    lines.push('--- Earlier (summarized) ---');
    for (const msg of olderMessages) {
      const prefix = msg.role === 'user' ? 'User' : 'Claude';
      const text = msg.content.slice(0, MAX_SUMMARY_CHARS);
      lines.push(`${prefix}: ${text}${msg.content.length > MAX_SUMMARY_CHARS ? '...' : ''}`);
    }
  }

  if (recentMessages.length > 0) {
    lines.push('--- Recent conversation ---');
    for (const msg of recentMessages) {
      const prefix = msg.role === 'user' ? 'User' : 'Claude';
      const text = msg.content.length > 3000
        ? msg.content.slice(0, 3000) + '\n[...truncated]'
        : msg.content;
      lines.push(`${prefix}: ${text}`);
    }
  }

  lines.push('[End of context]');
  let block = lines.join('\n');

  if (block.length > MAX_CONTEXT_CHARS) {
    if (block.length > 30000) {
      console.warn(`[context] 컨텍스트 ${block.length}자 → 축소 중`);
    }
    const trimmedLines = ['[Previous conversation context for continuity]', '--- Recent conversation ---'];
    for (const msg of recentMessages.slice(-4)) {
      const prefix = msg.role === 'user' ? 'User' : 'Claude';
      const text = msg.content.length > 1000
        ? msg.content.slice(0, 1000) + '\n[...truncated]'
        : msg.content;
      trimmedLines.push(`${prefix}: ${text}`);
    }
    trimmedLines.push('[End of context]');
    block = trimmedLines.join('\n');
  }

  return block;
}

// ── 스트림 파서 ──
function parseStreamJson(proc, onEvent) {
  let buffer = '';
  proc.stdout.on('data', (chunk) => {
    buffer += chunk.toString('utf8');
    const lines = buffer.split('\n');
    buffer = lines.pop();
    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        onEvent(JSON.parse(line));
      } catch {}
    }
  });
}

// ── 공통 Claude 턴 실행 ──
function executeClaudeTurn({ session, userText, onUpdate, timeout = SEND_TIMEOUT }) {
  const contextBlock = buildContextBlock(session.messageHistory.slice(0, -1));
  const fullPrompt = contextBlock
    ? `[Conversation context]\n${contextBlock}\n\n[Current request]\n${userText}`
    : userText;

  const args = [
    '-p', fullPrompt,
    '--model', session.model,
    '--output-format', 'stream-json',
    '--include-partial-messages',
    '--verbose',
    '--no-session-persistence',
    '--dangerously-skip-permissions',
  ];

  const proc = spawn('claude', args, {
    cwd: session.cwd,
    env: { ...process.env, CLAUDECODE: '', TERM: 'dumb', NO_COLOR: '1' },
    stdio: ['ignore', 'pipe', 'pipe'],
    shell: false,
  });
  session.proc = proc;

  let displayBuffer = '';
  let toolStatus = '';
  let finalResult = '';
  let stderrBuffer = '';
  const startTime = Date.now();
  const cfg = getConfig();
  const editIntervalMs = cfg.stream_edit_interval_ms || 2000;

  proc.stderr.on('data', (d) => {
    if (stderrBuffer.length < 10000) stderrBuffer += d.toString('utf8');
  });

  parseStreamJson(proc, (event) => {
    if (event.type === 'stream_event') {
      const ev = event.event;
      if (ev?.delta?.type === 'text_delta') {
        displayBuffer += ev.delta.text;
      }
      if (ev?.type === 'content_block_start' && ev.content_block?.type === 'tool_use') {
        toolStatus = `🔧 _${ev.content_block.name}_ 실행 중...`;
      }
      if (ev?.type === 'content_block_stop' && toolStatus) {
        displayBuffer += `\n${toolStatus.replace('실행 중...', '완료')}\n`;
        toolStatus = '';
      }
    }

    if (event.type === 'result' && event.result) {
      finalResult = typeof event.result === 'string'
        ? event.result
        : (event.result.text || JSON.stringify(event.result));
    }
  });

  const editTimer = setInterval(async () => {
    if (displayBuffer.length > 0 && onUpdate) {
      const elapsed = ((Date.now() - startTime) / 1000).toFixed(0);
      const display = displayBuffer.length > 3800
        ? '…' + displayBuffer.slice(-3700)
        : displayBuffer;
      const content = display + (toolStatus ? `\n\n${toolStatus}` : '');
      try {
        await onUpdate(content, elapsed);
      } catch {}
    }
  }, editIntervalMs);

  return new Promise((resolve, reject) => {
    let settled = false;

    const timeoutTimer = setTimeout(() => {
      if (!settled) {
        proc.kill('SIGKILL');
        const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
        settle({
          displayText: displayBuffer,
          historyText: finalResult || displayBuffer,
          elapsed,
          exitCode: -1,
          timedOut: true,
          stderr: stderrBuffer,
        });
      }
    }, timeout);

    const settle = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeoutTimer);
      clearInterval(editTimer);
      session.proc = null;
      resolve(result);
    };

    proc.on('close', (code) => {
      const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
      settle({
        displayText: displayBuffer,
        historyText: finalResult || displayBuffer,
        elapsed,
        exitCode: code,
        timedOut: false,
        stderr: stderrBuffer,
      });
    });

    proc.on('error', (err) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeoutTimer);
      clearInterval(editTimer);
      session.proc = null;
      reject(new Error(err.message + (stderrBuffer ? `\n${stderrBuffer}` : '')));
    });
  });
}

// ── 대시보드/상태 핸들러 ──

function buildDashboardEmbed() {
  const state = getAliveState();
  const sessions = Object.values(state.sessions || {});
  const active = sessions.filter(s => s.status === 'active');
  const idle = sessions.filter(s => s.status === 'idle');

  const embed = new EmbedBuilder()
    .setTitle('🤖 Claude Process Status')
    .setColor(active.length > 0 ? COLOR.SUCCESS : (sessions.length > 0 ? COLOR.WARNING : COLOR.INFO))
    .setTimestamp();

  if (sessions.length === 0) {
    embed.setDescription('활성 프로세스가 없습니다.');
  }

  const sorted = [...sessions].sort((a, b) => {
    const order = { active: 0, idle: 1 };
    return (order[a.status] ?? 2) - (order[b.status] ?? 2);
  });

  const MAX_DISPLAY = 8;
  for (const s of sorted.slice(0, MAX_DISPLAY)) {
    const icon = s.status === 'active' ? '🟢' : '🟡';
    const statusText = s.status === 'active' ? '**작업 중**' : '대기';
    const agents = s.agent_count || 0;
    const tokens = s.live_total_tokens ? `\n🔤 ${formatTokens(s.live_total_tokens)} tokens` : '';
    embed.addFields({
      name: `${icon} ${s.project}`,
      value: `${statusText} · 에이전트 ${agents}개${tokens}`,
      inline: true,
    });
  }
  if (sorted.length > MAX_DISPLAY) {
    embed.addFields({
      name: '\u200b',
      value: `_+${sorted.length - MAX_DISPLAY}개 프로젝트 더 있음_`,
      inline: false,
    });
  }

  const totalAgents = sessions.reduce((sum, s) => sum + (s.agent_count || 0), 0);
  const totalTokens = sessions.reduce((sum, s) => sum + (s.live_total_tokens || 0), 0);
  embed.addFields({
    name: '📊 현황',
    value: `🟢 작업 중 **${active.length}** · 🟡 대기 **${idle.length}** · 에이전트 총 **${totalAgents}**개` +
           (totalTokens > 0 ? `\n🔤 실시간 토큰 합계 **${formatTokens(totalTokens)}**` : ''),
    inline: false,
  });

  const now = new Date();
  const timeStr = now.toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false });
  embed.setFooter({ text: `마지막 업데이트: ${timeStr}` });

  const row = new ActionRowBuilder().addComponents(
    new ButtonBuilder()
      .setCustomId('dashboard_refresh')
      .setLabel('새로고침')
      .setEmoji('🔄')
      .setStyle(ButtonStyle.Secondary)
  );

  return { embeds: [embed], components: [row] };
}

async function handleStatus() {
  await runTrackerAsync('scan');
  invalidateStateCache();
  return buildDashboardEmbed();
}

function handleSnapshot() {
  runTracker('snapshot');
  return { content: '✅ 스냅샷이 기록되었습니다.', ephemeral: true };
}

function handleReport(period = 'today') {
  const now = new Date();
  let since;
  switch (period) {
    case 'week': since = new Date(now - 7 * 86400000).toISOString().slice(0, 10); break;
    case 'all': since = null; break;
    default: since = now.toISOString().slice(0, 10); break;
  }

  const entries = getTokenHistory(since);
  if (entries.length === 0) {
    return { content: '📋 해당 기간에 기록이 없습니다.' };
  }

  const byDate = {};
  for (const e of entries) {
    if (!byDate[e.date]) byDate[e.date] = {};
    if (!byDate[e.date][e.project]) byDate[e.date][e.project] = { maxTokens: 0, prompts: new Set() };
    const p = byDate[e.date][e.project];
    p.maxTokens = Math.max(p.maxTokens, e.total_tokens || 0);
    for (const pr of (e.prompts || [])) {
      if (pr && !pr.startsWith('<task-notification>')) p.prompts.add(pr.slice(0, 100));
    }
  }

  const embed = new EmbedBuilder()
    .setTitle('📋 토큰 히스토리 리포트')
    .setColor(COLOR.INFO)
    .setTimestamp();

  const dates = Object.keys(byDate).sort().reverse().slice(0, 7);
  for (const date of dates) {
    const projects = Object.entries(byDate[date])
      .map(([proj, data]) => ({ proj, ...data }))
      .sort((a, b) => b.maxTokens - a.maxTokens);

    const lines = projects.map(p => {
      const icon = p.maxTokens >= 100000 ? '🔴' : p.maxTokens >= 50000 ? '🟡' : '🟢';
      const promptList = [...p.prompts].slice(0, 2)
        .map(pr => `  💬 _${pr.slice(0, 60)}${pr.length > 60 ? '…' : ''}_`).join('\n');
      return `${icon} **${p.proj}** — ${formatTokens(p.maxTokens)} tokens` +
             (promptList ? `\n${promptList}` : '');
    });

    embed.addFields({ name: `📅 ${date}`, value: lines.join('\n\n') || '-', inline: false });
  }

  return { embeds: [embed] };
}

async function handleDashboard(interaction) {
  await runTrackerAsync('scan');
  invalidateStateCache();
  const payload = buildDashboardEmbed();
  const cfg = getConfig();

  if (cfg.dashboard_channel_id && cfg.dashboard_message_id) {
    try {
      const channel = await client.channels.fetch(cfg.dashboard_channel_id);
      const msg = await channel.messages.fetch(cfg.dashboard_message_id);
      await msg.edit(payload);
      await interaction.editReply({ content: '✅ 대시보드가 갱신되었습니다.' });
      return;
    } catch (e) {
      console.log('[dashboard] 기존 메시지를 찾을 수 없음, 새로 생성합니다.');
    }
  }

  const channel = await client.channels.fetch(interaction.channelId);
  const msg = await channel.send(payload);

  cfg.dashboard_channel_id = interaction.channelId;
  cfg.dashboard_message_id = msg.id;
  saveConfig(cfg);

  await interaction.editReply({ content: '✅ 대시보드가 이 채널에 설정되었습니다.' });
}

// ── /project 핸들러 ──

async function handleProject(interaction) {
  await runTrackerAsync('scan');
  invalidateStateCache();
  const state = getAliveState();
  const sessions = Object.values(state.sessions || {});
  const activeOrIdle = sessions.filter(s => s.status === 'active' || s.status === 'idle');

  if (activeOrIdle.length === 0) {
    return interaction.reply({
      content: '❌ 활성/유휴 프로젝트가 없습니다.',
      ephemeral: true,
    });
  }

  const cfg = getConfig();
  const currentDefault = (cfg.channel_defaults || {})[interaction.channelId];

  const sorted = activeOrIdle.sort((a, b) => {
    const order = { active: 0, idle: 1 };
    return (order[a.status] ?? 2) - (order[b.status] ?? 2);
  });

  if (sorted.length <= 5) {
    const row = new ActionRowBuilder();
    for (const s of sorted) {
      const icon = s.status === 'active' ? '\u{1F7E2}' : '\u{1F7E1}';
      row.addComponents(
        new ButtonBuilder()
          .setCustomId(`project_select:${s.project}`)
          .setLabel(`${icon} ${s.project}`)
          .setStyle(s.project === currentDefault ? ButtonStyle.Success : ButtonStyle.Secondary)
      );
    }

    const content = currentDefault
      ? `현재 기본 프로젝트: **${currentDefault}**\n변경할 프로젝트를 선택하세요:`
      : '이 채널의 기본 프로젝트를 선택하세요:';

    await interaction.reply({ content, components: [row], ephemeral: true });
  } else {
    const select = new StringSelectMenuBuilder()
      .setCustomId('project_select_menu')
      .setPlaceholder('프로젝트를 선택하세요')
      .addOptions(sorted.slice(0, SELECT_MAX_OPTIONS).map(s => ({
        label: s.project,
        value: s.project,
        emoji: s.status === 'active' ? '\u{1F7E2}' : '\u{1F7E1}',
        default: s.project === currentDefault,
      })));

    const row = new ActionRowBuilder().addComponents(select);

    const content = currentDefault
      ? `현재 기본 프로젝트: **${currentDefault}**\n변경할 프로젝트를 선택하세요:`
      : '이 채널의 기본 프로젝트를 선택하세요:';

    await interaction.reply({ content, components: [row], ephemeral: true });
  }
}

// ── 공통 세션 종료 (중복 제거) ──
// handleEnd, session_end 버튼, session_cleanup 버튼에서 공통으로 사용

async function terminateSession(channelId, { threadMessage = '🔚 세션 종료.', sendRestartButton = true } = {}) {
  const session = activeSessions.get(channelId);
  if (!session) return null;

  // 1. 종료 시각 기록 + 영속화
  session.endedAt = Date.now();
  saveSession(session);

  // 2. 프로세스 종료
  if (isSessionBusy(session)) {
    session.proc.kill('SIGKILL');
  }

  // 3. 스레드에 종료 메시지 전송 후 아카이브
  if (session.threadRef) {
    try {
      await session.threadRef.send({ content: threadMessage });
    } catch (e) {
      console.warn('[terminate] 스레드 메시지 전송 실패:', e.message);
    }
    try {
      await session.threadRef.setArchived(true);
    } catch (e) {
      console.warn('[terminate] 스레드 아카이브 실패:', e.message);
    }
  }

  // 3.5. 부모 채널에 재시작 버튼 전송
  if (sendRestartButton) {
    try {
      const parentChannel = await client.channels.fetch(session.channelId);
      const restartRow = new ActionRowBuilder().addComponents(
        new ButtonBuilder()
          .setCustomId(`session_restart:${session.id}`)
          .setLabel('🔄 다시 시작')
          .setStyle(ButtonStyle.Primary)
      );
      const channelTag = session.channelName ? ` (#${session.channelName})` : '';
      await parentChannel.send({
        content: `💤 **${session.projectName}**${channelTag} 세션이 종료됐습니다.`,
        components: [restartRow],
      });
    } catch (e) {
      console.warn('[terminate] 재시작 버튼 전송 실패:', e.message);
    }
  }

  // 4. starter message + 스레드 마지막 버튼 메시지에서 버튼 제거
  if (session.starterMessageRef) {
    try {
      await session.starterMessageRef.edit({ components: [] });
    } catch (e) {
      console.warn('[terminate] starter 버튼 제거 실패:', e.message);
    }
  }
  if (session.lastThreadButtonMsg) {
    try {
      await session.lastThreadButtonMsg.edit({ components: [] });
    } catch (e) {
      console.warn('[terminate] 스레드 버튼 제거 실패:', e.message);
    }
  }

  // 5. activeSessions에서 제거
  activeSessions.delete(channelId);

  return session;
}

// ── 공통 턴 실행 + 결과 처리 (Phase 2 통합) ──
// 세션의 starterMessage를 업데이트하고 스레드에 히스토리를 게시하는 공통 로직

async function runTurnAndUpdateThread({ session, userText, userDisplayText, onProgress }) {
  pushHistory(session, 'user', userDisplayText || userText);
  session.lastActivity = Date.now();

  console.log(`[turn] ${session.projectName}: "${userText.slice(0, 50)}..." (model: ${session.model}, turn: ${session.turnCount + 1})`);

  const result = await executeClaudeTurn({
    session,
    userText,
    onUpdate: onProgress,
  });

  session.turnCount++;
  pushHistory(session, 'assistant', result.historyText);
  updateTokenStats(session);

  console.log(`[turn] 완료: ${result.elapsed}s, ${result.displayText.length}자`);

  // starter message 편집 (결과)
  if (session.starterMessageRef) {
    try {
      await session.starterMessageRef.edit({
        embeds: [buildResultEmbed(session, result)],
        components: [buildSessionButtons(session.channelId)],
      });
    } catch (e) {
      console.warn('[turn] starter message 편집 실패:', e.message);
    }
  }

  // 스레드에 턴 히스토리 게시 (버튼 포함)
  if (session.threadRef) {
    try {
      // 이전 스레드 버튼 메시지에서 버튼 제거
      if (session.lastThreadButtonMsg) {
        try {
          await session.lastThreadButtonMsg.edit({ components: [] });
        } catch (_) { /* 이전 메시지 편집 실패 무시 */ }
      }
      const threadMsg = await session.threadRef.send({
        embeds: [buildTurnHistoryEmbed(session, userDisplayText || userText, result)],
        components: [buildSessionButtons(session.channelId)],
      });
      session.lastThreadButtonMsg = threadMsg;
    } catch (e) {
      console.warn('[turn] 스레드 히스토리 게시 실패:', e.message);
    }
  }

  // 영속화
  saveSession(session);

  return result;
}

// ── /send 핸들러 (Phase 2: 스레드 기반 리디자인) ──

async function handleSend(interaction) {
  if (!isUserAllowed(interaction.user.id)) {
    return interaction.reply({
      content: '❌ /send 권한이 없습니다. config.json의 allowed_users에 등록하세요.',
      ephemeral: true,
    });
  }

  let projectName = interaction.options.getString('project');
  if (projectName) projectName = projectName.replace(/^[\u{1F7E0}-\u{1F7EB}]\s*/u, '');
  const messageText = interaction.options.getString('message') || '';
  const explicitModel = interaction.options.getString('model');
  const model = explicitModel || 'opus';
  const fileAttachment = interaction.options.getAttachment('file');
  const attachments = [
    interaction.options.getAttachment('image'),
    interaction.options.getAttachment('image2'),
    interaction.options.getAttachment('image3'),
  ].filter(a => a && isImageFile(a.name));

  // 텍스트 파일 내용 읽기 (4000자 초과 우회용)
  let fileContent = '';
  let fileLabel = '';
  if (fileAttachment) {
    const ext = (fileAttachment.name.split('.').pop() || '').toLowerCase();
    if (TEXT_EXTENSIONS.has(ext)) {
      try {
        fileContent = await fetchTextFile(fileAttachment);
        fileLabel = `📄 **${fileAttachment.name}** (${fileContent.length.toLocaleString()}자)`;
      } catch (e) {
        console.warn('[send] 파일 읽기 실패:', e.message);
      }
    }
  }

  // message와 file 중 하나는 반드시 있어야 함
  const combinedMessage = [messageText, fileContent].filter(Boolean).join('\n\n---\n\n');
  if (!combinedMessage.trim()) {
    return interaction.reply({
      content: '❌ 메시지를 입력하거나 텍스트 파일을 첨부하세요.',
      ephemeral: true,
    });
  }

  const channelName = interaction.channel?.name || '';

  // 동시 실행 가드 (빠른 Map 조회만 — defer 전에 가능)
  let session = activeSessions.get(interaction.channelId);
  if (isSessionBusy(session)) {
    return interaction.reply({
      content: '⚠️ 이 채널에서 이미 Claude가 작업 중입니다. 완료 후 다시 시도하세요.',
      ephemeral: true,
    });
  }

  // 빠른 경로: config 캐시만 사용, I/O 없음
  if (!projectName) {
    const cfg = getConfig();
    const channelDefault = (cfg.channel_defaults || {})[interaction.channelId];
    if (channelDefault) projectName = channelDefault;
  }

  // deferReply는 Discord 3초 제한 전에 반드시 호출
  // 기존 세션에 스레드가 있고, 같은 프로젝트면 ephemeral
  const hasExistingThread = session?.threadId && (!projectName || session.projectName === projectName);
  if (hasExistingThread) {
    await interaction.deferReply({ flags: 64 });
  } else {
    await interaction.deferReply();
  }

  // 느린 작업은 defer 이후 실행 (runTracker scan, findProjectCwd 등)
  if (!projectName) {
    runTracker('scan');
    const state = getAliveState();
    const activeSess = Object.values(state.sessions || {}).filter(s => s.status === 'active' || s.status === 'idle');
    if (activeSess.length === 1) {
      projectName = activeSess[0].project;
    } else {
      // 활성 세션이 없거나 여러 개 → known_projects 폴백 (Claude가 꺼져있어도 자동 선택)
      const cfgK = getConfig();
      const knownNames = Object.keys(cfgK.known_projects || {});
      if (knownNames.length === 1) {
        projectName = knownNames[0];
      } else if (knownNames.length > 1) {
        saveFailedPrompt({ message: combinedMessage, project: null, reason: '프로젝트 미지정 (복수)', user: interaction.user.tag });
        return interaction.editReply({
          content: `❌ 프로젝트를 지정해주세요.\n알려진 프로젝트: **${knownNames.join('**, **')}**\n\`/project\`로 이 채널의 기본값을 설정하거나, \`/send\`에서 project 옵션을 선택하세요.`,
        });
      } else {
        // 활성 프로젝트도 known_projects도 없으면 → 디폴트 프로젝트 사용
        projectName = DEFAULT_PROJECT_NAME;
      }
    }
  }

  const cwd = findProjectCwd(projectName);
  if (!cwd) {
    const state = getAliveState();
    const available = Object.values(state.sessions || {}).map(s => s.project);
    saveFailedPrompt({ message: combinedMessage, project: projectName, reason: `프로젝트 "${projectName}" 없음`, user: interaction.user.tag });
    return interaction.editReply({
      content: `❌ 프로젝트 "${projectName}"을 찾을 수 없습니다.\n사용 가능: ${available.join(', ') || '없음'}`,
    });
  }

  // CWD 기억 (다음번에 Claude가 꺼져 있어도 재시작 가능)
  saveKnownProject(projectName, cwd);
  // 이 채널에 기본 프로젝트 미설정 시 자동 설정
  if (!getConfig().channel_defaults?.[interaction.channelId]) {
    setChannelDefaultProject(interaction.channelId, projectName);
  }

  // 프로젝트 전환 감지 → 기존 세션 종료 + 새 세션 생성
  if (session && session.projectName !== projectName) {
    await terminateSession(interaction.channelId, {
      threadMessage: `🔄 프로젝트 전환: **${projectName}**(으)로 이동`,
      sendRestartButton: false,
    });
    session = null;
  }

  // 세션 생성 또는 재사용
  if (!session) {
    session = createSessionObject({ channelId: interaction.channelId, channelName, projectName, cwd, model });
    activeSessions.set(interaction.channelId, session);
  } else if (explicitModel) {
    session.model = explicitModel;
  }

  // 이미지 첨부 처리
  const imagePaths = await prepareImageAttachments(attachments);
  // fileLabel이 있으면 displayText에 파일 정보 포함
  const baseDisplayText = fileLabel
    ? (messageText ? `${messageText}\n\n${fileLabel}` : fileLabel)
    : undefined;
  const { promptText: finalMessage, displayText: userDisplayText } = buildImagePrompt(combinedMessage, imagePaths, baseDisplayText);

  try {
    if (!session.threadId) {
      // 새 세션: reply가 starter message, 스레드를 붙임
      await interaction.editReply({ embeds: [buildProgressEmbed(session, '_처리 중..._', '0')] });
      const starterMsg = await interaction.fetchReply();
      await initSessionThread(session, starterMsg);

      try {
        await runTurnAndUpdateThread({
          session,
          userText: finalMessage,
          userDisplayText,
          onProgress: makeProgressUpdater(session),
        });
      } catch (e) {
        console.error(`[send] ${projectName} 실패:`, e.message);
        saveFailedPrompt({ message: combinedMessage, project: projectName, reason: e.message, user: interaction.user.tag });
        recordErrorInHistory(session);
        try {
          await interaction.editReply({ embeds: [buildErrorEmbed(session, e.message)] });
        } catch (editErr) {
          console.warn('[send] 에러 응답 편집 실패:', editErr.message);
        }
      }
    } else {
      // 기존 스레드가 있는 세션 — deferReply가 ephemeral로 호출됨
      try {
        await runTurnAndUpdateThread({
          session,
          userText: finalMessage,
          userDisplayText,
          onProgress: makeProgressUpdater(session),
        });
        await interaction.editReply({ content: `✅ 처리 완료. 스레드에서 확인하세요. (<#${session.threadId}>)` });
      } catch (e) {
        console.error(`[send] ${projectName} 실패:`, e.message);
        saveFailedPrompt({ message: combinedMessage, project: projectName, reason: e.message, user: interaction.user.tag });
        recordErrorInHistory(session);
        try {
          await interaction.editReply({ content: `❌ 오류: ${e.message.slice(0, 200)}` });
        } catch (editErr) {
          console.warn('[send] 에러 응답 편집 실패:', editErr.message);
        }
      }
    }
  } finally {
    cleanupTempFiles(imagePaths);
  }
}

// ── /end 핸들러 (Phase 7.1) ──

async function handleEnd(interaction) {
  const session = activeSessions.get(interaction.channelId);
  if (!session) {
    return interaction.reply({ content: '이 채널에 활성 세션이 없습니다.', ephemeral: true });
  }

  const terminated = await terminateSession(interaction.channelId, {
    threadMessage: `🔚 세션 종료. ${session.turnCount}턴 완료.`,
  });

  const summary = `세션 종료: **${terminated.projectName}**\n` +
    `턴: ${terminated.turnCount} · 시작: <t:${Math.floor(terminated.createdAt / 1000)}:R>`;

  await interaction.reply({ content: `✅ ${summary}\n저장된 세션은 \`/sessions\`에서 확인할 수 있습니다.` });
}

// ── /session 핸들러 (Phase 7.2) ──

async function handleSession(interaction) {
  const session = activeSessions.get(interaction.channelId);

  if (!session) {
    return interaction.reply({
      content: '이 채널에 활성 세션이 없습니다.\n`/send`로 새 세션을 시작하세요.',
      ephemeral: true,
    });
  }

  const isRunning = isSessionBusy(session);
  const embed = new EmbedBuilder()
    .setTitle(`📋 세션 정보`)
    .setColor(isRunning ? COLOR.WARNING : COLOR.SUCCESS)
    .addFields(
      { name: '프로젝트', value: session.projectName, inline: true },
      { name: '모델', value: session.model, inline: true },
      { name: '턴', value: `${session.turnCount}`, inline: true },
      { name: '상태', value: isRunning ? '⏳ 실행 중' : '✅ 대기', inline: true },
      { name: '히스토리', value: `${session.messageHistory.length}개 메시지`, inline: true },
    )
    .setFooter({ text: `마지막 활동: ${new Date(session.lastActivity).toLocaleTimeString('ko-KR')}` })
    .setTimestamp();

  if (session.threadId) {
    embed.addFields({
      name: '스레드',
      value: `<#${session.threadId}>`,
      inline: true,
    });
  }

  // 토큰 통계
  if (session.tokenStats) {
    embed.addFields({
      name: '📝 컨텍스트',
      value: `${(session.tokenStats.totalHistoryChars / 1000).toFixed(0)}K자 · ${session.tokenStats.warningLevel}`,
      inline: true,
    });
  }

  // 최근 메시지 미리보기
  const recent = session.messageHistory.slice(-4);
  if (recent.length > 0) {
    const preview = recent.map(m => {
      const prefix = m.role === 'user' ? '💬' : '🤖';
      const text = m.content.slice(0, 80);
      return `${prefix} ${text}${m.content.length > 80 ? '…' : ''}`;
    }).join('\n');
    embed.addFields({ name: '최근 대화', value: preview, inline: false });
  }

  await interaction.reply({ embeds: [embed], ephemeral: true });
}

// ── Phase 4.3: /sessions 핸들러 ──

async function handleSessions(interaction) {
  const files = readdirSync(SESSIONS_DIR).filter(f => f.endsWith('.json'));
  const sessions = [];
  for (const f of files) {
    try {
      const data = JSON.parse(readFileSync(join(SESSIONS_DIR, f), 'utf8'));
      sessions.push(data);
    } catch {}
  }
  sessions.sort((a, b) => b.lastActivity - a.lastActivity);

  if (sessions.length === 0) {
    return interaction.reply({ content: '저장된 세션이 없습니다.', ephemeral: true });
  }

  const select = new StringSelectMenuBuilder()
    .setCustomId('session_load_menu')
    .setPlaceholder('불러올 세션을 선택하세요')
    .addOptions(sessions.slice(0, SELECT_MAX_OPTIONS).map(s => ({
      label: `${s.projectName} — ${s.turnCount}턴`.slice(0, 100),
      description: `${new Date(s.lastActivity).toLocaleDateString('ko-KR')} · ${(s.tokenStats?.totalHistoryChars / 1000 || 0).toFixed(0)}K자`.slice(0, 100),
      value: s.id,
      emoji: s.endedAt ? '📦' : '🟢',
    })));

  const embed = new EmbedBuilder()
    .setTitle('📚 저장된 세션')
    .setColor(COLOR.INFO)
    .setDescription(sessions.slice(0, 10).map((s, i) => {
      const age = Math.floor((Date.now() - s.lastActivity) / 86400000);
      const status = s.endedAt ? '종료' : '**활성**';
      const deleteIn = s.endedAt ? `${Math.max(0, SESSION_RETENTION_DAYS - Math.floor((Date.now() - s.endedAt) / 86400000))}일 후 삭제` : '';
      return `${i + 1}. **${s.projectName}** — ${s.turnCount}턴 · ${status} · ${age}일 전${deleteIn ? ` · ⏳ ${deleteIn}` : ''}`;
    }).join('\n') || '_(없음)_');

  const row = new ActionRowBuilder().addComponents(select);
  await interaction.reply({ embeds: [embed], components: [row], ephemeral: true });
}

// ── 대시보드 자동 갱신 ──

let _dashboardRefreshCount = 0;
let _dashboardRefreshing = false;
let _dashboardFailCount = 0;
const DASHBOARD_FAIL_THRESHOLD = 3;
const DASHBOARD_SCAN_INTERVAL = 5; // 5번째 주기마다 scan 실행

async function updateDashboardMessage() {
  if (_dashboardRefreshing) return; // 중첩 실행 방지
  _dashboardRefreshing = true;
  try {
    const cfg = getConfig();
    if (!cfg.dashboard_channel_id || !cfg.dashboard_message_id) return;

    // 매 5번째 주기마다 scan 실행하여 state.json 갱신
    _dashboardRefreshCount++;
    if (_dashboardRefreshCount % DASHBOARD_SCAN_INTERVAL === 1) {
      await runTrackerAsync('scan');
      invalidateStateCache();
    }

    const channel = await client.channels.fetch(cfg.dashboard_channel_id);
    const msg = await channel.messages.fetch(cfg.dashboard_message_id);
    await msg.edit(buildDashboardEmbed());
    _dashboardFailCount = 0; // 성공 시 리셋
  } catch (e) {
    if (e.code === 10008 || e.code === 10003) {
      // 일시적 오류에도 바로 config 초기화하지 않고 연속 실패 카운터로 관리
      _dashboardFailCount++;
      console.warn(`[auto-refresh] 대시보드 접근 실패 (${_dashboardFailCount}/${DASHBOARD_FAIL_THRESHOLD})`);
      if (_dashboardFailCount >= DASHBOARD_FAIL_THRESHOLD) {
        console.warn('[auto-refresh] 연속 실패 한도 도달, config 초기화.');
        const cfg = getConfig();
        delete cfg.dashboard_channel_id;
        delete cfg.dashboard_message_id;
        saveConfig(cfg);
        _dashboardFailCount = 0;
      }
    } else {
      console.warn('[auto-refresh] 대시보드 갱신 실패:', e.message);
    }
  } finally {
    _dashboardRefreshing = false;
  }
}

// ── follow_up_mode 체크 ──

function shouldRespondToMessage(message) {
  const cfg = getConfig();
  const mode = cfg.follow_up_mode || 'mention';

  if (mode === 'all') return true;
  if (mode === 'mention') return message.mentions.has(client.user);
  if (mode.startsWith('prefix:')) {
    const prefix = mode.slice('prefix:'.length);
    return message.content.startsWith(prefix);
  }
  return false;
}

// ── Bot 시작 ──

const client = new Client({
  intents: [
    GatewayIntentBits.Guilds,
    GatewayIntentBits.GuildMessages,
    GatewayIntentBits.MessageContent,
  ]
});

client.once('ready', async () => {
  console.log(`✅ 봇 로그인: ${client.user.tag}`);

  mkdirSync(SESSIONS_DIR, { recursive: true });

  const rest = new REST({ version: '10' }).setToken(BOT_TOKEN);

  for (const [guildId, guild] of client.guilds.cache) {
    try {
      await rest.put(Routes.applicationGuildCommands(client.user.id, guildId), {
        body: commands.map(c => c.toJSON()),
      });
      console.log(`✅ 슬래시 커맨드 ${commands.length}개 등록됨 (${guild.name})`);
    } catch (e) {
      console.error(`커맨드 등록 실패 (${guild.name}):`, e);
    }
  }

  try {
    await rest.put(Routes.applicationCommands(client.user.id), { body: [] });
  } catch {}

  // 봇 재시작 시 영속 세션 복원
  try {
    const savedSessions = loadAllSessions();
    let restored = 0;
    for (const data of savedSessions) {
      if (data.endedAt) continue; // 종료된 세션은 activeSessions에 안 넣음

      try {
        const channel = await client.channels.fetch(data.channelId);
        let threadRef = null;
        let starterMessageRef = null;

        if (data.threadId && channel) {
          threadRef = await channel.threads.fetch(data.threadId).catch(() => null);
        }
        if (data.starterMessageId && channel) {
          starterMessageRef = await channel.messages.fetch(data.starterMessageId).catch(() => null);
        }

        const session = {
          ...data,
          proc: null,
          threadRef,
          starterMessageRef,
        };
        activeSessions.set(data.channelId, session);
        restored++;
        console.log(`[restore] 세션 복원: ${data.projectName} (${data.turnCount}턴)`);
      } catch (e) {
        console.warn(`[restore] 세션 복원 실패: ${data.projectName}`, e.message);
        data.endedAt = Date.now();
        saveSession(data);
      }
    }
    if (restored > 0) console.log(`[restore] 총 ${restored}개 세션 복원 완료`);
  } catch (e) {
    console.warn('[restore] 세션 복원 중 오류:', e.message);
  }

  // setTimeout 체이닝으로 중첩 실행 방지
  (function scheduleDashboardRefresh() {
    setTimeout(async () => {
      await updateDashboardMessage();
      scheduleDashboardRefresh();
    }, 60_000);
  })();

  // 5분마다 세션 타임아웃 체크
  setInterval(async () => {
    const now = Date.now();
    const cfg = getConfig();
    const timeout = (cfg.session_timeout_minutes || 30) * 60 * 1000;
    for (const [channelId, session] of activeSessions) {
      if (now - session.lastActivity > timeout) {
        console.log(`[cleanup] 세션 만료: ${session.projectName} (channel ${channelId})`);
        await terminateSession(channelId, {
          threadMessage: `💤 ${cfg.session_timeout_minutes || 30}분간 활동이 없어 세션을 자동 종료했습니다. \`/sessions\`에서 언제든 다시 불러올 수 있습니다.`,
        });
      }
    }
  }, 5 * 60 * 1000);

  // 1시간마다 보존 기간(10일) 초과 세션 삭제
  setInterval(async () => {
    try {
      const files = readdirSync(SESSIONS_DIR).filter(f => f.endsWith('.json'));
      const cutoff = Date.now() - SESSION_RETENTION_DAYS * 86400000;

      for (const file of files) {
        try {
          const data = JSON.parse(readFileSync(join(SESSIONS_DIR, file), 'utf8'));
          if (data.endedAt && data.endedAt < cutoff) {
            // Discord 스레드 삭제 시도
            if (data.threadId && data.starterMessageId) {
              try {
                const channel = await client.channels.fetch(data.channelId);
                const starterMsg = await channel.messages.fetch(data.starterMessageId);
                await starterMsg.delete();
              } catch {} // 이미 삭제됐으면 무시
            }
            unlinkSync(join(SESSIONS_DIR, file));
            console.log(`[cleanup] 10일 만료 세션 삭제: ${data.projectName}`);
          }
        } catch (e) {
          console.warn(`[cleanup] 세션 파일 처리 실패: ${file}`, e.message);
        }
      }
    } catch (e) {
      console.warn('[cleanup] 10일 정리 실행 실패:', e.message);
    }
  }, 60 * 60 * 1000);
});

// ── Interaction 핸들러 (분리) ──

async function handleAutocomplete(interaction) {
  const focused = interaction.options.getFocused();
  const state = getAliveState();
  const sessions = Object.values(state.sessions || {});
  const seen = new Set();
  const activeOrIdle = sessions
    .filter(s => s.status === 'active' || s.status === 'idle')
    .sort((a, b) => {
      const order = { active: 0, idle: 1 };
      return (order[a.status] ?? 2) - (order[b.status] ?? 2);
    })
    .filter(s => {
      if (seen.has(s.project)) return false;
      seen.add(s.project);
      return true;
    });

  const filtered = focused
    ? activeOrIdle.filter(s => s.project.toLowerCase().includes(focused.toLowerCase()))
    : activeOrIdle;

  const choices = filtered.slice(0, 24).map(s => {
    const icon = s.status === 'active' ? '\u{1F7E2}' : '\u{1F7E1}';
    return { name: `${icon} ${s.project}`, value: s.project };
  });
  // 디폴트 프로젝트 항상 표시 (중복 방지)
  if (!choices.some(c => c.value === DEFAULT_PROJECT_NAME) &&
      (!focused || DEFAULT_PROJECT_NAME.includes(focused.toLowerCase()))) {
    choices.push({ name: `\u{1F4E6} ${DEFAULT_PROJECT_NAME}`, value: DEFAULT_PROJECT_NAME });
  }

  await interaction.respond(choices);
}

async function handleButtonDashboardRefresh(interaction) {
  if (_dashboardRefreshing) {
    await interaction.deferUpdate();
    return;
  }
  const disabledRow = new ActionRowBuilder().addComponents(
    new ButtonBuilder()
      .setCustomId('dashboard_refresh')
      .setLabel('스캔 중...')
      .setEmoji('⏳')
      .setStyle(ButtonStyle.Secondary)
      .setDisabled(true)
  );
  await interaction.update({ components: [disabledRow] });
  await runTrackerAsync('scan');
  invalidateStateCache();
  await interaction.editReply(buildDashboardEmbed());
}

async function handleButtonProjectSelect(interaction) {
  const projectName = interaction.customId.slice('project_select:'.length);
  setChannelDefaultProject(interaction.channelId, projectName);
  await interaction.update({
    content: `이 채널의 기본 프로젝트가 **${projectName}**(으)로 설정되었습니다.\n이제 \`/send\`에서 프로젝트를 생략할 수 있습니다.`,
    components: [],
  });
}

async function handleButtonSessionContinue(interaction) {
  const channelId = interaction.customId.slice('session_continue:'.length);
  const session = activeSessions.get(channelId);
  if (!session) {
    await interaction.reply({ content: '세션이 만료되었습니다. `/send`로 새 세션을 시작하세요.', ephemeral: true });
    return;
  }

  const modal = new ModalBuilder()
    .setCustomId(`session_input:${channelId}`)
    .setTitle(`${session.projectName} — 이어서 대화`);

  const input = new TextInputBuilder()
    .setCustomId('message_input')
    .setLabel('메시지')
    .setPlaceholder('Claude에게 보낼 메시지를 입력하세요...')
    .setStyle(TextInputStyle.Paragraph)
    .setRequired(true);

  modal.addComponents(new ActionRowBuilder().addComponents(input));
  await interaction.showModal(modal);
}

async function handleButtonSessionCleanup(interaction) {
  const channelId = interaction.customId.slice('session_cleanup:'.length);
  if (!activeSessions.has(channelId)) {
    await interaction.reply({ content: '세션이 만료되었습니다.', ephemeral: true });
    return;
  }

  await terminateSession(channelId, {
    threadMessage: '✅ 세션 저장 완료. 새 세션을 시작합니다.',
    sendRestartButton: false,
  });

  await interaction.reply({
    content: `🗑️ 히스토리 정리 완료.\n다음 \`/send\`로 새 세션이 시작됩니다.\n이전 세션은 \`/sessions\`에서 불러올 수 있습니다.`,
  });
}

async function handleButtonSessionRestart(interaction) {
  const sessionId = interaction.customId.slice('session_restart:'.length);
  let restartData;
  try {
    restartData = loadSessionFile(sessionId);
  } catch {
    await interaction.reply({ content: '❌ 세션 정보를 찾을 수 없습니다.', ephemeral: true });
    return;
  }

  const modal = new ModalBuilder()
    .setCustomId(`restart_modal:${sessionId}`)
    .setTitle(`${restartData.projectName} — 다시 시작`);

  const restartInput = new TextInputBuilder()
    .setCustomId('message_input')
    .setLabel('첫 메시지')
    .setPlaceholder('Claude에게 보낼 메시지를 입력하세요...')
    .setStyle(TextInputStyle.Paragraph)
    .setRequired(true);

  modal.addComponents(new ActionRowBuilder().addComponents(restartInput));
  await interaction.showModal(modal);
}

async function handleButtonSessionEnd(interaction) {
  const channelId = interaction.customId.slice('session_end:'.length);
  const session = activeSessions.get(channelId);
  if (!session) {
    await interaction.reply({ content: '세션이 이미 종료되었습니다.', ephemeral: true });
    return;
  }

  const terminated = await terminateSession(channelId, {
    threadMessage: `🔚 세션 종료. ${session.turnCount}턴 완료.`,
  });

  const summary = `세션 종료: **${terminated.projectName}** (${terminated.turnCount}턴)`;
  await interaction.reply({ content: `✅ ${summary}\n저장된 세션은 \`/sessions\`에서 확인할 수 있습니다.` });
}

async function handleButton(interaction) {
  const id = interaction.customId;
  if (id === 'dashboard_refresh') return handleButtonDashboardRefresh(interaction);
  if (id.startsWith('project_select:')) return handleButtonProjectSelect(interaction);
  if (id.startsWith('session_continue:')) return handleButtonSessionContinue(interaction);
  if (id.startsWith('session_cleanup:')) return handleButtonSessionCleanup(interaction);
  if (id.startsWith('session_restart:')) return handleButtonSessionRestart(interaction);
  if (id.startsWith('session_end:')) return handleButtonSessionEnd(interaction);
}

async function handleSelectMenu(interaction) {
  if (interaction.customId === 'project_select_menu') {
    const projectName = interaction.values[0];
    setChannelDefaultProject(interaction.channelId, projectName);
    await interaction.update({
      content: `이 채널의 기본 프로젝트가 **${projectName}**(으)로 설정되었습니다.\n이제 \`/send\`에서 프로젝트를 생략할 수 있습니다.`,
      components: [],
    });
    return;
  }

  if (interaction.customId === 'session_load_menu') {
    const sessionId = interaction.values[0];
    let data;
    try {
      data = loadSessionFile(sessionId);
    } catch {
      await interaction.update({ content: '❌ 세션 파일을 찾을 수 없습니다.', components: [], embeds: [] });
      return;
    }

    if (activeSessions.has(interaction.channelId)) {
      await terminateSession(interaction.channelId, {
        threadMessage: '📦 다른 세션을 불러옵니다.',
        sendRestartButton: false,
      });
    }

    const newSession = {
      ...createSessionObject({ channelId: interaction.channelId, projectName: data.projectName, cwd: data.cwd, model: data.model }),
      turnCount: data.turnCount,
      messageHistory: data.messageHistory || [],
      tokenStats: data.tokenStats || { totalHistoryChars: 0, lastContextChars: 0, warningLevel: 'safe' },
    };
    activeSessions.set(interaction.channelId, newSession);
    saveSession(newSession);

    await interaction.update({
      content: `✅ **${data.projectName}** 세션 불러오기 완료 (${data.turnCount}턴, ${(data.messageHistory || []).length}개 메시지).\n\`/send\`로 대화를 이어가세요.`,
      components: [],
      embeds: [],
    });
  }
}

async function handleModalSessionInput(interaction) {
  const channelId = interaction.customId.slice('session_input:'.length);
  const session = activeSessions.get(channelId);
  if (!session) {
    await interaction.reply({ content: '세션이 만료되었습니다.', ephemeral: true });
    return;
  }

  if (!isUserAllowed(interaction.user.id)) {
    await interaction.reply({ content: '❌ 권한이 없습니다.', ephemeral: true });
    return;
  }

  if (isSessionBusy(session)) {
    await interaction.reply({ content: '⚠️ Claude가 아직 작업 중입니다.', ephemeral: true });
    return;
  }

  const userText = interaction.fields.getTextInputValue('message_input');
  if (!userText.trim()) {
    await interaction.reply({ content: '메시지를 입력해주세요.', ephemeral: true });
    return;
  }

  await interaction.deferReply({ flags: 64 });

  try {
    await runTurnAndUpdateThread({
      session,
      userText,
      onProgress: makeProgressUpdater(session),
    });
    await interaction.deleteReply().catch(() => {});
  } catch (e) {
    console.error(`[modal] ${session.projectName} 실패:`, e.message);
    recordErrorInHistory(session);
    try {
      await interaction.editReply({ content: `❌ 오류: ${e.message.slice(0, 200)}` });
    } catch (editErr) {
      console.warn('[modal] 에러 응답 편집 실패:', editErr.message);
    }
  }
}

async function handleModalRestart(interaction) {
  const sessionId = interaction.customId.slice('restart_modal:'.length);
  let restartData;
  try {
    restartData = loadSessionFile(sessionId);
  } catch {
    await interaction.reply({ content: '❌ 세션 정보를 찾을 수 없습니다.', ephemeral: true });
    return;
  }

  if (!isUserAllowed(interaction.user.id)) {
    await interaction.reply({ content: '❌ 권한이 없습니다.', ephemeral: true });
    return;
  }

  const userText = interaction.fields.getTextInputValue('message_input');
  if (!userText.trim()) {
    await interaction.reply({ content: '메시지를 입력해주세요.', ephemeral: true });
    return;
  }

  if (activeSessions.has(interaction.channelId)) {
    await terminateSession(interaction.channelId, {
      threadMessage: '🔄 세션을 재시작합니다.',
      sendRestartButton: false,
    });
  }

  const restartChannelName = interaction.channel?.name || restartData.channelName || '';
  const newSession = createSessionObject({
    channelId: interaction.channelId,
    channelName: restartChannelName,
    projectName: restartData.projectName,
    cwd: restartData.cwd,
    model: restartData.model,
  });
  activeSessions.set(interaction.channelId, newSession);

  await interaction.deferReply();
  const restartStarterMsg = await interaction.fetchReply();
  await restartStarterMsg.edit({ embeds: [buildProgressEmbed(newSession, '_처리 중..._', '0')] });
  await initSessionThread(newSession, restartStarterMsg);
  saveSession(newSession);

  try {
    await runTurnAndUpdateThread({
      session: newSession,
      userText,
      userDisplayText: userText,
      onProgress: makeProgressUpdater(newSession),
    });
  } catch (e) {
    console.error(`[restart] ${restartData.projectName} 실패:`, e.message);
    recordErrorInHistory(newSession);
    try {
      await interaction.editReply({ embeds: [buildErrorEmbed(newSession, e.message)] });
    } catch {}
  }
}

async function handleModalSubmit(interaction) {
  if (interaction.customId.startsWith('session_input:')) return handleModalSessionInput(interaction);
  if (interaction.customId.startsWith('restart_modal:')) return handleModalRestart(interaction);
}

// ── interactionCreate 핸들러 ──

client.on('interactionCreate', async (interaction) => {
  if (interaction.isAutocomplete()) {
    try { await handleAutocomplete(interaction); }
    catch (e) {
      console.error('autocomplete 오류:', e.message);
      try { await interaction.respond([]); } catch {}
    }
    return;
  }

  if (interaction.isButton()) {
    try { await handleButton(interaction); }
    catch (e) { console.error('버튼 처리 오류:', e.message); }
    return;
  }

  if (interaction.isStringSelectMenu()) {
    try { await handleSelectMenu(interaction); }
    catch (e) { console.error('셀렉트 메뉴 처리 오류:', e.message); }
    return;
  }

  if (interaction.isModalSubmit()) {
    try { await handleModalSubmit(interaction); }
    catch (e) { console.error('모달 처리 오류:', e.message); }
    return;
  }

  // ── 슬래시 커맨드 처리 ──
  if (!interaction.isChatInputCommand()) return;

  try {
    switch (interaction.commandName) {
      case 'status':
        await interaction.deferReply();
        await interaction.editReply(await handleStatus());
        break;
      case 'snapshot': await interaction.reply(handleSnapshot()); break;
      case 'report':
        await interaction.deferReply();
        await interaction.editReply(handleReport(interaction.options.getString('period') || 'today'));
        break;
      case 'dashboard':
        await interaction.deferReply({ ephemeral: true });
        await handleDashboard(interaction);
        break;
      case 'send': await handleSend(interaction); break;
      case 'project': await handleProject(interaction); break;
      case 'end': await handleEnd(interaction); break;
      case 'session': await handleSession(interaction); break;
      case 'sessions': await handleSessions(interaction); break;
      default: await interaction.reply({ content: '알 수 없는 명령어' });
    }
  } catch (e) {
    console.error('핸들러 오류:', e);
    try {
      const msg = { content: `❌ 오류: ${e.message}`, ephemeral: true };
      if (interaction.replied || interaction.deferred) {
        await interaction.followUp(msg);
      } else {
        await interaction.reply(msg);
      }
    } catch (replyErr) {
      console.error('오류 응답 전송 실패:', replyErr.message);
    }
  }
});

// ── Phase 6: messageCreate 스레드 감지 ──

function findSessionForMessage(message) {
  if (message.channel.isThread()) {
    const session = activeSessions.get(message.channel.parentId);
    if (session && session.threadId === message.channelId) {
      return { session, isThread: true };
    }
    return null;
  }

  const session = activeSessions.get(message.channelId);
  if (!session || !shouldRespondToMessage(message)) return null;
  return { session, isThread: false };
}

async function buildFollowUpPayload(message) {
  const rawText = message.content.trim()
    .replace(new RegExp(`<@!?${client.user.id}>`, 'g'), '').trim();

  const imageAtts = [...message.attachments.filter(a => isImageFile(a.name)).values()];
  const textAtts = [...message.attachments.filter(a => {
    const ext = (a.name.split('.').pop() || '').toLowerCase();
    return TEXT_EXTENSIONS.has(ext);
  }).values()];

  if (!rawText && imageAtts.length === 0 && textAtts.length === 0) return null;

  // 텍스트 파일 내용 읽기
  let textFileContent = '';
  let textFileLabel = '';
  for (const att of textAtts) {
    try {
      const content = await fetchTextFile(att);
      textFileContent += (textFileContent ? '\n\n---\n\n' : '') + content;
      textFileLabel += (textFileLabel ? ', ' : '') + `📄 ${att.name} (${content.length.toLocaleString()}자)`;
    } catch (e) {
      console.warn('[follow-up] 텍스트 파일 읽기 실패:', e.message);
    }
  }

  const combinedText = [rawText, textFileContent].filter(Boolean).join('\n\n---\n\n');
  if (!combinedText && imageAtts.length === 0) return null;

  const imagePaths = await prepareImageAttachments(imageAtts);
  const baseDisplay = textFileLabel ? (rawText ? `${rawText}\n${textFileLabel}` : textFileLabel) : undefined;
  const { promptText, displayText } = buildImagePrompt(combinedText || rawText, imagePaths, baseDisplay);

  const finalText = (imagePaths.length > 0 || textFileContent)
    ? (promptText || combinedText)
    : rawText;

  if (!finalText) { cleanupTempFiles(imagePaths); return null; }

  return { promptText: finalText, displayText, imagePaths };
}

client.on('messageCreate', async (message) => {
  if (message.author.bot || !message.guild) return;

  const match = findSessionForMessage(message);
  if (!match) return;
  const { session, isThread } = match;

  if (isSessionBusy(session)) {
    await message.react('⏳').catch(() => {});
    return;
  }
  if (!isUserAllowed(message.author.id)) return;

  const payload = await buildFollowUpPayload(message);
  if (!payload) return;

  await message.react('🔄').catch(() => {});
  session.lastActivity = Date.now();

  console.log(`[follow-up] ${session.projectName}: "${payload.promptText.slice(0, 50)}..." (turn: ${session.turnCount + 1}, thread: ${isThread})`);

  try {
    const result = await runTurnAndUpdateThread({
      session,
      userText: payload.promptText,
      userDisplayText: payload.displayText,
      onProgress: makeProgressUpdater(session),
    });

    await message.reactions.removeAll().catch(() => {});
    await message.react(result.exitCode === 0 ? '✅' : '❌').catch(() => {});
  } catch (e) {
    console.error(`[follow-up] ${session.projectName} 실패:`, e.message);
    recordErrorInHistory(session);

    await message.reactions.removeAll().catch(() => {});
    await message.react('❌').catch(() => {});

    if (session.threadRef) {
      try {
        await session.threadRef.send({ embeds: [buildErrorEmbed(session, e.message)] });
      } catch (threadErr) {
        console.warn('[follow-up] 스레드 에러 메시지 전송 실패:', threadErr.message);
      }
    }
  } finally {
    cleanupTempFiles(payload.imagePaths);
  }
});

// Graceful shutdown
function shutdown() {
  console.log('봇 종료 중...');
  // 모든 활성 세션 저장
  for (const [, session] of activeSessions) {
    try { saveSession(session); } catch {}
    if (isSessionBusy(session)) {
      session.proc.kill('SIGKILL');
    }
  }
  client.destroy();
  process.exit(0);
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

client.login(BOT_TOKEN).catch(err => {
  console.error('봇 로그인 실패:', err.message);
  process.exit(1);
});
