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
  // 걷기 속도. 클라이언트(Player.SPEED)·활동 속도 폴백·상한이 모두 이 값에서
  // 파생돼야 한다 — 여러 곳에 4.2를 따로 적어 두면 하나만 고쳐도 알 수 없다.
  WALK_SPEED: 4.2,
  // 지터 여유 1.6배. 활동 속도에도 같은 비율을 적용한다(speedCapOf).
  SPEED_TOLERANCE: 1.6,
  // 걷기 상한(= 아무 운동도 하지 않을 때). 리터럴로 두면 WALK_SPEED와 갈린다.
  get MAX_SPEED() { return this.WALK_SPEED * this.SPEED_TOLERANCE; },
  MOVE_MIN_INTERVAL_MS: 80,   // 10Hz + 여유
  // 경주 참가/포기 간격 — 전원 방송을 유발하는 경로다.
  RACE_MIN_INTERVAL_MS: 500,
  // 경주 중 속도 상한 배수. 평소(1.6)보다 조이고, 클램프된 초과 거리를 누적해
  // 상시 마진으로 달리는 것도 잡는다.
  RACE_SPEED_TOLERANCE: 1.25,
  RACE_OVERAGE_DQ: 3.0,
  // NPC 정산 간격 — 연타로 같은 부탁을 두 번 처리하려는 것을 막는다.
  NPC_MIN_INTERVAL_MS: 400,
  // 정산 허용 거리 = NPC 배회 반경 + 이 값. 클라이언트가 보는 NPC 위치는
  // 시간 함수라 기기마다 조금 다르므로, 대화 거리(2.2)보다 넉넉해야 한다.
  NPC_TALK_PAD: 3.5,
  ACTIVITY_MIN_INTERVAL_MS: 250,   // 운동 전환은 전원 브로드캐스트라 도배를 막는다
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
  // 존 판정 여유(유닛). 서버 좌표는 최대 한 틱 뒤처지므로 경계에서 정상
  // 조작이 거부되지 않게 조금 넓게 본다.
  ZONE_PAD: 1.5,
  // 놀이기구에 앉은 사람이 자리에서 벗어날 수 있는 최대 거리(유닛).
  RIDE_LEASH: 0.6,
  // 캐릭터 반지름(클라이언트 Player.RADIUS와 같은 값) — 밀림·경계·좌석 검증이
  // 모두 이 값을 쓴다. 리터럴로 흩뿌리면 한쪽만 고쳐도 알 수 없다.
  AGENT_RADIUS: 0.35,
};

/**
 * 놀이기구 좌석 개수의 기본값 — **좌표 계산과 검증이 같은 값을 봐야 한다.**
 * 한쪽만 폴백이 다르면 서로 다른 자리에 같은 좌표가 나온다(seat 4 ≡ seat 0).
 */
