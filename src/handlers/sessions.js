import {
  EmbedBuilder, ActionRowBuilder, ButtonBuilder, ButtonStyle,
  StringSelectMenuBuilder,
} from 'discord.js';
import { COLOR, SESSIONS_DIR, SESSION_RETENTION_DAYS, SELECT_MAX_OPTIONS } from '../constants.js';
import { activeSessions, getClient } from '../state.js';
import {
  isSessionBusy, saveSession, loadSessionFile, loadAllSessions,
} from '../session.js';

// ── Common session termination ──

export async function terminateSession(channelId, { threadMessage = '🔚 Session ended.', sendRestartButton = true } = {}) {
  const session = activeSessions.get(channelId);
  if (!session) return null;

  // 1. Record end time and persist
  session.endedAt = Date.now();
  saveSession(session);

  // 2. Kill the process if running
  if (isSessionBusy(session)) {
    session.proc.kill('SIGKILL');
  }

  // 3. Send end message to thread and archive it
  if (session.threadRef) {
    try {
      await session.threadRef.send({ content: threadMessage });
    } catch (e) {
      console.warn('[terminate] Failed to send thread message:', e.message);
    }
    try {
      await session.threadRef.setArchived(true);
    } catch (e) {
      console.warn('[terminate] Failed to archive thread:', e.message);
    }
  }

  // 4. Post a restart button to the parent channel
  if (sendRestartButton) {
    try {
      const client = getClient();
      const parentChannel = await client.channels.fetch(session.channelId);
      const restartRow = new ActionRowBuilder().addComponents(
        new ButtonBuilder()
          .setCustomId(`session_restart:${session.id}`)
          .setLabel('🔄 Restart')
          .setStyle(ButtonStyle.Primary)
      );
      const channelTag = session.channelName ? ` (#${session.channelName})` : '';
      await parentChannel.send({
        content: `💤 **${session.projectName}**${channelTag} session ended.`,
        components: [restartRow],
      });
    } catch (e) {
      console.warn('[terminate] Failed to send restart button:', e.message);
    }
  }

  // 5. Remove buttons from the starter message and last thread message
  if (session.starterMessageRef) {
    try {
      await session.starterMessageRef.edit({ components: [] });
    } catch (e) {
      console.warn('[terminate] Failed to remove starter buttons:', e.message);
    }
  }
  if (session.lastThreadButtonMsg) {
    try {
      await session.lastThreadButtonMsg.edit({ components: [] });
    } catch (e) {
      console.warn('[terminate] Failed to remove thread buttons:', e.message);
    }
  }

  // 6. Remove from active sessions
  activeSessions.delete(channelId);

  return session;
}

// ── /end handler ──

export async function handleEnd(interaction) {
  const session = activeSessions.get(interaction.channelId);
  if (!session) {
    return interaction.reply({ content: 'No active session in this channel.', ephemeral: true });
  }

  await interaction.deferReply();
  const terminated = await terminateSession(interaction.channelId, {
    threadMessage: `🔚 Session ended. ${session.turnCount} turns completed.`,
  });

  if (!terminated) {
    return interaction.editReply({ content: '⚠️ Error while ending the session.' });
  }

  const summary = `Session ended: **${terminated.projectName}**\n` +
    `Turns: ${terminated.turnCount} · Started: <t:${Math.floor(terminated.createdAt / 1000)}:R>`;

  await interaction.editReply({ content: `✅ ${summary}\nView saved sessions with \`/sessions\`.` });
}

// ── /session handler ──

export async function handleSession(interaction) {
  const session = activeSessions.get(interaction.channelId);

  if (!session) {
    return interaction.reply({
      content: 'No active session in this channel.\nStart one with `/send`.',
      ephemeral: true,
    });
  }

  const isRunning = isSessionBusy(session);
  const embed = new EmbedBuilder()
    .setTitle('📋 Session Info')
    .setColor(isRunning ? COLOR.WARNING : COLOR.SUCCESS)
    .addFields(
      { name: 'Project', value: session.projectName, inline: true },
      { name: 'Model', value: session.model, inline: true },
      { name: 'Turns', value: `${session.turnCount}`, inline: true },
      { name: 'Status', value: isRunning ? '⏳ Running' : '✅ Idle', inline: true },
      { name: 'History', value: `${session.messageHistory.length} messages`, inline: true },
      { name: 'Claude Session', value: session.claudeSessionId ? '✅ Resume available' : '❌ None (new session)', inline: true },
    )
    .setFooter({ text: `Last activity: ${new Date(session.lastActivity).toLocaleTimeString('en-US')}` })
    .setTimestamp();

  if (session.threadId) {
    embed.addFields({ name: 'Thread', value: `<#${session.threadId}>`, inline: true });
  }

  if (session.tokenStats) {
    embed.addFields({
      name: '📝 Context',
      value: `${(session.tokenStats.totalHistoryChars / 1000).toFixed(0)}K chars · ${session.tokenStats.warningLevel}`,
      inline: true,
    });
  }

  // Recent message preview
  const recent = session.messageHistory.slice(-4);
  if (recent.length > 0) {
    const preview = recent.map(m => {
      const prefix = m.role === 'user' ? '💬' : '🤖';
      const text = m.content.slice(0, 80);
      return `${prefix} ${text}${m.content.length > 80 ? '…' : ''}`;
    }).join('\n');
    embed.addFields({ name: 'Recent Messages', value: preview, inline: false });
  }

  await interaction.reply({ embeds: [embed], ephemeral: true });
}

// ── /sessions handler ──

export async function handleSessions(interaction) {
  await interaction.deferReply({ flags: 64 });
  const sessions = loadAllSessions().sort((a, b) => b.lastActivity - a.lastActivity);

  if (sessions.length === 0) {
    return interaction.editReply({ content: 'No saved sessions found.' });
  }

  const select = new StringSelectMenuBuilder()
    .setCustomId('session_load_menu')
    .setPlaceholder('Select a session to load')
    .addOptions(sessions.slice(0, SELECT_MAX_OPTIONS).map(s => ({
      label: `${s.projectName} — ${s.turnCount} turns`.slice(0, 100),
      description: `${new Date(s.lastActivity).toLocaleDateString('en-US')} · ${(s.tokenStats?.totalHistoryChars / 1000 || 0).toFixed(0)}K chars`.slice(0, 100),
      value: s.id,
      emoji: s.endedAt ? '📦' : '🟢',
    })));

  const embed = new EmbedBuilder()
    .setTitle('📚 Saved Sessions')
    .setColor(COLOR.INFO)
    .setDescription(sessions.slice(0, 10).map((s, i) => {
      const age = Math.floor((Date.now() - s.lastActivity) / 86400000);
      const status = s.endedAt ? 'ended' : '**active**';
      const deleteIn = s.endedAt ? `${Math.max(0, SESSION_RETENTION_DAYS - Math.floor((Date.now() - s.endedAt) / 86400000))}d until deletion` : '';
      return `${i + 1}. **${s.projectName}** — ${s.turnCount} turns · ${status} · ${age}d ago${deleteIn ? ` · ⏳ ${deleteIn}` : ''}`;
    }).join('\n') || '_(none)_');

  const row = new ActionRowBuilder().addComponents(select);
  await interaction.editReply({ embeds: [embed], components: [row] });
}
