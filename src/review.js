// ── Auto Code Review Session Separation ──
// Runs git diff → extracts changed functions → greps callers → assembles review prompt
// Executes in a fresh Sonnet session for minimal token cost

import { execSync } from 'child_process';
import { existsSync } from 'fs';
import { join, normalize } from 'path';
import { EmbedBuilder, ActionRowBuilder, ButtonBuilder, ButtonStyle } from 'discord.js';
import { COLOR } from './constants.js';
import { getConfig } from './config.js';

// ── Diff & dependency extraction ──

function runGit(cmd, cwd) {
  try {
    return execSync(`git ${cmd}`, { cwd, encoding: 'utf8', timeout: 10000 }).trim();
  } catch { return ''; }
}

function isGitRepo(cwd) {
  return existsSync(join(cwd, '.git'));
}

/**
 * session.messageHistory를 스캔해서 Claude가 마지막으로 작업한 known_project의 cwd를 반환.
 * 못 찾으면 session.cwd를 그대로 반환.
 */
function inferCwdFromSession(session) {
  const projects = getConfig().known_projects || {};
  const history = session.messageHistory || [];

  // 최신 메시지부터 역순으로 스캔
  for (let i = history.length - 1; i >= 0; i--) {
    const { content } = history[i];
    if (!content) continue;
    // known_projects의 경로나 이름이 메시지에 포함되어 있으면 그 프로젝트 선택
    for (const [name, path] of Object.entries(projects)) {
      const normalizedPath = normalize(path).replace(/\\/g, '/').toLowerCase();
      const contentLower = content.replace(/\\/g, '/').toLowerCase();
      if (contentLower.includes(normalizedPath) || contentLower.includes(`/${name}/`) || contentLower.includes(`\\${name}\\`)) {
        if (existsSync(path)) return path;
      }
    }
  }

  return session.cwd;
}

/**
 * session.modifiedFiles(절대경로 Set)에서 cwd 기준 상대경로 배열 반환.
 */
function getSessionFiles(session, cwd) {
  if (!session.modifiedFiles?.size) return [];
  const cwdNorm = normalize(cwd).replace(/\\/g, '/');
  return [...session.modifiedFiles]
    .map(fp => {
      const n = normalize(fp).replace(/\\/g, '/');
      return n.startsWith(cwdNorm + '/') ? n.slice(cwdNorm.length + 1) : null;
    })
    .filter(Boolean);
}

function getLatestDiff(cwd, files) {
  // 세션에서 수정한 특정 파일들만 대상으로
  const fileArgs = files && files.length > 0 ? `-- ${files.map(f => `"${f}"`).join(' ')}` : '';

  let diff = runGit(`diff --cached --unified=5 ${fileArgs}`, cwd);
  if (diff) return { diff, source: 'staged' };
  diff = runGit(`diff --unified=5 ${fileArgs}`, cwd);
  if (diff) return { diff, source: 'unstaged' };
  diff = runGit(`diff HEAD~1 --unified=5 ${fileArgs}`, cwd);
  if (diff) return { diff, source: 'commit' };
  return { diff: '', source: null };
}

function getCommitInfo(cwd) {
  const hash = runGit('log -1 --format=%h', cwd);
  const msg = runGit('log -1 --format=%s', cwd);
  return { hash, msg };
}

