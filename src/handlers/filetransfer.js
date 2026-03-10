import { AttachmentBuilder } from 'discord.js';
import { existsSync, statSync } from 'fs';
import { resolve, basename } from 'path';
import { isUserAllowed } from '../config.js';
import { MAX_UPLOAD_SIZE, RECEIVED_DIR } from '../constants.js';
import { downloadAnyAttachment } from '../files.js';

function formatSize(bytes) {
  if (bytes >= 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)}MB`;
  return `${(bytes / 1024).toFixed(0)}KB`;
}

// /file path:<path> — PC에서 Discord로 파일 업로드
export async function handleFile(interaction) {
  if (!isUserAllowed(interaction.user.id)) {
    return interaction.reply({ content: '❌ Not authorized.', ephemeral: true });
  }

  const rawPath = interaction.options.getString('path').replace(/^["']|["']$/g, '');
  const absPath = resolve(rawPath);

  if (!existsSync(absPath)) {
    return interaction.reply({ content: `❌ File not found: \`${absPath}\``, ephemeral: true });
  }

  const stat = statSync(absPath);
  if (!stat.isFile()) {
    return interaction.reply({ content: `❌ Not a file: \`${absPath}\``, ephemeral: true });
  }

  if (stat.size > MAX_UPLOAD_SIZE) {
    return interaction.reply({
      content: `❌ File too large (${formatSize(stat.size)}, limit: 24MB): \`${basename(absPath)}\``,
      ephemeral: true,
    });
  }

  await interaction.deferReply();
  try {
    const attachment = new AttachmentBuilder(absPath);
    await interaction.editReply({
      content: `📤 \`${absPath}\` (${formatSize(stat.size)})`,
      files: [attachment],
    });
  } catch (e) {
    await interaction.editReply({ content: `❌ Upload failed: ${e.message.slice(0, 200)}` });
  }
}

// /receive file:<attachment> — Discord에서 PC로 파일 저장
export async function handleReceive(interaction) {
  if (!isUserAllowed(interaction.user.id)) {
    return interaction.reply({ content: '❌ Not authorized.', ephemeral: true });
  }

  const attachment = interaction.options.getAttachment('file');
  const subfolder = interaction.options.getString('folder') || '';
  const destDir = subfolder
    ? resolve(RECEIVED_DIR, subfolder.replace(/[\\/:*?"<>|]/g, '_'))
    : RECEIVED_DIR;

  await interaction.deferReply();
  try {
    const savedPath = await downloadAnyAttachment(attachment, destDir);
    await interaction.editReply({
      content: `📥 Saved to PC:\n\`${savedPath}\`\n(${formatSize(attachment.size)})`,
    });
  } catch (e) {
    await interaction.editReply({ content: `❌ Failed to save: ${e.message.slice(0, 200)}` });
  }
}
