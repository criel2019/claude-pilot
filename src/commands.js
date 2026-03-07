import { SlashCommandBuilder } from 'discord.js';

export const commands = [
  new SlashCommandBuilder()
    .setName('status')
    .setDescription('Show Claude process status'),

  new SlashCommandBuilder()
    .setName('snapshot')
    .setDescription('Record a token snapshot now'),

  new SlashCommandBuilder()
    .setName('report')
    .setDescription('Token usage report')
    .addStringOption(o => o.setName('period').setDescription('Time period').addChoices(
      { name: 'Today',       value: 'today' },
      { name: 'Last 7 days', value: 'week'  },
      { name: 'All time',    value: 'all'   },
    )),

  new SlashCommandBuilder()
    .setName('dashboard')
    .setDescription('Post a live-updating dashboard embed'),

  new SlashCommandBuilder()
    .setName('send')
    .setDescription('Send a message to a Claude session')
    .addStringOption(o => o.setName('message').setDescription('Message to send (optional if file attached)').setRequired(false))
    .addStringOption(o => o.setName('project').setDescription('Project name').setAutocomplete(true))
    .addStringOption(o => o.setName('model').setDescription('Model to use').addChoices(
      { name: 'Opus (default, powerful)', value: 'opus'   },
      { name: 'Sonnet (fast)',            value: 'sonnet' },
      { name: 'Haiku (lightweight)',      value: 'haiku'  },
    ))
    .addAttachmentOption(o => o.setName('file').setDescription('Text file (.txt/.md) — for content over 4000 chars').setRequired(false))
    .addAttachmentOption(o => o.setName('image').setDescription('Image attachment').setRequired(false))
    .addAttachmentOption(o => o.setName('image2').setDescription('Image attachment 2').setRequired(false))
    .addAttachmentOption(o => o.setName('image3').setDescription('Image attachment 3').setRequired(false)),

  new SlashCommandBuilder()
    .setName('project')
    .setDescription("Set this channel's default project"),

  new SlashCommandBuilder()
    .setName('compact')
    .setDescription('Compress the current session context with a summary'),

  new SlashCommandBuilder()
    .setName('model')
    .setDescription('Change the model for this session')
    .addStringOption(o => o.setName('model').setDescription('Model to use').setRequired(true).addChoices(
      { name: 'Opus (powerful)', value: 'opus'   },
      { name: 'Sonnet (fast)',   value: 'sonnet' },
      { name: 'Haiku (lightweight)', value: 'haiku' },
    )),

  new SlashCommandBuilder()
    .setName('end')
    .setDescription('End the current Claude session in this channel'),

  new SlashCommandBuilder()
    .setName('session')
    .setDescription('Show current session info'),

  new SlashCommandBuilder()
    .setName('sessions')
    .setDescription('List saved sessions / reload one'),

  new SlashCommandBuilder()
    .setName('gpt')
    .setDescription('Start a GPT Codex session (requires codex CLI)')
    .addStringOption(o => o.setName('message').setDescription('First message').setRequired(true))
    .addStringOption(o => o.setName('project').setDescription('Project name').setAutocomplete(true))
    .addStringOption(o => o.setName('model').setDescription('GPT model').addChoices(
      { name: 'GPT-5.4 (default)', value: 'gpt-5.4'          },
      { name: 'GPT-5.3 Instant',   value: 'gpt-5.3-instant'  },
      { name: 'GPT-5.2',           value: 'gpt-5.2'          },
      { name: 'GPT-4o (legacy)',    value: 'gpt-4o'           },
    )),

  new SlashCommandBuilder()
    .setName('gpt-project')
    .setDescription('List registered GPT Codex projects'),
];