function extractChangedFunctions(diff) {
  const functions = new Set();
  // Match function/method names from @@ hunk headers and diff content
  const patterns = [
    /^@@.*@@\s*(?:function\s+)?(\w+)\s*\(/gm,         // @@ ... @@ functionName(
    /^\+\s*(?:export\s+)?(?:async\s+)?function\s+(\w+)/gm, // +function foo
    /^\+\s*(?:export\s+)?(?:const|let|var)\s+(\w+)\s*=/gm,  // +const foo =
    /^\+\s*(\w+)\s*\([^)]*\)\s*\{/gm,                  // +foo() {
  ];
  for (const pat of patterns) {
    let m;
    while ((m = pat.exec(diff)) !== null) {
      if (m[1] && m[1].length > 2 && !['if', 'for', 'while', 'switch', 'return', 'const', 'let', 'var'].includes(m[1])) {
        functions.add(m[1]);
      }
    }
  }
  return [...functions];
}

function extractChangedFiles(diff) {
  const files = new Set();
  const re = /^diff --git a\/(.+?) b\//gm;
  let m;
  while ((m = re.exec(diff)) !== null) files.add(m[1]);
  return [...files];
}

function grepCallers(cwd, functionNames, changedFiles) {
  const callers = [];
  for (const fn of functionNames.slice(0, 10)) { // Limit to 10 functions
    try {
      const result = execSync(
        `git grep -n "${fn}(" -- "*.js" "*.ts" "*.jsx" "*.tsx" "*.css"`,
        { cwd, encoding: 'utf8', timeout: 5000 }
      ).trim();
      if (result) {
        const lines = result.split('\n')
          .filter(l => !changedFiles.some(f => l.startsWith(f + ':'))) // Exclude the changed file itself
          .slice(0, 5); // Max 5 callers per function
        if (lines.length > 0) {
          callers.push({ function: fn, refs: lines });
        }
      }
    } catch {} // grep returns non-zero if no match
  }
  return callers;
}

// ── Review perspective classification ──

function classifyReviewPerspective(files, commitMsg) {
  const allFiles = files.join(' ');
  const msg = (commitMsg || '').toLowerCase();

  if (files.some(f => f.endsWith('.css'))) {
    return { perspective: 'CSS/레이아웃', focus: '반응형 깨짐, 중복 속성, z-index 충돌, 미디어쿼리 누락' };
  }
  if (files.some(f => f.includes('games/'))) {
    return { perspective: '게임 로직', focus: '런타임 에러, 엣지케이스, 멀티플레이어 동기화, 상태 불일치' };
  }
  if (msg.match(/분리|모듈|리팩/)) {
    return { perspective: '리팩토링', focus: '임포트 누락, 기존 호출부 깨짐, 변수 스코프 변경' };
  }
  if (msg.match(/추가|새로|만들/)) {
    return { perspective: '신규 기능', focus: '기존 코드 충돌, 네이밍 일관성, 초기화 누락' };
  }
  return { perspective: '일반', focus: '런타임 에러, 로직 결함, 타입 불일치' };
}

// ── Prompt assembly ──

export function buildReviewPrompt(session) {
  const cwd = inferCwdFromSession(session);
  // 세션에서 실제로 Edit/Write한 파일만 diff 범위 제한 (토큰 절약)
  const sessionFiles = getSessionFiles(session, cwd);
  const { diff, source } = getLatestDiff(cwd, sessionFiles);
  if (!diff) return null;

  // commit일 때만 커밋 정보 사용, 나머지는 "미커밋 변경사항"
  const commitInfo = source === 'commit' ? getCommitInfo(cwd) : { hash: null, msg: null };
  const { hash, msg } = commitInfo;

  const files = extractChangedFiles(diff);
  const functions = extractChangedFunctions(diff);
  const callers = grepCallers(cwd, functions, msg);
  const { perspective, focus } = classifyReviewPerspective(files, msg);

  // Truncate diff if too large (keep under 30K chars for a small session)
  const maxDiffChars = 25000;
  const truncatedDiff = diff.length > maxDiffChars
    ? diff.substring(0, maxDiffChars) + '\n\n[...diff truncated, ' + (diff.length - maxDiffChars) + ' chars omitted]'
    : diff;

  const sourceLabel = source === 'commit' ? `커밋: ${hash} "${msg}"` : `미커밋 변경사항 (${source})`;
  const parts = [
    `## 리뷰 대상`,
    sourceLabel,
    `변경 파일: ${files.join(', ')}`,
    `관점: ${perspective} — ${focus}`,
    '',
    `## 변경 내용 (diff)`,
    '```diff',
    truncatedDiff,
    '```',
  ];

  if (callers.length > 0) {
    parts.push('', '## 의존 코드 (변경된 함수를 호출하는 곳)');
    for (const c of callers) {
      parts.push(`### ${c.function}()`);
      for (const ref of c.refs) {
        parts.push(`  ${ref}`);
      }
    }
  }

  parts.push(
    '',
    '## 요청',
    '위 diff와 호출부를 보고 다음만 확인해주세요:',
    '1. 런타임 에러 가능성 (null 참조, 타입 에러, 범위 초과)',
    '2. 호출부와 인자/반환값 불일치',
    '3. 엣지케이스 (빈 배열, 0, 음수, 중복 호출)',
    '4. 기존 기능이 깨질 가능성',
    '',
    '문제가 없으면 "이상 없음"이라고만 답하고,',
    '문제가 있으면 파일:라인 형식으로 구체적으로 지적해주세요.',
    '불필요한 스타일 제안이나 리팩토링 권장은 하지 마세요.',
  );

  return {
    prompt: parts.join('\n'),
    meta: { hash, msg, source, cwd, files, functions: functions.slice(0, 10), perspective, callerCount: callers.length },
  };
}

// ── Discord UI ──

export function buildReviewButton(projectName) {
  return new ActionRowBuilder().addComponents(
    new ButtonBuilder()
      .setCustomId(`review_start:${projectName}`)
      .setLabel('📋 코드 리뷰')
      .setStyle(ButtonStyle.Primary),
  );
}

// ── Pending review store (for apply-fix flow) ──
// key: channelId, value: { reviewResult, diff, cwd, files }
const pendingReviews = new Map();

export function storePendingReview(channelId, data) {
  pendingReviews.set(channelId, data);
}

export function popPendingReview(channelId) {
  const data = pendingReviews.get(channelId);
  pendingReviews.delete(channelId);
  return data;
}

export function buildReviewResultEmbed(meta, result) {
  const noIssue = result.toLowerCase().includes('이상 없음') || result.toLowerCase().includes('no issue');

  return new EmbedBuilder()
    .setTitle(`${noIssue ? '✅' : '🔍'} 코드 리뷰 — ${meta.source === 'commit' ? `${meta.hash} ${meta.msg}` : '미커밋 변경사항'}`)
    .setColor(noIssue ? COLOR.SUCCESS : COLOR.WARNING)
    .setDescription(result.length > 3800 ? result.substring(0, 3800) + '...' : result)
    .addFields(
      { name: '파일', value: meta.files.slice(0, 5).join('\n') || '-', inline: true },
      { name: '관점', value: meta.perspective, inline: true },
      { name: '의존부', value: `${meta.callerCount}개 호출부 확인`, inline: true },
    )
    .setFooter({ text: 'sonnet · diff-based review' })
    .setTimestamp();
}

export function buildReviewApplyButton(channelId) {
  return new ActionRowBuilder().addComponents(
    new ButtonBuilder()
      .setCustomId(`review_apply:${channelId}`)
      .setLabel('✏️ 수정 적용')
      .setStyle(ButtonStyle.Danger),
  );
}
