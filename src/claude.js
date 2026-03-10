import { spawn, execSync } from 'child_process';
import { readFileSync, existsSync, statSync } from 'fs';
import { join, basename, resolve } from 'path';
import { AttachmentBuilder } from 'discord.js';
import {
  SEND_TIMEOUT, THREAD_NAME_MAX, THREAD_AUTO_ARCHIVE,
  EMBED_MAX_CHARS, EMBED_TRIM_CHARS, BOT_DIR,
  MAX_UPLOAD_SIZE, ALLOWED_SEND_ROOTS,
} from './constants.js';

// Resolve the claude CLI entry point for shell-free spawning on Windows.
// npm global shims (.cmd) don't work with shell:false, so we locate the
// actual JS entry and invoke it via node directly.
function resolveClaudeBin() {
  const cliRelative = join('node_modules', '@anthropic-ai', 'claude-code', 'cli.js');

  // 1. Try npm global prefix (works for default npm, nvm, custom prefix)
  try {
    const prefix = execSync('npm root -g', { encoding: 'utf8' }).trim();
    const cliJs = join(prefix, '@anthropic-ai', 'claude-code', 'cli.js');
    if (existsSync(cliJs)) return { cmd: process.execPath, prefix: [cliJs] };
  } catch {}

  // 2. Try APPDATA/npm (Windows default)
  if (process.env.APPDATA) {
    const cliJs = join(process.env.APPDATA, 'npm', cliRelative);
    if (existsSync(cliJs)) return { cmd: process.execPath, prefix: [cliJs] };
  }

  // 3. Fallback: use shell to let OS resolve claude
  return { cmd: 'claude', prefix: [], shell: true };
}

export const CLAUDE_BIN = resolveClaudeBin();
import { getConfig } from './config.js';
import { pushHistory, updateTokenStats, saveSession, recordErrorInHistory } from './session.js';
import { cleanupTempFiles } from './files.js';
import {
  buildProgressEmbed, buildResultEmbed,
  buildTurnHistoryEmbed, buildSessionButtons,
  buildProgressButtons, buildErrorEmbed, buildRetryButton,
} from './embeds.js';

// ── File send marker parser ──
// Claude includes [SEND_FILE:/path] in its response to trigger a Discord file upload.

const SENSITIVE_FILENAME_RE = /\.(env|pem|key|pfx|p12)$|^(id_rsa|id_ed25519|\.ssh|SAM|SYSTEM|NTDS\.dit)$/i;

function isSafeFilePath(fp, sessionCwd) {
  const normalized = resolve(fp).replace(/\\/g, '/');
  const allowedRoots = sessionCwd
    ? [...ALLOWED_SEND_ROOTS, sessionCwd.replace(/\\/g, '/')]
    : ALLOWED_SEND_ROOTS;
  const underAllowedRoot = allowedRoots.some(root =>
    normalized.toLowerCase().startsWith(root.toLowerCase())
  );
  if (!underAllowedRoot) return { ok: false, reason: '허용되지 않은 경로' };
  if (SENSITIVE_FILENAME_RE.test(basename(normalized))) return { ok: false, reason: '민감한 파일' };
  return { ok: true };
}

function extractFileSendRequests(text) {
  // Exclude newlines from path to prevent multi-line injection
  const pattern = /\[SEND_FILE:([^\]\r\n]+)\]/g;
  const paths = [];
  let match;
  while ((match = pattern.exec(text)) !== null) paths.push(match[1].trim());
  const cleanedText = text.replace(/\[SEND_FILE:[^\]\r\n]+\]/g, '').replace(/\n{3,}/g, '\n\n').trim();
  return { paths, cleanedText };
}

// ── Context builder ──
// Constructs a conversation history block injected as context into each Claude turn.