const SEAT_DEFAULTS = { swing: 2, carousel: 4, seesaw: 2 };
/** 뺑뺑이 좌석/손잡이 기본값 — 클라이언트(scripts/park.gd)와 같아야 한다. */
const CAROUSEL_SLOT_INSET = 0.75;

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
    /** 범위를 벗어난 데이터는 기본값으로 대체하고 알린다(밸런스 데이터 규칙). */
    const num = (value, fallback, min, max, key = '값') => {
      const n = Number(value);
      if (!Number.isFinite(n) || n < min || n > max) {
        if (value !== undefined) {
          // 어느 파일 어느 키인지 없으면 찾을 수 없다 — 키를 함께 찍는다.
          console.warn(`[animals_farm] ${key}이(가) 범위를 벗어나 기본값(${fallback})으로 대체: ${value} (허용 ${min}~${max})`);
        }
        return fallback;
      }
      return n;
    };
    // 섬 크기는 축구장 좌표 검증에 쓰므로 먼저 읽는다.
    const islandX = Number(worldCfg.size_x) || 50.7;
    const islandZ = Number(worldCfg.size_z) || 28.5;
    // 운동(활동)과 운동장 — 클라이언트와 **같은 파일**을 읽는다. 활동별 이동
    // 속도 상한이 서버에만 다르게 있으면 "자전거를 탔는데 서버가 계속
    // 되돌리는" 상태가 된다.
    const actCfg = readJson(join(dataDir, 'activities.json'), {});
    this.activities = new Map();
    for (const a of actCfg.activities || []) {
      if (!a || !a.id) continue;
      // 폴백은 **걷기 속도**다. 예전에는 MAX_SPEED로 폴백했는데, 데이터에
      // `"speed": 0` 같은 오타가 나면 클라이언트는 못 움직이는데(0.0을 그대로
      // 씀) 서버는 상한을 대폭 열어 주는 상태가 됐다.
      const speed = Number(a.speed);
      const valid = Number.isFinite(speed) && speed > 0;
      if (!valid && a.speed !== undefined) {
        console.warn(`[animals_farm] activities.json의 ${a.id}.speed가 올바르지 않아 걷기 속도로 대체: ${a.speed}`);
      }
      this.activities.set(String(a.id), {
        speed: valid ? speed : LIMITS.WALK_SPEED,
        // 그 활동을 할 수 있는 존 id. 없으면 어디서나(킥보드).
        zone: a.zone ? String(a.zone) : '',
        // 타고 있는 동안 직접 조작할 수 없다 — 놀이기구가 위치를 정한다.
        locked: a.locked === true,
        // 자리가 있으면 **서버가 배정한다**(같은 자리에 둘이 앉는 것을 막는다).
        seats: Number.isFinite(Number(a.seats)) ? Math.max(0, Math.floor(Number(a.seats))) : 0,
        // 미리 정한 목록이 아닌 값을 trick에 담는 활동(그네의 '자리:진폭' 등).
        freeTrick: a.free_trick === true,
        tricks: new Set((a.tricks || []).map((k) => String(k.id))),
      });
    }
    // 운동장처럼 "그 안에서만 되는" 활동을 서버도 판정할 수 있어야 한다 —
    // 클라이언트만 막으면 변조한 클라이언트가 섬 전역에서 자전거 속도를 쓴다.
    this.zones = (worldCfg.zones || []).filter((z) => z && z.id);
    // 활동이 가리키는 존이 실제로 있는지 확인한다. 없으면 그 활동은 **어디서도
    // 못 하는 상태**가 되는데, 조용히 그러면 원인을 찾기 어렵다.
    const zoneIds = new Set(this.zones.map((z) => String(z.id)));
    for (const [id, a] of this.activities) {
      if (a.zone && !zoneIds.has(a.zone)) {
        console.warn(`[animals_farm] activities.json의 ${id}.zone("${a.zone}")이 world.json zones에 없습니다 — 그 활동은 어디서도 시작할 수 없습니다`);
      }
    }
    // 축구 값도 유효범위를 강제한다(밸런스 데이터 규칙 — items의 price_range,
    // gatherables의 respawn_sec에 이미 있는 처리다).
    //
    // 특히 friction: 음수면 Math.pow(음수, 0.1)이 **NaN**이 되고, 그 NaN이 공
    // 좌표로 퍼져 JSON에서 null로 직렬화된다 — 공이 화면에서 사라지고 서버를
    // 재시작할 때까지 복구되지 않는다. 1 이상이면 감쇠가 아니라 가속이라
    // 공이 영원히 멈추지 않는다.
    const s = actCfg.soccer || {};
    this.soccerCfg = {
      kickRange: num(s.kick_range, 1.5, 0.2, 6, 'soccer.kick_range'),
      kickSpeed: num(s.kick_speed, 13, 1, 40, 'soccer.kick_speed'),
      dribbleRange: num(s.dribble_range, 0.55, 0.1, 3, 'soccer.dribble_range'),
      dribbleSpeed: num(s.dribble_speed, 4.5, 0.5, 20, 'soccer.dribble_speed'),
      // 개구간 (0,1): 0이면 즉시 정지, 1 이상이면 가속.
      friction: num(s.friction_per_sec, 0.28, 0.001, 0.999, 'soccer.friction_per_sec'),
      bounce: num(s.bounce, 0.55, 0, 1, 'soccer.bounce'),
      kickInterval: num(s.kick_min_interval_ms, 260, 0, 5000, 'soccer.kick_min_interval_ms'),
    };
    // 놀이터(park) — 놀이기구 물리 값과 기구 좌표.
    const pk = actCfg.park || {};
    this.parkCfg = {
      seesawGravity: num(pk.seesaw_gravity, 2.6, 0.1, 20, 'park.seesaw_gravity'),
      // 폴백도 **고친 값**이어야 한다 — 2.2는 최대 각도를 훨씬 넘겨 판이 끝까지
      // 꺾이던 값이라, 데이터가 범위를 벗어나면 예전 동작으로 되돌아갔다.
      seesawPush: num(pk.seesaw_push, 0.6, 0.1, 20, 'park.seesaw_push'),
      // 아래에서 물리 상한(진폭 = push/√gravity ≤ max_angle)과 맞는지 확인한다.
      seesawDamping: num(pk.seesaw_damping, 0.55, 0.01, 0.999, 'park.seesaw_damping'),
      seesawMaxAngle: num(pk.seesaw_max_angle, 0.42, 0.05, 1.4, 'park.seesaw_max_angle'),
      seesawPushInterval: num(pk.seesaw_push_min_interval_ms, 400, 0, 5000, 'park.seesaw_push_min_interval_ms'),
      carouselPushInterval: num(pk.carousel_push_min_interval_ms, 500, 0, 5000, 'park.carousel_push_min_interval_ms'),
      carouselPush: num(pk.carousel_push, 1.0, 0.05, 10, 'park.carousel_push'),
      carouselMaxSpeed: num(pk.carousel_max_speed, 3.2, 0.2, 12, 'park.carousel_max_speed'),
      carouselFriction: num(pk.carousel_friction, 0.6, 0.01, 0.999, 'park.carousel_friction'),
      // 그네 진폭 단계 — 값 개수가 곧 진폭의 유효 범위다(trick 검증에 쓴다).
      swingAmpSteps: Array.isArray(pk.swing_amp_steps)
        ? pk.swing_amp_steps
          .map((v, i) => num(v, 0.3, 0.05, 1.4, `park.swing_amp_steps[${i}]`))
        : [0.28, 0.55, 0.85],
    };
    // **값끼리의 정합성**을 확인한다. 개별 범위만 보면 "2.2"가 통과해서 판이
    // 밀 때마다 끝까지 꺾이는 예전 동작으로 조용히 돌아간다(리뷰 지적).
    const pushLimit = this.parkCfg.seesawMaxAngle * Math.sqrt(this.parkCfg.seesawGravity);
    if (this.parkCfg.seesawPush > pushLimit) {
      // 경고만 하면 배포에서는 아무도 안 본다 — 다른 값들처럼 **잘라 낸다**.
      console.warn(`[animals_farm] park.seesaw_push(${this.parkCfg.seesawPush})가 물리 상한 ${pushLimit.toFixed(2)}을 넘어 잘랐습니다(진폭 = push/√gravity ≤ max_angle)`);
      this.parkCfg.seesawPush = pushLimit;
    }
    this.park = worldCfg.park || {};
    // **좌석 개수의 단일 출처는 world.json의 park다**(좌석 좌표를 그 값으로
    // 계산하므로). activities.json의 seats와 갈리면 없는 자리가 배정되고,
    // 좌표 계산이 기구 밖을 가리켜 허공에 앉는다(리뷰 지적).
    const geomSeats = {
      swing: Math.floor(Number(this.park.swing?.seats)),
      carousel: Math.floor(Number(this.park.carousel?.slots)),
      seesaw: 2,
    };
    for (const [id, raw] of Object.entries(geomSeats)) {
      if (!this.activities.has(id)) continue;
      const a = this.activities.get(id);
      // 값이 이상하면 **건너뛰지 않고 정규화한다.** 건너뛰면 activities.json
      // 값이 남아, 이 가드가 막으려던 "없는 자리 배정"이 그대로 생긴다
      // (slots: 0이면 네 명이 같은 좌표에 앉았다 — 리뷰 지적).
      // 상한 99인 이유: trick 형식이 두 자리 정수까지만 받는다.
      // 폴백은 **seatPosition이 쓰는 기본값**이어야 한다. activities.json 값으로
      // 두면 좌표 계산(기본값 4/2)과 갈려서, 서버는 서로 다른 자리로 배정하는데
      // 좌표가 같아진다(seat 4 ≡ seat 0) — 이 가드가 막으려던 상태다(리뷰 지적).
      const geomDefault = SEAT_DEFAULTS[id] ?? a.seats;
      const count = Number.isFinite(raw) ? Math.max(1, Math.min(99, raw)) : geomDefault;
      if (a.seats !== count) {
        console.warn(`[animals_farm] ${id}의 좌석 수가 어긋나거나 범위를 벗어났습니다(activities.json ${a.seats} / world.json ${raw}) — ${count}으로 맞춥니다`);
      }
      a.seats = count;
    }
    // 뺑뺑이 좌석/손잡이 값의 관계도 확인한다 — world.json 주석이 요구하는
    // 조건("grip_offset이 캐릭터 반지름 0.35보다 커야 기둥이 몸을 관통하지
    // 않는다", "slot_inset이 반지름보다 작아야 좌석이 판 위에 있다")을 강제하는
    // 코드가 없으면 주석만 남고 버그가 재발한다(리뷰 지적).
    const cs = this.park.carousel;
    if (cs) {
      const inset = Number(cs.slot_inset);
      const grip = Number(cs.grip_offset);
      const radius = Number(cs.radius);
      if (Number.isFinite(inset) && Number.isFinite(radius) && (inset < 0 || inset >= radius)) {
        console.warn(`[animals_farm] park.carousel.slot_inset(${inset})은 0 이상 radius(${radius}) 미만이어야 합니다 — 좌석이 판 밖으로 나갑니다`);
      }
      // 기둥은 사각 기둥이라 **모서리**까지 봐야 한다: 반지름 + 반두께 × √2.
      const thick = Number.isFinite(Number(cs.grip_thick)) ? Number(cs.grip_thick) : 0.1;
      const gripMin = LIMITS.AGENT_RADIUS + (thick / 2) * Math.SQRT2;
      if (Number.isFinite(grip) && grip <= gripMin) {
        console.warn(`[animals_farm] park.carousel.grip_offset(${grip})이 ${gripMin.toFixed(2)} 이하입니다 — 손잡이 기둥이 캐릭터를 관통합니다(캐릭터 반지름 ${LIMITS.AGENT_RADIUS} + 기둥 모서리)`);
      }
      if (Number.isFinite(grip) && Number.isFinite(inset) && grip > inset) {
        console.warn(`[animals_farm] park.carousel.grip_offset(${grip})이 slot_inset(${inset})보다 커서 손잡이가 판 밖에 뜹니다`);
      }
    }

    // 시소 기울기는 **서버가 소유한다**(축구공과 같은 이유: 각자 계산하면
    // 기기마다 다르게 기울어 누가 위에 있는지가 갈린다).
    // 뺑뺑이는 각도를 서버가 적분해 방송한다 — 밀 때마다 속도가 바뀌므로
    // 시간 함수로는 맞출 수 없다.
    this.seesaw = { angle: 0, vel: 0 };
    this.carousel = { angle: 0, speed: 0 };

    this.playground = worldCfg.playground || {};
    // 축구장 값도 정규화한다 — size_x가 없거나 오타면 hx가 NaN이 되어 골 판정과
    // 경계 반사가 모두 false가 되고, 공이 섬 밖으로 무한히 굴러간다(friction과
    // 같은 실패 종류다).
    const rawField = this.playground.field || null;
    this.field = rawField
      ? {
        // 범위는 섬 안이어야 한다 — 섬 밖 축구장은 통과시키면 안 된다.
        x: num(rawField.x, 0, -islandX / 2, islandX / 2, 'playground.field.x'),
        z: num(rawField.z, 0, -islandZ / 2, islandZ / 2, 'playground.field.z'),
        // 중심과 크기를 따로만 보면 "x=38, size_x=20"이 둘 다 통과해 축구장이
        // 섬 밖으로 나간다 — 절반을 더한 값으로 검사한다(리뷰 지적).
        size_x: num(rawField.size_x, 20, 2,
          Math.max(2, (islandX / 2 - Math.abs(Number(rawField.x) || 0)) * 2), 'playground.field.size_x'),
        size_z: num(rawField.size_z, 12, 2,
          Math.max(2, (islandZ / 2 - Math.abs(Number(rawField.z) || 0)) * 2), 'playground.field.size_z'),
        goal_width: num(rawField.goal_width, 4.4, 0.5,
          Math.max(1, Number(rawField.size_z) || 12), 'playground.field.goal_width'),
        goal_depth: num(rawField.goal_depth, 1.1, 0.1, 20, 'playground.field.goal_depth'),
      }
      : null;
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
    // islandX/islandZ와 같은 값이다 — 두 번 계산하면 위쪽 검사에서 한쪽만
    // 갱신돼 어긋난다(생성자 순서 함정).
    this.sizeX = islandX;
    this.sizeZ = islandZ;
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

    // 아이템 정의(가격 포함)를 서버도 읽는다. 판매 금액을 클라이언트가 주장하게
    // 두면 벨을 임의로 불릴 수 있다 — 가격의 단일 출처는 data/items.json이고
    // 서버가 그 값으로 직접 계산한다.
    const itemCfg = readJson(join(dataDir, 'items.json'), { items: {} });
    // 이름을 itemDefs로 둔 이유: this.items는 **월드에 놓인 아이템 엔티티 맵**
    // 으로 이미 쓰이고 있어서, 정의를 같은 이름에 넣으면 아래에서 통째로
    // 덮어써진다(실제로 그렇게 해서 가격이 전부 null이 됐다).
    this.itemDefs = itemCfg.items || {};
    this.itemIds = new Set(Object.keys(this.itemDefs));

    // 달리기 경주. 판정(체크포인트 순서·순위·보상)을 전부 서버가 갖는다.
    this.playgroundCfg = worldCfg.playground || {};
    const raceCfg = (worldCfg.playground || {}).race || {};
    const raceLimits = raceCfg.limits || {};
    const rlim = (key, fallback) => raceLimits[key] || fallback;
    this.raceCfg = {
      checkpoints: (raceCfg.checkpoints || []).map((c) => ({
        id: String(c.id || ''), x: Number(c.x) || 0, z: Number(c.z) || 0,
      })),
      radius: num(raceCfg.radius, 2.5, rlim('radius', [1, 5])[0], rlim('radius', [1, 5])[1], 'race/radius'),
      laps: Math.floor(num(raceCfg.laps, 2, rlim('laps', [1, 5])[0], rlim('laps', [1, 5])[1], 'race/laps')),
      lobbySec: num(raceCfg.lobby_sec, 10, rlim('lobby_sec', [3, 60])[0], rlim('lobby_sec', [3, 60])[1], 'race/lobby_sec'),
      countdownSec: num(raceCfg.countdown_sec, 3, rlim('countdown_sec', [1, 10])[0], rlim('countdown_sec', [1, 10])[1], 'race/countdown_sec'),
      timeoutSec: num(raceCfg.timeout_sec, 90, rlim('timeout_sec', [20, 600])[0], rlim('timeout_sec', [20, 600])[1], 'race/timeout_sec'),
      finishedSec: num(raceCfg.finished_sec, 15, rlim('finished_sec', [3, 60])[0], rlim('finished_sec', [3, 60])[1], 'race/finished_sec'),
      // 보상도 유효범위를 강제한다 — 300 대신 30000을 오타로 넣으면 경제가
      // 무너지는데, 다른 필드와 달리 상한이 없었다(리뷰 지적).
      rewards: (Array.isArray(raceCfg.rewards) && raceCfg.rewards.length > 0
        ? raceCfg.rewards : [300, 150, 50]
      ).map((v, i) => Math.floor(num(v, [300, 150, 50][i] || 50,
        rlim('reward', [0, 5000])[0], rlim('reward', [0, 5000])[1], `race/rewards[${i}]`))),
      finishReward: Math.floor(num(raceCfg.finish_reward, 20,
        rlim('finish_reward', [0, 1000])[0], rlim('finish_reward', [0, 1000])[1], 'race/finish_reward')),
      // 트랙 밴드(레인 안쪽 경계 비율). 체크포인트만으로는 인필드 횡단을 막지
      // 못한다 — 두 체크포인트 사이에 밴드를 벗어나면 다음 통과를 인정하지 않는다.
      bandInner: Math.max(0.05, (Number(worldCfg.playground.track.outer_a) - Number(worldCfg.playground.track.lane) * 2) / Number(worldCfg.playground.track.outer_a)),
      bandOuter: 1.04,
    };
    if (this.raceCfg.checkpoints.length < 2) {
      console.warn('[world] race.checkpoints가 2개 미만입니다 — 경주를 열 수 없습니다');
    }
    // 상태 기계: idle → lobby → countdown → running → finished → idle.
    this.race = { phase: 'idle', endsAt: 0, startedAt: 0, runners: new Map() };

    const gatherCfg = readJson(join(dataDir, 'gatherables.json'), { spawns: [] });
    const gatherLimits = (gatherCfg.limits || {}).respawn_sec || [10, 86400];
    // 확률 테이블(낚시·벌레). **서버가 굴린다** — 클라이언트가 아이템을 주장하면
    // 비싼 것만 반복해서 잡을 수 있고, 시간·월 조건도 기기 시계로 우회된다.
    // hours는 [시작, 끝)이고 시작 > 끝이면 자정을 넘는 구간이다. months는 있으면
    // 그 달에만 나온다(계절 문자열을 쓰지 않는 이유: 서버(JS)와 클라이언트
    // (GDScript)가 같은 매핑을 각자 구현하면 두 곳이 갈린다).
    const weightRange = (gatherCfg.limits || {}).catch_weight || [1, 1000];
    this.catchTables = {};
    for (const [kind, rows] of Object.entries(gatherCfg.catch_tables || {})) {
      const entries = (rows || [])
        .map((r) => ({
          item: String(r.item || ''),
          weight: Math.min(Number(weightRange[1]), Math.max(Number(weightRange[0]), Number(r.weight) || 1)),
          hours: Array.isArray(r.hours) && r.hours.length === 2
            ? [Number(r.hours[0]), Number(r.hours[1])] : null,
          months: Array.isArray(r.months) && r.months.length > 0
            ? r.months.map(Number) : null,
        }))
        .filter((r) => r.item);
      // 정의에 없는 아이템은 걸러낸다 — 그대로 두면 가방에 팔 수 없는 물건이
      // 쌓이고(판매는 items.json 가격으로만 정산한다) 도감에도 유령이 생긴다.
      const known = entries.filter((r) => this.itemIds.has(r.item));
      for (const r of entries) {
        if (!this.itemIds.has(r.item)) {
          console.warn(`[world] catch_tables.${kind}의 "${r.item}"이 data/items.json에 없습니다 — 무시합니다`);
        }
      }
      this.catchTables[kind] = known;
      if (known.length === 0) {
        console.warn(`[world] catch_tables.${kind}가 비어 있습니다 — 그 종류는 아무것도 잡히지 않습니다`);
      }
    }

    this.gatherables = (gatherCfg.spawns || []).map((s, index) => ({
      index,
      kind: String(s.kind || 'tree'),
      // 낚시터·벌레 스폿은 item이 없다 — catch_tables가 정한다(빈 문자열).
      item: this.catchTables[String(s.kind)] ? '' : String(s.item || 'wood'),
      x: Number(s.x) || 0,
      z: Number(s.z) || 0,
      // 유효범위는 데이터가 소유한다(클라이언트 Balance.clamp_value와 같은 규칙).
      respawnSec: Math.min(Number(gatherLimits[1]), Math.max(Number(gatherLimits[0]), Number(s.respawn_sec) || 30)),
      availableAt: 0,
    }));

    // 이웃 동물(NPC). 위치·대사는 클라이언트가 그리고, 서버는 **부탁과 정산**만
    // 소유한다(data/npcs.json 주석 참고).
    const npcCfg = readJson(join(dataDir, 'npcs.json'), { npcs: [] });
    const npcLimits = npcCfg.limits || {};
    this.npcRewardMultiplier = num(
      npcCfg.reward_multiplier, 1.8,
      (npcLimits.reward_multiplier || [1.0, 5.0])[0],
      (npcLimits.reward_multiplier || [1.0, 5.0])[1],
      'npcs.json/reward_multiplier');
    const countRange = npcLimits.request_count || [1, 5];
    this.npcs = new Map();
    for (const raw of npcCfg.npcs || []) {
      const id = String(raw.id || '');
      if (!id) continue;
      // 정의에 없는 아이템을 요구하면 그 부탁은 절대 완료할 수 없다(가격도
      // 계산할 수 없다) — 로드할 때 걸러내고 알린다.
      const requests = (raw.requests || [])
        .map((r) => ({
          item: String(r.item || ''),
          count: Math.min(Number(countRange[1]),
            Math.max(Number(countRange[0]), Math.floor(Number(r.count) || 1))),
        }))
        .filter((r) => {
          if (!this.itemIds.has(r.item)) {
            console.warn(`[world] npcs.json의 ${id} 부탁 아이템 "${r.item}"이 items.json에 없습니다 — 무시합니다`);
            return false;
          }
          // **시간 제한이 붙은 아이템은 부탁으로 쓸 수 없다.** 부탁은 하루 내내
          // 고정이므로(결정적 해시), 낮에만 나오는 것을 부탁받으면 밤에 접속한
          // 사람은 그날 아무것도 할 수 없다. 월 제한도 같은 이유로 막는다 —
          // 9~5월에 매미를 부탁하면 그 날은 통째로 죽은 부탁이 된다.
          const limited = this.catchEntryFor(r.item);
          if (limited) {
            console.warn(`[world] npcs.json의 ${id} 부탁 아이템 "${r.item}"은 시간·월 제한이 있어 부탁으로 쓸 수 없습니다 — 무시합니다`);
            return false;
          }
          return true;
        });
      if (requests.length === 0) {
        console.warn(`[world] NPC ${id}에 유효한 부탁이 없습니다 — 부탁을 주지 않습니다`);
      }
      this.npcs.set(id, {
        id,
        label: String(raw.label || id),
        x: Number(raw.x) || 0,
        z: Number(raw.z) || 0,
        // 배회 반경 + 여유가 정산 허용 거리다. 배회는 클라이언트가 시간
        // 함수로 그리므로(scripts/npc.gd) 보이는 위치가 기기마다 조금 다르다.
        wanderRadius: num(raw.wander_radius, 3.0,
          (npcLimits.wander_radius || [0, 8])[0],
          (npcLimits.wander_radius || [0, 8])[1],
          `npcs.json/${id}/wander_radius`),
        requests,
      });
    }

    const emoteCfg = readJson(join(dataDir, 'emotes.json'), { emotes: [] });
    this.emoteIds = new Set((emoteCfg.emotes || []).map((e) => String(e.id)));


    this.players = new Map();   // token -> record
    this.items = new Map();     // id -> {id, item, x, z, at}
    this.dirty = false;
    this._saveTimer = null;
    for (const [id] of Object.entries(geomSeats)) {
      const count = this.activities.has(id)
        ? this.activities.get(id).seats
        : (SEAT_DEFAULTS[id] ?? 2);
      for (let i = 0; i < count; i += 1) {
        const at = this.seatPosition(id, i);
        if (!at) continue;
        // 경계는 **클라이언트와 같은 기준**이어야 한다: 클라이언트는
        // size/2 - RADIUS(0.35)로 클램프하므로, 그 사이에 좌석이 있으면 타는
        // 사람 화면만 안으로 밀려 그려진다 — 이 검사가 잡겠다던 증상이다.
        // (이 블록은 생성자 **끝**에 있다 — 위쪽에 두면 this.obstacles와
        //  this.sizeX가 아직 없어서 터진다. 실측으로 배웠다.)

        const inside = Number.isFinite(at.x) && Number.isFinite(at.z)
          && Math.abs(at.x) <= this.sizeX / 2 - LIMITS.AGENT_RADIUS
          && Math.abs(at.z) <= this.sizeZ / 2 - LIMITS.AGENT_RADIUS;
        if (!inside) {
          console.warn(`[animals_farm] ${id} ${i}번 좌석이 섬 밖이거나 좌표가 잘못됐습니다(${at.x}, ${at.z}) — data/world.json의 park를 확인하세요`);
          continue;
        }
        // 좌석이 바위와 겹치면 클라이언트는 밀려나고 서버 앵커는 좌석에 남아
        // 화면이 갈린다. 여유는 **실제 이동 경로와 같은 기본값**(에이전트 반지름
        // 0.35)을 쓴다 — 다른 값을 쓰면 문제 없는 좌석에도 경고가 뜬다.
        const pushed = this.pushOutObstacles({ x: at.x, z: at.z });
        if (Math.abs(pushed.x - at.x) > 0.001 || Math.abs(pushed.z - at.z) > 0.001) {
          console.warn(`[animals_farm] ${id} ${i}번 좌석이 장애물과 겹칩니다(${at.x}, ${at.z}) — data/world.json의 park나 obstacles를 확인하세요`);
        }
      }
    }



    // persist:false는 "디스크를 아예 쓰지 않는다"는 뜻이다 — 쓰기만 막고 읽기를
    // 허용하면 유닛 테스트가 실행 중인 서버의 런타임 상태를 물려받는다.
    // 실제로 브라우저 테스트가 남긴 월드 아이템 2개 때문에 "드랍 후 아이템 1개"
    // 단정이 3으로 깨졌다(2026-09-04 실측).
    // 좌석 좌표를 **기동 시 한 번 확인한다.** 섬 밖이나 NaN이면 서버는
    // 클램프해 저장을 보호하지만, 클라이언트는 클램프하지 않아 타는 사람 화면과
    // 남들 화면이 다른 자리에 보인다("허공에 앉는" 증상이 형태만 바뀐다).
    // 값을 고쳐야 하는 문제이므로 조용히 넘기지 않는다(리뷰 지적).
    // geomSeats를 손으로 다시 적지 않는다 — 기구가 늘면 한쪽에만 추가돼 검사가
    // 조용히 빠진다(리뷰 지적).
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
  pushOutObstacles(pos, agentRadius = LIMITS.AGENT_RADIUS) {
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

  /**
   * resetActivity: 운동 상태를 비울지. **소켓 동일성을 아는 쪽(전송 계층)이
   * 정한다** — 여기서 `p.online`으로 추측하면 안 된다: 폰이 절전으로 끊길 때
   * close가 늦게 오거나 오지 않아, 그 전에 재접속하면 online이 아직 true여서
   * 초기화를 건너뛴다. 그러면 새 클라이언트(운동 없음)와 서버(자전거)가
   * 어긋난 채 브로드캐스트가 돌아와 **다시 자전거를 태운다**(리뷰 지적).
   */
  join({ token, name, preset, resetActivity = false }) {
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
        // NPC별 마지막 완료 날짜(서버 날짜 문자열). 기기 시계로 반복하는 것을
        // 막으려면 서버 시계로 판정해야 한다.
        npcDone: {},
        // 도감 — 아이템별 **누적** 획득 수. 팔거나 버려도 줄지 않는다(기록이다).
        dex: {},
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
        lastActivityAt: 0,
        lastPushAt: 0,
        // 놀이기구에 앉은 자리(있으면 그 근처를 벗어날 수 없다).
        rideAnchor: null,
      };
      this.players.set(token, p);
      this._markDirty();
    } else {
      // 재접속: 이름/외형은 클라이언트가 보낸 최신 값으로 갱신하되 위치와
      // 인벤토리는 서버 기록이 우선이다(docs/protocol.md §4).
      p.name = cleanName;
      if (preset) p.preset = String(preset);
      // **운동 상태는 초기화한다.** 새로 들어온 클라이언트는 아무 운동도 하지
      // 않는 상태로 시작하므로, 서버가 옛 상태를 들고 있으면 남들 화면에는
      // 계속 자전거를 탄 모습이 보이고 **서버 이동 상한도 자전거로 열려 있다**
      // (같은 버튼을 두 번 눌러야 겨우 복구됐다). rename도 이 함수를 쓰므로
      // 호출자가 "새 접속인가"를 알려 준다(resetActivity).
      if (resetActivity || !p.online) {
        p.activity = '';
        p.trick = '';
        p.rideAnchor = null;
      }
      this._markDirty();
    }
    p.online = true;
    // 옛 레코드(필드 추가 이전)를 만나도 뒤에서 undefined를 만지지 않게 채운다.
    if (!p.npcDone || typeof p.npcDone !== 'object') p.npcDone = {};
    if (!p.dex || typeof p.dex !== 'object') p.dex = {};
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
    // 놀이기구에 앉아 있으면 그 자리 근처를 벗어날 수 없다. 0.6은 좌석에
    // 미끄러져 들어오는 오차 여유다(클라이언트가 좌석까지 걸어간 뒤 앉는다).
    if (p.rideAnchor) {
      const ax = p.rideAnchor.x;
      const az = p.rideAnchor.z;
      const d = Math.hypot(target.x - ax, target.z - az);
      if (d > LIMITS.RIDE_LEASH) {
        const k = LIMITS.RIDE_LEASH / d;
        target.x = ax + (target.x - ax) * k;
        target.z = az + (target.z - az) * k;
      }
    }
    const dist = Math.hypot(target.x - p.x, target.z - p.z);
    // 경주 중에는 상한을 조인다(1.6 → 1.25). 벨이 걸린 판정에서 60% 마진은
    // 너무 넓다 — 자전거 7.6이 12.16까지 허용됐다(리뷰 지적).
    const racing = this.race.phase === 'running' && this.race.runners.has(token);
    const maxDist = (racing
      ? this.speedOf(p) * LIMITS.RACE_SPEED_TOLERANCE
      : this.speedCapOf(p)) * dt;
    if (dist > maxDist) {
      // 상한을 넘으면 거부하지 않고 상한까지만 이동시킨다 — 거부하면 지터가
      // 큰 클라이언트가 영구히 뒤처지고, 그대로 받으면 순간이동이 된다.
      //
      // **경주 중이면 명백한 초과만 실격**으로 표시한다(벨 보상이 걸려 있다).
      // 지터로 조금 넘는 것과 순간이동을 구분하려고 1.5배를 기준으로 둔다 —
      // 이 값을 1.0으로 두면 프레임이 튄 사람이 억울하게 실격된다.
      // 초과 거리를 **누적**한다. 상한을 계속 밀어붙이는 클라이언트는 실격
      // 없이 정직한 주행보다 빠른데(클램프는 거부가 아니다), 누적을 보면 그
      // 상시 마진이 잡힌다. 한 번의 순간이동도 같은 기준으로 걸린다.
      this.raceAddOverage(token, dist - maxDist);
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
    // **운동장을 벗어나면 서버도 운동을 해제한다.**
    //
    // 시작할 때만 검사하면 변조한 클라이언트가 운동장 안에서 자전거를 켜고
    // 나가서 섬 전역을 자전거 상한으로 돌아다닐 수 있다 — 검사가 왕복 한 번을
    // 추가한 것에 그친다(리뷰 지적). 정직한 클라이언트도 같은 시점에 스스로
    // 해제하므로(world.gd의 _check_zone) 눈에 보이는 차이는 없다.
    let dismounted = null;
    const act = this.activities.get(p.activity || '');
    if (act && act.zone && !this.inZone(p.x, p.z, act.zone, LIMITS.ZONE_PAD)) {
      p.activity = '';
      p.trick = '';
      p.rideAnchor = null;
      dismounted = { token, activity: '', trick: '' };
    }
    // 축구 중에 공에 닿으면 밀어낸다(드리블). 차기는 별도 조작이지만, 걸어가
    // 부딪혔는데 공이 가만히 있으면 공처럼 보이지 않는다.
    this.dribble(p);
    this._markDirty();
    return { player: p, dismounted };
  }

  /**
   * 놀이기구 좌석의 **월드 좌표**. 클라이언트(scripts/park.gd)와 같은 계산이며,
   * 값은 data/world.json의 park가 단일 출처다.
   *
   * 왜 서버가 이걸 알아야 하나: 좌석 고정(rideAnchor)을 "요청 당시 위치"로 잡으면
   * **서버가 자리를 재배정할 때 어긋난다** — 그네 0번을 탭했는데 1번이 배정되면
   * 클라이언트는 1번 좌석으로 옮겨 앉지만 서버는 0번 자리에 묶어 둬서, 내 화면엔
   * 그네에 앉아 있고 남들 화면엔 두 그네 사이 허공에 낀 채로 보인다.
   * 좌석 좌표에서 유도하면 멱등해져서 trick이 바뀔 때마다 앵커가 흐르는 문제도
   * 없어진다(리뷰 지적).
   */
  seatPosition(id, seat) {
    const pk = this.park || {};
    // `|| 기본값`을 쓰지 않는다 — 0도 정당한 값이다(slot_inset: 0 = 테두리에 딱 서기).
    const val = (v, fallback) => (Number.isFinite(Number(v)) ? Number(v) : fallback);
    if (id === 'swing' && pk.swing) {
      const s = pk.swing;
      const count = Math.max(Math.floor(val(s.seats, 2)), 1);
      const gap = val(s.seat_gap, 1.6);
      return { x: val(s.x, 0), z: val(s.z, 0) + (seat - (count - 1) / 2) * gap };
    }
    if (id === 'carousel' && pk.carousel) {
      const c = pk.carousel;
      // 클라이언트(carousel_slots)가 int()로 자르므로 여기서도 자른다 —
      // 4.5를 넣으면 서버는 4.5, 클라는 4로 계산해 좌석 좌표가 갈린다.
      const slots = Math.max(Math.floor(val(c.slots, 4)), 1);
      // 폴백도 클라이언트(park.gd의 _slot_inset)와 **같은 값**이어야 한다 —
      // 키가 빠지면 좌석 반지름이 0.4유닛 어긋나 "내 화면엔 손잡이, 남 화면엔
      // 옆"이 된다(리뷰 지적).
      const r = val(c.radius, 2) - val(c.slot_inset, CAROUSEL_SLOT_INSET);
      const th = (Math.PI * 2 * seat) / slots;
      return { x: val(c.x, 0) + Math.cos(th) * r, z: val(c.z, 0) + Math.sin(th) * r };
    }
    if (id === 'seesaw' && pk.seesaw) {
      const s = pk.seesaw;
      const arm = val(s.arm, 1.6);
      return { x: val(s.x, 0) + (seat === 0 ? -arm : arm), z: val(s.z, 0) };
    }
    return null;
  }

  /** 활동별 이동 속도 상한(초당 유닛). 지터 여유는 걷기와 같은 비율로 준다. */
  // 지금 활동의 **명목 속도**(여유 배수를 곱하지 않은 값).
  speedOf(p) {
    const act = this.activities.get(p.activity || '');
    return act ? act.speed : LIMITS.WALK_SPEED;
  }

  speedCapOf(p) {
    return this.speedOf(p) * LIMITS.SPEED_TOLERANCE;
  }

  /**
   * 좌표가 그 id의 존 안인가. 모양은 클라이언트(_point_in_zone)와 같은 규칙:
   * radius(원) / rect(사각형) / ellipse(타원).
   *
   * pad를 주는 이유: 서버가 가진 좌표는 10Hz로 오므로 최대 한 틱 뒤처진다.
   * 여유가 없으면 존 경계에서 정상 조작이 간헐적으로 거부된다.
   */
  inZone(x, z, id, pad = 0) {
    for (const zone of this.zones) {
      if (String(zone.id) !== id) continue;
      const cx = Number(zone.x) || 0;
      const cz = Number(zone.z) || 0;
      const shape = String(zone.shape || 'circle');
      if (shape === 'rect') {
        const hx = (Number(zone.size_x) || 0) / 2 + pad;
        const hz = (Number(zone.size_z) || 0) / 2 + pad;
        if (Math.abs(x - cx) <= hx && Math.abs(z - cz) <= hz) return true;
      } else if (shape === 'ellipse') {
        const a = (Number(zone.a) || 1) + pad;
        const b = (Number(zone.b) || 1) + pad;
        const dx = (x - cx) / a;
        const dz = (z - cz) / b;
        if (dx * dx + dz * dz <= 1) return true;
      } else if (Math.hypot(x - cx, z - cz) <= (Number(zone.radius) || 0) + pad) {
        return true;
      }
    }
    return false;
  }

  /**
   * 운동 상태 변경. 남들 화면에 보여야 하므로 서버를 거친다.
   * kind가 빈 문자열이면 "그만두기"(원래 모습으로).
   */
  activity(token, kind, trick = '', now = Date.now()) {
    const p = this.players.get(token);
    if (!p) return { error: { code: 'not_joined', message: '먼저 join이 필요합니다' } };
    // 운동 전환은 전원 브로드캐스트 + 저장 표시라 도배되면 증폭이 크다.
    // 받는 쪽은 처음 보는 (운동, 기술) 조합마다 스프라이트 프레임을 새로
    // 만들기까지 한다(PlayerSprite) — 남의 클라이언트에 프레임 스파이크를 준다.
    const id = String(kind || '');
    if (id && !this.activities.has(id)) {
      return { error: { code: 'bad_activity', message: '알 수 없는 운동' } };
    }
    const act = id ? this.activities.get(id) : null;
    let wanted = String(trick || '');
    if (act && wanted) {
      if (act.freeTrick) {
        // **엄격하게 정규화한다.** 그대로 방송되고, 받는 쪽은 처음 보는
        // (운동, 기술) 조합마다 스프라이트 프레임을 새로 만든다 — 임의 문자열을
        // 허용하면 남의 클라이언트에 프레임 스파이크를 먹일 수 있다(리뷰 지적).
        // 형식은 "자리" 또는 "자리:진폭"이고 둘 다 유효 범위의 정수여야 한다.
        const m = /^(\d{1,2})(?::(\d{1,2}))?$/.exec(wanted);
        if (!m) {
          wanted = '';
        } else {
          const amps = this.parkCfg.swingAmpSteps.length;
          const seat = Number.parseInt(m[1], 10);
          const amp = m[2] === undefined ? null : Number.parseInt(m[2], 10);
          const seatOk = seat >= 0 && seat < Math.max(act.seats, 1);
          const ampOk = amp === null || (amp >= 0 && amp < amps);
          wanted = seatOk && ampOk
            ? (amp === null ? String(seat) : `${seat}:${amp}`)
            : '';
        }
      } else if (!act.tricks.has(wanted)) {
        wanted = '';
      }
    }
    // 자리가 있는 기구는 **서버가 빈 자리를 배정한다.** 클라이언트가 고른 자리가
    // 이미 찼으면 다른 빈 자리로 옮기고, 없으면 거절한다 — 그러지 않으면 두
    // 사람이 같은 좌석에 겹쳐 앉는다.
    if (act && act.seats > 0) {
      const taken = new Set();
      for (const other of this.players.values()) {
        if (other.token === token || !other.online || other.activity !== id) continue;
        taken.add(String(other.trick || '').split(':')[0]);
      }
      const parts = wanted.split(':');
      const rest = parts.length > 1 ? parts.slice(1).join(':') : '';
      let seat = Number.parseInt(parts[0], 10);
      if (!Number.isInteger(seat) || seat < 0 || seat >= act.seats || taken.has(String(seat))) {
        seat = -1;
        for (let i = 0; i < act.seats; i += 1) {
          if (!taken.has(String(i))) { seat = i; break; }
        }
      }
      if (seat < 0) {
        return { error: { code: 'seat_taken', message: '빈 자리가 없습니다' } };
      }
      wanted = rest ? `${seat}:${rest}` : String(seat);
    }
    // **아무것도 바뀌지 않으면 조용히 끝낸다.** 도배를 막는 실질적인 지점이
    // 여기다(같은 값을 최대 속도로 보내도 브로드캐스트가 나가지 않는다).
    if (id === (p.activity || '') && wanted === (p.trick || '')) {
      return { noop: true };
    }
    // **그만두기는 스로틀하지 않는다.** 클라이언트가 운동장을 벗어나 스스로
    // 해제를 보낼 때 그게 거부되면, 스로틀 응답이 권위 상태(자전거)를 되돌려
    // 보내 클라이언트가 다시 자전거를 탄다 — 경계에서 껐다 켜졌다 한다
    // (리뷰 지적). 해제는 상태를 줄이는 방향이고, 위 no-op 검사가 반복을 막는다.
    if (id !== '' && now - (p.lastActivityAt || 0) < LIMITS.ACTIVITY_MIN_INTERVAL_MS) {
      return { throttled: true };
    }
    // 운동장에서만 하는 운동은 **서버도** 위치를 본다. 클라이언트만 막으면
    // 변조한 클라이언트가 어디서나 자전거 속도 상한을 받는다.
    if (act && act.zone && !this.inZone(p.x, p.z, act.zone, LIMITS.ZONE_PAD)) {
      return { error: { code: 'not_in_zone', message: '그 장소에서만 할 수 있습니다' } };
    }
    p.lastActivityAt = now;
    p.activity = id;
    p.trick = id ? wanted : '';
    // **탄 자리에 위치를 고정한다.** 좌석 배정으로 겹침만 막고 좌표는 클라이언트
    // 주장을 그대로 받으면, 놀이기구에 앉은 채로 섬을 돌아다닐 수 있다.
    //
    // 이 대입은 **검증을 모두 통과한 뒤**에 해야 한다. 예전에는 좌석 배정
    // 단계에서 먼저 박아서, 스로틀·존 검사로 거부된 요청도 앵커를 남겼다 —
    // 타고 있지도 않은데 그 지점 0.6유닛 밖으로 영구히 못 나갔다(리뷰 지적).
    // 앵커는 **좌석 좌표**에서 유도한다(요청 당시 위치가 아니다 — seatPosition 주석).
    const seated = act && act.seats > 0;
    if (seated) {
      const seatNo = Number.parseInt(String(wanted).split(':')[0], 10) || 0;
      const at = this.seatPosition(id, seatNo);
      p.rideAnchor = at || { x: p.x, z: p.z };
      if (at) {
        // 좌석 좌표는 **검증을 거쳐야 한다.** 이 값이 p.x/p.z로 들어가고 그건
        // 디스크에 저장된다 — world.json의 park 좌표 오타 하나로 플레이어
        // 저장 위치가 섬 밖으로 영구히 옮겨질 수 있다(리뷰 지적).
        const safe = this.clampPos(at.x, at.z);
        at.x = safe.x;
        at.z = safe.z;
        // **위치도 배정된 자리로 맞춘다.** 앵커만 옮기면 서버 좌표는 옛 자리에
        // 남는다 — 타는 동안 클라이언트는 이동을 보내지 않고(input_locked),
        // 보낸다 해도 속도 상한(1.28 u/s)으로는 좌석 간격을 넘는 데 십수
        // 패킷이 걸린다. 그 사이 남들 화면에는 **다른 사람과 겹친 자리**에
        // 서 있는 것으로 보인다(리뷰 지적).
        // 좌석 좌표는 이미 존 검사를 통과한 고정값이라 순간이동 악용이 아니다.
        const nx = Math.round(at.x * 100) / 100;
        const nz = Math.round(at.z * 100) / 100;
        // 좌석이 그대로면(그네 진폭만 바꾼 경우) 방송할 이유가 없다.
        if (p.x !== nx || p.z !== nz) {
          p.x = nx;
          p.z = nz;
          p.moved = true;
        }
      }
    } else {
      p.rideAnchor = null;
    }
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

  /**
   * 놀이기구를 민다(액션 버튼). what: 'seesaw' | 'carousel'.
   * **타고 있는 사람만** 밀 수 있다 — 지나가면서 남의 기구를 흔들 수는 없다.
   */
  pushRide(token, what, now = Date.now()) {
    const p = this.players.get(token);
    if (!p) return { error: { code: 'not_joined', message: '먼저 join이 필요합니다' } };
    if (p.activity !== what) {
      return { error: { code: 'not_riding', message: '타고 있을 때만 밀 수 있습니다' } };
    }
    if (what === 'seesaw') {
      if (now - (p.lastPushAt || 0) < this.parkCfg.seesawPushInterval) return { throttled: true };
      p.lastPushAt = now;
      // 자리 0은 -각, 자리 1은 +각 방향으로 누른다.
      const seat = Number.parseInt(String(p.trick || '0').split(':')[0], 10) || 0;
      this.seesaw.vel += (seat === 0 ? 1 : -1) * this.parkCfg.seesawPush;
      return { pushed: 'seesaw' };
    }
    if (what === 'carousel') {
      if (now - (p.lastPushAt || 0) < this.parkCfg.carouselPushInterval) return { throttled: true };
      p.lastPushAt = now;
      this.carousel.speed = Math.min(
        this.carousel.speed + this.parkCfg.carouselPush, this.parkCfg.carouselMaxSpeed);
      return { pushed: 'carousel' };
    }
    return { error: { code: 'bad_ride', message: '알 수 없는 놀이기구' } };
  }

  /** 타고 있는 사람이 있는지. 아무도 없으면 물리를 돌리지 않는다. */
  hasRider(kind) {
    for (const p of this.players.values()) {
      if (p.online && p.activity === kind) return true;
    }
    return false;
  }

  /**
   * 놀이기구 물리 한 스텝. 바뀐 값이 있으면 돌려준다(없으면 null).
   * 시소는 중력으로 수평으로 돌아오고, 뺑뺑이는 마찰로 느려진다.
   */
  tickPark(dt) {
    const before = { seesaw: this.seesaw.angle, carousel: this.carousel.angle };
    const cfg = this.parkCfg;
    // 시소: 스프링-감쇠. 아무도 안 타면 수평으로 돌려놓는다.
    if (this.hasRider('seesaw') || Math.abs(this.seesaw.angle) > 0.001 || Math.abs(this.seesaw.vel) > 0.001) {
      this.seesaw.vel -= this.seesaw.angle * cfg.seesawGravity * dt;
      this.seesaw.vel *= Math.pow(cfg.seesawDamping, dt);
      this.seesaw.angle += this.seesaw.vel * dt;
      if (this.seesaw.angle > cfg.seesawMaxAngle) {
        this.seesaw.angle = cfg.seesawMaxAngle;
        this.seesaw.vel = -Math.abs(this.seesaw.vel) * 0.3;
      } else if (this.seesaw.angle < -cfg.seesawMaxAngle) {
        this.seesaw.angle = -cfg.seesawMaxAngle;
        this.seesaw.vel = Math.abs(this.seesaw.vel) * 0.3;
      }
      if (!this.hasRider('seesaw') && Math.abs(this.seesaw.angle) < 0.01 && Math.abs(this.seesaw.vel) < 0.05) {
        this.seesaw.angle = 0;
        this.seesaw.vel = 0;
      }
    }
    // 뺑뺑이: 밀면 빨라지고 마찰로 느려진다.
    if (this.carousel.speed > 0.001) {
      this.carousel.angle = (this.carousel.angle + this.carousel.speed * dt) % (Math.PI * 2);
      this.carousel.speed *= Math.pow(this.parkCfg.carouselFriction, dt);
      if (this.carousel.speed < 0.05) this.carousel.speed = 0;
    }
    const changed = Math.abs(before.seesaw - this.seesaw.angle) > 0.0005
      || Math.abs(before.carousel - this.carousel.angle) > 0.0005;
    return changed ? this.parkState() : null;
  }

  parkState() {
    return {
      seesaw: Math.round(this.seesaw.angle * 1000) / 1000,
      carousel: Math.round(this.carousel.angle * 1000) / 1000,
      carouselSpeed: Math.round(this.carousel.speed * 100) / 100,
    };
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
    // 점수를 함께 싣는다 — docs/protocol.md가 `ball`을 {x, z, score}로 적고
    // 클라이언트는 이 값을 존 라벨에 "0 : 0"으로 보여 준다(골 토스트는 지나가
    // 버려서, 지금 몇 대 몇인지 알 방법이 그것뿐이다).
    return this.ball.active
      ? { x: this.ball.x, z: this.ball.z, score: { ...this.score } }
      : null;
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
    // 낚시터·벌레 스폿은 무엇이 잡히는지를 **여기서** 정한다. 지금 시간·월에
    // 맞는 항목이 하나도 없으면(예: 겨울 밤의 벌레) 잡히지 않는다 — 그 경우
    // 재생 쿨다운을 걸지 않는다(잡을 수 없는 자리에 벌을 줄 이유가 없다).
    let item = g.item;
    if (!item) {
      item = this.rollCatch(g.kind, now);
      if (!item) {
        return { error: { code: 'nothing_here', message: '지금은 아무것도 없습니다' } };
      }
    }
    p.lastGatherAt = now;
    g.availableAt = now + g.respawnSec * 1000;
    p.inventory[item] = Number(p.inventory[item] || 0) + 1;
    this.recordDex(p, item);
    this._markDirty();
    return { inventory: p.inventory, gathered: { index: g.index, item, availableAt: g.availableAt } };
  }

  // 이 아이템이 확률 테이블에서 **시간·월 제한**을 받는지. 받으면 그 항목을
  // 돌려준다(부탁 후보에서 빼는 데 쓴다).
  catchEntryFor(item) {
    for (const rows of Object.values(this.catchTables)) {
      for (const r of rows) {
        if (r.item !== item) continue;
        if (r.hours || r.months) return r;
      }
    }
    return null;
  }

  // 지금(시간·월) 잡을 수 있는 항목만 남긴다.
  //
  // **경계에 여유를 두지 않는다.** 클라이언트는 자기 시계로 "지금 잡히는 것"을
  // 표시할 뿐이고 실제 판정은 여기서만 하므로, 여유를 주면 그만큼 조건이 느슨해질
  // 뿐이다(기기 시계를 앞당겨 실러캔스를 잡는 경로를 열어 준다).
  catchableEntries(kind, now = Date.now()) {
    const table = this.catchTables[String(kind)] || [];
    const d = new Date(now);
    const hour = d.getHours();
    const month = d.getMonth() + 1;
    return table.filter((r) => {
      if (r.months && !r.months.includes(month)) return false;
      if (!r.hours) return true;
      const [from, to] = r.hours;
      // 시작 > 끝이면 자정을 넘는 구간(예: 19~5시).
      return from <= to ? (hour >= from && hour < to) : (hour >= from || hour < to);
    });
  }

  // 가중치 추첨. 조건에 맞는 항목이 없으면 빈 문자열.
  rollCatch(kind, now = Date.now(), rnd = Math.random) {
    const rows = this.catchableEntries(kind, now);
    const total = rows.reduce((sum, r) => sum + r.weight, 0);
    if (total <= 0) return '';
    let pick = rnd() * total;
    for (const r of rows) {
      pick -= r.weight;
      if (pick < 0) return r.item;
    }
    return rows[rows.length - 1].item;
  }

  // 지금 캘 수 없는 채집물 목록(스냅샷·브로드캐스트용).
  gatherableStates(now = Date.now()) {
    return this.gatherables
      .filter((g) => now < g.availableAt)
      .map((g) => ({ index: g.index, availableAt: g.availableAt }));
  }

  // ---- 달리기 경주 (서버 권위) ----

  raceOpen() {
    return this.raceCfg.checkpoints.length >= 2;
  }

  // 트랙 밴드(달리는 레인) 안인지. 달걀 왜곡은 무시하고 타원 비율로 본다 —
  // 판정에 쓰는 것은 "인필드를 가로질렀는가"이고, 그 정도 정확도로 충분하다.
  onTrackBand(x, z) {
    const tr = (this.playgroundCfg || {}).track || {};
    const a = Number(tr.outer_a) || 10.6;
    const b = Number(tr.outer_b) || 7.232;
    const cx = Number(tr.x) || 0;
    const cz = Number(tr.z) || 0;
    const ratio = Math.hypot((x - cx) / a, (z - cz) / b);
    return ratio >= this.raceCfg.bandInner && ratio <= this.raceCfg.bandOuter;
  }

  // 남에게 보낼 상태. **변할 때만** 보낸다(공·놀이기구와 같은 원칙).
  raceState(now = Date.now()) {
    const runners = [];
    for (const [token, r] of this.race.runners) {
      const p = this.players.get(token);
      runners.push({
        token,
        name: p ? p.name : '',
        lap: r.lap,
        cp: r.cp,
        rank: r.rank,
        finishMs: r.finishMs,
        dq: r.dq,
      });
    }
    // 순위 → 진행도 순으로 정렬해 클라이언트가 그대로 그릴 수 있게 한다.
    runners.sort((a, b) => {
      if (a.rank && b.rank) return a.rank - b.rank;
      if (a.rank) return -1;
      if (b.rank) return 1;
      return (b.lap * 100 + b.cp) - (a.lap * 100 + a.cp);
    });
    return {
      phase: this.race.phase,
      // 남은 시간은 서버 시계 기준 밀리초로 준다 — 절대 시각을 주면 기기 시계
      // 차이만큼 어긋난다.
      remainMs: Math.max(0, this.race.endsAt - now),
      laps: this.raceCfg.laps,
      runners,
    };
  }

  raceJoin(token, now = Date.now()) {
    const p = this.players.get(token);
    if (!p) return { error: { code: 'not_joined', message: '먼저 join이 필요합니다' } };
    // 참가/포기도 간격 제한을 받는다 — 한 클라이언트의 1메시지가 전원에게
    // 방송되는 증폭 경로이고, idle에서 연타하면 phase 전이가 실제로 반복된다.
    if (now - (p.lastRaceAt || 0) < LIMITS.RACE_MIN_INTERVAL_MS) {
      return { error: { code: 'rate_limited', message: '너무 빠릅니다' } };
    }
    p.lastRaceAt = now;
    if (!this.raceOpen()) return { error: { code: 'race_closed', message: '경주를 열 수 없습니다' } };
    // 운동장 안에서만 참가할 수 있다 — 섬 반대편에서 참가하면 출발선까지
    // 순간이동하거나, 시작하자마자 실격이다.
    if (!this.inZone(p.x, p.z, 'playground')) {
      return { error: { code: 'not_in_zone', message: '운동장에서만 참가할 수 있습니다' } };
    }
    if (this.race.phase !== 'idle' && this.race.phase !== 'lobby') {
      return { error: { code: 'race_busy', message: '지금은 참가할 수 없습니다' } };
    }
    if (this.race.phase === 'idle') {
      this.race.phase = 'lobby';
      this.race.endsAt = now + this.raceCfg.lobbySec * 1000;
      this.race.seq += 1;
    }
    this.race.runners.set(token, { cp: -1, lap: 0, rank: 0, finishMs: 0, dq: false, reward: 0 });
    return { state: this.raceState(now) };
  }

  raceLeave(token, now = Date.now(), { rateLimit = true } = {}) {
    const p = this.players.get(token);
    if (rateLimit && p && now - (p.lastRaceAt || 0) < LIMITS.RACE_MIN_INTERVAL_MS) {
      return { error: { code: 'rate_limited', message: '너무 빠릅니다' } };
    }
    if (!this.race.runners.has(token)) {
      return { error: { code: 'not_racing', message: '참가 중이 아닙니다' } };
    }
    if (p && rateLimit) p.lastRaceAt = now;
    this.race.runners.delete(token);
    if (p) p.rideAnchor = null;
    // 아무도 안 남으면 즉시 되돌린다 — 빈 대기실이 카운트다운을 시작하면
    // 지나가던 사람이 영문 모를 숫자를 본다.
    //
    // **단 결과 국면(finished)에서는 리셋하지 않는다.** 15초 대기는 보상 연타를
    // 막는 쿨다운인데, 마지막 참가자가 포기 버튼을 누르면 그게 사라졌다.
    if (this.race.runners.size === 0 && this.race.phase !== 'finished') this._raceReset();
    return { state: this.raceState(now) };
  }

  // 접속이 끊겼을 때(전송 계층이 호출). 간격 제한을 적용하지 않는다 — 끊김은
  // 사용자 조작이 아니고, 남겨두면 굳은 좌표의 러너가 경주를 90초 동안 막는다.
  raceDrop(token, now = Date.now()) {
    if (!this.race.runners.has(token)) return false;
    this.raceLeave(token, now, { rateLimit: false });
    return true;
  }

  // 출발선 부근에 참가자를 나란히 세운다. 결승선(0번)과 그 이전 체크포인트를
  // 잇는 방향으로 조금씩 밀어 겹치지 않게 한다.
  _raceLineUp(now) {
    const cps = this.raceCfg.checkpoints;
    if (cps.length === 0) return;
    const start = cps[0];
    const prev = cps[cps.length - 1];
    const dx = start.x - prev.x;
    const dz = start.z - prev.z;
    const len = Math.hypot(dx, dz) || 1;
    // 출발선과 직교한 방향(트랙 폭 방향)으로 벌린다.
    const nx = -dz / len;
    const nz = dx / len;
    let i = 0;
    for (const token of this.race.runners.keys()) {
      const p = this.players.get(token);
      if (!p) continue;
      const offset = (i - (this.race.runners.size - 1) / 2) * 0.7;
      // 출발선 **직전**에 세운다 — 선 위에 세우면 시작과 동시에 통과 판정이
      // 나서 첫 바퀴가 공짜가 된다.
      const back = 0.9;
      const pos = this.clampPos(
        start.x - (dx / len) * back + nx * offset,
        start.z - (dz / len) * back + nz * offset);
      p.x = Math.round(pos.x * 100) / 100;
      p.z = Math.round(pos.z * 100) / 100;
      p.moved = true;
      p.rideAnchor = { x: p.x, z: p.z };
      p.lastMoveAt = now;
      i += 1;
    }
  }

  _raceReset() {
    for (const token of this.race.runners.keys()) {
      const p = this.players.get(token);
      if (p) p.rideAnchor = null;
    }
    this.race.phase = 'idle';
    this.race.endsAt = 0;
    this.race.startedAt = 0;
    this.race.runners.clear();
  }

  // 속도 상한을 넘긴 이동이 감지되면 그 주행을 무효로 표시한다.
  //
  // 되돌리지 않는 이유: 벨 보상이 걸려 있어 "상한을 넘겨 앞서 나가기"를 막아야
  // 하지만, 지터가 큰 클라이언트를 즉시 실격시키면 억울하다 — 그래서 상한
  // 초과 **거리**가 명백할 때만(보정량이 한 틱 이동거리보다 클 때) 표시한다.
  // 초과 거리를 누적하고 기준을 넘으면 실격으로 표시한다.
  raceAddOverage(token, over) {
    const r = this.race.runners.get(token);
    if (!r || this.race.phase !== 'running' || r.rank > 0 || r.dq) return false;
    r.overage = (r.overage || 0) + Math.max(0, over);
    if (r.overage < LIMITS.RACE_OVERAGE_DQ) return false;
    r.dq = true;
    return true;
  }

  raceFlagSpeeding(token) {
    const r = this.race.runners.get(token);
    if (!r || this.race.phase !== 'running' || r.rank > 0) return false;
    r.dq = true;
    return true;
  }

  // 서버 틱에서 호출된다. 상태가 바뀌면 true.
  tickRace(now = Date.now()) {
    const cfg = this.raceCfg;
    let changed = false;
    switch (this.race.phase) {
      case 'lobby':
        if (now >= this.race.endsAt) {
          if (this.race.runners.size === 0) { this._raceReset(); return true; }
          this.race.phase = 'countdown';
          this.race.endsAt = now + cfg.countdownSec * 1000;
          for (const r of this.race.runners.values()) {
            r.cp = -1; r.lap = 0; r.rank = 0; r.finishMs = 0; r.dq = false;
            r.reward = 0; r.offTrack = false; r.overage = 0;
          }
          // **출발선에 세운다.** 카운트다운 동안 아무 제약이 없으면 트랙
          // 반대편에 있던 사람이 출발선까지 1/4바퀴(약 11유닛, 걷기 2.6초)를
          // 더 가야 해서 순위가 그것으로 갈린다. 놀이기구 좌석과 같은 방식
          // (rideAnchor)으로 묶어 두고 running에서 푼다.
          this._raceLineUp(now);
          changed = true;
        }
        break;
      case 'countdown':
        if (now >= this.race.endsAt) {
          this.race.phase = 'running';
          this.race.startedAt = now;
          this.race.endsAt = now + cfg.timeoutSec * 1000;
          // 출발 잠금을 푼다(카운트다운 동안 출발선에 묶여 있었다).
          for (const token of this.race.runners.keys()) {
            const p = this.players.get(token);
            if (p) p.rideAnchor = null;
          }
          changed = true;
        }
        break;
      case 'running': {
        for (const [token, r] of this.race.runners) {
          if (r.rank > 0 || r.dq) continue;
          const p = this.players.get(token);
          // 접속이 끊긴 참가자는 좌표가 굳는다 — 진행 판정에서 뺀다.
          if (!p || !p.online) continue;
          // **다음 체크포인트만** 본다. 순서를 어기면 진행하지 않는다 — 되돌리면
          // 트랙 밖으로 한 번 튀는 것만으로 순위가 뒤집힌다.
          const nextIndex = (r.cp + 1) % cfg.checkpoints.length;
          const cp = cfg.checkpoints[nextIndex];
          const near = Math.hypot(p.x - cp.x, p.z - cp.z) <= cfg.radius;
          // **밴드 이탈 감지.** 체크포인트 8개로도 인필드 직선 횡단이 2% 이득이
          // 남고, 4개였을 때는 9%였다 — "트랙을 안 도는 것"이 최적 전략이 되면
          // 경주가 아니다. 두 체크포인트 사이에 트랙 밖으로 나가면 다음 통과를
          // 인정하지 않고, 밴드로 돌아와 체크포인트에서 떨어지면 풀린다.
          if (!this.onTrackBand(p.x, p.z)) {
            r.offTrack = true;
          } else if (!near) {
            r.offTrack = false;
          }
          if (!near || r.offTrack) continue;
          // 출발선(0번)에 **마지막 체크포인트에서 도달하면** 한 바퀴다.
          // cp가 -1인 상태에서의 0번 통과는 출발이므로 세지 않는다(별도
          // started 플래그를 두면 리셋을 빼먹기 쉽다).
          const wasStart = r.cp === -1;
          r.cp = nextIndex;
          if (nextIndex === 0 && !wasStart) r.lap += 1;
          if (r.lap >= cfg.laps) {
            r.finishMs = now - this.race.startedAt;
            r.rank = 1 + [...this.race.runners.values()].filter((o) => o.rank > 0).length;
          }
          changed = true;
        }
        // 끊긴 사람은 "달리는 중"으로 세지 않는다 — 그러지 않으면 완주자가
        // 있어도 타임아웃 90초를 다 채운다(리뷰 지적).
        const active = [...this.race.runners.entries()].filter(([token, r]) => {
          if (r.rank > 0 || r.dq) return false;
          const p = this.players.get(token);
          return !!p && p.online;
        });
        if (active.length === 0 || now >= this.race.endsAt) {
          this._raceFinish(now);
          changed = true;
        }
        break;
      }
      case 'finished':
        if (now >= this.race.endsAt) { this._raceReset(); changed = true; }
        break;
      default:
        break;
    }
    return changed;
  }

  // 결과 정산. **참가자가 1명이면 완주 보상만 준다** — 혼자 돌려 1등 보상을
  // 반복해서 긁는 경로를 막는다.
  _raceFinish(now) {
    const cfg = this.raceCfg;
    // **"혼자면 완주 보상만"은 연결 수가 아니라 완주자 수로 본다.** 연결 수를
    // 보면 탭 두 개로 참가한 뒤 하나만 달려도 1등 보상이 나갔다(리뷰 지적).
    const finishers = [...this.race.runners.values()].filter((r) => r.rank > 0 && !r.dq).length;
    const solo = finishers < 2;
    for (const [token, r] of this.race.runners) {
      const p = this.players.get(token);
      if (!p || r.dq || r.rank === 0) continue;
      let reward = cfg.finishReward;
      if (!solo && r.rank <= cfg.rewards.length) reward = cfg.rewards[r.rank - 1];
      r.reward = reward;
      p.bells = Math.max(0, Math.floor(p.bells + reward));
    }
    this.race.phase = 'finished';
    this.race.endsAt = now + cfg.finishedSec * 1000;
    this._markDirty();
  }

  // 결과(보상 포함) — finished 상태에서 클라이언트에 보낸다.
  raceResults() {
    const out = [];
    for (const [token, r] of this.race.runners) {
      const p = this.players.get(token);
      out.push({
        token, name: p ? p.name : '', rank: r.rank, finishMs: r.finishMs,
        dq: r.dq, reward: r.reward || 0, bells: p ? p.bells : 0,
      });
    }
    out.sort((a, b) => (a.rank || 99) - (b.rank || 99));
    return out;
  }

  // ---- 이웃 동물(NPC) 부탁 ----

  // 오늘 날짜 문자열(서버 시계). 하루 1회 제한의 기준이다 — 클라이언트 날짜를
  // 쓰면 기기 시계를 넘겨 부탁을 무한 반복할 수 있다.
  dayKey(now = Date.now()) {
    const d = new Date(now);
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  }

  // (토큰, NPC, 날짜)의 **결정적** 해시로 부탁을 고른다.
  //
  // 왜 결정적인가: 서버가 재시작해도, 스냅샷을 다시 받아도 같은 부탁이어야
  // 한다. 무작위로 고르면 "가져왔는데 다른 걸 요구한다"가 되고, 상태를 따로
  // 저장하면 세이브 스키마가 늘어난다.
  npcRequest(token, npcId, now = Date.now()) {
    const npc = this.npcs.get(String(npcId));
    if (!npc || npc.requests.length === 0) return null;
    const seed = `${token}|${npcId}|${this.dayKey(now)}`;
    let h = 2166136261;
    for (let i = 0; i < seed.length; i++) {
      h ^= seed.charCodeAt(i);
      h = Math.imul(h, 16777619) >>> 0;
    }
    return npc.requests[h % npc.requests.length];
  }

  // 부탁 보상 = 판매가 총합 × reward_multiplier. **서버가 계산한다** —
  // 클라이언트가 금액을 주장하면 벨을 임의로 불릴 수 있다.
  npcReward(request) {
    if (!request) return 0;
    const price = this.priceOf(request.item);
    return Math.max(0, Math.floor(price * request.count * this.npcRewardMultiplier));
  }

  // 이 플레이어가 보는 NPC 상태(welcome/snapshot과 정산 응답에 함께 실린다).
  npcState(token, now = Date.now()) {
    const p = this.players.get(token);
    const today = this.dayKey(now);
    const out = {};
    for (const npc of this.npcs.values()) {
      const request = this.npcRequest(token, npc.id, now);
      const done = !!(p && p.npcDone && p.npcDone[npc.id] === today);
      out[npc.id] = {
        done,
        request: request ? { item: request.item, count: request.count } : null,
        reward: request ? this.npcReward(request) : 0,
      };
    }
    return out;
  }

  // 부탁한 물건을 건넨다. 가방·벨의 단일 출처가 서버이므로 여기서 정산한다.
  npcDeliver(token, npcId, now = Date.now()) {
    const p = this.players.get(token);
    if (!p) return { error: { code: 'not_joined', message: '먼저 join이 필요합니다' } };
    if (now - (p.lastNpcAt || 0) < LIMITS.NPC_MIN_INTERVAL_MS) {
      return { error: { code: 'rate_limited', message: '너무 빠릅니다' }, state: this.npcState(token, now) };
    }
    // **실패도 간격 제한에 넣는다.** 성공만 기록하면 too_far/unknown_npc를
    // 무한 연타할 수 있고, 다른 핸들러(채집·판매)와 규칙이 달라진다.
    p.lastNpcAt = now;
    const npc = this.npcs.get(String(npcId));
    if (!npc) {
      return { error: { code: 'unknown_npc', message: '없는 이웃입니다' }, state: this.npcState(token, now) };
    }
    const today = this.dayKey(now);
    if (p.npcDone[npc.id] === today) {
      // **거절에도 현재 상태를 싣는다.** 세션을 켜둔 채 자정을 넘기면
      // 클라이언트가 어제 상태로 굳어 "오늘은 충분해"만 보여준다.
      return { error: { code: 'already_done', message: '오늘은 이미 도와줬습니다' }, state: this.npcState(token, now) };
    }
    // **거리를 검사한다.** 없으면 섬 반대편에서 부탁을 정산할 수 있다. 기준은
    // 데이터의 고정 좌표이고, 배회 반경 + 여유(NPC_TALK_PAD)만큼 넉넉히 준다.
    const dist = Math.hypot(p.x - npc.x, p.z - npc.z);
    if (dist > npc.wanderRadius + LIMITS.NPC_TALK_PAD) {
      return { error: { code: 'too_far', message: '이웃에게서 너무 멉니다' }, state: this.npcState(token, now) };
    }
    const request = this.npcRequest(token, npc.id, now);
    if (!request) {
      return { error: { code: 'no_request', message: '지금은 부탁이 없습니다' }, state: this.npcState(token, now) };
    }
    const have = Number(p.inventory[request.item] || 0);
    if (have < request.count) {
      return {
        error: { code: 'not_enough', message: '물건이 부족합니다' },
        // 부족한 수를 알려 준다 — "부족하다"만 말하면 가방 화면을 왕복해야 한다.
        need: { item: request.item, count: request.count, have },
        state: this.npcState(token, now),
      };
    }
    const left = have - request.count;
    if (left <= 0) delete p.inventory[request.item];
    else p.inventory[request.item] = left;
    const reward = this.npcReward(request);
    p.bells = Math.max(0, Math.floor(p.bells + reward));
    p.npcDone[npc.id] = today;
    this._markDirty();
    return {
      npc: npc.id,
      reward,
      given: { item: request.item, count: request.count },
      bells: p.bells,
      inventory: p.inventory,
      state: this.npcState(token, now),
    };
  }

  // ---- 도감 ----

  // 획득을 도감에 누적한다. **팔거나 버려도 줄지 않는다** — 도감은 "무엇을
  // 가졌는지"가 아니라 "무엇을 만났는지"의 기록이다.
  recordDex(p, item, count = 1) {
    if (!p || !item) return;
    if (!p.dex) p.dex = {};
    p.dex[item] = Number(p.dex[item] || 0) + count;
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
    // 누가 버렸는지 남긴다 — 자기가 버린 것을 자기가 줍는 경우를 도감에서
    // 빼려면 필요하다(버리고 줍기 반복으로 숫자를 올릴 수 있다).
    const entity = { id: randomUUID(), item: id, x: pos.x, z: pos.z, at: Date.now(), by: token };
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
    // 남이 버린 것을 주워도 "만난 것"은 만난 것이다 — 도감에 누적한다.
    // **단 내가 버린 것을 내가 주우면 세지 않는다**: 버리고 줍기를 반복해
    // 도감 숫자를 얼마든지 올릴 수 있다(리뷰 지적).
    if (entity.by !== token) this.recordDex(p, entity.item);
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
      // 놀이기구 상태(시소 기울기·뺑뺑이 각도). 새로 들어온 사람도 맞춰야 한다.
      park: this.parkState(),
      // 공은 축구를 하는 사람이 있을 때만 의미가 있다.
      ball: this.ball.active
        ? { x: this.ball.x, z: this.ball.z, score: { ...this.score } }
        : null,
      // by(버린 사람)를 함께 보낸다 — 클라이언트가 "내가 버린 것"을 도감에서
      // 빼려면 재접속·resync 뒤에도 그 정보가 있어야 한다(없으면 규칙이 두
      // 곳에서 갈린다).
      items: [...this.items.values()].map((i) => ({
        id: i.id, item: i.item, x: i.x, z: i.z, by: i.by || '',
      })),
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
        // NPC 부탁 완료 날짜와 도감은 진행도다 — 재시작해도 남아야 한다.
        npcDone: p.npcDone || {}, dex: p.dex || {},
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
        // 없으면 빈 값 — 옛 상태 파일에는 이 필드가 없다(마이그레이션 불필요).
        npcDone: p.npcDone && typeof p.npcDone === 'object' ? p.npcDone : {},
        dex: p.dex && typeof p.dex === 'object' ? p.dex : {},
        online: false,
        lastMoveAt: 0, lastChatAt: 0, lastEmoteAt: 0, lastGatherAt: 0, lastSellAt: 0,
        lastNpcAt: 0,
      });
    }
    for (const i of data.items || []) {
      if (!i || !i.id || !this.itemIds.has(String(i.item))) continue;
      const pos = this.clampPos(i.x, i.z);
      this.items.set(String(i.id), {
        id: String(i.id), item: String(i.item), x: pos.x, z: pos.z,
        at: Number(i.at) || 0,
        // 옛 상태 파일에는 by가 없다 — 없으면 "남이 버린 것"으로 본다.
        by: WorldState.validToken(i.by) ? String(i.by) : '',
      });
    }
    for (const g of data.gatherables || []) {
      const target = this.gatherables[Number(g.index)];
      if (target) target.availableAt = Number(g.availableAt) || 0;
    }
    console.log(`[world] 상태 복원: 캐릭터 ${this.players.size}명, 월드 아이템 ${this.items.size}개`);
  }
}
