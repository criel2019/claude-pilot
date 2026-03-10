import { readdirSync, readFileSync, unlinkSync, existsSync } from 'fs';
import { join } from 'path';
import { EmbedBuilder } from 'discord.js';
import { SESSIONS_DIR, SESSION_RETENTION_DAYS, COLOR } from './constants.js';
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

// Polls for alert.json from the Token Analyzer; sends a Discord warning when a 5M+ token turn is detected.
const TOKEN_ANALYZER_DIR = join(
  process.env.HOME || process.env.USERPROFILE,
  'Desktop', '작업 폴더', 'Claude Token Analayzer',
);
const ALERT_FILE = join(TOKEN_ANALYZER_DIR, 'alert.json');

export function startTokenAlertWatch() {
  setInterval(async () => {
    if (!existsSync(ALERT_FILE)) return;
    let alert;
    try {
      alert = JSON.parse(readFileSync(ALERT_FILE, 'utf8'));
      unlinkSync(ALERT_FILE); // consume immediately
    } catch { return; }

    const cfg = getConfig();
    const channelId = cfg.dashboard_channel_id;
    if (!channelId) return;

    const client = getClient();
    if (!client) return;

    try {
      const channel = await client.channels.fetch(channelId);
      if (!channel) return;

      const bigTurnLines = (alert.bigTurns || [])
        .map(t => `• **${(t.tokens / 1_000_000).toFixed(1)}M** tokens — "${t.prompt?.slice(0, 80) || '?'}..."`)
        .join('\n');

      const embed = new EmbedBuilder()
        .setTitle('🚨 토큰 폭주 경고')
        .setColor(COLOR.ERROR)
        .setDescription(
          `**${alert.project}** 프로젝트에서 5M+ 토큰 턴이 감지되었습니다.\n\n` +
          `세션: \`${alert.sessionId?.slice(0, 12) || '?'}...\`\n` +
          `모델: ${alert.model || '?'}\n` +
          `총 토큰: **${((alert.totalTokens || 0) / 1_000_000).toFixed(1)}M**\n` +
          `예상 비용: **$${(alert.cost || 0).toFixed(2)}**\n` +
          `태그: ${(alert.tags || []).join(', ') || '-'}\n\n` +
          `**고비용 턴:**\n${bigTurnLines || '-'}`
        )
        .setFooter({ text: 'Token Analyzer · SessionEnd hook' })
        .setTimestamp(alert.timestamp ? new Date(alert.timestamp) : new Date());

      await channel.send({ embeds: [embed] });
      console.log(`[alert] Token alert sent for ${alert.project}`);
    } catch (e) {
      console.warn('[alert] Failed to send token alert:', e.message);
    }
  }, 30_000); // check every 30 seconds
}

export function startAllTimers() {
  startDashboardRefreshLoop();
  startSessionTimeoutCheck();
  startFileRetentionCleanup();
  startTokenAlertWatch();
}
