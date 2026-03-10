import { readFileSync, writeFileSync, existsSync, readdirSync, unlinkSync } from 'fs';
import { join } from 'path';
import { randomUUID } from 'crypto';
import {
  SESSIONS_DIR, MAX_HISTORY_MESSAGES, QUEUE_MAX_SIZE,
  DEFAULT_PROJECT_NAME, TOKEN_HISTORY,
} from './constants.js';
import { getConfig, saveConfig, getDefaultCwd } from './config.js';
import { getAliveState } from './tracker.js';

// Returns true if the session's Claude process is currently running
export function isSessionBusy(session) {
  return session?.proc && session.proc.exitCode === null;
}

// Adds an item to the pending message queue; returns false if the queue is full
export function enqueueMessage(session, item) {
  if (!session.pendingMessages) session.pendingMessages = [];
  if (session.pendingMessages.length >= QUEUE_MAX_SIZE) return false;
  session.pendingMessages.push(item);
  return true;
}

// Appends a message to the session history and enforces the max limit
export function pushHistory(session, role, content) {
  session.messageHistory.push({ role, content, timestamp: Date.now() });
  if (session.messageHistory.length > MAX_HISTORY_MESSAGES) {
    session.messageHistory = session.messageHistory.slice(-MAX_HISTORY_MESSAGES);
  }
}

// Records an error in history when a turn fails without an assistant response
export function recordErrorInHistory(session) {
  const lastMsg = session.messageHistory[session.messageHistory.length - 1];
  if (lastMsg && lastMsg.role === 'user') {
    pushHistory(session, 'assistant', '[Error — no response]');
  }
  saveSession(session);
}

export function resetHistory(session) {
  session.messageHistory = [];
  session.tokenStats = { totalHistoryChars: 0, lastContextChars: 0, warningLevel: 'safe' };
  saveSession(session);
}

// Persists a session to disk, excluding runtime-only fields
export function saveSession(session) {
  const data = { ...session };
  delete data.proc;
  delete data.threadRef;
  delete data.starterMessageRef;
  delete data.lastThreadButtonMsg;
  delete data.pendingMessages;
  delete data.drainingQueue;
  delete data.lastTurnText;
  delete data.lastTurnDisplayText;
  const filePath = join(SESSIONS_DIR, `${data.id}.json`);
  writeFileSync(filePath, JSON.stringify(data, null, 2), 'utf8');
}

export function loadAllSessions() {
  const files = readdirSync(SESSIONS_DIR).filter(f => f.endsWith('.json'));
  const sessions = [];
  for (const file of files) {
    try {
      const data = JSON.parse(readFileSync(join(SESSIONS_DIR, file), 'utf8'));
      sessions.push(data);
    } catch (e) {
      console.warn(`[load] Failed to read session file: ${file}`, e.message);
    }
  }
  return sessions;
}

export function loadSessionFile(sessionId) {
  return JSON.parse(readFileSync(join(SESSIONS_DIR, `${sessionId}.json`), 'utf8'));
}

export function deleteSessionFile(sessionId) {
  const filePath = join(SESSIONS_DIR, `${sessionId}.json`);
  try { unlinkSync(filePath); } catch {}
}

// Creates a new session object including runtime-only fields
export function createSessionObject({ channelId, channelName, projectName, cwd, model }) {
  return {
    id: randomUUID(),
    channelId,
    channelName: channelName || '',
    threadId: null,
    starterMessageId: null,
    projectName,
    cwd,
    model: model || 'opus',
    claudeSessionId: null,
    proc: null,
    createdAt: Date.now(),
    lastActivity: Date.now(),
    endedAt: null,
    turnCount: 0,
    messageHistory: [],
    modifiedFiles: new Set(), // Edit/Write 툴 콜로 수정된 파일 경로 추적
    tokenStats: { totalHistoryChars: 0, lastContextChars: 0, warningLevel: 'safe' },
    threadRef: null,
    starterMessageRef: null,
    lastThreadButtonMsg: null,
    pendingMessages: [],
    drainingQueue: false,
    lastTurnText: null,
    lastTurnDisplayText: null,
  };
}

// Recomputes token/context stats and warning level from current history
export function updateTokenStats(session) {
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

// Resolves the working directory for a given project name
export function findProjectCwd(projectName) {
  if (!projectName || projectName === DEFAULT_PROJECT_NAME) {
    return getDefaultCwd();
  }
  const state = getAliveState();
  const lower = projectName.toLowerCase();
  // Exact match first
  for (const s of Object.values(state.sessions || {})) {
    if (s.project === projectName) return s.cwd;
  }
  // Partial match
  for (const s of Object.values(state.sessions || {})) {
    if (s.project.toLowerCase().includes(lower)) return s.cwd;
  }
  // Fallback: remembered from a previous session (works even when Claude is not running)
  const cfg = getConfig();
  if (cfg.known_projects?.[projectName]) return cfg.known_projects[projectName];
  return getDefaultCwd();
}

// Saves a project's CWD to config so it can be resolved even after Claude exits
export function saveKnownProject(name, cwd) {
  const cfg = getConfig();
  if (!cfg.known_projects) cfg.known_projects = {};
  if (!cfg.known_projects[name]) {
    cfg.known_projects[name] = cwd;
    saveConfig(cfg);
  }
}

// Stores the default project for a Discord channel in config
export function setChannelDefaultProject(channelId, projectName) {
  const cfg = getConfig();
  if (!cfg.channel_defaults) cfg.channel_defaults = {};
  cfg.channel_defaults[channelId] = projectName;
  saveConfig(cfg);
}

export function getTokenHistory(since) {
  if (!existsSync(TOKEN_HISTORY)) return [];
  try {
    const lines = readFileSync(TOKEN_HISTORY, 'utf8').trim().split('\n').filter(Boolean);
    const entries = lines.map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
    if (since) return entries.filter(e => e.date >= since);
    return entries;
  } catch { return []; }
}
