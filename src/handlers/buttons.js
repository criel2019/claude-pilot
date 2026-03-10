import {
  ModalBuilder, TextInputBuilder, TextInputStyle, ActionRowBuilder,
  ButtonBuilder, ButtonStyle,
} from 'discord.js';
import { spawn } from 'child_process';
import { CLAUDE_BIN } from '../claude.js';
import { isUserAllowed } from '../config.js';
import { activeSessions } from '../state.js';
import {
  isSessionBusy, enqueueMessage, loadSessionFile,
  setChannelDefaultProject, recordErrorInHistory, resetHistory, updateTokenStats,
} from '../session.js';
import { runTrackerAsync, invalidateAllCaches } from '../tracker.js';
import { buildDashboardEmbed, isDashboardRefreshing } from '../dashboard.js';
import { runTurnAndUpdateThread, makeProgressUpdater, drainQueue, parseStreamJson } from '../claude.js';
import { terminateSession } from './sessions.js';
import { handleGptEnd, activeGptSessions } from './gpt.js';
import { buildReviewPrompt, buildReviewResultEmbed, buildReviewApplyButton, storePendingReview } from '../review.js';

// Separate flag for button-triggered refreshes (distinct from auto-refresh lock)
let _buttonRefreshing = false;

async function handleButtonDashboardRefresh(interaction) {
  // Block if either auto-refresh or another button refresh is already running
  if (isDashboardRefreshing() || _buttonRefreshing) {
    await interaction.deferUpdate();
    return;
  }
  _buttonRefreshing = true;
  try {
    // Include current embeds in update so they aren't cleared while scanning
    const disabledRow = new ActionRowBuilder().addComponents(
      new ButtonBuilder()
        .setCustomId('dashboard_refresh')
        .setLabel('Scanning...')
        .setEmoji('⏳')
        .setStyle(ButtonStyle.Secondary)
        .setDisabled(true)
    );
    await interaction.update({ components: [disabledRow] });
    await runTrackerAsync('scan');
    invalidateAllCaches();
    await interaction.editReply(buildDashboardEmbed());
  } finally {
    _buttonRefreshing = false;
  }
}

async function handleButtonProjectSelect(interaction) {
  const projectName = interaction.customId.slice('project_select:'.length);
  setChannelDefaultProject(interaction.channelId, projectName);
  await interaction.update({
    content: `Default project for this channel set to **${projectName}**.\nYou can now omit the project option in \`/send\`.`,
    components: [],
  });
}

async function handleButtonSessionContinue(interaction) {
  const channelId = interaction.customId.slice('session_continue:'.length);
  const session = activeSessions.get(channelId);
  if (!session) {
    await interaction.reply({ content: 'Session expired. Start a new one with `/send`.', ephemeral: true });
    return;
  }

  const modal = new ModalBuilder()
    .setCustomId(`session_input:${channelId}`)
    .setTitle(`${session.projectName} — Continue`);

  const input = new TextInputBuilder()
    .setCustomId('message_input')
    .setLabel('Message')
    .setPlaceholder('Type your message to Claude...')
    .setStyle(TextInputStyle.Paragraph)
    .setRequired(true);

  modal.addComponents(new ActionRowBuilder().addComponents(input));
  await interaction.showModal(modal);
}

async function handleButtonSessionCleanup(interaction) {
  const channelId = interaction.customId.slice('session_cleanup:'.length);
  if (!activeSessions.has(channelId)) {
    await interaction.reply({ content: 'Session has already ended.', ephemeral: true });
    return;
  }

  await interaction.deferReply({ ephemeral: true });
  await terminateSession(channelId, {
    threadMessage: '✅ Session saved. Starting fresh.',
    sendRestartButton: false,
  });
  await interaction.editReply({
    content: `🗑️ History cleared.\nThe next \`/send\` will start a new session.\nPrevious sessions can be loaded with \`/sessions\`.`,
  });
}

async function handleButtonSessionRestart(interaction) {
  const sessionId = interaction.customId.slice('session_restart:'.length);
  let restartData;
  try {
    restartData = loadSessionFile(sessionId);
  } catch {
    await interaction.reply({ content: '❌ Session data not found.', ephemeral: true });
    return;
  }

  const modal = new ModalBuilder()
    .setCustomId(`restart_modal:${sessionId}`)
    .setTitle(`${restartData.projectName} — Restart`);

  const restartInput = new TextInputBuilder()
    .setCustomId('message_input')
    .setLabel('First message')
    .setPlaceholder('Type your message to Claude...')
    .setStyle(TextInputStyle.Paragraph)
    .setRequired(true);

  modal.addComponents(new ActionRowBuilder().addComponents(restartInput));
  await interaction.showModal(modal);
}