export function buildContextBlock(messageHistory) {
  if (messageHistory.length === 0) return '';

  const cfg = getConfig();
  const MAX_RECENT_MESSAGES = (cfg.max_context_history_turns || 4) * 2;
  const MAX_SUMMARY_CHARS = 150;
  const MAX_CONTEXT_CHARS = cfg.max_context_chars || 50000;

  const lines = ['[Previous conversation context for continuity]'];

  const olderMessages = messageHistory.length > MAX_RECENT_MESSAGES
    ? messageHistory.slice(0, messageHistory.length - MAX_RECENT_MESSAGES)
    : [];
  const recentMessages = messageHistory.slice(-MAX_RECENT_MESSAGES);

  if (olderMessages.length > 0) {
    lines.push('--- Earlier (summarized) ---');
    for (const msg of olderMessages) {
      const prefix = msg.role === 'user' ? 'User' : 'Claude';
      const text = msg.content.slice(0, MAX_SUMMARY_CHARS);
      lines.push(`${prefix}: ${text}${msg.content.length > MAX_SUMMARY_CHARS ? '...' : ''}`);
    }
  }

  if (recentMessages.length > 0) {
    lines.push('--- Recent conversation ---');
    for (const msg of recentMessages) {
      const prefix = msg.role === 'user' ? 'User' : 'Claude';
      const text = msg.content.length > 3000
        ? msg.content.slice(0, 3000) + '\n[...truncated]'
        : msg.content;
      lines.push(`${prefix}: ${text}`);
    }
  }

  lines.push('[End of context]');
  let block = lines.join('\n');

  if (block.length > MAX_CONTEXT_CHARS) {
    if (block.length > 30000) {
      console.warn(`[context] Context is ${block.length} chars — trimming`);
    }
    const trimmedLines = ['[Previous conversation context for continuity]', '--- Recent conversation ---'];
    for (const msg of recentMessages.slice(-4)) {
      const prefix = msg.role === 'user' ? 'User' : 'Claude';
      const text = msg.content.length > 1000
        ? msg.content.slice(0, 1000) + '\n[...truncated]'
        : msg.content;
      trimmedLines.push(`${prefix}: ${text}`);
    }
    trimmedLines.push('[End of context]');
    block = trimmedLines.join('\n');
  }

  return block;
}

// ── Stream JSON parser ──
// Parses line-delimited JSON events from the Claude CLI stdout stream.

export function parseStreamJson(proc, onEvent) {
  let buffer = '';
  proc.stdout.on('data', (chunk) => {
    buffer += chunk.toString('utf8');
    const lines = buffer.split('\n');
    buffer = lines.pop();
    for (const line of lines) {
      if (!line.trim()) continue;
      try { onEvent(JSON.parse(line)); } catch {}
    }
  });
  proc.stdout.on('end', () => {
    if (buffer.trim()) {
      try { onEvent(JSON.parse(buffer)); } catch {}
    }
  });
}

// Reads gpt-projects.md for use as a system prompt listing registered projects
function readProjectList() {
  try {
    return readFileSync(join(BOT_DIR, 'gpt-projects.md'), 'utf8').trim();
  } catch {
    return '';
  }
}

// ── Claude turn executor ──
// Spawns the Claude CLI and streams events, calling onUpdate periodically.

