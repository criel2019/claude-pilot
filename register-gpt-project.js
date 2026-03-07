#!/usr/bin/env node
/**
 * GPT 프로젝트 등록 스크립트
 * Claude 또는 Codex AI 에이전트가 호출하여 gpt-projects.md에 프로젝트를 등록합니다.
 *
 * 사용법:
 *   node register-gpt-project.js <프로젝트이름> <절대경로>
 *
 * 예시:
 *   node register-gpt-project.js blog "C:\Users\YourName\Projects\blog"
 */

import { existsSync, readFileSync, writeFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const GPT_PROJECTS_FILE = join(__dirname, 'gpt-projects.md');

const [,, name, projectPath] = process.argv;

if (!name || !projectPath) {
  console.error('사용법: node register-gpt-project.js <이름> <경로>');
  process.exit(1);
}

// 경로 존재 확인
if (!existsSync(projectPath)) {
  console.error(`❌ 경로가 존재하지 않습니다: ${projectPath}`);
  process.exit(1);
}

// 파일이 없으면 빈 파일로 생성
if (!existsSync(GPT_PROJECTS_FILE)) {
  writeFileSync(GPT_PROJECTS_FILE, '# GPT Projects\n\n<!-- Format: project-name: /absolute/path/to/project -->\n\n', 'utf8');
}

// 중복 확인
const content = readFileSync(GPT_PROJECTS_FILE, 'utf8');
const lines = content.split('\n');
for (const line of lines) {
  const trimmed = line.trim();
  if (trimmed.startsWith('#') || trimmed.startsWith('<!--') || !trimmed) continue;
  const colonIdx = trimmed.indexOf(':');
  if (colonIdx === -1) continue;
  const existingName = trimmed.slice(0, colonIdx).trim();
  if (existingName === name) {
    console.log(`⚠️  이미 등록된 프로젝트입니다: ${name}`);
    console.log(`   기존 경로: ${trimmed.slice(colonIdx + 1).trim()}`);
    console.log(`   새 경로:   ${projectPath}`);
    // 기존 항목 업데이트
    const updated = lines.map(l => {
      const t = l.trim();
      if (!t || t.startsWith('#') || t.startsWith('<!--')) return l;
      const ci = t.indexOf(':');
      if (ci === -1) return l;
      if (t.slice(0, ci).trim() === name) return `${name}: ${projectPath}`;
      return l;
    }).join('\n');
    writeFileSync(GPT_PROJECTS_FILE, updated, 'utf8');
    console.log(`✅ 업데이트 완료: ${name} → ${projectPath}`);
    process.exit(0);
  }
}

// 새 항목 추가
const newContent = content.trimEnd() + `\n${name}: ${projectPath}\n`;
writeFileSync(GPT_PROJECTS_FILE, newContent, 'utf8');
console.log(`✅ 등록 완료: ${name} → ${projectPath}`);
