import { isUserAllowed } from '../config.js';
import { activeSessions } from '../state.js';
import {
  isSessionBusy, enqueueMessage, loadSessionFile, createSessionObject,
  saveSession, recordErrorInHistory,
} from '../session.js';
import { buildProgressEmbed, buildErrorEmbed, buildProgressButtons } from '../embeds.js';
import { initSessionThread, runTurnAndUpdateThread, makeProgressUpdater, drainQueue } from '../claude.js';
import { terminateSession } from './sessions.js';

async function handleModalSessionInput(interaction) {
  const channelId = interaction.customId.slice('session_input:'.length);
  const session = activeSessions.get(channelId);
  if (!session) {
    await interaction.reply({ content: 'Session has expired.', ephemeral: true });
    return;
  }
  if (!isUserAllowed(interaction.user.id)) {
    await interaction.reply({ content: '❌ Not authorized.', ephemeral: true });
    return;
  }

  const userText = interaction.fields.getTextInputValue('message_input');
  if (!userText.trim()) {
    await interaction.reply({ content: 'Message cannot be empty.', ephemeral: true });
    return;
  }

  if (isSessionBusy(session)) {
    const enqueued = enqueueMessage(session, { promptText: userText, displayText: userText, imagePaths: [] });
    await interaction.reply({
      content: enqueued
        ? `⏳ Added to queue (position ${session.pendingMessages.length}). Will be processed after the current task.`
        : '⚠️ Queue is full.',
      ephemeral: true,
    });
    return;
  }

  await interaction.deferReply({ flags: 64 });

  try {
    await runTurnAndUpdateThread({
      session,
      userText,
      onProgress: makeProgressUpdater(session),
    });
    await drainQueue(session);
    await interaction.deleteReply().catch(() => {});
  } catch (e) {
    console.error(`[modal] ${session.projectName} failed:`, e.message);
    recordErrorInHistory(session);
    try {
      await interaction.editReply({ content: `❌ Error: ${e.message.slice(0, 200)}` });
    } catch (editErr) {
      console.warn('[modal] Failed to edit error reply:', editErr.message);
    }
  }
}

async function handleModalRestart(interaction) {
  const sessionId = interaction.customId.slice('restart_modal:'.length);
  let restartData;
  try {
    restartData = loadSessionFile(sessionId);
  } catch {
    await interaction.reply({ content: '❌ Session data not found.', ephemeral: true });
    return;
  }
  if (!isUserAllowed(interaction.user.id)) {
    await interaction.reply({ content: '❌ Not authorized.', ephemeral: true });
    return;
  }

  const userText = interaction.fields.getTextInputValue('message_input');
  if (!userText.trim()) {
    await interaction.reply({ content: 'Message cannot be empty.', ephemeral: true });
    return;
  }

  await interaction.deferReply();

  if (activeSessions.has(interaction.channelId)) {
    await terminateSession(interaction.channelId, {
      threadMessage: '🔄 Restarting session.',
      sendRestartButton: false,
    });
  }

  const newSession = createSessionObject({
    channelId: interaction.channelId,
    channelName: interaction.channel?.name || restartData.channelName || '',
    projectName: restartData.projectName,
    cwd: restartData.cwd,
    model: restartData.model,
  });
  activeSessions.set(interaction.channelId, newSession);

  const starterMsg = await interaction.fetchReply();
  await starterMsg.edit({
    embeds: [buildProgressEmbed(newSession, '_Processing..._', '0')],
    components: [buildProgressButtons(newSession.channelId)],
  });
  await initSessionThread(newSession, starterMsg);
  saveSession(newSession);

  try {
    await runTurnAndUpdateThread({
      session: newSession,
      userText,
      userDisplayText: userText,
      onProgress: makeProgressUpdater(newSession),
    });
    await drainQueue(newSession);
  } catch (e) {
    console.error(`[restart] ${restartData.projectName} failed:`, e.message);
    recordErrorInHistory(newSession);
    try {
      await interaction.editReply({ embeds: [buildErrorEmbed(newSession, e.message)] });
    } catch {}
  }
}

export async function handleModalSubmit(interaction) {
  if (interaction.customId.startsWith('session_input:')) return handleModalSessionInput(interaction);
  if (interaction.customId.startsWith('restart_modal:'))  return handleModalRestart(interaction);
}