export function executeClaudeTurn({ session, userText, onUpdate, timeout = SEND_TIMEOUT }) {
  const NON_INTERACTIVE_PROMPT = [
    'CRITICAL: This is a non-interactive, one-shot prompt environment (Discord bot).',
    'You CANNOT use these interactive tools: EnterPlanMode, ExitPlanMode, AskUserQuestion.',
    'They will fail silently and the user will never see the questions or plans.',
    'Instead:',
    '- Do NOT enter plan mode. Proceed directly with implementation.',
    '- If you have questions, list them clearly in your text response. The user will answer in the next message.',
    '- If you want to show a plan, write it directly in your text response.',
    '- Always work autonomously and make reasonable default decisions when possible.',
    '- To send a file to the user via Discord, include [SEND_FILE:/absolute/path/to/file] anywhere in your response. Multiple markers are allowed. The bot will attach the files automatically.',
  ].join('\n');

  const projectList = readProjectList();
  const systemPrompt = projectList
    ? `${NON_INTERACTIVE_PROMPT}\n\nRegistered projects:\n${projectList}`
    : NON_INTERACTIVE_PROMPT;

  // Use --resume to continue a previous session when available
  const args = ['-p', userText];
  if (session.claudeSessionId) {
    args.unshift('--resume', session.claudeSessionId);
  }
  args.push(
    '--model', session.model,
    '--output-format', 'stream-json',
    '--include-partial-messages',
    '--verbose',
    '--dangerously-skip-permissions',
    '--append-system-prompt', systemPrompt,
  );

  const proc = spawn(CLAUDE_BIN.cmd, [...CLAUDE_BIN.prefix, ...args], {
    cwd: session.cwd,
    env: { ...process.env, CLAUDECODE: '', TERM: 'dumb', NO_COLOR: '1' },
    stdio: ['ignore', 'pipe', 'pipe'],
    shell: CLAUDE_BIN.shell || false,
  });
  session.proc = proc;

  let displayBuffer = '';
  let toolStatus = '';
  let finalResult = '';
  let stderrBuffer = '';
  let costData = null;
  const startTime = Date.now();
  const cfg = getConfig();
  const editIntervalMs = cfg.stream_edit_interval_ms || 2000;

  proc.stderr.on('data', (d) => {
    if (stderrBuffer.length < 10000) stderrBuffer += d.toString('utf8');
  });

  parseStreamJson(proc, (event) => {
    // Current CLI format: assistant events (--include-partial-messages)
    if (event.type === 'assistant' && event.message?.content) {
      let text = '';
      for (const block of event.message.content) {
        if (block.type === 'text') text += block.text;
        else if (block.type === 'tool_use') {
          toolStatus = `🔧 _${block.name}_ running...`;
          // Edit/Write 툴에서 수정된 파일 경로 추적
          const fp = block.input?.file_path ?? block.input?.path;
          if (fp && /Edit|Write|MultiEdit|NotebookEdit/.test(block.name)) {
            session.modifiedFiles?.add(fp);
          }
        }
      }
      if (text) displayBuffer = text;
      // Clear tool status when the last block is not a tool_use
      const lastBlock = event.message.content[event.message.content.length - 1];
      if (lastBlock?.type !== 'tool_use') toolStatus = '';
    }

    // Legacy format: stream_event (for older CLI versions)
    if (event.type === 'stream_event') {
      const ev = event.event;
      if (ev?.delta?.type === 'text_delta') {
        displayBuffer += ev.delta.text;
      }
      if (ev?.type === 'content_block_start' && ev.content_block?.type === 'tool_use') {
        toolStatus = `🔧 _${ev.content_block.name}_ running...`;
      }
      if (ev?.type === 'content_block_stop' && toolStatus) {
        displayBuffer += `\n${toolStatus.replace('running...', 'done')}\n`;
        toolStatus = '';
      }
    }

    if (event.type === 'result' && event.result) {
      // Extract session_id for --resume on the next turn
      if (event.session_id) {
        console.log(`[claude] session_id received: ${event.session_id}`);
        session.claudeSessionId = event.session_id;
      }
      finalResult = typeof event.result === 'string'
        ? event.result
        : (event.result.text || JSON.stringify(event.result));
      if (event.cost_usd != null) {
        costData = {
          costUsd: event.cost_usd,
          inputTokens: event.usage?.input_tokens ?? null,
          outputTokens: event.usage?.output_tokens ?? null,
        };
      }
    }
  });

  const editTimer = setInterval(async () => {
    if (displayBuffer.length > 0 && onUpdate) {
      const elapsed = ((Date.now() - startTime) / 1000).toFixed(0);
      const display = displayBuffer.length > EMBED_MAX_CHARS
        ? '…' + displayBuffer.slice(-EMBED_TRIM_CHARS)
        : displayBuffer;
      const content = display + (toolStatus ? `\n\n${toolStatus}` : '');
      try {
        await onUpdate(content, elapsed);
      } catch {}
    }
  }, editIntervalMs);

  return new Promise((resolve, reject) => {
    let settled = false;

    const timeoutTimer = setTimeout(() => {
      if (!settled) {
        proc.kill('SIGKILL');
        const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
        settle({
          displayText: displayBuffer || finalResult,
          historyText: finalResult || displayBuffer,
          elapsed,
          exitCode: -1,
          timedOut: true,
          stderr: stderrBuffer,
          costData,
        });
      }
    }, timeout);

    const settle = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeoutTimer);
      clearInterval(editTimer);
      session.proc = null;
      resolve(result);
    };

    proc.on('close', (code) => {
      const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
      settle({
        displayText: displayBuffer || finalResult,
        historyText: finalResult || displayBuffer,
        elapsed,
        exitCode: code,
        timedOut: false,
        stderr: stderrBuffer,
        costData,
      });
    });

    proc.on('error', (err) => {
      if (settled) return;
      // Clear claudeSessionId when --resume fails so the next turn starts fresh
      if (session.claudeSessionId) {
        console.warn(`[claude] Resume failed — clearing claudeSessionId: ${err.message}`);
        session.claudeSessionId = null;
      }
      settled = true;
      clearTimeout(timeoutTimer);
      clearInterval(editTimer);
      session.proc = null;
      reject(new Error(err.message + (stderrBuffer ? `\n${stderrBuffer}` : '')));
    });
  });
}

