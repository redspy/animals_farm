import path from 'path';
import { fileURLToPath } from 'url';
import { execFile } from 'child_process';

// Claude Code Notification 훅 전용 스크립트. 권한 승인 대기, AskUserQuestion
// 대기 등 "Claude가 사용자 입력/확인을 기다리는 시점"에 발동한다(Stop과는 별개
// 이벤트 — Stop은 응답 턴이 완전히 끝났을 때만 발동해서 AskUserQuestion처럼
// 턴 중간에 멈춰서 기다리는 시점은 못 잡음, connect_dise에서 실측 확인됨).

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_MESSAGE = '⏳ Claude가 확인/입력을 기다리는 중';

let input = '';
process.stdin.on('data', (d) => { input += d; });
process.stdin.on('end', () => {
  let message = DEFAULT_MESSAGE;
  try {
    const hookData = JSON.parse(input || '{}');
    const raw = hookData.message || hookData.title || hookData.notification;
    if (typeof raw === 'string' && raw.trim()) {
      message = raw.length > 300 ? raw.slice(0, 300) + '…' : raw;
    }
  } catch { /* keep default */ }

  const scriptPath = path.join(__dirname, 'telegram-ask.js');
  execFile('node', [scriptPath, '--notify', message], { timeout: 15000 }, () => {
    process.exit(0);
  });
});
