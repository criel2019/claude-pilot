import { readdirSync, readFileSync, unlinkSync } from 'fs';
import { join } from 'path';
import { SESSIONS_DIR, SESSION_RETENTION_DAYS } from './constants.js';
import { getConfig } from './config.js';
import { activeSessions, getClient } from './state.js';
import { isSessionBusy } from './session.js';
import { terminateSession } from './handlers/sessions.js';
import { updateDashboardMessage } from './dashboard.js';

// Uses setTimeout chaining instead of setInterval to prevent overlapping refresh calls.
export function startDashboardRefreshLoop() {
  (function schedule() {
    setTimeout(async () => {
      await updateDashboardMessage();
      schedule();
    }, 60_000);
  })();
}

// Checks every 5 minutes for sessions idle past the configured timeout and terminates them.
export function startSessionTimeoutCheck() {
  setInterval(async () => {
    const now = Date.now();
    const cfg = getConfig();
    const timeout = (cfg.session_timeout_minutes || 60) * 60 * 1000;
    for (const [channelId, session] of [...activeSessions]) {
      if (now - session.lastActivity > timeout) {
        if (isSessionBusy(session)) continue; // active Claude process is exempt
        console.log(`[cleanup] Session timed out: ${session.projectName} (channel ${channelId})`);
        await terminateSession(channelId, {
          threadMessage: `💤 Session auto-closed after ${cfg.session_timeout_minutes || 60} min of inactivity. Use \`/sessions\` to resume.`,
        });
      }
    }
  }, 5 * 60 * 1000);
}

// Runs hourly: deletes session files and their Discord starter messages after SESSION_RETENTION_DAYS.
export function startFileRetentionCleanup() {
  setInterval(async () => {
    const client = getClient();
    try {
      const files = readdirSync(SESSIONS_DIR).filter(f => f.endsWith('.json'));
      const cutoff = Date.now() - SESSION_RETENTION_DAYS * 86400000;
      for (const file of files) {
        try {
          const data = JSON.parse(readFileSync(join(SESSIONS_DIR, file), 'utf8'));
          if (data.endedAt && data.endedAt < cutoff) {
            if (data.threadId && data.starterMessageId) {
              try {
                const channel = await client.channels.fetch(data.channelId);
                const starterMsg = await channel.messages.fetch(data.starterMessageId);
                await starterMsg.delete();
              } catch {}
            }
            unlinkSync(join(SESSIONS_DIR, file));
            console.log(`[cleanup] Deleted ${SESSION_RETENTION_DAYS}-day expired session: ${data.projectName}`);
          }
        } catch (e) {
          console.warn(`[cleanup] Failed to process session file ${file}:`, e.message);
        }
      }
    } catch (e) {
      console.warn('[cleanup] Retention cleanup error:', e.message);
    }
  }, 60 * 60 * 1000);
}

export function startAllTimers() {
  startDashboardRefreshLoop();
  startSessionTimeoutCheck();
  startFileRetentionCleanup();
}
