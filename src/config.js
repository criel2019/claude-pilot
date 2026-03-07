import { readFileSync, writeFileSync } from 'fs';
import { CONFIG_FILE, FAILED_PROMPTS_FILE, MAX_FAILED_PROMPTS } from './constants.js';

// Config file is cached for 30 seconds to avoid disk reads on every request
let _configCache = null;
let _configCacheTime = 0;
const CONFIG_CACHE_TTL = 30_000;

export function getConfig() {
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

export function invalidateConfigCache() {
  _configCache = null;
  _configCacheTime = 0;
}

export function saveConfig(cfg) {
  writeFileSync(CONFIG_FILE, JSON.stringify(cfg, null, 2), 'utf8');
  invalidateConfigCache();
}

// Default working directory: config.json's default_cwd, then home directory
export function getDefaultCwd() {
  const cfg = getConfig();
  return cfg.default_cwd || process.env.HOME || process.env.USERPROFILE || process.cwd();
}

// Re-read config on every call to support hot-reload without bot restart
export function isUserAllowed(userId) {
  const cfg = getConfig();
  const allowed = cfg.allowed_users;
  if (!allowed || allowed.length === 0) return true;
  return allowed.map(String).includes(String(userId));
}

// Persist failed prompts as JSONL for debugging, capped at MAX_FAILED_PROMPTS entries
export function saveFailedPrompt({ message, project, reason, user }) {
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

// BOT_TOKEN is read once at startup; missing token exits immediately with a clear message
export const BOT_TOKEN = (() => {
  const token = getConfig().bot_token;
  if (!token) {
    console.error('bot_token is missing from config.json.');
    console.error('Run install.sh or add it manually to ~/.claude-tracker/config.json');
    process.exit(1);
  }
  return token;
})();
