import { spawn, execSync } from 'child_process';
import { existsSync, readFileSync } from 'fs';
import { join } from 'path';
import { EmbedBuilder, ActionRowBuilder, ButtonBuilder, ButtonStyle } from 'discord.js';
import { isUserAllowed } from '../config.js';
import { BOT_DIR, COLOR, THREAD_AUTO_ARCHIVE, THREAD_NAME_MAX } from '../constants.js';

const CODEX_TIMEOUT = 60 * 60 * 1000;
const CLAUDE_REWRITE_TIMEOUT = 5 * 60_000;
const GPT_PROJECTS_FILE = join(BOT_DIR, 'gpt-projects.md');

function resolveClaudeBin() {
  const cliRelative = join('node_modules', '@anthropic-ai', 'claude-code', 'cli.js');
  try {
    const prefix = execSync('npm root -g', { encoding: 'utf8' }).trim();
    const cliJs = join(prefix, '@anthropic-ai', 'claude-code', 'cli.js');
    if (existsSync(cliJs)) return { cmd: process.execPath, prefix: [cliJs] };
  } catch {}
  if (process.env.APPDATA) {
    const cliJs = join(process.env.APPDATA, 'npm', cliRelative);
    if (existsSync(cliJs)) return { cmd: process.execPath, prefix: [cliJs] };
  }
  return { cmd: 'claude', prefix: [], shell: true };
}

const CLAUDE_BIN = resolveClaudeBin();

function buildGptButtons(threadId) {
  return new ActionRowBuilder().addComponents(
    new ButtonBuilder()
      .setCustomId(`gpt_end:${threadId}`)
      .setLabel('End Session')
      .setStyle(ButtonStyle.Danger),
  );
}

export const activeGptSessions = new Map();

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

