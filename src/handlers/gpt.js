import { spawn } from 'child_process';
import { existsSync, readFileSync } from 'fs';
import { join } from 'path';
import { EmbedBuilder, ActionRowBuilder, ButtonBuilder, ButtonStyle } from 'discord.js';
import { isUserAllowed } from '../config.js';
import { BOT_DIR, COLOR, THREAD_AUTO_ARCHIVE, THREAD_NAME_MAX } from '../constants.js';

const CODEX_TIMEOUT = 60 * 60 * 1000; // 1 hour

function buildGptButtons(threadId) {
  return new ActionRowBuilder().addComponents(
    new ButtonBuilder()
      .setCustomId(`gpt_end:${threadId}`)
      .setLabel('End Session')
      .setEmoji('🔚')
      .setStyle(ButtonStyle.Danger),
  );
}

const GPT_PROJECTS_FILE = join(BOT_DIR, 'gpt-projects.md');

// ── GPT session state (threadId → session) ──

export const activeGptSessions = new Map();

// ── gpt-projects.md parser ──

export function getGptProjects() {
  try {
    const content = readFileSync(GPT_PROJECTS_FILE, 'utf8');
    const projects = {};
    for (const line of content.split('\n')) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#') || trimmed.startsWith('<!--')) continue;
      const colonIdx = trimmed.indexOf(':');
      if (colonIdx === -1) continue;
      const name = trimmed.slice(0, colonIdx).trim();
      const path = trimmed.slice(colonIdx + 1).trim();
      if (name && path) projects[name] = path;
    }
    return projects;
  } catch {
    return {};
  }
}

// ── Claude-assisted prompt rewriter ──
// Uses Claude CLI to improve the user's message before passing it to Codex.

function rewriteWithClaude(userMessage) {
  return new Promise((resolve, reject) => {
    const prompt = [
      'You are an expert AI prompt engineer.',
      'Rewrite the user\'s message so that an AI coding agent (Codex) understands it clearly.',
      '- Make intent explicit and unambiguous',
      '- Break complex requests into numbered steps if needed',
      '- Remove vague language; use precise descriptions',
      '- Output ONLY the rewritten prompt. No preamble, no explanation.',
      '- Keep the same language as the input (Korean → Korean, English → English)',
      '',
      'User message:',
      userMessage,
    ].join('\n');

    const proc = spawn('claude', [
      '-p', prompt,
      '--output-format', 'stream-json',
      '--include-partial-messages',
      '--verbose',
      '--no-session-persistence',
      '--dangerously-skip-permissions',
    ], {
      env: { ...process.env, CLAUDECODE: '', TERM: 'dumb', NO_COLOR: '1' },
      stdio: ['ignore', 'pipe', 'pipe'],
      shell: false,
    });

    let finalResult = '';
    let displayBuffer = '';
    let stderrBuf = '';
    let buffer = '';

    proc.stdout.on('data', chunk => {
      buffer += chunk.toString('utf8');
      const lines = buffer.split('\n');
      buffer = lines.pop();
      for (const line of lines) {
        if (!line.trim()) continue;
        try {
          const event = JSON.parse(line);
          if (event.type === 'assistant' && event.message?.content) {
            for (const block of event.message.content) {
              if (block.type === 'text') displayBuffer = block.text;
            }
          }
          if (event.type === 'result' && event.result) {
            finalResult = typeof event.result === 'string'
              ? event.result
              : (event.result.text || JSON.stringify(event.result));
          }
        } catch {}
      }
    });
    proc.stderr.on('data', d => { if (stderrBuf.length < 5000) stderrBuf += d.toString('utf8'); });

    const timer = setTimeout(() => { proc.kill('SIGKILL'); reject(new Error('Claude rewrite timed out')); }, 60_000);

    proc.on('close', () => {
      clearTimeout(timer);
      const text = (finalResult || displayBuffer).trim();
      if (!text) return reject(new Error(`Claude returned empty response${stderrBuf ? ': ' + stderrBuf.slice(0, 200) : ''}`));
      resolve(text);
    });
    proc.on('error', err => { clearTimeout(timer); reject(err); });
  });
}

// ── Codex executor ──

