import { execFileSync, execFile } from 'child_process';
import { readFileSync, readdirSync, statSync } from 'fs';
import { TRACKER_BIN, STATE_FILE } from './constants.js';

export function runTracker(...args) {
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

export function runTrackerAsync(...args) {
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

export function formatTokens(n) {
  if (n >= 1000000) return `${(n / 1000000).toFixed(1)}M`;
  if (n >= 1000) return `${Math.floor(n / 1000)}K`;
  return `${n}`;
}

// state.json cache with a 5-second TTL to avoid repeated disk reads
let _stateCache = null;
let _stateCacheTime = 0;
const STATE_CACHE_TTL = 5_000;

export function getState() {
  const now = Date.now();
  if (_stateCache && now - _stateCacheTime < STATE_CACHE_TTL) return _stateCache;
  try { _stateCache = JSON.parse(readFileSync(STATE_FILE, 'utf8')); }
  catch {
    console.warn('[state] Failed to read state.json, returning empty state');
    _stateCache = { sessions: {}, projects: {} };
  }
  _stateCacheTime = now;
  return _stateCache;
}

export function invalidateStateCache() {
  _stateCache = null;
  _stateCacheTime = 0;
}

// ── Batch PID check ──
// Calls tasklist once to get all live claude.exe PIDs and caches the result for 10 seconds.

let _alivePidCache = null;
let _alivePidCacheTime = 0;
const PID_CACHE_TTL = 10_000;

export function getAlivePids() {
  const now = Date.now();
  if (_alivePidCache && now - _alivePidCacheTime < PID_CACHE_TTL) return _alivePidCache;
  try {
    const out = execFileSync('tasklist', ['/FI', 'IMAGENAME eq claude.exe', '/NH'], {
      encoding: 'utf8', timeout: 10000, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe']
    });
    // tasklist output: "claude.exe   17812 Console   1   278,240 K"
    // Extract the PID (first number after the image name)
    _alivePidCache = new Set(
      [...out.matchAll(/^\S+\.exe\s+(\d+)\s/gm)].map(m => parseInt(m[1]))
    );
  } catch {
    _alivePidCache = new Set();
  }
  _alivePidCacheTime = now;
  return _alivePidCache;
}

export function isWinPidAlive(pid) {
  if (!pid || pid <= 0) return false;
  return getAlivePids().has(pid);
}

// ── Native process scanner ──
// Reads /tmp/claude-*-cwd files directly to detect running Claude processes.
// This is equivalent to the bash tracker's cmd_scan() but runs in Node without spawning a shell.

let _nativeScanCache = null;
let _nativeScanTime = 0;
const NATIVE_SCAN_TTL = 15_000;

/**
 * Scans /tmp/claude-*-cwd files and returns a map of active CWDs.
 * Status is determined by file modification time (modified within 2 minutes = active).
 * @returns {{ cwds: Map<string, {status: string, agentCount: number}> }}
 */
export function nativeScanClaude() {
  const now = Date.now();
  if (_nativeScanCache && now - _nativeScanTime < NATIVE_SCAN_TTL) return _nativeScanCache;

  const tmpDir = _getTmpDir();
  const ACTIVE_THRESHOLD_MS = 2 * 60 * 1000;
  const cwds = new Map();

  try {
    const files = readdirSync(tmpDir).filter(f => /^claude-[0-9a-f]+-cwd$/.test(f));
    const cwdToFiles = new Map();

    for (const file of files) {
      try {
        const fullPath = `${tmpDir}/${file}`;
        const st = statSync(fullPath);
        const content = readFileSync(fullPath, 'utf8').trim();
        if (!content) continue;

        const cwd = _normalizeCwd(content);
        if (!cwdToFiles.has(cwd)) cwdToFiles.set(cwd, []);
        cwdToFiles.get(cwd).push({ mtime: st.mtimeMs });
      } catch {
        // Ignore read errors — file may have been deleted (race condition)
      }
    }

    // Filter out parent directories when a child directory is also present
    const allCwds = [...cwdToFiles.keys()];
    const filteredCwds = allCwds.filter(cwd => {
      return !allCwds.some(other => other !== cwd && other.startsWith(cwd + '/'));
    });

    for (const cwd of filteredCwds) {
      const fileEntries = cwdToFiles.get(cwd) || [];
      const activeFiles = fileEntries.filter(f => (now - f.mtime) < ACTIVE_THRESHOLD_MS);
      const status = activeFiles.length > 0 ? 'active' : 'idle';
      const agentCount = activeFiles.length;
      cwds.set(cwd, { status, agentCount });
    }
  } catch (e) {
    console.warn('[native-scan] /tmp scan failed:', e.message);
  }

  _nativeScanCache = { cwds };
  _nativeScanTime = now;
  return _nativeScanCache;
}

export function invalidateNativeScanCache() {
  _nativeScanCache = null;
  _nativeScanTime = 0;
}

export function invalidateAllCaches() {
  invalidateStateCache();
  invalidateNativeScanCache();
}

/**
 * Finds the temp directory that contains claude-*-cwd files.
 * Node.js /tmp and MINGW bash /tmp may point to different locations on Windows,
 * so multiple candidates are checked in order.
 */
function _getTmpDir() {
  const candidates = [
    process.env.TEMP,
    process.env.TMP,
    '/tmp',
  ].filter(Boolean);

  for (const dir of candidates) {
    try {
      const files = readdirSync(dir);
      if (files.some(f => f.startsWith('claude-') && f.endsWith('-cwd'))) {
        return dir;
      }
    } catch {}
  }

  return process.env.TEMP || '/tmp';
}

/** Normalizes a CWD path from MINGW format to Windows format */
function _normalizeCwd(cwd) {
  let normalized = cwd;

  // /c/Users/... → C:/Users/...
  normalized = normalized.replace(/^\/([a-zA-Z])\//, (_, letter) => letter.toUpperCase() + ':/');

  // /tmp/... → Windows TEMP directory
  // In MINGW bash, /tmp maps to the Windows TEMP directory (e.g. C:\Users\<user>\AppData\Local\Temp)
  if (normalized.startsWith('/tmp/') || normalized === '/tmp') {
    const winTemp = (process.env.TEMP || process.env.TMP || '').replace(/\\/g, '/');
    if (winTemp) {
      normalized = normalized.replace(/^\/tmp/, winTemp);
    }
  }

  // Backslashes → forward slashes
  normalized = normalized.replace(/\\/g, '/');
  return normalized;
}

/**
 * Compares two CWD paths accounting for MINGW/Windows path format differences.
 */
function _cwdMatch(cwdA, cwdB) {
  if (!cwdA || !cwdB) return false;
  const a = _normalizeCwd(cwdA).toLowerCase().replace(/\/+$/, '');
  const b = _normalizeCwd(cwdB).toLowerCase().replace(/\/+$/, '');
  return a === b;
}

// ── getAliveState ──
// Merges native scan results with state.json to produce the current live session map.
// auto_discovered sessions are validated against the native scan (CWD matching).

export function getAliveState() {
  const state = getState();
  const alive = {};
  const aliveProjects = {};
  const alivePids = getAlivePids();
  const nativeScan = nativeScanClaude();

  function findNativeMatch(sessionCwd) {
    if (!sessionCwd) return null;
    for (const [nativeCwd, info] of nativeScan.cwds) {
      if (_cwdMatch(sessionCwd, nativeCwd)) return info;
    }
    return null;
  }

  const matchedNativeCwds = new Set();

  for (const [sid, s] of Object.entries(state.sessions || {})) {
    const pidAlive = s.pid && alivePids.has(s.pid);

    if (s.auto_discovered) {
      // auto_discovered: only include if the CWD is still present in the native scan
      const nativeInfo = findNativeMatch(s.cwd);
      if (!nativeInfo) continue; // CWD file gone — process has exited

      s.status = nativeInfo.status;
      s.agent_count = nativeInfo.agentCount;
      alive[sid] = s;
      matchedNativeCwds.add(_normalizeCwd(s.cwd).toLowerCase().replace(/\/+$/, ''));
    } else if (pidAlive) {
      // Hook-registered session: include only if the PID is alive
      alive[sid] = s;
      if (s.cwd) {
        matchedNativeCwds.add(_normalizeCwd(s.cwd).toLowerCase().replace(/\/+$/, ''));
      }
    } else {
      continue; // PID gone — skip
    }

    if (s.project) {
      const proj = state.projects?.[s.project] || { status: s.status };
      const existing = aliveProjects[s.project];
      // active takes priority over idle
      if (!existing || s.status === 'active') {
        aliveProjects[s.project] = { ...proj, status: s.status };
      }
    }
  }

  // Add CWDs found by native scan that aren't in state.json yet
  // (this handles the case where the bash tracker hasn't run since the session started)
  for (const [nativeCwd, info] of nativeScan.cwds) {
    const normalizedKey = nativeCwd.toLowerCase().replace(/\/+$/, '');
    if (matchedNativeCwds.has(normalizedKey)) continue;

    // Use the directory basename as a temporary project name
    const parts = nativeCwd.replace(/\/+$/, '').split('/');
    const projectName = parts[parts.length - 1] || nativeCwd;

    if (aliveProjects[projectName]) continue; // Avoid duplicate project names

    const tempSid = `native-${Date.now()}-${projectName}`;
    alive[tempSid] = {
      project: projectName,
      cwd: nativeCwd,
      status: info.status,
      auto_discovered: true,
      agent_count: info.agentCount,
      started_at: Math.floor(Date.now() / 1000),
      last_activity: Math.floor(Date.now() / 1000),
    };
    aliveProjects[projectName] = {
      cwd: nativeCwd,
      status: info.status,
      last_activity: Math.floor(Date.now() / 1000),
    };
  }

  return { sessions: alive, projects: aliveProjects };
}
