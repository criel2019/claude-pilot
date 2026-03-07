import { writeFileSync, mkdirSync, unlinkSync } from 'fs';
import { join } from 'path';
import { randomUUID } from 'crypto';
import {
  IMAGE_EXTENSIONS, MAX_IMAGE_SIZE, TEMP_DIR,
  EMBED_MAX_CHARS, EMBED_TRIM_CHARS,
} from './constants.js';

export function isImageFile(filename) {
  if (!filename) return false;
  const dot = filename.lastIndexOf('.');
  if (dot === -1) return false;
  return IMAGE_EXTENSIONS.includes(filename.slice(dot).toLowerCase());
}

export async function downloadAttachment(attachment) {
  if (attachment.size > MAX_IMAGE_SIZE) {
    throw new Error(`File too large (${(attachment.size / 1024 / 1024).toFixed(1)}MB > ${MAX_IMAGE_SIZE / 1024 / 1024}MB)`);
  }
  mkdirSync(TEMP_DIR, { recursive: true });
  const dot = attachment.name.lastIndexOf('.');
  const ext = dot !== -1 ? attachment.name.slice(dot) : '.bin';
  const filePath = join(TEMP_DIR, `${Date.now()}-${randomUUID().slice(0, 8)}${ext}`);
  const res = await fetch(attachment.proxyURL || attachment.url);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  writeFileSync(filePath, Buffer.from(await res.arrayBuffer()));
  return filePath;
}

export function cleanupTempFile(filePath) {
  if (filePath) try { unlinkSync(filePath); } catch {}
}

export function cleanupTempFiles(paths) {
  for (const p of paths) cleanupTempFile(p);
}

// Trims embed text to fit within Discord's character limit
export function trimEmbedText(text, fallback = '_(empty response)_') {
  if (!text) return fallback;
  return text.length > EMBED_MAX_CHARS ? '…' + text.slice(-EMBED_TRIM_CHARS) : text;
}

// Fetches the content of a text file attachment
export async function fetchTextFile(attachment) {
  const res = await fetch(attachment.proxyURL || attachment.url);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.text();
}

export async function prepareImageAttachments(attachments) {
  const paths = [];
  for (const att of attachments) {
    try {
      paths.push(await downloadAttachment(att));
    } catch (e) {
      console.warn('[image] Download failed:', e.message);
    }
  }
  return paths;
}

export function buildImagePrompt(baseText, imagePaths, overrideDisplayText) {
  if (imagePaths.length === 0) return { promptText: baseText, displayText: overrideDisplayText };
  const refs = imagePaths.map((p, i) => `${i + 1}. ${p}`).join('\n');
  const prefix = baseText ? baseText + '\n\n' : '';
  const displayBase = overrideDisplayText ?? (baseText || '');
  return {
    promptText: prefix + `[The user attached ${imagePaths.length} image(s). Read each file at the following path(s):\n${refs}]`,
    displayText: (displayBase ? displayBase + '\n' : '') + `📎 _${imagePaths.length} image(s) attached_`,
  };
}