function runCodex({ prompt, model, cwd, onProgress }) {
  return new Promise((resolve, reject) => {
    const args = ['exec', '--json', '--ephemeral', '--dangerously-bypass-approvals-and-sandbox'];
    if (model) args.push('-m', model);
    args.push('-'); // Prompt is passed via stdin

    const proc = spawn('codex', args, {
      cwd: cwd || process.cwd(),
      env: { ...process.env, NO_COLOR: '1' },
      stdio: ['pipe', 'pipe', 'pipe'],
      shell: true,
    });

    proc.stdin.write(prompt, 'utf8');
    proc.stdin.end();

    let responseText = '';
    let usage = null;
    let stderrBuf = '';
    let buffer = '';

    proc.stdout.on('data', chunk => {
      buffer += chunk.toString('utf8');
      const lines = buffer.split('\n');
      buffer = lines.pop();
      for (const line of lines) {
        if (!line.trim()) continue;
        try {
          const event = JSON.parse(line);

          if (event.type !== 'turn.completed') {
            console.log('[codex-event]', JSON.stringify(event).slice(0, 200));
          }

          if (onProgress) {
            if (event.type === 'turn.started') {
              onProgress('🤖 _Codex reasoning..._');
            } else if (event.type === 'item.created') {
              const t = event.item?.type;
              if (t === 'local_shell_call') onProgress('🔧 _Running shell command..._');
              else if (t === 'function_call') onProgress(`🔧 _Calling tool: ${event.item?.name || ''}_`);
            } else if (event.type === 'item.completed') {
              const t = event.item?.type;
              if (t === 'local_shell_call') {
                const cmd = event.item?.call?.command?.slice(0, 60) || '';
                onProgress(`✅ _Shell done: \`${cmd}\`_`);
              }
            }
          }

          if (event.type === 'item.completed' && event.item?.type === 'agent_message') {
            responseText = event.item.text || '';
          }
          if (event.type === 'turn.completed' && event.usage) {
            usage = event.usage;
          }
        } catch {}
      }
    });
    proc.stderr.on('data', d => { if (stderrBuf.length < 5000) stderrBuf += d.toString('utf8'); });

    const timer = setTimeout(() => { proc.kill('SIGKILL'); reject(new Error('Codex timed out (1 hour)')); }, CODEX_TIMEOUT);

    proc.on('close', code => {
      clearTimeout(timer);
      const text = responseText.trim();
      if (!text) return reject(new Error(`Codex returned no response (exit ${code})${stderrBuf ? '\n' + stderrBuf.slice(0, 300) : ''}`));
      resolve({ text, usage });
    });
    proc.on('error', err => { clearTimeout(timer); reject(err); });
  });
}

function truncate(text, max = 1024) {
  return text.length <= max ? text : text.slice(0, max - 3) + '...';
}

// ── GPT turn runner ──
// Rewrites the user's message with Claude, then runs Codex, then posts the result.

async function runGptTurn({ session, userText, thread }) {
  session.busy = true;
  session.lastActivity = Date.now();

  const startTime = Date.now();
  const elapsed = () => ((Date.now() - startTime) / 1000).toFixed(0);

  let progressMsg = null;
  let lastStatus = '';
  const updateProgress = async (status) => {
    lastStatus = status;
    const text = `${status}\n_Elapsed: ${elapsed()}s_`;
    try {
      if (!progressMsg) {
        progressMsg = await thread.send({ content: text });
      } else {
        await progressMsg.edit({ content: text });
      }
    } catch {}
  };

  // Periodic elapsed time update every 3 seconds
  const ticker = setInterval(async () => {
    if (lastStatus) await updateProgress(lastStatus);
  }, 3000);

  await updateProgress('✏️ _Claude rewriting prompt..._');

  // 1. Claude rewrite
  let rewritten;
  try {
    rewritten = await rewriteWithClaude(userText);
  } catch (e) {
    clearInterval(ticker);
    session.busy = false;
    throw new Error(`Claude rewrite failed: ${e.message}`);
  }

  await updateProgress('⏳ _Starting Codex..._');

  // 2. Codex execution
  let codexResult;
  try {
    codexResult = await runCodex({
      prompt: rewritten,
      model: session.model,
      cwd: session.cwd,
      onProgress: (status) => updateProgress(status),
    });
  } catch (e) {
    clearInterval(ticker);
    session.busy = false;
    throw new Error(`Codex failed: ${e.message}`);
  }

  clearInterval(ticker);

  session.busy = false;
  const elapsedSec = ((Date.now() - startTime) / 1000).toFixed(1);
  const tokenInfo = codexResult.usage
    ? `in: ${codexResult.usage.input_tokens} / out: ${codexResult.usage.output_tokens}`
    : '';

  const summaryEmbed = new EmbedBuilder()
    .setColor(COLOR.SUCCESS)
    .addFields(
      { name: '📝 Original', value: truncate(userText, 512) },
      { name: '✏️ Rewritten by Claude', value: truncate(rewritten, 512) },
    )
    .setFooter({ text: `${session.model} · ${elapsedSec}s${tokenInfo ? ` · ${tokenInfo} tokens` : ''}` })
    .setTimestamp();

  const responseEmbed = new EmbedBuilder()
    .setColor(COLOR.INFO)
    .setTitle(`🤖 ${session.model}`)
    .setDescription(truncate(codexResult.text, 4000));

  // Replace the progress message with the final result
  if (progressMsg) {
    await progressMsg.edit({ content: '', embeds: [summaryEmbed, responseEmbed] }).catch(async () => {
      await thread.send({ embeds: [summaryEmbed, responseEmbed] });
    });
  } else {
    await thread.send({ embeds: [summaryEmbed, responseEmbed] });
  }

  session.turnCount = (session.turnCount || 0) + 1;
}

// ── /gpt command handler ──

