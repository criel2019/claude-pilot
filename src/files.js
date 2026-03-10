import { writeFileSync, mkdirSync, unlinkSync, existsSync } from 'fs';
import { join } from 'path';
import { randomUUID } from 'crypto';
import {
  IMAGE_EXTENSIONS, MAX_IMAGE_SIZE, MAX_UPLOAD_SIZE, TEMP_DIR,
  EMBED_MAX_CHARS, EMBED_TRIM_CHARS,
} from './constants.js';

// ─── Natural-language destination parsing ────────────────────────────────────

const USERPROFILE = (process.env.USERPROFILE || process.env.HOME || '').replace(/\\/g, '/');

const DIR_ALIASES = [
  { patterns: ['다운로드', 'download'], dirName: 'Downloads' },
  { patterns: ['바탕화면', '데스크탑', 'desktop'], dirName: 'Desktop' },
  { patterns: ['문서', 'document'], dirName: 'Documents' },
  { patterns: ['사진', 'picture', 'photo'], dirName: 'Pictures' },
  { patterns: ['음악', 'music'], dirName: 'Music' },
  { patterns: ['동영상', '비디오', 'video'], dirName: 'Videos' },
];

/**
 * Parse a destination directory from natural-language text.
 * Returns an absolute path string (forward slashes) or null.
 */
export function parseDestDir(text) {
  if (!text) return null;
  const lower = text.toLowerCase();

  // Explicit drive path (e.g. "E:/projects/foo", "C:\Users\User\Desktop")
  const pathMatch = text.match(/[A-Za-z]:[\\/][^\s"'<>|?*\n]*/);
  if (pathMatch) {
    return pathMatch[0].replace(/\\/g, '/').replace(/\/+$/, '');
  }

  // Named system-folder aliases
  if (USERPROFILE) {
    for (const { patterns, dirName } of DIR_ALIASES) {
      if (patterns.some(p => lower.includes(p))) {
        return join(USERPROFILE, dirName).replace(/\\/g, '/');
      }
    }
  }

  return null;
}

/**
 * Returns true when the text is *only* a save/move command with no extra task
 * (e.g. "바탕화면에 저장해줘", "download folder please", "E:/foo/ 에 넣어").
 */
export function isPureSaveText(text) {
  if (!text) return true;
  const stripped = text
    .replace(/다운로드|바탕화면|데스크탑|문서 폴더|문서|사진 폴더|사진|음악 폴더|음악|동영상 폴더|동영상|비디오/g, '')
    .replace(/저장|넣어|옮겨|이동|받아|해줘|해줘요|해주세요|부탁|폴더에|폴더로|에다가|에다|에|로|줘|해/g, '')
    .replace(/save|put|move|store|copy|please|here|folder|directory|to|in|into/gi, '')
    .replace(/[A-Za-z]:[\\/][^\s]*/g, '')   // strip explicit paths
    .replace(/\s+/g, ' ')
    .trim();
  return stripped.length < 5;
}

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

// Downloads any file attachment to destDir, deduplicating filenames
export async function downloadAnyAttachment(attachment, destDir) {
  if (attachment.size > MAX_UPLOAD_SIZE) {
    throw new Error(`File too large (${(attachment.size / 1024 / 1024).toFixed(1)}MB > 24MB)`);
  }
  mkdirSync(destDir, { recursive: true });
  const safeName = attachment.name.replace(/[\\/:*?"<>|]/g, '_');
  const dot = safeName.lastIndexOf('.');
  const base = dot !== -1 ? safeName.slice(0, dot) : safeName;
  const ext = dot !== -1 ? safeName.slice(dot) : '';
  let filePath = join(destDir, safeName);
  let counter = 1;
  while (existsSync(filePath)) {
    filePath = join(destDir, `${base} (${counter})${ext}`);
    counter++;
  }
  const res = await fetch(attachment.proxyURL || attachment.url);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  writeFileSync(filePath, Buffer.from(await res.arrayBuffer()));
  return filePath;
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
