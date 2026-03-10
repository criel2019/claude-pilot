import {
  ModalBuilder, TextInputBuilder, TextInputStyle,
  ActionRowBuilder, ButtonBuilder, ButtonStyle,
} from 'discord.js';
import { DEFAULT_PROJECT_NAME } from '../constants.js';
import { isUserAllowed } from '../config.js';
import { activeSessions } from '../state.js';
import {
  isSessionBusy, enqueueMessage, loadSessionFile, createSessionObject,
  saveSession, setChannelDefaultProject, recordErrorInHistory,
  resetHistory, updateTokenStats,
} from '../session.js';
import { getAliveState, runTrackerAsync, invalidateAllCaches } from '../tracker.js';
import {
  buildDashboardEmbed, isDashboardRefreshing,
  handleStatus, handleSnapshot, handleReport, handleDashboard,
} from '../dashboard.js';
import { buildProgressEmbed, buildErrorEmbed, buildProgressButtons } from '../embeds.js';
import {
  initSessionThread, runTurnAndUpdateThread, makeProgressUpdater, drainQueue,
} from '../claude.js';
import { handleSend } from './send.js';
import { handleProject } from './project.js';
import { handleFile, handleReceive } from './filetransfer.js';
import { terminateSession, handleEnd, handleSession, handleSessions } from './sessions.js';
import { handleGpt, handleGptProject, getGptProjects } from './gpt.js';
import { handleButton } from './buttons.js';
import { handleModalSubmit } from './modals.js';

// ── Autocomplete ──

async function handleAutocomplete(interaction) {
  // GPT project autocomplete
  if (interaction.commandName === 'gpt' && interaction.options.getFocusedOption().name === 'project') {
    const focused = interaction.options.getFocused();
    const projects = getGptProjects();
    const choices = Object.keys(projects)
      .filter(name => !focused || name.toLowerCase().includes(focused.toLowerCase()))
      .slice(0, 25)
      .map(name => ({ name: `📁 ${name}`, value: name }));
    return interaction.respond(choices);
  }

  // Claude project autocomplete — show active/idle sessions sorted by status
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

  // Always include the default project (deduplicated)
  if (!choices.some(c => c.value === DEFAULT_PROJECT_NAME) &&
      (!focused || DEFAULT_PROJECT_NAME.includes(focused.toLowerCase()))) {
    choices.push({ name: `\u{1F4E6} ${DEFAULT_PROJECT_NAME}`, value: DEFAULT_PROJECT_NAME });
  }

  await interaction.respond(choices);
}

// ── Select menu handler ──