export async function handleGpt(interaction) {
  if (!isUserAllowed(interaction.user.id)) {
    return interaction.reply({ content: '❌ Not authorized.', ephemeral: true });
  }

  const projects = getGptProjects();
  const projectNames = Object.keys(projects);

  if (projectNames.length === 0) {
    return interaction.reply({
      content: `❌ No GPT projects registered.\nRegister one with \`node register-gpt-project.js <name> <path>\`.\nFile: \`${GPT_PROJECTS_FILE}\``,
      ephemeral: true,
    });
  }

  const userMessage = interaction.options.getString('message');
  const model = interaction.options.getString('model') || 'gpt-5.4';
  let projectName = interaction.options.getString('project');

  if (!projectName) {
    if (projectNames.length === 1) {
      projectName = projectNames[0];
    } else {
      return interaction.reply({
        content: `❌ Please specify a project with the \`project\` option.\nRegistered projects: **${projectNames.join('**, **')}**`,
        ephemeral: true,
      });
    }
  }

  const cwd = projects[projectName];
  if (!cwd) {
    return interaction.reply({ content: `❌ Project **${projectName}** not found.`, ephemeral: true });
  }
  if (!existsSync(cwd)) {
    return interaction.reply({ content: `❌ Project path does not exist: \`${cwd}\``, ephemeral: true });
  }

  // Reject if another Codex task is already running in this channel
  const existingSession = [...activeGptSessions.values()].find(s => s.channelId === interaction.channelId);
  if (existingSession?.busy) {
    return interaction.reply({ content: '⚠️ Codex is already running in this channel.', ephemeral: true });
  }

  await interaction.deferReply();

  const session = {
    channelId: interaction.channelId,
    projectName,
    cwd,
    model,
    turnCount: 0,
    busy: false,
    lastActivity: Date.now(),
    threadRef: null,
  };

  const starterMsg = await interaction.fetchReply();
  const threadName = `[GPT] ${projectName}`.slice(0, THREAD_NAME_MAX);
  const thread = await starterMsg.startThread({
    name: threadName,
    autoArchiveDuration: THREAD_AUTO_ARCHIVE,
  });
  session.threadRef = thread;
  activeGptSessions.set(thread.id, session);

  await interaction.editReply({
    embeds: [new EmbedBuilder()
      .setColor(COLOR.INFO)
      .setTitle('🤖 GPT Codex Session Started')
      .setDescription(`**Project:** ${projectName}\n**Path:** \`${cwd}\`\n**Model:** ${model}`)
      .setFooter({ text: 'Continue the conversation in the thread' })],
    components: [buildGptButtons(thread.id)],
  });

  try {
    await thread.send({ content: '⏳ _Processing..._' });
    await runGptTurn({ session, userText: userMessage, thread });
  } catch (e) {
    console.error('[gpt] First turn failed:', e.message);
    await thread.send({ content: `❌ ${e.message.slice(0, 300)}` });
  }
}

// ── Thread follow-up message handler ──

export async function handleGptThreadMessage(message, session) {
  if (session.busy) {
    await message.react('⏳').catch(() => {});
    return;
  }

  const userText = message.content.trim();
  if (!userText) return;

  await message.react('🔄').catch(() => {});

  try {
    await runGptTurn({ session, userText, thread: message.channel });
    await message.reactions.removeAll().catch(() => {});
    await message.react('✅').catch(() => {});
  } catch (e) {
    console.error('[gpt] Follow-up turn failed:', e.message);
    await message.reactions.removeAll().catch(() => {});
    await message.react('❌').catch(() => {});
    await message.channel.send({ content: `❌ ${e.message.slice(0, 300)}` });
  }
}

// ── GPT session end (called from button handler) ──

export async function handleGptEnd(interaction, threadId) {
  const session = activeGptSessions.get(threadId);
  if (!session) {
    return interaction.reply({ content: 'Session is already ended.', ephemeral: true });
  }

  // Acknowledge before async work to meet Discord's 3-second deadline
  await interaction.deferUpdate();
  activeGptSessions.delete(threadId);

  if (session.threadRef) {
    try {
      await session.threadRef.send({ content: `🔚 Session ended (${session.turnCount} turns completed)` });
      await session.threadRef.setArchived(true);
    } catch {}
  }

  try {
    await interaction.editReply({ components: [] });
  } catch {}
}

// ── /gpt-project command handler ──

export async function handleGptProject(interaction) {
  if (!isUserAllowed(interaction.user.id)) {
    return interaction.reply({ content: '❌ Not authorized.', ephemeral: true });
  }

  const projects = Object.entries(getGptProjects());
  if (projects.length === 0) {
    return interaction.reply({
      content: `No GPT projects registered.\nRegister one with \`node register-gpt-project.js <name> <path>\`.\nFile: \`${GPT_PROJECTS_FILE}\``,
      ephemeral: true,
    });
  }

  const embed = new EmbedBuilder()
    .setColor(COLOR.INFO)
    .setTitle('📁 GPT Projects')
    .setDescription(projects.map(([name, path]) => `**${name}**\n\`${path}\``).join('\n\n'))
    .setFooter({ text: GPT_PROJECTS_FILE });

  return interaction.reply({ embeds: [embed], ephemeral: true });
}