// Creates a progress updater that edits the starter message embed while Claude is running
export function makeProgressUpdater(session) {
  return async (content, elapsed) => {
    if (!session.starterMessageRef) return;
    try {
      await session.starterMessageRef.edit({
        embeds: [buildProgressEmbed(session, content, elapsed)],
        components: [buildProgressButtons(session.channelId)],
      });
    } catch {}
  };
}

// Processes queued messages sequentially after the current turn completes
export async function drainQueue(session) {
  if (session.drainingQueue) return; // Prevent re-entrant drain
  session.drainingQueue = true;
  try {
    while (session.pendingMessages?.length > 0) {
      const item = session.pendingMessages.shift();
      try {
        const result = await runTurnAndUpdateThread({
          session,
          userText: item.promptText,
          userDisplayText: item.displayText,
          onProgress: makeProgressUpdater(session),
        });
        if (item.discordMessage) {
          await item.discordMessage.reactions.removeAll().catch(() => {});
          await item.discordMessage.react(result.exitCode === 0 ? '✅' : '❌').catch(() => {});
        }
      } catch (e) {
        console.error('[queue] Failed to process queued item:', e.message);
        recordErrorInHistory(session);
        if (item.discordMessage) {
          await item.discordMessage.reactions.removeAll().catch(() => {});
          await item.discordMessage.react('❌').catch(() => {});
        }
        if (session.threadRef) {
          try { await session.threadRef.send({ embeds: [buildErrorEmbed(session, e.message)] }); } catch {}
        }
      } finally {
        if (item.imagePaths?.length) cleanupTempFiles(item.imagePaths);
      }
    }
  } finally {
    session.drainingQueue = false;
  }
}

// Creates a Discord thread attached to the session's starter message
export async function initSessionThread(session, starterMsg) {
  const threadName = session.channelName
    ? `[Claude] #${session.channelName} | ${session.projectName}`
    : `[Claude] ${session.projectName}`;
  try {
    const thread = await starterMsg.startThread({
      name: threadName.slice(0, THREAD_NAME_MAX),
      autoArchiveDuration: THREAD_AUTO_ARCHIVE,
    });
    session.threadId = thread.id;
    session.starterMessageId = starterMsg.id;
    session.threadRef = thread;
    session.starterMessageRef = starterMsg;
  } catch (e) {
    console.error('[thread] Failed to create thread:', e.message);
    session.starterMessageRef = starterMsg;
  }
}

// ── Turn runner ──
// Executes a single Claude turn, updates the starter embed and posts to the thread.

