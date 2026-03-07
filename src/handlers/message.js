import { TEXT_EXTENSIONS } from '../constants.js';
import { isUserAllowed } from '../config.js';
import { activeSessions, getClient } from '../state.js';
import { isSessionBusy, enqueueMessage, recordErrorInHistory } from '../session.js';
import {
  isImageFile, fetchTextFile, prepareImageAttachments,
  buildImagePrompt, cleanupTempFiles,
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

  const imageAtts = [...message.attachments.filter(a => isImageFile(a.name)).values()];
  const textAtts = [...message.attachments.filter(a => {
    const ext = (a.name.split('.').pop() || '').toLowerCase();
    return TEXT_EXTENSIONS.has(ext);
  }).values()];

  if (!rawText && imageAtts.length === 0 && textAtts.length === 0) return null;

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

  const combinedText = [rawText, textFileContent].filter(Boolean).join('\n\n---\n\n');
  if (!combinedText && imageAtts.length === 0) return null;

  const imagePaths = await prepareImageAttachments(imageAtts);
  const baseDisplay = textFileLabel ? (rawText ? `${rawText}\n${textFileLabel}` : textFileLabel) : undefined;
  const { promptText, displayText } = buildImagePrompt(combinedText || rawText, imagePaths, baseDisplay);

  const finalText = (imagePaths.length > 0 || textFileContent)
    ? (promptText || combinedText)
    : rawText;

  if (!finalText) { cleanupTempFiles(imagePaths); return null; }

  return { promptText: finalText, displayText, imagePaths };
}

export async function handleMessageCreate(message) {
  if (message.author.bot || !message.guild) return;

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
