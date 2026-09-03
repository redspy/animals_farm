import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

// 텔레그램으로 질문(+선택지 버튼)을 보내고, 사용자가 버튼을 누를 때까지 대기해
// 선택된 답을 stdout에 출력하는 CLI 유틸리티. Claude 세션이 의사결정이 필요한
// 시점에 Bash로 이 스크립트를 호출해 사용자 응답을 받아오는 용도.
// --notify 모드는 응답을 기다리지 않고 한 방향으로만 알림을 보낸다(작업 완료 등).
//
// 사용법:
//   node scripts/telegram-ask.js "질문 텍스트" "옵션1" "옵션2" [옵션3] [옵션4] [--timeout=20]
//   node scripts/telegram-ask.js --notify "완료 알림 메시지"   (응답 대기 없이 즉시 전송)
//   node scripts/telegram-ask.js --get-chat-id   (봇 최초 설정 시 CHAT_ID 확인용)
//
// 필요한 환경변수(.env, 프로젝트 루트, git에 커밋되지 않음):
//   TELEGRAM_ASK_BOT_TOKEN=123456789:AAF...
//   TELEGRAM_ASK_CHAT_ID=123456789   (--get-chat-id로 확인 전에는 비워둬도 됨)

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, '..');

function loadEnv() {
  const envPath = path.join(rootDir, '.env');
  if (!fs.existsSync(envPath)) return;
  const content = fs.readFileSync(envPath, 'utf-8');
  for (const line of content.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    const value = trimmed.slice(eq + 1).trim();
    if (!(key in process.env)) process.env[key] = value;
  }
}
loadEnv();

const BOT_TOKEN = process.env.TELEGRAM_ASK_BOT_TOKEN;
const CHAT_ID = process.env.TELEGRAM_ASK_CHAT_ID;
const API = (method) => `https://api.telegram.org/bot${BOT_TOKEN}/${method}`;

async function tgCall(method, body) {
  const res = await fetch(API(method), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body || {}),
  });
  const data = await res.json();
  if (!data.ok) throw new Error(`Telegram API 오류(${method}): ${data.description || JSON.stringify(data)}`);
  return data.result;
}

async function getChatIdMode() {
  if (!BOT_TOKEN) {
    console.error('TELEGRAM_ASK_BOT_TOKEN이 .env에 없습니다. 먼저 BotFather로 봇을 만들고 토큰을 .env에 넣어주세요.');
    process.exit(1);
  }
  console.log('텔레그램 앱에서 방금 만든 봇에게 아무 메시지나 (예: /start) 보낸 뒤 Enter를 누르세요...');
  await new Promise((resolve) => process.stdin.once('data', resolve));
  const updates = await tgCall('getUpdates', {});
  if (!updates.length) {
    console.error('받은 메시지가 없습니다. 봇에게 메시지를 먼저 보냈는지 확인 후 다시 시도하세요.');
    process.exit(1);
  }
  const last = updates[updates.length - 1];
  const chat = last.message?.chat || last.callback_query?.message?.chat;
  if (!chat) {
    console.error('chat 정보를 찾지 못했습니다.');
    process.exit(1);
  }
  console.log(`\nCHAT_ID = ${chat.id}  (type: ${chat.type})`);
  console.log('이 값을 .env의 TELEGRAM_ASK_CHAT_ID에 넣으세요.');
  process.exit(0);
}

async function notifyMode() {
  if (!BOT_TOKEN || !CHAT_ID) {
    console.error('TELEGRAM_ASK_BOT_TOKEN / TELEGRAM_ASK_CHAT_ID가 .env에 설정되어 있어야 합니다.');
    process.exit(1);
  }
  const idx = process.argv.indexOf('--notify');
  const message = process.argv[idx + 1];
  if (!message) {
    console.error('사용법: node scripts/telegram-ask.js --notify "메시지"');
    process.exit(1);
  }
  try {
    await tgCall('sendMessage', {
      chat_id: CHAT_ID,
      text: `✅ *[animals_farm] 작업 완료*\n\n${message}`,
      parse_mode: 'Markdown',
    });
  } catch (e) {
    // 메시지에 미완성 마크다운 특수문자(*, _, ` 등)가 섞이면 Telegram이 파싱
    // 실패로 통째로 거부함 — 일반 텍스트로 재시도(Claude 응답 요약을 그대로
    // 보낼 때 흔히 발생, connect_dise Stop 훅에서 실측).
    await tgCall('sendMessage', {
      chat_id: CHAT_ID,
      text: `✅ [animals_farm] 작업 완료\n\n${message}`,
    });
  }
  console.log(JSON.stringify({ status: 'sent' }));
  process.exit(0);
}