async function handleButtonSessionEnd(interaction) {
  const channelId = interaction.customId.slice('session_end:'.length);
  const session = activeSessions.get(channelId);
  if (!session) {
    await interaction.reply({ content: 'Session is already ended.', ephemeral: true });
    return;
  }

  await interaction.deferReply();
  const terminated = await terminateSession(channelId, {
    threadMessage: `🔚 Session ended. ${session.turnCount} turns completed.`,
  });
  if (!terminated) {
    await interaction.editReply({ content: '⚠️ Error while ending the session.' });
    return;
  }
  await interaction.editReply({
    content: `✅ Session ended: **${terminated.projectName}** (${terminated.turnCount} turns)\nView saved sessions with \`/sessions\`.`,
  });
}

async function handleButtonSessionCancel(interaction) {
  const channelId = interaction.customId.slice('session_cancel:'.length);
  const session = activeSessions.get(channelId);
  // Capture proc locally to guard against race condition on double-click
  const proc = session?.proc;
  if (!proc || proc.exitCode !== null) {
    await interaction.reply({ content: 'Nothing to cancel.', ephemeral: true });
    return;
  }
  session.pendingMessages = [];
  proc.kill('SIGKILL');
  await interaction.reply({ content: '⏹ Task cancelled. Pending queue cleared.', ephemeral: true });
}

async function handleButtonSessionResetHistory(interaction) {
  const channelId = interaction.customId.slice('session_reset_history:'.length);
  const session = activeSessions.get(channelId);
  if (!session) {
    await interaction.reply({ content: 'Session has expired.', ephemeral: true });
    return;
  }
  if (!isUserAllowed(interaction.user.id)) {
    await interaction.reply({ content: '❌ Not authorized.', ephemeral: true });
    return;
  }
  if (isSessionBusy(session)) {
    await interaction.reply({ content: '⏳ Session is busy. Try again after it finishes.', ephemeral: true });
    return;
  }
  resetHistory(session);
  await interaction.reply({ content: '🗑 History cleared. The Claude session context is preserved.', ephemeral: true });
}

async function handleButtonSessionRetry(interaction) {
  const channelId = interaction.customId.slice('session_retry:'.length);
  const session = activeSessions.get(channelId);
  if (!session) {
    await interaction.reply({ content: 'Session has expired.', ephemeral: true });
    return;
  }
  if (!isUserAllowed(interaction.user.id)) {
    await interaction.reply({ content: '❌ Not authorized.', ephemeral: true });
    return;
  }
  if (isSessionBusy(session)) {
    await interaction.reply({ content: '⏳ Session is busy.', ephemeral: true });
    return;
  }
  if (!session.lastTurnText) {
    await interaction.reply({ content: 'No previous request to retry. (Not available after bot restart.)', ephemeral: true });
    return;
  }

  // Remove the last user+assistant pair from history before retrying
  const len = session.messageHistory.length;
  if (len >= 2 &&
      session.messageHistory[len - 1]?.role === 'assistant' &&
      session.messageHistory[len - 2]?.role === 'user') {
    session.messageHistory.splice(-2, 2);
  } else if (len >= 1 && session.messageHistory[len - 1]?.role === 'assistant') {
    session.messageHistory.pop();
  }
  updateTokenStats(session);

  // deferUpdate: acknowledge button click without sending a new message
  await interaction.deferUpdate();
  try {
    await runTurnAndUpdateThread({
      session,
      userText: session.lastTurnText,
      userDisplayText: session.lastTurnDisplayText || session.lastTurnText,
      onProgress: makeProgressUpdater(session),
    });
    await drainQueue(session);
  } catch (e) {
    console.error(`[retry] ${session.projectName} failed:`, e.message);
    recordErrorInHistory(session);
    await interaction.followUp({ content: `❌ Retry failed: ${e.message.slice(0, 200)}`, ephemeral: true });
  }
}

