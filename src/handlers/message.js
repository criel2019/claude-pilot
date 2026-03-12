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

// savedDir: handleMessageCreate에서 이미 저장한 경우 해당 경로를 전달.
//   null이면 이 함수 내에서 직접 저장 수행.
async function buildFollowUpPayload(message, savedDir = null) {
  const client = getClient();
  const rawText = message.content.trim()
    .replace(new RegExp(`<@!?${client.user.id}>`, 'g'), '').trim();

  // 이미 저장된 경우 재파싱 없이 savedDir 사용; 아니면 텍스트에서 파싱
  const destDir = savedDir ?? parseDestDir(rawText);
  const skipSave = savedDir !== null;

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

  // Read text file attachments — skipSave이면 이미 저장됐으므로 다운로드 생략
  const saveDir = destDir || RECEIVED_DIR;
  let textFileContent = '';
  let textFileLabel = '';
  for (const att of textAtts) {
    try {
      let savedPath = null;
      if (!skipSave) {
        savedPath = await downloadAnyAttachment(att, saveDir);
      }
      const content = await fetchTextFile(att);
      textFileContent += (textFileContent ? '\n\n---\n\n' : '') + content;
      const saveInfo = savedPath
        ? ` → saved: ${savedPath}`
        : (savedDir ? ` (saved to ${savedDir})` : '');
      textFileLabel += (textFileLabel ? ', ' : '') + `📄 ${att.name} (${content.length.toLocaleString()} chars)${saveInfo}`;
    } catch (e) {
      console.warn('[follow-up] Failed to read/save text file:', e.message);
    }
  }

  // Download binary file attachments — skipSave이면 이미 저장됐으므로 다운로드 생략
  let binaryFileContext = '';
  let binaryFileLabel = '';
  for (const att of binaryAtts) {
    if (skipSave) {
      const safeName = att.name.replace(/[\\/:*?"<>|]/g, '_');
      binaryFileContext += `\n[File received and saved to PC: ${savedDir}/${safeName}]`;
      binaryFileLabel += (binaryFileLabel ? ', ' : '') + `📥 ${att.name}`;
    } else {
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
// attachmentList: optional array to limit which attachments to save (default: all)
async function handleDirectFileSave(message, destDir, attachmentList = null) {
  const atts = attachmentList ?? [...message.attachments.values()];
  console.log(`[file-save] ${atts.length} attachment(s) → ${destDir}`);
  await message.react('🔄').catch(() => {});
  const results = [];
  for (const att of atts) {
    try {
      const savedPath = await downloadAnyAttachment(att, destDir);
      results.push(`✅ \`${att.name}\` → \`${savedPath}\``);
    } catch (e) {
      console.error(`[file-save] Failed to save ${att.name}:`, e.message);
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

// Auto-saves non-image file attachments to RECEIVED_DIR (no session / no destDir case)
async function autoSaveAttachments(message) {
  const nonImageAtts = [...message.attachments.values()].filter(a => !isImageFile(a.name));
  if (nonImageAtts.length > 0) {
    await handleDirectFileSave(message, RECEIVED_DIR, nonImageAtts);
  }
}

export async function handleMessageCreate(message) {
  if (message.author.bot || !message.guild) return;
  if (message.attachments.size > 0) {
    console.log(`[msg] Attachments: ${[...message.attachments.values()].map(a => `${a.name} (${a.size})`).join(', ')}`);
  }

  // Direct file-save: when the user attaches files with a save-destination,
  // always save them immediately regardless of session state.
  // isPureSaveText → direct-only (no Claude turn). Otherwise save + continue to session.
  let destDirSaved = false;
  let precomputedDestDir = null;
  if (message.attachments.size > 0 && isUserAllowed(message.author.id)) {
    const client = getClient();
    const rawText = message.content.trim()
      .replace(new RegExp(`<@!?${client.user.id}>`, 'g'), '').trim();
    const destDir = parseDestDir(rawText);
    if (destDir) {
      if (isPureSaveText(rawText)) {
        return handleDirectFileSave(message, destDir);
      }
      // Not a pure save command but has a dest dir — save files first, then continue
      await handleDirectFileSave(message, destDir);
      destDirSaved = true;
      precomputedDestDir = destDir;  // buildFollowUpPayload에 전달해 중복 저장 방지
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
  if (!match) {
    // No active session — auto-save any non-image file attachments to RECEIVED_DIR
    if (!destDirSaved && message.attachments.size > 0 && isUserAllowed(message.author.id)) {
      await autoSaveAttachments(message);
    }
    return;
  }
  const { session, isThread } = match;

  if (isSessionBusy(session)) {
    if (!isUserAllowed(message.author.id)) return;
    const payload = await buildFollowUpPayload(message, precomputedDestDir);
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

  const payload = await buildFollowUpPayload(message, precomputedDestDir);
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