async function handleSelectMenu(interaction) {
  if (interaction.customId === 'project_select_menu') {
    const projectName = interaction.values[0];
    setChannelDefaultProject(interaction.channelId, projectName);
    await interaction.update({
      content: `Default project for this channel set to **${projectName}**.\nYou can now omit the project option in \`/send\`.`,
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
      await interaction.update({ content: '❌ Session file not found.', components: [], embeds: [] });
      return;
    }

    if (activeSessions.has(interaction.channelId)) {
      await terminateSession(interaction.channelId, {
        threadMessage: '📦 Loading another session.',
        sendRestartButton: false,
      });
    }

    const newSession = {
      ...createSessionObject({
        channelId: interaction.channelId,
        channelName: data.channelName || '',
        projectName: data.projectName,
        cwd: data.cwd,
        model: data.model,
      }),
      turnCount: data.turnCount,
      messageHistory: data.messageHistory || [],
      tokenStats: data.tokenStats || { totalHistoryChars: 0, lastContextChars: 0, warningLevel: 'safe' },
      claudeSessionId: data.claudeSessionId || null,
    };
    activeSessions.set(interaction.channelId, newSession);
    saveSession(newSession);

    const resumeStatus = newSession.claudeSessionId ? '✅ Resume available' : 'New Claude session';
    await interaction.update({
      content: `✅ Loaded **${data.projectName}** (${data.turnCount} turns, ${(data.messageHistory || []).length} messages · ${resumeStatus}).\nUse \`/send\` to continue.`,
      components: [],
      embeds: [],
    });
    return;
  }

  await interaction.reply({ content: 'Unknown select menu.', ephemeral: true });
}

// ── /compact handler ──

async function handleCompact(interaction) {
  const session = activeSessions.get(interaction.channelId);
  if (!session) {
    return interaction.reply({ content: 'No active session in this channel.', ephemeral: true });
  }
  if (!isUserAllowed(interaction.user.id)) {
    return interaction.reply({ content: '❌ Not authorized.', ephemeral: true });
  }
  if (isSessionBusy(session)) {
    return interaction.reply({ content: '⏳ Session is busy. Try again after it finishes.', ephemeral: true });
  }
  if (session.pendingMessages?.length > 0) {
    return interaction.reply({ content: '⏳ Pending messages in queue. Try again after they are processed.', ephemeral: true });
  }
  if (session.messageHistory.length === 0) {
    return interaction.reply({ content: 'History is empty.', ephemeral: true });
  }

  await interaction.deferReply({ ephemeral: true });

  // Preserve lastTurnText so the compact prompt doesn't overwrite it
  const savedLastTurnText = session.lastTurnText;
  const savedLastTurnDisplayText = session.lastTurnDisplayText;

  const compactPrompt = [
    'Please provide a concise summary of our conversation so far, covering:',
    '- Main tasks/questions discussed',
    '- Key decisions and outcomes',
    '- Important code changes or outputs',
    '- Any pending/open items',
    'This summary will replace the full conversation history to reduce context length.',
  ].join('\n');

  try {
    const result = await runTurnAndUpdateThread({
      session,
      userText: compactPrompt,
      userDisplayText: '📦 Compressing context...',
      onProgress: makeProgressUpdater(session),
    });

    // Restore lastTurnText so retry still works after compact
    session.lastTurnText = savedLastTurnText;
    session.lastTurnDisplayText = savedLastTurnDisplayText;

    if (result.timedOut || result.exitCode !== 0) {
      await interaction.editReply({ content: '⚠️ Compact failed (timeout or error). History unchanged.' });
      return;
    }

    const summary = result.historyText || result.displayText;
    session.messageHistory = [
      { role: 'user', content: '[Context compressed — see summary below]', timestamp: Date.now() },
      { role: 'assistant', content: `[Conversation summary]\n${summary}`, timestamp: Date.now() },
    ];
    updateTokenStats(session);
    saveSession(session);
    await drainQueue(session);

    await interaction.editReply({
      content: `✅ Context compressed. Replaced with summary (${(summary.length / 1000).toFixed(1)}K chars).`,
    });
  } catch (e) {
    session.lastTurnText = savedLastTurnText;
    session.lastTurnDisplayText = savedLastTurnDisplayText;
    console.error(`[compact] ${session.projectName} failed:`, e.message);
    recordErrorInHistory(session);
    await interaction.editReply({ content: `❌ Compact failed: ${e.message.slice(0, 200)}` });
  }
}

// ── /model handler ──

async function handleModel(interaction) {
  const session = activeSessions.get(interaction.channelId);
  if (!session) {
    return interaction.reply({ content: 'No active session in this channel.', ephemeral: true });
  }
  if (!isUserAllowed(interaction.user.id)) {
    return interaction.reply({ content: '❌ Not authorized.', ephemeral: true });
  }

  const newModel = interaction.options.getString('model');
  const oldModel = session.model;
  session.model = newModel;
  saveSession(session);

  const busyNote = isSessionBusy(session) ? ' (current turn will finish with the previous model)' : '';
  await interaction.reply({
    content: `✅ Model changed: **${oldModel}** → **${newModel}**\nApplied from the next turn.${busyNote}`,
    ephemeral: true,
  });
}

// ── interactionCreate dispatcher ──

export async function handleInteractionCreate(interaction) {
  if (interaction.isAutocomplete()) {
    try { await handleAutocomplete(interaction); }
    catch (e) {
      console.error('Autocomplete error:', e.message);
      try { await interaction.respond([]); } catch {}
    }
    return;
  }

  if (interaction.isButton()) {
    try { await handleButton(interaction); }
    catch (e) {
      console.error('Button handler error:', e.message);
      try {
        if (!interaction.replied && !interaction.deferred)
          await interaction.reply({ content: `❌ 오류: ${e.message.slice(0, 200)}`, ephemeral: true });
      } catch {}
    }
    return;
  }

  if (interaction.isStringSelectMenu()) {
    try { await handleSelectMenu(interaction); }
    catch (e) {
      console.error('Select menu handler error:', e.message);
      try {
        if (!interaction.replied && !interaction.deferred)
          await interaction.reply({ content: `❌ 오류: ${e.message.slice(0, 200)}`, ephemeral: true });
      } catch {}
    }
    return;
  }

  if (interaction.isModalSubmit()) {
    try { await handleModalSubmit(interaction); }
    catch (e) {
      console.error('Modal handler error:', e.message);
      try {
        if (!interaction.replied && !interaction.deferred)
          await interaction.reply({ content: `❌ 오류: ${e.message.slice(0, 200)}`, ephemeral: true });
      } catch {}
    }
    return;
  }

  if (!interaction.isChatInputCommand()) return;

  // ── Slash command dispatcher ──
  try {
    switch (interaction.commandName) {
      case 'status':
        await interaction.deferReply();
        await interaction.editReply(await handleStatus());
        break;
      case 'snapshot':
        await interaction.deferReply({ ephemeral: true });
        await interaction.editReply(await handleSnapshot());
        break;
      case 'report':
        await interaction.deferReply();
        await interaction.editReply(handleReport(interaction.options.getString('period') || 'today'));
        break;
      case 'dashboard':
        await interaction.deferReply({ ephemeral: true });
        await handleDashboard(interaction);
        break;
      case 'send':    await handleSend(interaction); break;
      case 'project': await handleProject(interaction); break;
      case 'compact': await handleCompact(interaction); break;
      case 'model':   await handleModel(interaction); break;
      case 'end':     await handleEnd(interaction); break;
      case 'session': await handleSession(interaction); break;
      case 'sessions': await handleSessions(interaction); break;
      case 'gpt':         await handleGpt(interaction); break;
      case 'gpt-project': await handleGptProject(interaction); break;
      case 'file':        await handleFile(interaction); break;
      case 'receive':     await handleReceive(interaction); break;
      default: await interaction.reply({ content: 'Unknown command.' });
    }
  } catch (e) {
    console.error('Command handler error:', e);
    try {
      const msg = { content: `❌ Error: ${e.message}`, ephemeral: true };
      if (interaction.replied || interaction.deferred) {
        await interaction.followUp(msg);
      } else {
        await interaction.reply(msg);
      }
    } catch (replyErr) {
      console.error('Failed to send error reply:', replyErr.message);
    }
  }
}
