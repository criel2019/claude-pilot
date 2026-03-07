import {
  ActionRowBuilder, ButtonBuilder, ButtonStyle,
  StringSelectMenuBuilder,
} from 'discord.js';
import { SELECT_MAX_OPTIONS } from '../constants.js';
import { getConfig } from '../config.js';
import { runTrackerAsync, invalidateStateCache, invalidateNativeScanCache, getAliveState } from '../tracker.js';

export async function handleProject(interaction) {
  await interaction.deferReply({ ephemeral: true });
  await runTrackerAsync('scan');
  invalidateStateCache();
  invalidateNativeScanCache();
  const state = getAliveState();
  const sessions = Object.values(state.sessions || {});
  const activeOrIdle = sessions.filter(s => s.status === 'active' || s.status === 'idle');

  if (activeOrIdle.length === 0) {
    return interaction.editReply({ content: '❌ No active or idle projects found.' });
  }

  const cfg = getConfig();
  const currentDefault = (cfg.channel_defaults || {})[interaction.channelId];

  const sorted = activeOrIdle.sort((a, b) => {
    const order = { active: 0, idle: 1 };
    return (order[a.status] ?? 2) - (order[b.status] ?? 2);
  });

  const content = currentDefault
    ? `Current default project: **${currentDefault}**\nSelect a project to change it:`
    : 'Select the default project for this channel:';

  if (sorted.length <= 5) {
    const row = new ActionRowBuilder();
    for (const s of sorted) {
      const icon = s.status === 'active' ? '\u{1F7E2}' : '\u{1F7E1}';
      row.addComponents(
        new ButtonBuilder()
          .setCustomId(`project_select:${s.project}`.slice(0, 100))
          .setLabel(`${icon} ${s.project}`.slice(0, 80))
          .setStyle(s.project === currentDefault ? ButtonStyle.Success : ButtonStyle.Secondary)
      );
    }
    await interaction.editReply({ content, components: [row] });
  } else {
    const select = new StringSelectMenuBuilder()
      .setCustomId('project_select_menu')
      .setPlaceholder('Select a project')
      .addOptions(sorted.slice(0, SELECT_MAX_OPTIONS).map(s => ({
        label: s.project,
        value: s.project,
        emoji: s.status === 'active' ? '\u{1F7E2}' : '\u{1F7E1}',
        default: s.project === currentDefault,
      })));

    const row = new ActionRowBuilder().addComponents(select);
    await interaction.editReply({ content, components: [row] });
  }
}