function rewriteWithClaude(userMessage) {
  return new Promise((resolve, reject) => {
    const prompt = [
      'You are an expert AI prompt engineer.',
      'Rewrite the user request so Codex can execute it clearly.',
      '- Keep the same language as the user message.',
      '- Preserve intent exactly.',
      '- Remove ambiguity and vague wording.',
      '- Use numbered steps when the request contains multiple tasks.',
      '- Output only the rewritten prompt.',
      '',
      'User request:',
      userMessage,
    ].join('\n');

    const proc = spawn(CLAUDE_BIN.cmd, [
      ...CLAUDE_BIN.prefix,
      '-p', prompt,
      '--output-format', 'stream-json',
      '--include-partial-messages',
      '--verbose',
      '--no-session-persistence',
      '--dangerously-skip-permissions',
    ], {
      env: { ...process.env, CLAUDECODE: '', TERM: 'dumb', NO_COLOR: '1' },
      stdio: ['ignore', 'pipe', 'pipe'],
      shell: CLAUDE_BIN.shell || false,
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

    proc.stderr.on('data', chunk => {
      if (stderrBuf.length < 5000) stderrBuf += chunk.toString('utf8');
    });

    const timer = setTimeout(() => {
      proc.kill('SIGKILL');
      reject(new Error('Claude rewrite timed out'));
    }, CLAUDE_REWRITE_TIMEOUT);

    proc.on('close', () => {
      clearTimeout(timer);
      const text = (finalResult || displayBuffer).trim();
      if (!text) {
        reject(new Error(`Claude returned empty response${stderrBuf ? `: ${stderrBuf.slice(0, 200)}` : ''}`));
        return;
      }
      resolve(text);
    });

    proc.on('error', err => {
      clearTimeout(timer);
      reject(err);
    });
  });
}

function buildDirectCodexPrompt(userMessage) {
  return [
    'You are Codex, a coding agent working directly from the user request.',
    'Complete the task without relying on an external prompt rewriter.',
    'If anything is ambiguous, make the smallest reasonable assumption and state it briefly.',
    'Prefer concrete edits, commands, and verification over abstract discussion.',
    '',
    'User request:',
    userMessage,
  ].join('\n');
}

async function prepareCodexPrompt(userText, updateProgress) {
  await updateProgress('Preparing prompt...');

  try {
    const rewritten = await rewriteWithClaude(userText);
    return {
      prompt: rewritten,
      rewritten,
      promptNote: 'Prompt rewritten by Claude before running Codex.',
    };
  } catch (e) {
    console.warn('[gpt] Claude rewrite failed, using direct prompt:', e.message);
    await updateProgress('Claude rewrite failed. Falling back to a direct Codex prompt...');
    return {
      prompt: buildDirectCodexPrompt(userText),
      rewritten: null,
      promptNote: `Claude rewrite failed, so Codex ran from the original request. Reason: ${e.message}`,
    };
  }
}

function runCodex({ prompt, model, cwd, onProgress }) {
  return new Promise((resolve, reject) => {
    const args = ['exec', '--json', '--ephemeral', '--dangerously-bypass-approvals-and-sandbox'];
    if (model) args.push('-m', model);
    args.push('-');

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
              onProgress('Codex reasoning...');
            } else if (event.type === 'item.created') {
              const itemType = event.item?.type;
              if (itemType === 'local_shell_call') onProgress('Running shell command...');
              else if (itemType === 'function_call') onProgress(`Calling tool: ${event.item?.name || ''}`);
            } else if (event.type === 'item.completed' && event.item?.type === 'local_shell_call') {
              const cmd = event.item?.call?.command?.slice(0, 60) || '';
              onProgress(`Shell done: \`${cmd}\``);
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

    proc.stderr.on('data', chunk => {
      if (stderrBuf.length < 5000) stderrBuf += chunk.toString('utf8');
    });

    const timer = setTimeout(() => {
      proc.kill('SIGKILL');
      reject(new Error('Codex timed out (1 hour)'));
    }, CODEX_TIMEOUT);

    proc.on('close', code => {
      clearTimeout(timer);
      const text = responseText.trim();
      if (!text) {
        reject(new Error(`Codex returned no response (exit ${code})${stderrBuf ? `\n${stderrBuf.slice(0, 300)}` : ''}`));
        return;
      }
      resolve({ text, usage });
    });

    proc.on('error', err => {
      clearTimeout(timer);
      reject(err);
    });
  });
}

function truncate(text, max = 1024) {
  return text.length <= max ? text : `${text.slice(0, max - 3)}...`;
}

async function runGptTurn({ session, userText, thread }) {
  session.busy = true;
  session.lastActivity = Date.now();

  const startTime = Date.now();
  const elapsed = () => ((Date.now() - startTime) / 1000).toFixed(0);

  let progressMsg = null;
  let lastStatus = '';
  const updateProgress = async (status) => {
    lastStatus = status;
    const content = `${status}\n_Elapsed: ${elapsed()}s_`;
    try {
      if (!progressMsg) {
        progressMsg = await thread.send({ content });
      } else {
        await progressMsg.edit({ content });
      }
    } catch {}
  };

  const ticker = setInterval(async () => {
    if (lastStatus) await updateProgress(lastStatus);
  }, 3000);

  try {
    const promptInfo = await prepareCodexPrompt(userText, updateProgress);
    await updateProgress('Starting Codex...');

    const codexResult = await runCodex({
      prompt: promptInfo.prompt,
      model: session.model,
      cwd: session.cwd,
      onProgress: status => updateProgress(status),
    });

    const elapsedSec = ((Date.now() - startTime) / 1000).toFixed(1);
    const tokenInfo = codexResult.usage
      ? `in: ${codexResult.usage.input_tokens} / out: ${codexResult.usage.output_tokens}`
      : '';

    const summaryFields = [{ name: 'Original', value: truncate(userText, 512) }];
    if (promptInfo.rewritten) {
      summaryFields.push({ name: 'Rewritten by Claude', value: truncate(promptInfo.rewritten, 512) });
    } else {
      summaryFields.push({ name: 'Prompt path', value: truncate(promptInfo.promptNote, 512) });
    }

    const summaryEmbed = new EmbedBuilder()
      .setColor(COLOR.SUCCESS)
      .addFields(summaryFields)
      .setFooter({ text: `${session.model} | ${elapsedSec}s${tokenInfo ? ` | ${tokenInfo} tokens` : ''}` })
      .setTimestamp();

    const responseEmbed = new EmbedBuilder()
      .setColor(COLOR.INFO)
      .setTitle(session.model)
      .setDescription(truncate(codexResult.text, 4000));

    if (progressMsg) {
      await progressMsg.edit({ content: '', embeds: [summaryEmbed, responseEmbed] }).catch(async () => {
        await thread.send({ embeds: [summaryEmbed, responseEmbed] });
      });
    } else {
      await thread.send({ embeds: [summaryEmbed, responseEmbed] });
    }

    session.turnCount = (session.turnCount || 0) + 1;
    session.lastActivity = Date.now();
  } catch (e) {
    throw new Error(`Codex failed: ${e.message}`);
  } finally {
    clearInterval(ticker);
    session.busy = false;
  }
}

export async function handleGpt(interaction) {
  if (!isUserAllowed(interaction.user.id)) {
    return interaction.reply({ content: 'Not authorized.', ephemeral: true });
  }

  const projects = getGptProjects();
  const projectNames = Object.keys(projects);
  if (projectNames.length === 0) {
    return interaction.reply({
      content: `No GPT projects registered.\nRegister one with \`node register-gpt-project.js <name> <path>\`.\nFile: \`${GPT_PROJECTS_FILE}\``,
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
        content: `Please specify a project with the \`project\` option.\nRegistered projects: **${projectNames.join('**, **')}**`,
        ephemeral: true,
      });
    }
  }

  const cwd = projects[projectName];
  if (!cwd) {
    return interaction.reply({ content: `Project **${projectName}** not found.`, ephemeral: true });
  }
  if (!existsSync(cwd)) {
    return interaction.reply({ content: `Project path does not exist: \`${cwd}\``, ephemeral: true });
  }

  const existingSession = [...activeGptSessions.values()].find(s => s.channelId === interaction.channelId);
  if (existingSession?.busy) {
    return interaction.reply({ content: 'Codex is already running in this channel.', ephemeral: true });
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
    threadId: null,
    threadRef: null,
  };

  const starterMsg = await interaction.fetchReply();
  const threadName = `[GPT] ${projectName}`.slice(0, THREAD_NAME_MAX);
  const thread = await starterMsg.startThread({
    name: threadName,
    autoArchiveDuration: THREAD_AUTO_ARCHIVE,
  });
  session.threadId = thread.id;
  session.threadRef = thread;
  activeGptSessions.set(thread.id, session);

  await interaction.editReply({
    embeds: [new EmbedBuilder()
      .setColor(COLOR.INFO)
      .setTitle('GPT Codex Session Started')
      .setDescription(`**Project:** ${projectName}\n**Path:** \`${cwd}\`\n**Model:** ${model}`)
      .setFooter({ text: 'Continue the conversation in the thread' })],
    components: [buildGptButtons(thread.id)],
  });

  try {
    await runGptTurn({ session, userText: userMessage, thread });
  } catch (e) {
    console.error('[gpt] First turn failed:', e.message);
    await thread.send({ content: e.message.slice(0, 300) });
  }
}

export async function handleGptThreadMessage(message, session) {
  if (session.busy) {
    await message.react('\u23F3').catch(() => {});
    return;
  }

  const userText = message.content.trim();
  if (!userText) return;

  await message.react('\u{1F6E0}').catch(() => {});

  try {
    await runGptTurn({ session, userText, thread: message.channel });
    await message.reactions.removeAll().catch(() => {});
    await message.react('\u2705').catch(() => {});
  } catch (e) {
    console.error('[gpt] Follow-up turn failed:', e.message);
    await message.reactions.removeAll().catch(() => {});
    await message.react('\u274C').catch(() => {});
    await message.channel.send({ content: e.message.slice(0, 300) });
  }
}

export async function handleGptEnd(interaction, threadId) {
  const session = activeGptSessions.get(threadId);
  if (!session) {
    return interaction.reply({ content: 'Session is already ended.', ephemeral: true });
  }

  await interaction.deferUpdate();
  activeGptSessions.delete(threadId);

  if (session.threadRef) {
    try {
      await session.threadRef.send({ content: `Session ended (${session.turnCount} turns completed)` });
      await session.threadRef.setArchived(true);
    } catch {}
  }

  try {
    await interaction.editReply({ components: [] });
  } catch {}
}

export async function handleGptProject(interaction) {
  if (!isUserAllowed(interaction.user.id)) {
    return interaction.reply({ content: 'Not authorized.', ephemeral: true });
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
    .setTitle('GPT Projects')
    .setDescription(projects.map(([name, path]) => `**${name}**\n\`${path}\``).join('\n\n'))
    .setFooter({ text: GPT_PROJECTS_FILE });

  return interaction.reply({ embeds: [embed], ephemeral: true });
}
