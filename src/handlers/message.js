import { TEXT_EXTENSIONS, RECEIVED_DIR } from '../constants.js';
import { isUserAllowed } from '../config.js';
import { activeSessions, getClient } from '../state.js';
import { isSessionBusy, enqueueMessage, recordErrorInHistory } from '../session.js';
import {
  isImageFile, fetchTextFile, prepareImageAttachments,
  buildImagePrompt, cleanupTempFiles, downloadAnyAttachment,
  parseDestDir, isPureSaveText,
} from '../files.js';
import { runTurnAndUpdateThread, makeProgressUpdater, drainQueue } from '../claude.js';
import { buildErrorEmbed } from '../embeds.js';
import { activeGptSessions, handleGptThreadMessage } from './gpt.js';

function findSessionForMessage(message) {
  if (message.channel.isThread()) {
    const session = activeSessions.get(message.channel.parentId);
    if (session && session.threadId === message.channelId) {
      return { session, isThread: true };
    }
    return null;
  }

  const session = activeSessions.get(message.channelId);
  if (!session) return null;
  // Respond to all messages in channels with an active session (no mention required)
  return { session, isThread: false };
}

async function buildFollowUpPayload(message) {
  const client = getClient();
  const rawText = message.content.trim()
    .replace(new RegExp(`<@!?${client.user.id}>`, 'g'), '').trim();

  // Detect natural-language save destination in the message text
  const destDir = parseDestDir(rawText);

  const imageAtts = [...message.attachments.filter(a => isImageFile(a.name)).values()];
  const textAtts = [...message.attachments.filter(a => {
    const ext = (a.name.split('.').pop() || '').toLowerCase();
    return TEXT_EXTENSIONS.has(ext);
  }).values()];
  const binaryAtts = [...message.attachments.filter(a => {
    const ext = (a.name.split('.').pop() || '').toLowerCase();
    return !isImageFile(a.name) && !TEXT_EXTENSIONS.has(ext);
  }).values()];

  if (!rawText && imageAtts.length === 0 && textAtts.length === 0 && binaryAtts.length === 0) return null;

  // Read text file attachments
  let textFileContent = '';
  let textFileLabel = '';
  for (const att of textAtts) {
    try {
      const content = await fetchTextFile(att);
      textFileContent += (textFileContent ? '\n\n---\n\n' : '') + content;
      textFileLabel += (textFileLabel ? ', ' : '') + `📄 ${att.name} (${content.length.toLocaleString()} chars)`;
    } catch (e) {
      console.warn('[follow-up] Failed to read text file:', e.message);
    }
  }

  // Download binary file attachments — use destDir if the user specified one, else RECEIVED_DIR
  const saveDir = destDir || RECEIVED_DIR;
  let binaryFileContext = '';
  let binaryFileLabel = '';
  for (const att of binaryAtts) {
    try {
      const savedPath = await downloadAnyAttachment(att, saveDir);
      binaryFileContext += `\n[File received and saved to PC: ${savedPath}]`;
      binaryFileLabel += (binaryFileLabel ? ', ' : '') + `📥 ${att.name}`;
    } catch (e) {
      console.warn('[follow-up] Failed to save binary file:', e.message);
      binaryFileContext += `\n[File download failed: ${att.name} — ${e.message}]`;
      binaryFileLabel += (binaryFileLabel ? ', ' : '') + `❌ ${att.name}`;
    }
  }

  const combinedText = [rawText, textFileContent, binaryFileContext].filter(Boolean).join('\n\n---\n\n');
  if (!combinedText && imageAtts.length === 0) return null;

  const imagePaths = await prepareImageAttachments(imageAtts);
  const allLabels = [textFileLabel, binaryFileLabel].filter(Boolean).join(', ');
  const baseDisplay = allLabels ? (rawText ? `${rawText}\n${allLabels}` : allLabels) : undefined;
  const { promptText, displayText } = buildImagePrompt(combinedText || rawText, imagePaths, baseDisplay);

  const finalText = (imagePaths.length > 0 || textFileContent)
    ? (promptText || combinedText)
    : rawText;

  if (!finalText) { cleanupTempFiles(imagePaths); return null; }

  return { promptText: finalText, displayText, imagePaths };
}