function parseArgs(argv) {
  let timeoutMin = 20;
  const positional = [];
  for (const arg of argv) {
    const m = arg.match(/^--timeout=(\d+)$/);
    if (m) { timeoutMin = Number(m[1]); continue; }
    positional.push(arg);
  }
  const [question, ...options] = positional;
  return { question, options, timeoutMin };
}

async function askMode() {
  if (!BOT_TOKEN || !CHAT_ID) {
    console.error('TELEGRAM_ASK_BOT_TOKEN / TELEGRAM_ASK_CHAT_ID가 .env에 설정되어 있어야 합니다.');
    console.error('먼저 `node scripts/telegram-ask.js --get-chat-id`로 CHAT_ID를 확인하세요.');
    process.exit(1);
  }

  const { question, options, timeoutMin } = parseArgs(process.argv.slice(2));
  if (!question || options.length < 2 || options.length > 4) {
    console.error('사용법: node scripts/telegram-ask.js "질문" "옵션1" "옵션2" [옵션3] [옵션4] [--timeout=분]');
    process.exit(1);
  }

  const keyboard = options.map((opt, i) => ([{ text: opt, callback_data: `opt_${i}` }]));
  const sent = await tgCall('sendMessage', {
    chat_id: CHAT_ID,
    text: `❓ *[animals_farm] 의사결정 필요*\n\n${question}`,
    parse_mode: 'Markdown',
    reply_markup: { inline_keyboard: keyboard },
  });

  console.error(`[telegram-ask] 메시지 전송됨(message_id=${sent.message_id}). 응답 대기 중... (최대 ${timeoutMin}분)`);

  const deadline = Date.now() + timeoutMin * 60 * 1000;
  let offset = 0;

  while (Date.now() < deadline) {
    const remainingSec = Math.max(1, Math.min(25, Math.floor((deadline - Date.now()) / 1000)));
    let updates;
    try {
      updates = await tgCall('getUpdates', { offset, timeout: remainingSec });
    } catch (e) {
      console.error(`[telegram-ask] getUpdates 오류, 재시도: ${e.message}`);
      await new Promise((r) => setTimeout(r, 2000));
      continue;
    }

    for (const update of updates) {
      offset = update.update_id + 1;
      const cq = update.callback_query;
      if (!cq || cq.message?.message_id !== sent.message_id) continue;

      const idx = Number(String(cq.data).replace('opt_', ''));
      const chosen = options[idx];

      await tgCall('answerCallbackQuery', { callback_query_id: cq.id, text: `선택됨: ${chosen}` });
      await tgCall('editMessageText', {
        chat_id: CHAT_ID,
        message_id: sent.message_id,
        text: `❓ *[animals_farm] 의사결정 필요*\n\n${question}\n\n✅ 선택됨: *${chosen}*`,
        parse_mode: 'Markdown',
      });

      console.log(JSON.stringify({ status: 'answered', index: idx, choice: chosen }));
      process.exit(0);
    }
  }

  await tgCall('editMessageText', {
    chat_id: CHAT_ID,
    message_id: sent.message_id,
    text: `❓ *[animals_farm] 의사결정 필요*\n\n${question}\n\n⏱️ 시간 초과 — 응답 없음`,
    parse_mode: 'Markdown',
  }).catch(() => {});

  console.log(JSON.stringify({ status: 'timeout' }));
  process.exit(1);
}

if (process.argv.includes('--get-chat-id')) {
  await getChatIdMode();
} else if (process.argv.includes('--notify')) {
  await notifyMode();
} else {
  await askMode();
}
