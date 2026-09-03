import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { execFile } from 'child_process';
import os from 'os';

// Claude Code Stop 훅 전용 스크립트. 훅 이벤트 stdin(JSON)에서 transcript_path를
// 읽어 마지막 assistant 텍스트 응답을 요약해 텔레그램으로 전송한다.
// 실패해도 Claude 진행을 막으면 안 되므로 항상 exit 0.

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_MESSAGE = 'Claude 응답 완료';
const MAX_LEN = 500;

function findTranscriptPath(hookData) {
  if (hookData.transcript_path && fs.existsSync(hookData.transcript_path)) {
    return hookData.transcript_path;
  }
  const sessionId = hookData.session_id;
  const cwd = hookData.cwd || process.cwd();
  if (!sessionId) return null;
  const sanitized = cwd.replace(/\//g, '-');
  const guess = path.join(os.homedir(), '.claude', 'projects', sanitized, `${sessionId}.jsonl`);
  return fs.existsSync(guess) ? guess : null;
}

function lastAssistantText(transcriptPath) {
  const lines = fs.readFileSync(transcriptPath, 'utf-8').trim().split('\n');
  for (let i = lines.length - 1; i >= 0; i--) {
    if (!lines[i]) continue;
    let entry;
    try { entry = JSON.parse(lines[i]); } catch { continue; }
    if (entry.type !== 'assistant') continue;
    const content = entry.message?.content;
    if (!Array.isArray(content)) continue;
    const text = content
      .filter((c) => c.type === 'text' && c.text)
      .map((c) => c.text)
      .join('\n')
      .trim();
    if (text) return text;
  }
  return null;
}

function buildMessage(hookData) {
  try {
    const transcriptPath = findTranscriptPath(hookData);
    if (!transcriptPath) return DEFAULT_MESSAGE;
    const text = lastAssistantText(transcriptPath);
    if (!text) return DEFAULT_MESSAGE;
    return text.length > MAX_LEN ? text.slice(0, MAX_LEN) + '…' : text;
  } catch {
    return DEFAULT_MESSAGE;
  }
}

let input = '';
process.stdin.on('data', (d) => { input += d; });
process.stdin.on('end', () => {
  let hookData = {};
  try { hookData = JSON.parse(input || '{}'); } catch { /* keep {} */ }

  const message = buildMessage(hookData);
  const scriptPath = path.join(__dirname, 'telegram-ask.js');

  execFile('node', [scriptPath, '--notify', message], { timeout: 15000 }, () => {
    process.exit(0);
  });
});