async function handleButtonReviewStart(interaction) {
  const channelId = interaction.customId.slice('review_start:'.length);
  const session = activeSessions.get(channelId);
  if (!session) {
    await interaction.reply({ content: 'Session has expired. Start a new one with `/send`.', ephemeral: true });
    return;
  }
  if (!isUserAllowed(interaction.user.id)) {
    await interaction.reply({ content: '❌ Not authorized.', ephemeral: true });
    return;
  }

  // Build review prompt from git diff + dependency context
  const reviewData = buildReviewPrompt(session);
  if (!reviewData) {
    await interaction.reply({ content: '📋 변경 사항 없음 — 스테이지/언스테이지된 변경사항이 없습니다.', ephemeral: true });
    return;
  }

  await interaction.deferReply();
  const { prompt, meta } = reviewData;

  try {
    // Spawn a fresh Sonnet session (no --resume) for minimal cost
    const result = await new Promise((resolve, reject) => {
      const args = [
        '-p', prompt,
        '--model', 'sonnet',
        '--output-format', 'stream-json',
        '--verbose',
        '--dangerously-skip-permissions',
      ];

      const proc = spawn(CLAUDE_BIN.cmd, [...CLAUDE_BIN.prefix, ...args], {
        cwd: session.cwd,
        env: { ...process.env, CLAUDECODE: '', TERM: 'dumb', NO_COLOR: '1' },
        stdio: ['ignore', 'pipe', 'pipe'],
        shell: CLAUDE_BIN.shell || false,
      });

      let finalResult = '';
      let stderrBuf = '';
      const startTime = Date.now();

      proc.stderr.on('data', (d) => {
        if (stderrBuf.length < 5000) stderrBuf += d.toString('utf8');
      });

      let displayBuffer = '';
      parseStreamJson(proc, (event) => {
        // assistant 이벤트에서 텍스트 수집 (현재 CLI 포맷)
        if (event.type === 'assistant' && event.message?.content) {
          for (const block of event.message.content) {
            if (block.type === 'text') displayBuffer = block.text;
          }
        }
        // result 이벤트에서 최종 결과 추출
        if (event.type === 'result') {
          finalResult = typeof event.result === 'string'
            ? event.result
            : (event.result?.text || JSON.stringify(event.result) || '');
        }
      });

      const timeout = setTimeout(() => {
        proc.kill('SIGKILL');
        resolve({ text: finalResult || '⏱ 리뷰 시간 초과', timedOut: true });
      }, 3 * 60 * 1000); // 3 min timeout for review

      proc.on('close', () => {
        clearTimeout(timeout);
        resolve({ text: finalResult || displayBuffer, timedOut: false });
      });

      proc.on('error', (err) => {
        clearTimeout(timeout);
        reject(err);
      });
    });

    const reviewText = result.text || '리뷰 결과 없음';
    const embed = buildReviewResultEmbed(meta, reviewText);
    const noIssue = reviewText.toLowerCase().includes('이상 없음') || reviewText.toLowerCase().includes('no issue');

    // 이슈가 있을 때만 수정 적용 버튼 제공
    const components = noIssue ? [] : [buildReviewApplyButton(channelId)];

    // pending review 저장 (수정 적용 시 사용)
    if (!noIssue) {
      storePendingReview(channelId, {
        reviewResult: reviewText,
        cwd: meta.cwd,
        files: meta.files,
      });
    }

    await interaction.editReply({ embeds: [embed], components });
    console.log(`[review] Completed for ${session.projectName}: ${meta.hash} "${meta.msg}"`);
  } catch (e) {
    console.error('[review] Failed:', e.message);
    await interaction.editReply({ content: `❌ 리뷰 실패: ${e.message.slice(0, 300)}` });
  }
}

async function handleButtonReviewApply(interaction) {
  const channelId = interaction.customId.slice('review_apply:'.length);

  const modal = new ModalBuilder()
    .setCustomId(`review_apply_modal:${channelId}`)
    .setTitle('수정 적용');

  const commentInput = new TextInputBuilder()
    .setCustomId('comment')
    .setLabel('추가 지시 (선택사항)')
    .setPlaceholder('예: "기존 스타일과 맞춰줘", "주석도 달아줘" 등')
    .setStyle(TextInputStyle.Paragraph)
    .setRequired(false);

  modal.addComponents(new ActionRowBuilder().addComponents(commentInput));
  await interaction.showModal(modal);
}

async function handleButtonGptEnd(interaction) {
  const threadId = interaction.customId.slice('gpt_end:'.length);
  const session = activeGptSessions.get(threadId);
  if (!session) {
    await interaction.reply({ content: 'Session is already ended.', ephemeral: true });
    return;
  }
  await handleGptEnd(interaction, threadId);
}

export async function handleButton(interaction) {
  const id = interaction.customId;
  if (id === 'dashboard_refresh')              return handleButtonDashboardRefresh(interaction);
  if (id.startsWith('project_select:'))        return handleButtonProjectSelect(interaction);
  if (id.startsWith('session_continue:'))      return handleButtonSessionContinue(interaction);
  if (id.startsWith('session_cleanup:'))       return handleButtonSessionCleanup(interaction);
  if (id.startsWith('session_restart:'))       return handleButtonSessionRestart(interaction);
  if (id.startsWith('session_end:'))           return handleButtonSessionEnd(interaction);
  if (id.startsWith('session_cancel:'))        return handleButtonSessionCancel(interaction);
  if (id.startsWith('session_reset_history:')) return handleButtonSessionResetHistory(interaction);
  if (id.startsWith('session_retry:'))         return handleButtonSessionRetry(interaction);
  if (id.startsWith('review_start:'))          return handleButtonReviewStart(interaction);
  if (id.startsWith('review_apply:'))          return handleButtonReviewApply(interaction);
  if (id.startsWith('gpt_end:'))               return handleButtonGptEnd(interaction);
  await interaction.reply({ content: 'Unknown button.', ephemeral: true });
}
