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
import { runTracker, getAliveState, invalidateAllCaches } from '../tracker.js';

export async function handleSend(interaction) {
  if (!isUserAllowed(interaction.user.id)) {
    return interaction.reply({
      content: '❌ Not authorized to use /send. Add your user ID to `allowed_users` in config.json.',
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

  // Read text file content (workaround for Discord's 4000-char message limit)
  let fileContent = '';
  let fileLabel = '';
  if (fileAttachment) {
    const ext = (fileAttachment.name.split('.').pop() || '').toLowerCase();
    if (TEXT_EXTENSIONS.has(ext)) {
      try {
        fileContent = await fetchTextFile(fileAttachment);
        fileLabel = `📄 **${fileAttachment.name}** (${fileContent.length.toLocaleString()} chars)`;
      } catch (e) {
        console.warn('[send] Failed to read file:', e.message);
      }
    }
  }

  // At least one of message or file must be provided
  const combinedMessage = [messageText, fileContent].filter(Boolean).join('\n\n---\n\n');
  if (!combinedMessage.trim()) {
    return interaction.reply({
      content: '❌ Please enter a message or attach a text file.',
      ephemeral: true,
    });
  }

  const channelName = interaction.channel?.name || '';

  // When /send is called inside a thread, use the parent channel to avoid nested threads
  const effectiveChannelId = interaction.channel?.isThread?.()
    ? (interaction.channel.parentId ?? interaction.channelId)
    : interaction.channelId;

  // Fast busy check before deferring (no I/O needed)
  let session = activeSessions.get(effectiveChannelId);
  if (isSessionBusy(session)) {
    await interaction.deferReply({ flags: 64 });
    // Download attachments now before the Discord CDN URL expires
    const queueImagePaths = await prepareImageAttachments(attachments);
    const queueBaseDisplay = fileLabel
      ? (messageText ? `${messageText}\n\n${fileLabel}` : fileLabel)
      : undefined;
    const { promptText: queuedPrompt, displayText: queuedDisplay } = buildImagePrompt(combinedMessage, queueImagePaths, queueBaseDisplay);
    const enqueued = enqueueMessage(session, { promptText: queuedPrompt, displayText: queuedDisplay, imagePaths: queueImagePaths });
    if (!enqueued) {
      cleanupTempFiles(queueImagePaths);
      await interaction.editReply({ content: `⚠️ Queue is full (max ${QUEUE_MAX_SIZE}). Try again later.` });
      return;
    }
    await interaction.editReply({
      content: `⏳ Added to queue (${session.pendingMessages.length} waiting). Will be processed after the current task.`,
    });
    return;
  }

  // Resolve project from channel default (fast, config cache only)
  if (!projectName) {
    const cfg = getConfig();
    const channelDefault = (cfg.channel_defaults || {})[effectiveChannelId];
    if (channelDefault) projectName = channelDefault;
  }

  // Defer before slow I/O (must happen within Discord's 3-second window)
  // Use ephemeral reply when an existing thread is already attached
  const hasExistingThread = session?.threadId && (!projectName || session.projectName === projectName);
  if (hasExistingThread) {
    await interaction.deferReply({ flags: 64 });
  } else {
    await interaction.deferReply();
  }

  // Slow operations run after deferring
  if (!projectName) {
    runTracker('scan');
    invalidateAllCaches();
    const state = getAliveState();
    const activeSess = Object.values(state.sessions || {}).filter(s => s.status === 'active' || s.status === 'idle');
    if (activeSess.length === 1) {
      projectName = activeSess[0].project;
    } else {
      // Multiple or no active sessions — fall back to known_projects
      const cfgK = getConfig();
      const knownNames = Object.keys(cfgK.known_projects || {});
      if (knownNames.length === 1) {
        projectName = knownNames[0];
      } else {
        projectName = DEFAULT_PROJECT_NAME;
      }
    }
  }

  const cwd = findProjectCwd(projectName);

  // Remember CWD so the project can be resumed even after Claude exits
  if (projectName) saveKnownProject(projectName, cwd);
  // Auto-set channel default if not configured yet
  if (projectName && !getConfig().channel_defaults?.[effectiveChannelId]) {
    setChannelDefaultProject(effectiveChannelId, projectName);
  }

  // Project switch: update session metadata without terminating (Claude --resume handles the move)
  if (session && projectName && session.projectName !== projectName) {
    console.log(`[send] Project switch: ${session.projectName} → ${projectName} (session kept)`);
    session.projectName = projectName;
    session.cwd = cwd;
    session.claudeSessionId = null; // New project = fresh Claude session
    saveSession(session);
  }

  // Create or reuse session
  if (!session) {
    session = createSessionObject({ channelId: effectiveChannelId, channelName, projectName, cwd, model });
    activeSessions.set(effectiveChannelId, session);
  } else if (explicitModel) {
    session.model = explicitModel;
  }
  // Prepare image attachments and build the final prompt
  const imagePaths = await prepareImageAttachments(attachments);
  const baseDisplayText = fileLabel
    ? (messageText ? `${messageText}\n\n${fileLabel}` : fileLabel)
    : undefined;
  const { promptText: finalMessage, displayText: userDisplayText } = buildImagePrompt(combinedMessage, imagePaths, baseDisplayText);

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
        await interaction.editReply({ content: `✅ Done. Check the thread: (<#${session.threadId}>)` });
      }
    } catch (e) {
      console.error(`[send] ${projectName} failed:`, e.message);
      saveFailedPrompt({ message: combinedMessage, project: projectName, reason: e.message, user: interaction.user.tag });
      recordErrorInHistory(session);
      const errPayload = hasExistingThread
        ? { content: `❌ Error: ${e.message.slice(0, 200)}` }
        : { embeds: [buildErrorEmbed(session, e.message)] };
      try { await interaction.editReply(errPayload); } catch (editErr) {
        console.warn('[send] Failed to edit error reply:', editErr.message);
      }
    }
  } finally {
    cleanupTempFiles(imagePaths);
  }
}
