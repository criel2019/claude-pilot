import { DEFAULT_PROJECT_NAME, QUEUE_MAX_SIZE, TEXT_EXTENSIONS } from '../constants.js';
import { getConfig, isUserAllowed, saveFailedPrompt } from '../config.js';
import { activeSessions } from '../state.js';
import {
  isSessionBusy, enqueueMessage, createSessionObject, findProjectCwd,
  saveKnownProject, setChannelDefaultProject, recordErrorInHistory, saveSession,
} from '../session.js';
import {
  isImageFile, fetchTextFile, prepareImageAttachments,
  buildImagePrompt, cleanupTempFiles,
} from '../files.js';
import {
  initSessionThread, runTurnAndUpdateThread, makeProgressUpdater, drainQueue,
} from '../claude.js';
import { buildProgressEmbed, buildErrorEmbed, buildProgressButtons } from '../embeds.js';
import { runTrackerAsync, getAliveState, invalidateAllCaches } from '../tracker.js';

async function resolveTextAttachment(fileAttachment) {
  if (!fileAttachment) {
    return { fileContent: '', fileLabel: '' };
  }

  const ext = (fileAttachment.name.split('.').pop() || '').toLowerCase();
  if (!TEXT_EXTENSIONS.has(ext)) {
    return { fileContent: '', fileLabel: '' };
  }

  try {
    const fileContent = await fetchTextFile(fileAttachment);
    return {
      fileContent,
      fileLabel: `File **${fileAttachment.name}** (${fileContent.length.toLocaleString()} chars)`,
    };
  } catch (e) {
    console.warn('[send] Failed to read file:', e.message);
    return { fileContent: '', fileLabel: '' };
  }
}

function buildCombinedMessage(messageText, fileContent) {
  return [messageText, fileContent].filter(Boolean).join('\n\n---\n\n');
}

export async function handleSend(interaction) {
  if (!isUserAllowed(interaction.user.id)) {
    return interaction.reply({
      content: 'Not authorized to use /send. Add your user ID to `allowed_users` in config.json.',
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

  if (!messageText.trim() && !fileAttachment) {
    return interaction.reply({
      content: 'Please enter a message or attach a text file.',
      ephemeral: true,
    });
  }

  const channelName = interaction.channel?.name || '';

  // When /send is called inside a thread, use the parent channel to avoid nested threads.
  const effectiveChannelId = interaction.channel?.isThread?.()
    ? (interaction.channel.parentId ?? interaction.channelId)
    : interaction.channelId;

  let session = activeSessions.get(effectiveChannelId);
  if (isSessionBusy(session)) {
    await interaction.deferReply({ flags: 64 });

    const { fileContent, fileLabel } = await resolveTextAttachment(fileAttachment);
    const combinedMessage = buildCombinedMessage(messageText, fileContent);
    if (!combinedMessage.trim()) {
      await interaction.editReply({ content: 'Please enter a message or attach a readable text file.' });
      return;
    }

    const queueImagePaths = await prepareImageAttachments(attachments);
    const queueBaseDisplay = fileLabel
      ? (messageText ? `${messageText}\n\n${fileLabel}` : fileLabel)
      : undefined;
    const { promptText: queuedPrompt, displayText: queuedDisplay } = buildImagePrompt(
      combinedMessage,
      queueImagePaths,
      queueBaseDisplay,
    );
    const enqueued = enqueueMessage(session, {
      promptText: queuedPrompt,
      displayText: queuedDisplay,
      imagePaths: queueImagePaths,
    });
    if (!enqueued) {
      cleanupTempFiles(queueImagePaths);
      await interaction.editReply({ content: `Queue is full (max ${QUEUE_MAX_SIZE}). Try again later.` });
      return;
    }

    await interaction.editReply({
      content: `Added to queue (${session.pendingMessages.length} waiting). It will run after the current task.`,
    });
    return;
  }

  if (!projectName) {
    const cfg = getConfig();
    const channelDefault = (cfg.channel_defaults || {})[effectiveChannelId];
    if (channelDefault) projectName = channelDefault;
  }

  const hasExistingThread = session?.threadId && (!projectName || session.projectName === projectName);
  if (hasExistingThread) {
    await interaction.deferReply({ flags: 64 });
  } else {
    await interaction.deferReply();
  }

  const { fileContent, fileLabel } = await resolveTextAttachment(fileAttachment);
  const combinedMessage = buildCombinedMessage(messageText, fileContent);
  if (!combinedMessage.trim()) {
    await interaction.editReply({ content: 'Please enter a message or attach a readable text file.' });
    return;
  }

  if (!projectName) {
    await runTrackerAsync('scan');
    invalidateAllCaches();
    const state = getAliveState();
    const activeSess = Object.values(state.sessions || {}).filter(s => s.status === 'active' || s.status === 'idle');
    if (activeSess.length === 1) {
      projectName = activeSess[0].project;
    } else {
      const cfg = getConfig();
      const knownNames = Object.keys(cfg.known_projects || {});
      if (knownNames.length === 1) {
        projectName = knownNames[0];
      } else {
        projectName = DEFAULT_PROJECT_NAME;
      }
    }
  }

  const cwd = findProjectCwd(projectName);

  if (projectName) saveKnownProject(projectName, cwd);
  if (projectName && !getConfig().channel_defaults?.[effectiveChannelId]) {
    setChannelDefaultProject(effectiveChannelId, projectName);
  }

  if (session && projectName && session.projectName !== projectName) {
    console.log(`[send] Project switch: ${session.projectName} -> ${projectName} (session kept)`);
    session.projectName = projectName;
    session.cwd = cwd;
    session.claudeSessionId = null;
    saveSession(session);
  }

  if (!session) {
    session = createSessionObject({ channelId: effectiveChannelId, channelName, projectName, cwd, model });
    activeSessions.set(effectiveChannelId, session);
  } else if (explicitModel) {
    session.model = explicitModel;
  }

  const imagePaths = await prepareImageAttachments(attachments);
  const baseDisplayText = fileLabel
    ? (messageText ? `${messageText}\n\n${fileLabel}` : fileLabel)
    : undefined;
  const { promptText: finalMessage, displayText: userDisplayText } = buildImagePrompt(
    combinedMessage,
    imagePaths,
    baseDisplayText,
  );

  try {
    if (!session.threadId) {
      await interaction.editReply({
        embeds: [buildProgressEmbed(session, '_Processing..._', '0')],
        components: [buildProgressButtons(session.channelId)],
      });
      const starterMsg = await interaction.fetchReply();
      await initSessionThread(session, starterMsg);
    }

    try {
      await runTurnAndUpdateThread({
        session,
        userText: finalMessage,
        userDisplayText,
        onProgress: makeProgressUpdater(session),
      });
      await drainQueue(session);
      if (hasExistingThread) {
        await interaction.editReply({ content: `Done. Check the thread: (<#${session.threadId}>)` });
      }
    } catch (e) {
      console.error(`[send] ${projectName} failed:`, e.message);
      saveFailedPrompt({
        message: combinedMessage,
        project: projectName,
        reason: e.message,
        user: interaction.user.tag,
      });
      recordErrorInHistory(session);
      const errPayload = hasExistingThread
        ? { content: `Error: ${e.message.slice(0, 200)}` }
        : { embeds: [buildErrorEmbed(session, e.message)] };
      try {
        await interaction.editReply(errPayload);
      } catch (editErr) {
        console.warn('[send] Failed to edit error reply:', editErr.message);
      }
    }
  } finally {
    cleanupTempFiles(imagePaths);
  }
}
