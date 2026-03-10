import { isUserAllowed } from '../config.js';
import { activeSessions } from '../state.js';
import {
  isSessionBusy, enqueueMessage, loadSessionFile, createSessionObject,
  saveSession, recordErrorInHistory,
} from '../session.js';
import { buildProgressEmbed, buildErrorEmbed, buildProgressButtons } from '../embeds.js';
import { initSessionThread, runTurnAndUpdateThread, makeProgressUpdater, drainQueue, CLAUDE_BIN } from '../claude.js';
import { terminateSession } from './sessions.js';
import { popPendingReview } from '../review.js';
import { spawn } from 'child_process';
import { parseStreamJson } from '../claude.js';

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

async function handleModalReviewApply(interaction) {
  const channelId = interaction.customId.slice('review_apply_modal:'.length);
  const pending = popPendingReview(channelId);
  if (!pending) {
    await interaction.reply({ content: '⚠️ 리뷰 데이터가 만료됐습니다. 다시 리뷰 후 시도해주세요.', ephemeral: true });
    return;
  }
  if (!isUserAllowed(interaction.user.id)) {
    await interaction.reply({ content: '❌ Not authorized.', ephemeral: true });
    return;
  }

  const comment = interaction.fields.getTextInputValue('comment').trim();
  const prompt = [
    '아래 코드 리뷰 결과를 반영해서 해당 파일을 수정해줘.',
    comment ? `\n추가 지시: ${comment}` : '',
    '',
    '## 코드 리뷰 결과',
    pending.reviewResult,
    '',
    `## 수정 대상 파일`,
    pending.files.join(', '),
  ].join('\n');

  await interaction.deferReply();

  try {
    const result = await new Promise((resolve, reject) => {
      const args = [
        '-p', prompt,
        '--model', 'sonnet',
        '--output-format', 'stream-json',
        '--verbose',
        '--dangerously-skip-permissions',
      ];
      const proc = spawn(CLAUDE_BIN.cmd, [...CLAUDE_BIN.prefix, ...args], {
        cwd: pending.cwd,
        env: { ...process.env, CLAUDECODE: '', TERM: 'dumb', NO_COLOR: '1' },
        stdio: ['ignore', 'pipe', 'pipe'],
        shell: CLAUDE_BIN.shell || false,
      });

      let finalResult = '';
      let displayBuffer = '';
      let stderrBuf = '';

      proc.stderr.on('data', d => { if (stderrBuf.length < 2000) stderrBuf += d.toString('utf8'); });
      parseStreamJson(proc, (event) => {
        if (event.type === 'assistant' && event.message?.content) {
          for (const block of event.message.content) {
            if (block.type === 'text') displayBuffer = block.text;
          }
        }
        if (event.type === 'result') {
          finalResult = typeof event.result === 'string' ? event.result : (event.result?.text || '');
        }
      });

      const timeout = setTimeout(() => { proc.kill('SIGKILL'); resolve('⏱ 시간 초과'); }, 5 * 60 * 1000);
      proc.on('close', () => { clearTimeout(timeout); resolve(finalResult || displayBuffer || '완료 (출력 없음)'); });
      proc.on('error', err => { clearTimeout(timeout); reject(err); });
    });

    const text = typeof result === 'string' ? result : String(result);
    await interaction.editReply({
      content: `✅ 수정 완료\n\`\`\`\n${text.slice(0, 1800)}\n\`\`\``,
    });
  } catch (e) {
    console.error('[review_apply] Failed:', e.message);
    await interaction.editReply({ content: `❌ 수정 실패: ${e.message.slice(0, 300)}` });
  }
}

export async function handleModalSubmit(interaction) {
  if (interaction.customId.startsWith('session_input:'))      return handleModalSessionInput(interaction);
  if (interaction.customId.startsWith('restart_modal:'))      return handleModalRestart(interaction);
  if (interaction.customId.startsWith('review_apply_modal:')) return handleModalReviewApply(interaction);
  await interaction.reply({ content: 'Unknown modal.', ephemeral: true });
}
