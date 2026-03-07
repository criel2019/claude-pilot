import {
  EmbedBuilder, ActionRowBuilder, ButtonBuilder, ButtonStyle,
} from 'discord.js';
import { COLOR } from './constants.js';
import { getConfig, saveConfig } from './config.js';
import { getClient } from './state.js';
import {
  runTrackerAsync, invalidateStateCache,
  invalidateNativeScanCache, invalidateAllCaches, getAliveState, formatTokens,
} from './tracker.js';
import { getTokenHistory } from './session.js';

// ── Dashboard embed builder ──

export function buildDashboardEmbed() {
  // Invalidate native scan cache so the embed reflects the latest /tmp state
  invalidateNativeScanCache();

  const state = getAliveState();
  // Deduplicate by project name, preferring active over idle
  const projectMap = new Map();
  for (const s of Object.values(state.sessions || {})) {
    const existing = projectMap.get(s.project);
    if (!existing || s.status === 'active') {
      projectMap.set(s.project, s);
    }
  }
  const sessions = [...projectMap.values()];
  const active = sessions.filter(s => s.status === 'active');
  const idle = sessions.filter(s => s.status === 'idle');

  const embed = new EmbedBuilder()
    .setTitle('🤖 Claude Process Status')
    .setColor(active.length > 0 ? COLOR.SUCCESS : (sessions.length > 0 ? COLOR.WARNING : COLOR.INFO))
    .setTimestamp();

  if (sessions.length === 0) {
    embed.setDescription('No active processes.');
  }

  const sorted = [...sessions].sort((a, b) => {
    const order = { active: 0, idle: 1 };
    return (order[a.status] ?? 2) - (order[b.status] ?? 2);
  });

  const MAX_DISPLAY = 8;
  for (const s of sorted.slice(0, MAX_DISPLAY)) {
    const icon = s.status === 'active' ? '🟢' : '🟡';
    const statusText = s.status === 'active' ? '**Working**' : 'Idle';
    const agents = s.agent_count || 0;
    const tokens = s.live_total_tokens ? `\n🔤 ${formatTokens(s.live_total_tokens)} tokens` : '';
    embed.addFields({
      name: `${icon} ${s.project}`,
      value: `${statusText} · ${agents} agent(s)${tokens}`,
      inline: true,
    });
  }
  if (sorted.length > MAX_DISPLAY) {
    embed.addFields({
      name: '\u200b',
      value: `_+${sorted.length - MAX_DISPLAY} more project(s)_`,
      inline: false,
    });
  }

  const totalAgents = sessions.reduce((sum, s) => sum + (s.agent_count || 0), 0);
  const totalTokens = sessions.reduce((sum, s) => sum + (s.live_total_tokens || 0), 0);
  embed.addFields({
    name: '📊 Summary',
    value: `🟢 Working **${active.length}** · 🟡 Idle **${idle.length}** · **${totalAgents}** total agent(s)` +
           (totalTokens > 0 ? `\n🔤 Live tokens: **${formatTokens(totalTokens)}**` : ''),
    inline: false,
  });

  const now = new Date();
  const timeStr = now.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false });
  embed.setFooter({ text: `Last updated: ${timeStr}` });

  const row = new ActionRowBuilder().addComponents(
    new ButtonBuilder()
      .setCustomId('dashboard_refresh')
      .setLabel('Refresh')
      .setEmoji('🔄')
      .setStyle(ButtonStyle.Secondary)
  );

  return { embeds: [embed], components: [row] };
}

export async function handleStatus() {
  await runTrackerAsync('scan');
  invalidateAllCaches();
  return buildDashboardEmbed();
}

export async function handleSnapshot() {
  await runTrackerAsync('snapshot');
  return { content: '✅ Snapshot recorded.', ephemeral: true };
}

export function handleReport(period = 'today') {
  const now = new Date();
  let since;
  switch (period) {
    case 'week': since = new Date(now - 7 * 86400000).toISOString().slice(0, 10); break;
    case 'all': since = null; break;
    default: since = now.toISOString().slice(0, 10); break;
  }

  const entries = getTokenHistory(since);
  if (entries.length === 0) {
    return { content: '📋 No records found for this period.' };
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
    .setTitle('📋 Token Usage Report')
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

export async function handleDashboard(interaction) {
  const client = getClient();
  await runTrackerAsync('scan');
  invalidateAllCaches();
  const payload = buildDashboardEmbed();
  const cfg = getConfig();

  if (cfg.dashboard_channel_id && cfg.dashboard_message_id) {
    try {
      const channel = await client.channels.fetch(cfg.dashboard_channel_id);
      const msg = await channel.messages.fetch(cfg.dashboard_message_id);
      await msg.edit(payload);
      await interaction.editReply({ content: '✅ Dashboard updated.' });
      return;
    } catch (e) {
      console.log('[dashboard] Existing message not found, creating a new one.');
    }
  }

  const channel = await client.channels.fetch(interaction.channelId);
  const msg = await channel.send(payload);

  cfg.dashboard_channel_id = interaction.channelId;
  cfg.dashboard_message_id = msg.id;
  saveConfig(cfg);

  await interaction.editReply({ content: '✅ Dashboard created in this channel.' });
}

// ── Auto-refresh ──

let _dashboardRefreshCount = 0;
let _dashboardRefreshing = false;
let _dashboardFailCount = 0;
const DASHBOARD_FAIL_THRESHOLD = 3;
// Run a bash tracker scan every 5 refresh cycles (for token data and transcript updates)
const DASHBOARD_BASH_SCAN_INTERVAL = 5;

export function isDashboardRefreshing() {
  return _dashboardRefreshing;
}

export async function updateDashboardMessage() {
  if (_dashboardRefreshing) return; // Prevent overlapping refreshes
  _dashboardRefreshing = true;
  try {
    const cfg = getConfig();
    if (!cfg.dashboard_channel_id || !cfg.dashboard_message_id) return;

    _dashboardRefreshCount++;

    // Always invalidate state cache so the native scan reads fresh /tmp files
    invalidateStateCache();

    // Every 5th cycle: also run a bash tracker scan for token data
    if (_dashboardRefreshCount % DASHBOARD_BASH_SCAN_INTERVAL === 1) {
      await runTrackerAsync('scan');
      invalidateStateCache();
    }

    const client = getClient();
    const channel = await client.channels.fetch(cfg.dashboard_channel_id);
    const msg = await channel.messages.fetch(cfg.dashboard_message_id);
    await msg.edit(buildDashboardEmbed());
    _dashboardFailCount = 0;
  } catch (e) {
    if (e.code === 10008 || e.code === 10003) {
      // Message or channel deleted — use a failure counter before clearing config
      _dashboardFailCount++;
      console.warn(`[auto-refresh] Dashboard access failed (${_dashboardFailCount}/${DASHBOARD_FAIL_THRESHOLD})`);
      if (_dashboardFailCount >= DASHBOARD_FAIL_THRESHOLD) {
        console.warn('[auto-refresh] Failure threshold reached, clearing dashboard config.');
        const cfg = getConfig();
        delete cfg.dashboard_channel_id;
        delete cfg.dashboard_message_id;
        saveConfig(cfg);
        _dashboardFailCount = 0;
      }
    } else {
      console.warn('[auto-refresh] Dashboard refresh failed:', e.message);
    }
  } finally {
    _dashboardRefreshing = false;
  }
}
