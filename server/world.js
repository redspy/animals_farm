import { readFileSync, writeFileSync, renameSync, mkdirSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { randomUUID } from 'crypto';

// 월드 상태와 규칙. 전송(WebSocket)은 index.js가 담당하고, 여기서는 "무엇이
// 유효한가"만 다룬다 — 이 분리 덕에 서버 규칙을 소켓 없이 유닛 테스트할 수 있다
// (tests/server-world.test.mjs).
//
// 신뢰 모델(docs/protocol.md §3): 클라이언트가 보낸 좌표는 경계·속도 상한
// 안에서는 그대로 수용한다. 다만 **아이템 소유권은 서버가 판정**한다 —
// 중복 획득은 실제 손실로 이어지기 때문이다.

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO = join(__dirname, '..');
const STATE_DIR = join(__dirname, 'data');
const STATE_PATH = join(STATE_DIR, 'world.json');

export const LIMITS = {
  NAME_MAX: 12,
  CHAT_MAX: 200,
  // 클라이언트 이동속도(player.gd SPEED=4.2)의 1.6배. 정확한 시뮬레이션이
  // 아니라 순간이동/속도핵 완화용 상한이다.
  MAX_SPEED: 4.2 * 1.6,
  MOVE_MIN_INTERVAL_MS: 80,   // 10Hz + 여유
  GATHER_MIN_INTERVAL_MS: 250,  // 초당 4건 — 연타 채집 도배 방지
  CHAT_MIN_INTERVAL_MS: 500,  // 초당 2건
  EMOTE_MIN_INTERVAL_MS: 500,
  MAX_WORLD_ITEMS: 300,
  // 좌표 검증 유예: 네트워크 지터로 간격이 튀어도 바로 되돌리지 않도록
  // 속도 상한 계산에 최소 시간을 둔다.
  SPEED_MIN_DT_MS: 50,
};

const TOKEN_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function readJson(path, fallback) {
  try {
    return JSON.parse(readFileSync(path, 'utf-8'));
  } catch {
    return fallback;
  }
}

export class WorldState {
  constructor({ dataDir = join(REPO, 'data'), statePath = STATE_PATH, persist = true } = {}) {
    this.persistEnabled = persist;
    this.statePath = statePath;

    // 월드 크기·아이템·이모티콘은 클라이언트와 같은 data/*.json을 읽는다 —
    // 서버가 자기 사본을 갖고 있으면 둘이 갈려서 경계가 어긋난다.
    const worldCfg = readJson(join(dataDir, 'world.json'), {});
    this.sizeX = Number(worldCfg.size_x) || 50.7;
    this.sizeZ = Number(worldCfg.size_z) || 28.5;
    this.spawn = worldCfg.spawn || { x: 0, z: 0 };

    const emoteCfg = readJson(join(dataDir, 'emotes.json'), { emotes: [] });
    this.emoteIds = new Set((emoteCfg.emotes || []).map((e) => String(e.id)));

    const itemCfg = readJson(join(dataDir, 'items.json'), { items: {} });
    this.itemIds = new Set(Object.keys(itemCfg.items || {}));

    this.players = new Map();   // token -> record
    this.items = new Map();     // id -> {id, item, x, z, at}
    this.dirty = false;
    this._saveTimer = null;

    this._loadState();
  }

  // ---- 검증 유틸 ----

  static validToken(token) {
    return typeof token === 'string' && TOKEN_RE.test(token);
  }

  sanitizeName(raw) {
    if (typeof raw !== 'string') return '';
    // 제어문자 제거 후 길이 제한 — 클라이언트(SaveManager.sanitize_name)와
    // 같은 규칙이어야 사용자가 화면에서 본 이름이 서버에서 잘리지 않는다.
    const cleaned = [...raw.trim()].filter((c) => c.codePointAt(0) >= 32).join('');
    return cleaned.slice(0, LIMITS.NAME_MAX);
  }

  clampPos(x, z) {
    const hx = this.sizeX / 2;
    const hz = this.sizeZ / 2;
    return {
      x: Math.min(hx, Math.max(-hx, Number(x) || 0)),
      z: Math.min(hz, Math.max(-hz, Number(z) || 0)),
    };
  }

  // ---- 플레이어 ----

  join({ token, name, preset }) {
    if (!WorldState.validToken(token)) {
      return { error: { code: 'bad_token', message: '토큰 형식이 올바르지 않습니다' } };
    }
    const cleanName = this.sanitizeName(name);
    if (!cleanName) {
      return { error: { code: 'bad_name', message: '이름은 1~12자여야 합니다' } };
    }
    let p = this.players.get(token);
    if (!p) {
      const pos = this.clampPos(this.spawn.x, this.spawn.z);
      p = {
        token,
        name: cleanName,
        preset: String(preset || ''),
        x: pos.x,
        z: pos.z,
        dir: 'down',
        inventory: {},
        online: false,
        lastMoveAt: 0,
        lastChatAt: 0,
        lastEmoteAt: 0,
        lastGatherAt: 0,
      };
      this.players.set(token, p);
      this._markDirty();
    } else {
      // 재접속: 이름/외형은 클라이언트가 보낸 최신 값으로 갱신하되 위치와
      // 인벤토리는 서버 기록이 우선이다(docs/protocol.md §4).
      p.name = cleanName;
      if (preset) p.preset = String(preset);
      this._markDirty();
    }
    p.online = true;
    return { player: p };
  }

  leave(token) {
    const p = this.players.get(token);
    if (!p) return;
    p.online = false;
    // 레코드는 지우지 않는다 — 다시 들어왔을 때 위치·가방을 기억해야 한다.
    this._markDirty();
  }

  move(token, { x, z, dir }, now = Date.now()) {
    const p = this.players.get(token);
    if (!p) return { error: { code: 'not_joined', message: '먼저 join이 필요합니다' } };
    if (now - p.lastMoveAt < LIMITS.MOVE_MIN_INTERVAL_MS) {
      return { throttled: true };
    }
    const dt = Math.max(LIMITS.SPEED_MIN_DT_MS, now - (p.lastMoveAt || now)) / 1000;
    const target = this.clampPos(x, z);
    const dist = Math.hypot(target.x - p.x, target.z - p.z);
    const maxDist = LIMITS.MAX_SPEED * dt;
    if (dist > maxDist) {
      // 상한을 넘으면 거부하지 않고 상한까지만 이동시킨다 — 거부하면 지터가
      // 큰 클라이언트가 영구히 뒤처지고, 그대로 받으면 순간이동이 된다.
      const k = maxDist / dist;
      target.x = p.x + (target.x - p.x) * k;
      target.z = p.z + (target.z - p.z) * k;
    }
    p.x = Math.round(target.x * 100) / 100;
    p.z = Math.round(target.z * 100) / 100;
    if (typeof dir === 'string' && ['up', 'down', 'left', 'right'].includes(dir)) p.dir = dir;
    p.lastMoveAt = now;
    p.moved = true;
    this._markDirty();
    return { player: p };
  }

  chat(token, text, now = Date.now()) {
    const p = this.players.get(token);
    if (!p) return { error: { code: 'not_joined', message: '먼저 join이 필요합니다' } };
    if (now - p.lastChatAt < LIMITS.CHAT_MIN_INTERVAL_MS) {
      return { error: { code: 'rate_limited', message: '채팅이 너무 빠릅니다' } };
    }
    const clean = typeof text === 'string'
      ? [...text.trim()].filter((c) => c.codePointAt(0) >= 32).join('').slice(0, LIMITS.CHAT_MAX)
      : '';
    if (!clean) return { error: { code: 'empty_chat', message: '빈 메시지' } };
    p.lastChatAt = now;
    return { chat: { token, name: p.name, text: clean, at: now } };
  }

  emote(token, emote, now = Date.now()) {
    const p = this.players.get(token);
    if (!p) return { error: { code: 'not_joined', message: '먼저 join이 필요합니다' } };
    if (now - p.lastEmoteAt < LIMITS.EMOTE_MIN_INTERVAL_MS) {
      return { error: { code: 'rate_limited', message: '이모티콘이 너무 빠릅니다' } };
    }
    if (!this.emoteIds.has(String(emote))) {
      return { error: { code: 'bad_emote', message: '알 수 없는 이모티콘' } };
    }
    p.lastEmoteAt = now;
    return { emote: { token, emote: String(emote) } };
  }

  // 채집. 서버는 채집물의 위치·재생 상태를 모르므로 "클라이언트가 채집했다고
  // 주장하는 것"을 받아 적는다 — 이동 좌표와 같은 신뢰 수준이다(docs/protocol.md §3).
  // 그래도 서버가 가방의 단일 출처여야 한다: 그러지 않으면 드랍/줍기(서버 권위)와
  // 채집(클라이언트)이 서로 다른 가방을 보게 되고, 실제로 드랍이 항상
  // "가방에 없는 아이템"으로 거부됐다(2026-09-04 2탭 실측에서 발견).
  gather(token, item, now = Date.now()) {
    const p = this.players.get(token);
    if (!p) return { error: { code: 'not_joined', message: '먼저 join이 필요합니다' } };
    if (now - p.lastGatherAt < LIMITS.GATHER_MIN_INTERVAL_MS) {
      return { error: { code: 'rate_limited', message: '채집이 너무 빠릅니다' } };
    }
    const id = String(item);
    if (!this.itemIds.has(id)) {
      return { error: { code: 'bad_item', message: '알 수 없는 아이템' } };
    }
    p.lastGatherAt = now;
    p.inventory[id] = Number(p.inventory[id] || 0) + 1;
    this._markDirty();
    return { inventory: p.inventory };
  }

  // ---- 아이템 (서버 권위) ----

  drop(token, item, x, z) {
    const p = this.players.get(token);
    if (!p) return { error: { code: 'not_joined', message: '먼저 join이 필요합니다' } };
    const id = String(item);
    if (!this.itemIds.has(id)) {
      return { error: { code: 'bad_item', message: '알 수 없는 아이템' } };
    }
    const have = Number(p.inventory[id] || 0);
    if (have <= 0) {
      return { error: { code: 'no_item', message: '가방에 없는 아이템' } };
    }
    if (this.items.size >= LIMITS.MAX_WORLD_ITEMS) {
      return { error: { code: 'world_full', message: '월드에 놓인 물건이 너무 많습니다' } };
    }
    const pos = this.clampPos(x, z);
    if (have === 1) delete p.inventory[id]; else p.inventory[id] = have - 1;
    const entity = { id: randomUUID(), item: id, x: pos.x, z: pos.z, at: Date.now() };
    this.items.set(entity.id, entity);
    this._markDirty();
    return { item: entity, inventory: p.inventory };
  }

  pickup(token, entityId) {
    const p = this.players.get(token);
    if (!p) return { error: { code: 'not_joined', message: '먼저 join이 필요합니다' } };
    const entity = this.items.get(String(entityId));
    if (!entity) {
      // 이미 남이 주웠거나 없는 id — 조용히 무시하지 않고 알려준다(클라이언트가
      // 화면에서 아이템을 지울 수 있도록).
      return { error: { code: 'gone', message: '이미 없는 물건입니다' } };
    }
    this.items.delete(entity.id);
    p.inventory[entity.item] = Number(p.inventory[entity.item] || 0) + 1;
    this._markDirty();
    return { item: entity, inventory: p.inventory };
  }

  // ---- 스냅샷 ----

  snapshot() {
    const players = [];
    for (const p of this.players.values()) {
      if (!p.online) continue;
      players.push({ token: p.token, name: p.name, preset: p.preset, x: p.x, z: p.z, dir: p.dir });
    }
    return {
      players,
      items: [...this.items.values()].map((i) => ({ id: i.id, item: i.item, x: i.x, z: i.z })),
    };
  }

  takeMoves() {
    const moves = [];
    for (const p of this.players.values()) {
      if (!p.moved) continue;
      p.moved = false;
      moves.push({ token: p.token, x: p.x, z: p.z, dir: p.dir });
    }
    return moves;
  }

  // ---- 영속 ----

  _markDirty() {
    this.dirty = true;
    if (!this.persistEnabled || this._saveTimer) return;
    // 변경마다 디스크를 때리지 않도록 2초 디바운스(docs/protocol.md §4).
    this._saveTimer = setTimeout(() => {
      this._saveTimer = null;
      this.save();
    }, 2000);
    if (this._saveTimer.unref) this._saveTimer.unref();
  }

  save() {
    if (!this.persistEnabled || !this.dirty) return false;
    const payload = {
      schema_version: 1,
      saved_at: new Date().toISOString(),
      players: [...this.players.values()].map((p) => ({
        token: p.token, name: p.name, preset: p.preset,
        x: p.x, z: p.z, dir: p.dir, inventory: p.inventory,
      })),
      items: [...this.items.values()],
    };
    try {
      mkdirSync(dirname(this.statePath), { recursive: true });
      // 임시 파일에 쓰고 rename — 중간에 죽어도 반쯤 쓰인 파일이 남지 않는다.
      const tmp = `${this.statePath}.tmp`;
      writeFileSync(tmp, JSON.stringify(payload, null, 2));
      renameSync(tmp, this.statePath);
      this.dirty = false;
      return true;
    } catch (e) {
      console.error('[world] 상태 저장 실패:', e.message);
      return false;
    }
  }

  _loadState() {
    if (!existsSync(this.statePath)) return;
    const data = readJson(this.statePath, null);
    if (!data) {
      console.error('[world] 상태 파일이 손상됨 — 빈 상태로 시작(파일은 남겨둔다)');
      return;
    }
    for (const p of data.players || []) {
      if (!WorldState.validToken(p.token)) continue;
      const pos = this.clampPos(p.x, p.z);
      this.players.set(p.token, {
        token: p.token,
        name: this.sanitizeName(p.name),
        preset: String(p.preset || ''),
        x: pos.x, z: pos.z,
        dir: ['up', 'down', 'left', 'right'].includes(p.dir) ? p.dir : 'down',
        inventory: p.inventory && typeof p.inventory === 'object' ? p.inventory : {},
        online: false,
        lastMoveAt: 0, lastChatAt: 0, lastEmoteAt: 0, lastGatherAt: 0,
      });
    }
    for (const i of data.items || []) {
      if (!i || !i.id || !this.itemIds.has(String(i.item))) continue;
      const pos = this.clampPos(i.x, i.z);
      this.items.set(String(i.id), { id: String(i.id), item: String(i.item), x: pos.x, z: pos.z, at: Number(i.at) || 0 });
    }
    console.log(`[world] 상태 복원: 캐릭터 ${this.players.size}명, 월드 아이템 ${this.items.size}개`);
  }
}
