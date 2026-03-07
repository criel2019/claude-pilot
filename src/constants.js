import { join } from 'path';
import { fileURLToPath } from 'url';

export const BOT_DIR = join(fileURLToPath(import.meta.url), '..', '..');
export const DEFAULT_PROJECT_NAME = 'default';
export const DEFAULT_PROJECT_CWD = join(BOT_DIR, 'temp');
export const TRACKER_DIR = join(process.env.HOME || process.env.USERPROFILE, '.claude-tracker');
export const CONFIG_FILE = join(TRACKER_DIR, 'config.json');
export const STATE_FILE = join(TRACKER_DIR, 'state.json');
export const TOKEN_HISTORY = join(TRACKER_DIR, 'token-history.jsonl');
export const TRACKER_BIN = join(TRACKER_DIR, 'bin', 'claude-tracker');

export const SESSIONS_DIR = join(TRACKER_DIR, 'bot-sessions');
export const SESSION_RETENTION_DAYS = 10;

// Discord interaction timeout: 14 min (1 min buffer before Discord's 15-min limit)
export const SEND_TIMEOUT = 14 * 60 * 1000;
export const MAX_HISTORY_MESSAGES = 100;

// Embed color palette
export const COLOR = {
  SUCCESS: 0x2ECC71,
  WARNING: 0xF1C40F,
  ERROR:   0xE74C3C,
  TIMEOUT: 0xE67E22,
  INFO:    0x3498DB,
};

// Discord API limits
export const EMBED_MAX_CHARS   = 3800;
export const EMBED_TRIM_CHARS  = 3700;
export const EMBED_FIELD_MAX   = 1024;
export const THREAD_NAME_MAX   = 100;
export const THREAD_AUTO_ARCHIVE = 1440;
export const SELECT_MAX_OPTIONS  = 25;

// Attachment handling
export const TEMP_DIR         = join(TRACKER_DIR, 'tmp');
export const FAILED_PROMPTS_FILE = join(TRACKER_DIR, 'failed-prompts.jsonl');
export const MAX_FAILED_PROMPTS  = 20;
export const IMAGE_EXTENSIONS = ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'];
export const TEXT_EXTENSIONS  = new Set(['txt', 'md', 'json', 'js', 'ts', 'py', 'css', 'html', 'sh', 'yaml', 'yml', 'log']);
export const MAX_IMAGE_SIZE   = 10 * 1024 * 1024; // 10 MB

export const QUEUE_MAX_SIZE = 5;
