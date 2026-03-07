import {
  EmbedBuilder, ActionRowBuilder, ButtonBuilder, ButtonStyle,
} from 'discord.js';
import { COLOR, EMBED_FIELD_MAX } from './constants.js';
import { trimEmbedText } from './files.js';

export function buildProgressEmbed(session, content, elapsed) {
  return new EmbedBuilder()
    .setTitle(`⏳ ${session.projectName}`)
    .setColor(COLOR.WARNING)
    .setDescription(content)
    .setFooter({ text: `${session.model} · ${elapsed}s · turn ${session.turnCount + 1}` });
}

export function buildResultEmbed(session, result) {
  const display = trimEmbedText(result.displayText);

  const color = result.timedOut ? COLOR.TIMEOUT
    : result.exitCode === 0 ? COLOR.SUCCESS
    : COLOR.ERROR;

  const embed = new EmbedBuilder()
    .setTitle(`${result.timedOut ? '⚠️' : '📨'} ${session.projectName}`)
    .setColor(color)
    .setDescription(display)
    .setTimestamp();

  const stats = session.tokenStats;
  if (stats) {
    if (stats.warningLevel === 'caution') {
      embed.addFields({ name: '🟡 Context Notice', value: `History is ${(stats.totalHistoryChars / 1000).toFixed(0)}K chars — growing`, inline: false });
    } else if (stats.warningLevel === 'warning') {
      embed.addFields({ name: '🟠 Context Warning', value: `History is ${(stats.totalHistoryChars / 1000).toFixed(0)}K chars — response quality may degrade. **Consider starting a new session.**`, inline: false });
    } else if (stats.warningLevel === 'critical') {
      embed.addFields({ name: '🔴 Context Critical', value: `History is ${(stats.totalHistoryChars / 1000).toFixed(0)}K chars — context pollution risk!\n**Strongly recommended to clear history.**`, inline: false });
    }
  }

  const footerParts = [`${session.model} · ${result.elapsed}s · turn ${session.turnCount}`];
  if (stats) footerParts.push(`📝 ${(stats.totalHistoryChars / 1000).toFixed(0)}K chars`);
  if (result.costData?.costUsd != null) {
    footerParts.push(`💰 $${result.costData.costUsd.toFixed(4)}`);
  }
  if (result.costData?.inputTokens != null) {
    footerParts.push(`🔤 in:${result.costData.inputTokens.toLocaleString()} out:${(result.costData.outputTokens ?? 0).toLocaleString()}`);
  }
  embed.setFooter({ text: footerParts.join(' · ') });

  return embed;
}

export function buildErrorEmbed(session, errorMessage) {
  return new EmbedBuilder()
    .setTitle(`❌ ${session.projectName}`)
    .setColor(COLOR.ERROR)
    .setDescription(`Error: ${errorMessage.slice(0, 500)}`)
    .setTimestamp();
}

// Per-turn history embed posted to the session thread
export function buildTurnHistoryEmbed(session, userText, result) {
  const footerParts = [`${session.model} · ${result.elapsed}s`];
  if (result.costData?.costUsd != null) footerParts.push(`💰 $${result.costData.costUsd.toFixed(4)}`);
  if (result.costData?.inputTokens != null) {
    footerParts.push(`🔤 in:${result.costData.inputTokens.toLocaleString()} out:${(result.costData.outputTokens ?? 0).toLocaleString()}`);
  }

  return new EmbedBuilder()
    .setTitle(`Turn ${session.turnCount}`)
    .setColor(result.exitCode === 0 ? COLOR.SUCCESS : COLOR.ERROR)
    .addFields({ name: '💬 Request', value: userText.slice(0, EMBED_FIELD_MAX), inline: false })
    .setDescription(trimEmbedText(result.displayText))
    .setFooter({ text: footerParts.join(' · ') })
    .setTimestamp();
}

export function buildProgressButtons(channelId) {
  return new ActionRowBuilder().addComponents(
    new ButtonBuilder()
      .setCustomId(`session_cancel:${channelId}`)
      .setLabel('⏹ Cancel')
      .setStyle(ButtonStyle.Danger),
  );
}

export function buildSessionButtons(channelId) {
  return new ActionRowBuilder().addComponents(
    new ButtonBuilder()
      .setCustomId(`session_cleanup:${channelId}`)
      .setLabel('🆕 New Session')
      .setStyle(ButtonStyle.Secondary),
    new ButtonBuilder()
      .setCustomId(`session_reset_history:${channelId}`)
      .setLabel('🗑 Clear History')
      .setStyle(ButtonStyle.Secondary),
    new ButtonBuilder()
      .setCustomId(`session_end:${channelId}`)
      .setLabel('🔚 End Session')
      .setStyle(ButtonStyle.Danger),
  );
}

export function buildRetryButton(channelId) {
  return new ActionRowBuilder().addComponents(
    new ButtonBuilder()
      .setCustomId(`session_retry:${channelId}`)
      .setLabel('🔁 Retry')
      .setStyle(ButtonStyle.Primary),
  );
}