export async function runTurnAndUpdateThread({ session, userText, userDisplayText, onProgress }) {
  session.lastTurnText = userText;
  session.lastTurnDisplayText = userDisplayText || userText;
  pushHistory(session, 'user', userDisplayText || userText);
  session.lastActivity = Date.now();

  const resumeInfo = session.claudeSessionId ? `resume: ${session.claudeSessionId.slice(0, 8)}...` : 'new session';
  console.log(`[turn] ${session.projectName}: "${userText.slice(0, 50)}..." (model: ${session.model}, turn: ${session.turnCount + 1}, ${resumeInfo})`);

  const result = await executeClaudeTurn({
    session,
    userText,
    onUpdate: onProgress,
  });

  session.turnCount++;

  // Extract [SEND_FILE:/path] markers before storing history or displaying (always clean both)
  const { paths: sendFilePaths, cleanedText: cleanedDisplay } = extractFileSendRequests(result.displayText);
  result.displayText = cleanedDisplay;
  result.historyText = extractFileSendRequests(result.historyText).cleanedText;

  pushHistory(session, 'assistant', result.historyText);
  updateTokenStats(session);

  console.log(`[turn] Done: ${result.elapsed}s, ${result.displayText.length} chars`);

  const failed = result.exitCode !== 0 || result.timedOut;
  const sessionRow = buildSessionButtons(session.channelId);
  const retryRow = buildRetryButton(session.channelId);
  const resultComponents = failed ? [sessionRow, retryRow] : [sessionRow];

  // Update starter message with the final result embed
  if (session.starterMessageRef) {
    try {
      await session.starterMessageRef.edit({
        embeds: [buildResultEmbed(session, result)],
        components: resultComponents,
      });
    } catch (e) {
      console.warn('[turn] Failed to edit starter message:', e.message);
    }
  }

  // Post per-turn history to the thread
  if (session.threadRef) {
    try {
      // Remove buttons from the previous thread message
      if (session.lastThreadButtonMsg) {
        try {
          await session.lastThreadButtonMsg.edit({ components: [] });
        } catch (_) {}
      }
      const threadMsg = await session.threadRef.send({
        embeds: [buildTurnHistoryEmbed(session, userDisplayText || userText, result)],
        components: resultComponents,
      });
      session.lastThreadButtonMsg = threadMsg;
    } catch (e) {
      console.warn('[turn] Failed to post thread history:', e.message);
    }
  }

  // Send files requested via [SEND_FILE:/path] markers
  if (sendFilePaths.length > 0 && session.threadRef) {
    const validFiles = [];
    const errors = [];
    for (const fp of sendFilePaths) {
      const safety = isSafeFilePath(fp, session.cwd);
      if (!safety.ok) { errors.push(`❌ \`${basename(fp)}\`: ${safety.reason}`); continue; }
      try {
        if (!existsSync(fp)) { errors.push(`❌ \`${basename(fp)}\`: 파일 없음`); continue; }
        const size = statSync(fp).size;
        if (size > MAX_UPLOAD_SIZE) {
          errors.push(`❌ \`${basename(fp)}\`: 너무 큼 (${(size / 1024 / 1024).toFixed(1)}MB, 최대 24MB)`);
          continue;
        }
        validFiles.push(fp);
      } catch (e) {
        errors.push(`❌ \`${basename(fp)}\`: 읽기 실패 (${e.message})`);
      }
    }
    const MAX_FILES = 10;
    const filesToSend = validFiles.slice(0, MAX_FILES);
    const overflow = validFiles.length - filesToSend.length;
    try {
      if (filesToSend.length > 0) {
        const overflowNote = overflow > 0 ? ` (+${overflow}개 초과, 생략됨)` : '';
        await session.threadRef.send({
          content: `📤 ${filesToSend.map(fp => `\`${basename(fp)}\``).join(', ')}${overflowNote}`,
          files: filesToSend.map(fp => new AttachmentBuilder(fp)),
        });
      }
      if (errors.length > 0) await session.threadRef.send({ content: errors.join('\n') });
    } catch (e) {
      console.warn('[file-send] Failed to send file(s):', e.message);
    }
  }

  saveSession(session);

  return result;
}