// Handles "바탕화면에 저장해줘" / "save to E:/foo" style messages directly,
// without involving a Claude session.
async function handleDirectFileSave(message, destDir) {
  await message.react('🔄').catch(() => {});
  const results = [];
  for (const att of message.attachments.values()) {
    try {
      const savedPath = await downloadAnyAttachment(att, destDir);
      results.push(`✅ \`${att.name}\` → \`${savedPath}\``);
    } catch (e) {
      results.push(`❌ \`${att.name}\`: ${e.message.slice(0, 120)}`);
    }
  }
  await message.reactions.removeAll().catch(() => {});
  const allOk = results.every(r => r.startsWith('✅'));
  await message.react(allOk ? '✅' : '⚠️').catch(() => {});
  await message.reply({
    content: `📥 **저장 완료** (\`${destDir}\`)\n${results.join('\n')}`,
  }).catch(() => {});
}

export async function handleMessageCreate(message) {
  if (message.author.bot || !message.guild) return;

  // Direct file-save: handle outside (or inside) sessions when the entire
  // message is a "save this to <location>" command.
  if (message.attachments.size > 0 && isUserAllowed(message.author.id)) {
    const client = getClient();
    const rawText = message.content.trim()
      .replace(new RegExp(`<@!?${client.user.id}>`, 'g'), '').trim();
    const destDir = parseDestDir(rawText);
    if (destDir && isPureSaveText(rawText)) {
      return handleDirectFileSave(message, destDir);
    }
  }

  // Route messages from GPT threads to the GPT handler
  if (message.channel.isThread()) {
    const gptSession = activeGptSessions.get(message.channelId);
    if (gptSession) {
      if (!isUserAllowed(message.author.id)) return;
      return handleGptThreadMessage(message, gptSession);
    }
  }

  const match = findSessionForMessage(message);
  if (!match) return;
  const { session, isThread } = match;

  if (isSessionBusy(session)) {
    if (!isUserAllowed(message.author.id)) return;
    const payload = await buildFollowUpPayload(message);
    if (!payload) return;
    const enqueued = enqueueMessage(session, {
      promptText: payload.promptText,
      displayText: payload.displayText,
      imagePaths: payload.imagePaths,
      discordMessage: message,
    });
    await message.react(enqueued ? '⏳' : '⛔').catch(() => {});
    if (!enqueued) cleanupTempFiles(payload.imagePaths);
    return;
  }
  if (!isUserAllowed(message.author.id)) return;

  const payload = await buildFollowUpPayload(message);
  if (!payload) return;

  await message.react('🔄').catch(() => {});
  session.lastActivity = Date.now();

  console.log(`[follow-up] ${session.projectName}: "${payload.promptText.slice(0, 50)}..." (turn: ${session.turnCount + 1}, thread: ${isThread})`);

  try {
    const result = await runTurnAndUpdateThread({
      session,
      userText: payload.promptText,
      userDisplayText: payload.displayText,
      onProgress: makeProgressUpdater(session),
    });

    await message.reactions.removeAll().catch(() => {});
    await message.react(result.exitCode === 0 ? '✅' : '❌').catch(() => {});
    await drainQueue(session);
  } catch (e) {
    console.error(`[follow-up] ${session.projectName} failed:`, e.message);
    recordErrorInHistory(session);

    await message.reactions.removeAll().catch(() => {});
    await message.react('❌').catch(() => {});

    if (session.threadRef) {
      try {
        await session.threadRef.send({ embeds: [buildErrorEmbed(session, e.message)] });
      } catch (threadErr) {
        console.warn('[follow-up] Failed to send error to thread:', threadErr.message);
      }
    }
  } finally {
    cleanupTempFiles(payload.imagePaths);
  }
}
