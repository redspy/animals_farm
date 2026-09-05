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
  // 채집 사거리(클라이언트 Gatherable.INTERACT_DISTANCE = 1.6)에 네트워크
  // 지연 여유를 더한 값. 딱 1.6으로 하면 정상 플레이도 간헐적으로 거부된다.
  GATHER_RANGE: 1.6 + 0.7,
  // 캐릭터끼리 유지할 최소 간격(클라이언트 Player.SEPARATION과 같은 값).
  SEPARATION: 0.8,
  SELL_MIN_INTERVAL_MS: 400,
  // 새 캐릭터를 스폰 지점에 그대로 놓으면 모두 한 점에 겹친다. 접속 순서에
  // 따라 링 위로 흩어 놓는다 — 무작위가 아니라 **결정적**이어야 테스트가
  // 재현된다.
  SPAWN_RING_RADIUS: 1.3,
  SPAWN_RING_SLOTS: 8,
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
    // 운동(활동)과 운동장 — 클라이언트와 **같은 파일**을 읽는다. 활동별 이동
    // 속도 상한이 서버에만 다르게 있으면 "자전거를 탔는데 서버가 계속
    // 되돌리는" 상태가 된다.
    const actCfg = readJson(join(dataDir, 'activities.json'), {});
    this.activities = new Map();
    for (const a of actCfg.activities || []) {
      if (!a || !a.id) continue;
      this.activities.set(String(a.id), {
        speed: Number(a.speed) || LIMITS.MAX_SPEED,
        zoneOnly: a.zone_only !== false,
        tricks: new Set((a.tricks || []).map((k) => String(k.id))),
      });
    }
    this.soccerCfg = {
      kickRange: Number(actCfg.soccer?.kick_range) || 1.5,
      kickSpeed: Number(actCfg.soccer?.kick_speed) || 11,
      dribbleRange: Number(actCfg.soccer?.dribble_range) || 0.55,
      dribbleSpeed: Number(actCfg.soccer?.dribble_speed) || 4.5,
      friction: Number(actCfg.soccer?.friction_per_sec) || 0.28,
      bounce: Number(actCfg.soccer?.bounce) || 0.55,
      kickInterval: Number(actCfg.soccer?.kick_min_interval_ms) || 260,
    };
    this.playground = worldCfg.playground || {};
    this.field = this.playground.field || null;
    // 공 상태. active는 "축구를 하는 사람이 있다"는 뜻이다 — 아무도 없으면
    // 물리를 돌리지 않고 브로드캐스트도 하지 않는다.
    this.ball = {
      active: false,
      x: this.field ? Number(this.field.x) : 0,
      z: this.field ? Number(this.field.z) : 0,
      vx: 0,
      vz: 0,
    };
    this.score = { left: 0, right: 0 };
    this.sizeX = Number(worldCfg.size_x) || 50.7;
    this.sizeZ = Number(worldCfg.size_z) || 28.5;
    this.spawn = worldCfg.spawn || { x: 0, z: 0 };

    // 바위(통과 불가)와 채집물을 서버도 읽는다. 예전에는 둘 다 클라이언트만
    // 알아서, 조작된 클라이언트가 바위를 통과하거나 아무 데서나 채집을 주장할
    // 수 있었다(docs/protocol.md §3의 신뢰 경계를 좁히는 작업).
    this.obstacles = (worldCfg.obstacles || [])
      .filter((o) => o && Number.isFinite(Number(o.x)) && Number.isFinite(Number(o.z)))
      .map((o) => (String(o.shape || 'circle') === 'box'
        ? {
          id: String(o.id || ''), shape: 'box', x: Number(o.x), z: Number(o.z),
          halfX: (Number(o.size_x) || 1) / 2, halfZ: (Number(o.size_z) || 1) / 2,
        }
        : {
          id: String(o.id || ''), shape: 'circle', x: Number(o.x), z: Number(o.z),
          radius: Number(o.radius) || 1.0,
        }));

    const gatherCfg = readJson(join(dataDir, 'gatherables.json'), { spawns: [] });
    const gatherLimits = (gatherCfg.limits || {}).respawn_sec || [10, 86400];
    this.gatherables = (gatherCfg.spawns || []).map((s, index) => ({
      index,
      kind: String(s.kind || 'tree'),
      item: String(s.item || 'wood'),
      x: Number(s.x) || 0,
      z: Number(s.z) || 0,
      // 유효범위는 데이터가 소유한다(클라이언트 Balance.clamp_value와 같은 규칙).
      respawnSec: Math.min(Number(gatherLimits[1]), Math.max(Number(gatherLimits[0]), Number(s.respawn_sec) || 30)),
      availableAt: 0,
    }));

    const emoteCfg = readJson(join(dataDir, 'emotes.json'), { emotes: [] });
    this.emoteIds = new Set((emoteCfg.emotes || []).map((e) => String(e.id)));

    // 아이템 정의(가격 포함)를 서버도 읽는다. 판매 금액을 클라이언트가 주장하게
    // 두면 벨을 임의로 불릴 수 있다 — 가격의 단일 출처는 data/items.json이고
    // 서버가 그 값으로 직접 계산한다.
    const itemCfg = readJson(join(dataDir, 'items.json'), { items: {} });
    // 이름을 itemDefs로 둔 이유: this.items는 **월드에 놓인 아이템 엔티티 맵**
    // 으로 이미 쓰이고 있어서, 정의를 같은 이름에 넣으면 아래에서 통째로
    // 덮어써진다(실제로 그렇게 해서 가격이 전부 null이 됐다).
    this.itemDefs = itemCfg.items || {};
    this.itemIds = new Set(Object.keys(this.itemDefs));

    this.players = new Map();   // token -> record
    this.items = new Map();     // id -> {id, item, x, z, at}
    this.dirty = false;
    this._saveTimer = null;

    // persist:false는 "디스크를 아예 쓰지 않는다"는 뜻이다 — 쓰기만 막고 읽기를
    // 허용하면 유닛 테스트가 실행 중인 서버의 런타임 상태를 물려받는다.
    // 실제로 브라우저 테스트가 남긴 월드 아이템 2개 때문에 "드랍 후 아이템 1개"
    // 단정이 3으로 깨졌다(2026-09-04 실측).
    if (this.persistEnabled) this._loadState();
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

  // 바위 안이면 표면 밖으로 되돌린다. 거부하지 않고 밀어내는 이유는
  // 클라이언트와 같다 — 거부하면 지터가 큰 클라이언트가 벽에 붙어 멈춘다.
  pushOutObstacles(pos, agentRadius = 0.35) {
    let { x, z } = pos;
    for (const o of this.obstacles) {
      if (o.shape === 'box') {
        // 침투가 가장 적은 축으로 밀어낸다(클라이언트 PathPlanner.push_out과 같은 규칙).
        const hx = o.halfX + agentRadius;
        const hz = o.halfZ + agentRadius;
        const dx = x - o.x;
        const dz = z - o.z;
        if (Math.abs(dx) >= hx || Math.abs(dz) >= hz) continue;
        const penX = hx - Math.abs(dx);
        const penZ = hz - Math.abs(dz);
        if (penX <= penZ) x = o.x + (dx >= 0 ? hx : -hx);
        else z = o.z + (dz >= 0 ? hz : -hz);
        continue;
      }
      const r = o.radius + agentRadius;
      const dx = x - o.x;
      const dz = z - o.z;
      const d = Math.hypot(dx, dz);
      if (d >= r) continue;
      if (d <= 0.0001) { x = o.x + r; z = o.z; continue; }
      x = o.x + (dx / d) * r;
      z = o.z + (dz / d) * r;
    }
    return { x, z };
  }

  // 다른 캐릭터와 겹치면 **움직인 쪽**을 밀어낸다. 가만히 있는 쪽을 밀면
  // 조작하지 않은 사람이 끌려다닌다.
  pushOutPlayers(token, pos) {
    let { x, z } = pos;
    for (const other of this.players.values()) {
      if (other.token === token || !other.online) continue;
      const dx = x - other.x;
      const dz = z - other.z;
      const d = Math.hypot(dx, dz);
      if (d >= LIMITS.SEPARATION) continue;
      if (d <= 0.0001) { x = other.x + LIMITS.SEPARATION; z = other.z; continue; }
      x = other.x + (dx / d) * LIMITS.SEPARATION;
      z = other.z + (dz / d) * LIMITS.SEPARATION;
    }
    return { x, z };
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
      const pos = this.spawnSlot(this.players.size);
      p = {
        token,
        name: cleanName,
        preset: String(preset || ''),
        x: pos.x,
        z: pos.z,
        dir: 'down',
        inventory: {},
        bells: 0,
        online: false,
        lastMoveAt: 0,
        lastChatAt: 0,
        lastEmoteAt: 0,
        lastGatherAt: 0,
        lastSellAt: 0,
        // 운동 상태. 남들 화면에도 보여야 하므로 서버가 갖는다.
        activity: '',
        trick: '',
        lastKickAt: 0,
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

  // 접속 순서(index)에 따라 스폰 링 위의 자리를 정한다. 같은 index면 항상 같은
  // 자리 — 클라이언트 겹침 분리(PathPlanner.separate)가 나머지를 처리한다.
  spawnSlot(index) {
    const slot = index % LIMITS.SPAWN_RING_SLOTS;
    // 0번은 스폰 지점 그대로 두어 "혼자 접속하면 정해진 자리"가 유지된다.
    if (index === 0) return this.clampPos(this.spawn.x, this.spawn.z);
    const angle = (slot / LIMITS.SPAWN_RING_SLOTS) * Math.PI * 2;
    return this.clampPos(
      this.spawn.x + Math.cos(angle) * LIMITS.SPAWN_RING_RADIUS,
      this.spawn.z + Math.sin(angle) * LIMITS.SPAWN_RING_RADIUS,
    );
  }

  leave(token) {
    // 나간 사람이 축구 중이었다면 공을 치울지 다시 판단해야 한다.
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
    const maxDist = this.speedCapOf(p) * dt;
    if (dist > maxDist) {
      // 상한을 넘으면 거부하지 않고 상한까지만 이동시킨다 — 거부하면 지터가
      // 큰 클라이언트가 영구히 뒤처지고, 그대로 받으면 순간이동이 된다.
      const k = maxDist / dist;
      target.x = p.x + (target.x - p.x) * k;
      target.z = p.z + (target.z - p.z) * k;
    }
    // 경계 → 속도 상한 → 바위 → 캐릭터 순서로 보정한다. 캐릭터를 마지막에
    // 두면 겹침을 피하다 바위에 박히므로, 바위를 다시 한 번 적용한다.
    let resolved = this.pushOutObstacles(target);
    resolved = this.pushOutPlayers(token, resolved);
    resolved = this.pushOutObstacles(resolved);
    resolved = this.clampPos(resolved.x, resolved.z);
    p.x = Math.round(resolved.x * 100) / 100;
    p.z = Math.round(resolved.z * 100) / 100;
    if (typeof dir === 'string' && ['up', 'down', 'left', 'right'].includes(dir)) p.dir = dir;
    p.lastMoveAt = now;
    p.moved = true;
    // 축구 중에 공에 닿으면 밀어낸다(드리블). 차기는 별도 조작이지만, 걸어가
    // 부딪혔는데 공이 가만히 있으면 공처럼 보이지 않는다.
    this.dribble(p);
    this._markDirty();
    return { player: p };
  }

  /** 활동별 이동 속도 상한(초당 유닛). 지터 여유는 MAX_SPEED와 같은 비율로 준다. */
  speedCapOf(p) {
    const base = 4.2;
    const act = this.activities.get(p.activity || '');
    const speed = act ? act.speed : base;
    // LIMITS.MAX_SPEED가 base*1.6이므로 같은 여유 비율을 활동 속도에도 적용한다.
    return speed * (LIMITS.MAX_SPEED / base);
  }

  /**
   * 운동 상태 변경. 남들 화면에 보여야 하므로 서버를 거친다.
   * kind가 빈 문자열이면 "그만두기"(원래 모습으로).
   */
  activity(token, kind, trick = '') {
    const p = this.players.get(token);
    if (!p) return { error: { code: 'not_joined', message: '먼저 join이 필요합니다' } };
    const id = String(kind || '');
    if (id && !this.activities.has(id)) {
      return { error: { code: 'bad_activity', message: '알 수 없는 운동' } };
    }
    let t = String(trick || '');
    if (id && t && !this.activities.get(id).tricks.has(t)) t = '';
    p.activity = id;
    p.trick = id ? t : '';
    // 축구하는 사람이 생기면 공을 내보내고, 아무도 없으면 치운다.
    const changed = this.refreshBall();
    this._markDirty();
    return { activity: { token, activity: p.activity, trick: p.trick }, ballChanged: changed };
  }

  /** 축구 중인 사람이 있는지에 따라 공을 켜고 끈다. 상태가 바뀌면 true. */
  refreshBall() {
    let any = false;
    for (const p of this.players.values()) {
      if (p.online && p.activity === 'soccer') { any = true; break; }
    }
    if (any === this.ball.active) return false;
    this.ball.active = any;
    if (any) this.resetBall();
    return true;
  }

  resetBall() {
    this.ball.x = this.field ? Number(this.field.x) : 0;
    this.ball.z = this.field ? Number(this.field.z) : 0;
    this.ball.vx = 0;
    this.ball.vz = 0;
  }

  /** 걸어가 공에 닿으면 살짝 밀어낸다. */
  dribble(p) {
    if (!this.ball.active || p.activity !== 'soccer') return;
    const dx = this.ball.x - p.x;
    const dz = this.ball.z - p.z;
    const d = Math.hypot(dx, dz);
    if (d > this.soccerCfg.dribbleRange) return;
    // 겹쳐 있으면(거리 0) 바라보는 방향으로 밀어낸다.
    const dir = d > 0.001
      ? { x: dx / d, z: dz / d }
      : WorldState.dirVector(p.dir);
    this.ball.vx = dir.x * this.soccerCfg.dribbleSpeed;
    this.ball.vz = dir.z * this.soccerCfg.dribbleSpeed;
  }

  /**
   * 공 차기. 방향은 클라이언트가 보내되(바라보는 방향 또는 조준 방향),
   * **사거리와 활동 상태는 서버가 검사한다** — 그러지 않으면 맵 밖에서
   * 공을 골대에 넣을 수 있다.
   */
  kick(token, { dx, dz }, now = Date.now()) {
    const p = this.players.get(token);
    if (!p) return { error: { code: 'not_joined', message: '먼저 join이 필요합니다' } };
    if (!this.ball.active) return { error: { code: 'no_ball', message: '공이 없습니다' } };
    if (p.activity !== 'soccer') {
      return { error: { code: 'not_soccer', message: '축구 중에만 공을 찰 수 있습니다' } };
    }
    if (now - (p.lastKickAt || 0) < this.soccerCfg.kickInterval) {
      return { throttled: true };
    }
    const dist = Math.hypot(this.ball.x - p.x, this.ball.z - p.z);
    if (dist > this.soccerCfg.kickRange) {
      return { error: { code: 'too_far', message: '공이 너무 멉니다' } };
    }
    let vx = Number(dx);
    let vz = Number(dz);
    const len = Math.hypot(vx, vz);
    if (!Number.isFinite(len) || len < 0.001) {
      const v = WorldState.dirVector(p.dir);
      vx = v.x; vz = v.z;
    } else {
      vx /= len; vz /= len;
    }
    p.lastKickAt = now;
    this.ball.vx = vx * this.soccerCfg.kickSpeed;
    this.ball.vz = vz * this.soccerCfg.kickSpeed;
    return { kicked: { token, x: this.ball.x, z: this.ball.z, vx: this.ball.vx, vz: this.ball.vz } };
  }

  static dirVector(dir) {
    switch (dir) {
      case 'up': return { x: 0, z: -1 };
      case 'left': return { x: -1, z: 0 };
      case 'right': return { x: 1, z: 0 };
      default: return { x: 0, z: 1 };
    }
  }

  /**
   * 공 물리 한 스텝. 서버가 소유하는 이유: 각 클라이언트가 자기 화면에서
   * 굴리면 기기마다 공 위치가 달라져 "내 화면에서는 골"이 된다.
   * 반환값이 있으면 골이 들어간 것이다.
   */
  tickBall(dt) {
    if (!this.ball.active || !this.field) return null;
    const b = this.ball;
    if (Math.abs(b.vx) < 0.01 && Math.abs(b.vz) < 0.01) { b.vx = 0; b.vz = 0; return null; }
    b.x += b.vx * dt;
    b.z += b.vz * dt;
    // 마찰: 초당 friction 비율로 줄인다.
    const damp = Math.pow(this.soccerCfg.friction, dt);
    b.vx *= damp;
    b.vz *= damp;

    const cx = Number(this.field.x);
    const cz = Number(this.field.z);
    const hx = Number(this.field.size_x) / 2;
    const hz = Number(this.field.size_z) / 2;
    const gw = Number(this.field.goal_width) / 2;

    // 골 판정: 골라인을 넘었고 골대 폭 안이면 골.
    if (Math.abs(b.z - cz) <= gw) {
      if (b.x < cx - hx) return this.scoreGoal('left');
      if (b.x > cx + hx) return this.scoreGoal('right');
    }
    // 나머지 경계는 튕긴다 — 공이 섬 밖으로 나가면 주우러 갈 수 없다.
    if (b.x < cx - hx) { b.x = cx - hx; b.vx = Math.abs(b.vx) * this.soccerCfg.bounce; }
    if (b.x > cx + hx) { b.x = cx + hx; b.vx = -Math.abs(b.vx) * this.soccerCfg.bounce; }
    if (b.z < cz - hz) { b.z = cz - hz; b.vz = Math.abs(b.vz) * this.soccerCfg.bounce; }
    if (b.z > cz + hz) { b.z = cz + hz; b.vz = -Math.abs(b.vz) * this.soccerCfg.bounce; }
    b.x = Math.round(b.x * 100) / 100;
    b.z = Math.round(b.z * 100) / 100;
    return null;
  }

  scoreGoal(side) {
    // side는 **공이 들어간 골대**다. 왼쪽 골대에 넣으면 오른쪽 팀 득점이라는
    // 팀 개념은 아직 없으므로, 골대별 누적만 센다.
    this.score[side] += 1;
    this.resetBall();
    return { side, score: { ...this.score } };
  }

  ballState() {
    return this.ball.active ? { x: this.ball.x, z: this.ball.z } : null;
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
  // 채집. **서버가 채집물의 위치·재생 상태를 소유한다.**
  //
  // 예전에는 "클라이언트가 채집했다고 주장하는 것"을 그대로 받아 적었다.
  // 그러면 아무 데서나, 이미 캔 나무를, 원하는 아이템으로 만들어낼 수 있었다.
  // 이제 index로 채집물을 지정받아 (a) 존재 (b) 재생 완료 (c) 사거리 안을
  // 확인하고, 아이템 종류도 데이터에서 읽는다(클라이언트 주장 무시).
  gather(token, index, now = Date.now()) {
    const p = this.players.get(token);
    if (!p) return { error: { code: 'not_joined', message: '먼저 join이 필요합니다' } };
    if (now - p.lastGatherAt < LIMITS.GATHER_MIN_INTERVAL_MS) {
      return { error: { code: 'rate_limited', message: '채집이 너무 빠릅니다' } };
    }
    const g = this.gatherables[Number(index)];
    if (!g) return { error: { code: 'bad_gatherable', message: '없는 채집물입니다' } };
    if (now < g.availableAt) {
      return { error: { code: 'not_grown', message: '아직 자라지 않았습니다' } };
    }
    const dist = Math.hypot(p.x - g.x, p.z - g.z);
    if (dist > LIMITS.GATHER_RANGE) {
      return { error: { code: 'too_far', message: '너무 멉니다' } };
    }
    p.lastGatherAt = now;
    g.availableAt = now + g.respawnSec * 1000;
    p.inventory[g.item] = Number(p.inventory[g.item] || 0) + 1;
    this._markDirty();
    return { inventory: p.inventory, gathered: { index: g.index, item: g.item, availableAt: g.availableAt } };
  }

  // 지금 캘 수 없는 채집물 목록(스냅샷·브로드캐스트용).
  gatherableStates(now = Date.now()) {
    return this.gatherables
      .filter((g) => now < g.availableAt)
      .map((g) => ({ index: g.index, availableAt: g.availableAt }));
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

  // 아이템 판매가. 유효범위(price_range)를 벗어난 값은 데이터 오타로 보고
  // 클램프한다 — 클라이언트(Balance.clamp_value)와 같은 규칙이어야 화면에
  // 보이던 금액과 실제 정산이 어긋나지 않는다.
  priceOf(itemId) {
    const meta = this.itemDefs[itemId];
    if (!meta) return null;
    let price = Number(meta.sell_price) || 0;
    const range = meta.price_range;
    if (Array.isArray(range) && range.length === 2) {
      const lo = Number(range[0]);
      const hi = Number(range[1]);
      if (price < lo || price > hi) {
        console.warn(`[world] ${itemId} 가격 ${price}이 유효범위 [${lo}, ${hi}] 밖 — 클램프`);
      }
      price = Math.min(hi, Math.max(lo, price));
    }
    return price;
  }

  // 판매. **서버가 가방과 벨의 단일 출처**다.
  //
  // 예전에는 클라이언트가 자기 슬롯에서만 팔았고 서버 가방은 그대로여서,
  // 재접속하면 welcome이 서버 가방으로 덮어써 판 물건이 되살아났다(벨은 이미
  // 받은 상태) — 벨을 무한히 불릴 수 있는 경로였다(2026-09-04 발견).
  //
  // itemId를 주면 그 아이템만, 없으면 팔 수 있는 것 전부.
  sell(token, itemId = null, now = Date.now()) {
    const p = this.players.get(token);
    if (!p) return { error: { code: 'not_joined', message: '먼저 join이 필요합니다' } };
    if (now - p.lastSellAt < LIMITS.SELL_MIN_INTERVAL_MS) {
      return { error: { code: 'rate_limited', message: '판매가 너무 빠릅니다' } };
    }
    const targets = itemId ? [String(itemId)] : Object.keys(p.inventory);
    if (targets.length === 0) {
      return { error: { code: 'empty_bag', message: '팔 물건이 없습니다' } };
    }

    let total = 0;
    const sold = {};
    const unsold = [];
    for (const id of targets) {
      const count = Number(p.inventory[id] || 0);
      if (count <= 0) continue;
      const price = this.priceOf(id);
      if (price === null) {
        // 가격을 모르는 아이템은 팔지 않고 가방에 남긴다(플레이어 손실 방지).
        unsold.push(id);
        continue;
      }
      total += price * count;
      sold[id] = count;
      delete p.inventory[id];
    }
    if (Object.keys(sold).length === 0) {
      return { error: { code: 'nothing_sold', message: '팔 수 있는 물건이 없습니다' } };
    }
    p.lastSellAt = now;
    p.bells = Math.max(0, Math.floor(p.bells + total));
    this._markDirty();
    return { sold, total, bells: p.bells, inventory: p.inventory, unsold };
  }

  // ---- 스냅샷 ----

  snapshot() {
    const players = [];
    for (const p of this.players.values()) {
      if (!p.online) continue;
      players.push({
        token: p.token, name: p.name, preset: p.preset, x: p.x, z: p.z, dir: p.dir,
        activity: p.activity || '', trick: p.trick || '',
      });
    }
    return {
      players,
      // 공은 축구를 하는 사람이 있을 때만 의미가 있다.
      ball: this.ball.active
        ? { x: this.ball.x, z: this.ball.z, score: { ...this.score } }
        : null,
      items: [...this.items.values()].map((i) => ({ id: i.id, item: i.item, x: i.x, z: i.z })),
      // 이미 캔 채집물을 새로 들어온 사람 화면에도 숨겨야 한다.
      gatherables: this.gatherableStates(),
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
        x: p.x, z: p.z, dir: p.dir, inventory: p.inventory, bells: p.bells,
      })),
      items: [...this.items.values()],
      gatherables: this.gatherableStates(),
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
        bells: Number.isFinite(Number(p.bells)) ? Math.max(0, Math.floor(Number(p.bells))) : 0,
        online: false,
        lastMoveAt: 0, lastChatAt: 0, lastEmoteAt: 0, lastGatherAt: 0, lastSellAt: 0,
      });
    }
    for (const i of data.items || []) {
      if (!i || !i.id || !this.itemIds.has(String(i.item))) continue;
      const pos = this.clampPos(i.x, i.z);
      this.items.set(String(i.id), { id: String(i.id), item: String(i.item), x: pos.x, z: pos.z, at: Number(i.at) || 0 });
    }
    for (const g of data.gatherables || []) {
      const target = this.gatherables[Number(g.index)];
      if (target) target.availableAt = Number(g.availableAt) || 0;
    }
    console.log(`[world] 상태 복원: 캐릭터 ${this.players.size}명, 월드 아이템 ${this.items.size}개`);
  }
}
