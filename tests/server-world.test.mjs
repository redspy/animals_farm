import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldState, LIMITS } from '../server/world.js';

// 서버 규칙(docs/protocol.md §3) 테스트. 전송(WebSocket)과 분리돼 있어 소켓
// 없이 규칙만 검증할 수 있다. persist:false로 디스크를 건드리지 않는다.

const TOKEN_A = '11111111-1111-4111-8111-111111111111';
const TOKEN_B = '22222222-2222-4222-8222-222222222222';

function fresh() {
  return new WorldState({ persist: false });
}

test('토큰 형식이 아니면 join 거부', () => {
  const w = fresh();
  assert.equal(w.join({ token: 'nope', name: '가', preset: 'f1' }).error.code, 'bad_token');
});

test('이름은 12자로 잘리고 제어문자는 제거된다', () => {
  const w = fresh();
  const r = w.join({ token: TOKEN_A, name: '  가나다라마바사아자차카타파하\n ', preset: 'f1' });
  assert.equal(r.player.name.length, LIMITS.NAME_MAX);
  assert.ok(!r.player.name.includes('\n'));
});

test('빈 이름은 거부', () => {
  const w = fresh();
  assert.equal(w.join({ token: TOKEN_A, name: '   ', preset: 'f1' }).error.code, 'bad_name');
});

test('월드 경계를 넘는 좌표는 클램프된다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  // 속도 상한과 무관하게 경계 밖으로는 못 간다 — 시간을 넉넉히 줘서 상한을 비활성화
  const r = w.move(TOKEN_A, { x: 99999, z: 99999 }, Date.now() + 60_000);
  assert.ok(r.player.x <= w.sizeX / 2 + 0.001, `x=${r.player.x}`);
  assert.ok(r.player.z <= w.sizeZ / 2 + 0.001, `z=${r.player.z}`);
});

test('순간이동은 속도 상한까지만 반영된다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  const t0 = 1_000_000;
  w.move(TOKEN_A, { x: 0, z: 0 }, t0);
  // 100ms 뒤 10칸 이동 시도 → 상한(4.2*1.6*0.1 = 0.672)까지만
  const r = w.move(TOKEN_A, { x: 10, z: 0 }, t0 + 100);
  assert.ok(r.player.x > 0 && r.player.x < 1, `상한 초과: x=${r.player.x}`);
});

test('이동 메시지 레이트 리밋', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  const t0 = 2_000_000;
  w.move(TOKEN_A, { x: 0.1, z: 0 }, t0);
  const r = w.move(TOKEN_A, { x: 0.2, z: 0 }, t0 + 10);
  assert.equal(r.throttled, true);
});

test('채팅은 200자로 잘리고 초당 2건으로 제한된다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  const t0 = 3_000_000;
  const r1 = w.chat(TOKEN_A, 'ㄱ'.repeat(500), t0);
  assert.equal(r1.chat.text.length, LIMITS.CHAT_MAX);
  assert.equal(w.chat(TOKEN_A, '또', t0 + 100).error.code, 'rate_limited');
  assert.ok(w.chat(TOKEN_A, '이제 됨', t0 + 600).chat);
});

test('화이트리스트에 없는 이모티콘은 거부', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  assert.equal(w.emote(TOKEN_A, '<script>', 4_000_000).error.code, 'bad_emote');
  assert.ok(w.emote(TOKEN_A, 'happy', 4_001_000).emote);
});

// 채집물 하나를 골라 그 앞에 캐릭터를 세운다.
function standAt(w, token, g) {
  const p = w.players.get(token);
  p.x = g.x;
  p.z = g.z;
  return p;
}

test('채집은 서버가 사거리·재생 상태를 검증한다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  const g = w.gatherables[0];
  assert.ok(g, 'data/gatherables.json을 서버도 읽는다');

  // 멀리 있으면 거부 — 예전에는 아무 데서나 "캤다"고 주장할 수 있었다.
  const p = w.players.get(TOKEN_A);
  p.x = g.x + 50;
  p.z = g.z;
  assert.equal(w.gather(TOKEN_A, g.index, 5_000_000).error.code, 'too_far');

  standAt(w, TOKEN_A, g);
  const ok = w.gather(TOKEN_A, g.index, 5_100_000);
  assert.equal(ok.inventory[g.item], 1, '아이템 종류는 데이터에서 읽는다');
  assert.equal(ok.gathered.index, g.index);

  // 재생 전에는 다시 캘 수 없다(레이트 리밋을 지나되 재생 시간 안인 시점).
  assert.equal(w.gather(TOKEN_A, g.index, 5_100_000 + 1000).error.code, 'not_grown');
  // 재생 시간이 지나면 다시 캘 수 있다.
  assert.ok(w.gather(TOKEN_A, g.index, 5_100_000 + g.respawnSec * 1000 + 10).inventory[g.item] === 2);
});

test('없는 채집물 인덱스와 연타는 거부된다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  assert.equal(w.gather(TOKEN_A, 9999, 5_500_000).error.code, 'bad_gatherable');
  const g = w.gatherables[1];
  standAt(w, TOKEN_A, g);
  assert.ok(w.gather(TOKEN_A, g.index, 5_600_000).inventory);
  const g2 = w.gatherables[2];
  standAt(w, TOKEN_A, g2);
  assert.equal(w.gather(TOKEN_A, g2.index, 5_600_050).error.code, 'rate_limited');
});

test('캔 채집물은 스냅샷에 "아직 못 캠"으로 실린다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  const g = w.gatherables[3];
  standAt(w, TOKEN_A, g);
  w.gather(TOKEN_A, g.index, 6_500_000);
  const states = w.gatherableStates(6_500_100);
  assert.ok(states.some((s) => s.index === g.index), '새로 들어온 사람 화면에서도 감춰야 한다');
});

test('서버가 바위를 통과하지 못하게 밀어낸다', () => {
  const w = fresh();
  assert.ok(w.obstacles.length > 0, 'data/world.json의 바위를 서버도 읽는다');
  const rock = w.obstacles[0];
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  const p = w.players.get(TOKEN_A);
  p.x = rock.x - rock.radius - 2;
  p.z = rock.z;
  // 바위 중심으로 순간이동을 시도해도(속도 상한과 별개로) 표면 밖으로 밀린다.
  const r = w.move(TOKEN_A, { x: rock.x, z: rock.z }, Date.now() + 60_000);
  const d = Math.hypot(r.player.x - rock.x, r.player.z - rock.z);
  assert.ok(d >= rock.radius, `바위 안에 들어갔다: 거리 ${d.toFixed(2)} < ${rock.radius}`);
});

test('서버가 석벽(박스 장애물)도 통과하지 못하게 밀어낸다', () => {
  const w = fresh();
  const wall = w.obstacles.find((o) => o.shape === 'box');
  assert.ok(wall, 'data/world.json의 박스 장애물을 서버도 읽는다');
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  const p = w.players.get(TOKEN_A);
  p.x = wall.x;
  p.z = wall.z - wall.halfZ - 2;
  const r = w.move(TOKEN_A, { x: wall.x, z: wall.z }, Date.now() + 60_000);
  const insideX = Math.abs(r.player.x - wall.x) < wall.halfX;
  const insideZ = Math.abs(r.player.z - wall.z) < wall.halfZ;
  assert.ok(!(insideX && insideZ), `석벽 안에 들어갔다: (${r.player.x}, ${r.player.z})`);
});

test('서버가 캐릭터 겹침도 밀어낸다', () => {
  const w = fresh();
  const a = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  const b = w.join({ token: TOKEN_B, name: '나', preset: 'm1' }).player;
  a.x = 0; a.z = 0;
  b.x = 3; b.z = 0;
  // B가 A 위로 파고들려 해도 최소 간격이 유지된다(움직인 쪽이 밀린다).
  const r = w.move(TOKEN_B, { x: 0, z: 0 }, Date.now() + 60_000);
  const d = Math.hypot(r.player.x - a.x, r.player.z - a.z);
  assert.ok(d >= 0.79, `캐릭터가 겹쳤다: 거리 ${d.toFixed(2)}`);
  assert.equal(a.x, 0, '가만히 있는 쪽은 밀리지 않는다');
});

test('채집 → 드랍 → 다른 사람 줍기까지 서버 가방으로 이어진다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  w.join({ token: TOKEN_B, name: '나', preset: 'm1' });
  // 예전에는 채집이 클라이언트에만 반영돼 서버 가방이 비어 드랍이 항상
  // 거부됐다(2026-09-04 2탭 실측). 이 테스트가 그 회귀를 막는다.
  const g = w.gatherables.find((x) => x.item === 'wood');
  standAt(w, TOKEN_A, g);
  w.gather(TOKEN_A, g.index, 6_000_000);
  const dropped = w.drop(TOKEN_A, 'wood', 2, 2);
  assert.ok(dropped.item, '채집한 물건은 드랍할 수 있어야 함');
  assert.equal(w.pickup(TOKEN_B, dropped.item.id).inventory.wood, 1);
});

test('가방에 없는 아이템은 드랍할 수 없다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  assert.equal(w.drop(TOKEN_A, 'wood', 0, 0).error.code, 'no_item');
});

test('드랍 → 줍기로 소유권이 옮겨진다', () => {
  const w = fresh();
  const a = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  const b = w.join({ token: TOKEN_B, name: '나', preset: 'm1' }).player;
  a.inventory.wood = 2;

  const dropped = w.drop(TOKEN_A, 'wood', 1, 1);
  assert.equal(dropped.inventory.wood, 1, '드랍하면 가방에서 1개 줄어야 함');
  assert.equal(w.items.size, 1);

  const got = w.pickup(TOKEN_B, dropped.item.id);
  assert.equal(got.inventory.wood, 1, '주운 쪽 가방에 1개 들어와야 함');
  assert.equal(w.items.size, 0);
  assert.equal(b.inventory.wood, 1);
});

test('같은 아이템을 두 명이 동시에 주우면 한 명만 성공한다', () => {
  const w = fresh();
  const a = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  w.join({ token: TOKEN_B, name: '나', preset: 'm1' });
  a.inventory.shell = 1;
  const dropped = w.drop(TOKEN_A, 'shell', 0, 0);

  assert.ok(w.pickup(TOKEN_B, dropped.item.id).item, '먼저 요청한 쪽은 성공');
  assert.equal(w.pickup(TOKEN_A, dropped.item.id).error.code, 'gone', '두 번째는 거부');
});

test('판매는 서버가 정산하고 가방을 비운다', () => {
  const w = fresh();
  const a = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  a.inventory.wood = 2;    // 개당 60
  a.inventory.shell = 1;   // 개당 180
  const r = w.sell(TOKEN_A, null, 7_000_000);
  assert.equal(r.total, 2 * 60 + 180, '금액은 data/items.json 가격으로 계산');
  assert.equal(r.bells, 300);
  assert.deepEqual(r.inventory, {}, '판 물건은 서버 가방에서도 사라진다');
  assert.equal(a.bells, 300, '벨은 서버 레코드에 남는다');
});

test('아이템을 지정해 그 종류만 팔 수 있다', () => {
  const w = fresh();
  const a = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  a.inventory.wood = 1;
  a.inventory.shell = 2;
  const r = w.sell(TOKEN_A, 'shell', 7_100_000);
  assert.equal(r.total, 360);
  assert.equal(r.inventory.wood, 1, '지정하지 않은 아이템은 남는다');
  assert.ok(!('shell' in r.inventory));
});

// 이 테스트가 막는 회귀: 예전에는 판매가 클라이언트에만 반영돼 서버 가방이
// 그대로였고, 재접속 시 welcome이 서버 가방으로 덮어써 판 물건이 되살아났다.
// 벨은 이미 받은 상태라 이 과정을 반복하면 무한히 불릴 수 있었다.
test('판매 후 재접속해도 판 물건이 되살아나지 않는다', () => {
  const w = fresh();
  const a = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  a.inventory.fruit = 3;
  const r = w.sell(TOKEN_A, null, 7_200_000);
  assert.equal(r.total, 300);
  w.leave(TOKEN_A);

  const again = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  assert.deepEqual(again.inventory, {}, '가방이 비어 있어야 한다');
  assert.equal(again.bells, 300, '벨은 유지된다(기기를 바꿔도 같은 값)');
});

test('빈 가방 판매와 연타는 거부된다', () => {
  const w = fresh();
  const a = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  assert.equal(w.sell(TOKEN_A, null, 7_300_000).error.code, 'empty_bag');
  a.inventory.weed = 1;
  assert.ok(w.sell(TOKEN_A, null, 7_310_000).total > 0);
  a.inventory.weed = 1;
  assert.equal(w.sell(TOKEN_A, null, 7_310_100).error.code, 'rate_limited');
});

test('가격을 모르는 아이템은 팔리지 않고 가방에 남는다', () => {
  const w = fresh();
  const a = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  a.inventory.wood = 1;
  a.inventory['정체불명'] = 5;   // data/items.json에 없는 아이템
  const r = w.sell(TOKEN_A, null, 7_400_000);
  assert.equal(r.total, 60);
  assert.deepEqual(r.unsold, ['정체불명']);
  assert.equal(r.inventory['정체불명'], 5, '가격 미상 아이템은 남는다(손실 방지)');
});

test('가격이 유효범위를 벗어나면 클램프된 값으로 정산된다', () => {
  const w = fresh();
  // items.json의 weed는 [1, 100] 범위 — 범위 밖 가격을 넣어 클램프를 확인한다.
  w.itemDefs = { odd: { label: '이상', sell_price: 99999, price_range: [1, 100] } };
  w.itemIds = new Set(['odd']);
  const a = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  a.inventory.odd = 2;
  const r = w.sell(TOKEN_A, null, 7_500_000);
  assert.equal(r.total, 200, '100(상한)×2로 정산');
});

test('월드 아이템 총량 상한', () => {
  const w = fresh();
  const a = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  a.inventory.weed = LIMITS.MAX_WORLD_ITEMS + 5;
  for (let i = 0; i < LIMITS.MAX_WORLD_ITEMS; i++) w.drop(TOKEN_A, 'weed', 0, 0);
  assert.equal(w.drop(TOKEN_A, 'weed', 0, 0).error.code, 'world_full');
});

test('새 캐릭터는 스폰 지점에 겹치지 않게 흩어진다', () => {
  const w = fresh();
  // 모두 같은 지점에서 시작하면 캐릭터가 한 점에 쌓인다 — 접속 순서에 따라
  // 링 위로 흩어 놓는다(결정적이어야 테스트가 재현된다).
  const tokens = [
    '33333333-3333-4333-8333-333333333331',
    '33333333-3333-4333-8333-333333333332',
    '33333333-3333-4333-8333-333333333333',
    '33333333-3333-4333-8333-333333333334',
  ];
  const spots = tokens.map((tk, i) => {
    const p = w.join({ token: tk, name: `p${i}`, preset: 'f1' }).player;
    return { x: p.x, z: p.z };
  });
  for (let i = 0; i < spots.length; i++) {
    for (let j = i + 1; j < spots.length; j++) {
      const d = Math.hypot(spots[i].x - spots[j].x, spots[i].z - spots[j].z);
      assert.ok(d > 0.7, `${i}번과 ${j}번 스폰이 너무 가깝다: ${d.toFixed(2)}`);
    }
  }
  // 결정적: 같은 순서로 다시 만들면 같은 자리.
  const w2 = fresh();
  const again = tokens.map((tk, i) => {
    const p = w2.join({ token: tk, name: `p${i}`, preset: 'f1' }).player;
    return { x: p.x, z: p.z };
  });
  assert.deepEqual(again, spots, '스폰 배치가 결정적이어야 한다');
});

test('재접속하면 위치와 가방을 기억한다', () => {
  const w = fresh();
  const a = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  a.inventory.wood = 3;
  w.move(TOKEN_A, { x: 5, z: -3 }, Date.now() + 60_000);
  const beforeX = a.x;
  w.leave(TOKEN_A);

  const again = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  assert.equal(again.x, beforeX, '위치 기억');
  assert.equal(again.inventory.wood, 3, '가방 기억');
});

test('접속하지 않은 토큰은 아무 동작도 못 한다', () => {
  const w = fresh();
  assert.equal(w.move(TOKEN_A, { x: 1, z: 1 }).error.code, 'not_joined');
  assert.equal(w.chat(TOKEN_A, '가').error.code, 'not_joined');
  assert.equal(w.pickup(TOKEN_A, 'x').error.code, 'not_joined');
});

test('스냅샷에는 접속 중인 캐릭터만 들어간다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  w.join({ token: TOKEN_B, name: '나', preset: 'm1' });
  w.leave(TOKEN_B);
  const snap = w.snapshot();
  assert.equal(snap.players.length, 1);
  assert.equal(snap.players[0].token, TOKEN_A);
});

// ---------------------------------------------------------------------------
// 운동(활동)과 축구공 — 서버가 소유하는 것들
// ---------------------------------------------------------------------------

/** 운동장(축구장 중앙)으로 옮긴다 — 운동장 전용 운동은 서버도 위치를 본다. */
function intoPlayground(w, token) {
  const p = w.players.get(token);
  p.x = Number(w.field.x);
  p.z = Number(w.field.z);
  return p;
}

test('알 수 없는 운동은 거부하고, 빈 문자열은 그만두기다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  intoPlayground(w, TOKEN_A);
  // 레이트 리밋(250ms)이 있으므로 호출마다 시간을 넘겨준다.
  const t0 = Date.now();
  assert.equal(w.activity(TOKEN_A, '수영', '', t0).error.code, 'bad_activity');
  assert.equal(w.activity(TOKEN_A, 'bike', '', t0).activity.activity, 'bike');
  assert.equal(w.activity(TOKEN_A, '', '', t0 + 300).activity.activity, '', '빈 문자열이면 원래 모습');
});

test('줄넘기 기술은 줄넘기에만 붙고, 없는 기술은 버린다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  intoPlayground(w, TOKEN_A);
  const t0 = Date.now();
  assert.equal(w.activity(TOKEN_A, 'jumprope', 'double', t0).activity.trick, 'double');
  assert.equal(w.activity(TOKEN_A, 'jumprope', '공중제비', t0 + 300).activity.trick, '',
    '없는 기술은 무시한다 — 거부하면 오래된 클라이언트가 줄넘기를 아예 못 한다');
  assert.equal(w.activity(TOKEN_A, 'bike', 'double', t0 + 600).activity.trick, '',
    '자전거에는 줄넘기 기술이 붙지 않는다');
});

test('활동에 따라 이동 속도 상한이 달라진다', () => {
  const w = fresh();
  const walk = w.speedCapOf({ activity: '' });
  const bike = w.speedCapOf({ activity: 'bike' });
  const rope = w.speedCapOf({ activity: 'jumprope' });
  assert.ok(bike > walk, `자전거가 걷기보다 빨라야 한다 (${bike} vs ${walk})`);
  assert.ok(rope < walk, `줄넘기는 제자리 운동이라 느려야 한다 (${rope} vs ${walk})`);
});

test('자전거는 걷기 상한을 넘는 이동이 허용된다', () => {
  const w = fresh();
  const p = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  intoPlayground(w, TOKEN_A);
  const t0 = Date.now();
  const startX = Number(w.field.x);
  w.move(TOKEN_A, { x: startX, z: 0 }, t0);
  // 0.5초에 3유닛 = 6유닛/초 — 걷기 상한(6.72)에는 걸리지 않지만
  // 자전거(12.16)와는 확실히 구분되는 값으로 검증한다.
  w.activity(TOKEN_A, 'bike');
  w.move(TOKEN_A, { x: startX + 5.5, z: 0 }, t0 + 500);
  assert.ok(p.x > startX + 5.0, `자전거로 0.5초에 5유닛 이상 이동해야 한다 (x=${p.x})`);

  // 레이트 리밋(250ms) 때문에 시간을 벌린다.
  w.activity(TOKEN_A, '', '', t0 + 600);
  const walkStart = p.x;
  w.move(TOKEN_A, { x: walkStart + 5.5, z: 0 }, t0 + 1000);
  assert.ok(p.x - walkStart < 3.6,
    `걷기로는 0.5초에 3.4유닛(=6.72*0.5)까지만 이동해야 한다 (이동 ${p.x - walkStart})`);
});

test('축구를 시작하면 공이 나오고, 아무도 안 하면 사라진다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  intoPlayground(w, TOKEN_A);
  assert.equal(w.ballState(), null, '처음에는 공이 없다');
  const t0 = Date.now();
  w.activity(TOKEN_A, 'soccer', '', t0);
  assert.ok(w.ballState() != null, '축구를 시작하면 공이 나온다');
  assert.equal(w.snapshot().ball != null, true, '새로 들어온 사람도 공을 본다');
  w.activity(TOKEN_A, '', '', t0 + 300);
  assert.equal(w.ballState(), null, '아무도 축구를 하지 않으면 공을 치운다');
});

test('축구 중이 아니거나 공이 멀면 차지 못한다', () => {
  const w = fresh();
  const p = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  assert.equal(w.kick(TOKEN_A, { dx: 1, dz: 0 }).error.code, 'no_ball');
  intoPlayground(w, TOKEN_A);
  w.activity(TOKEN_A, 'soccer');
  // 공에서 멀찍이 떨어진다(축구장 안이지만 사거리 밖).
  p.x = Number(w.field.x) - Number(w.field.size_x) / 2 + 0.5;
  assert.equal(w.kick(TOKEN_A, { dx: 1, dz: 0 }).error.code, 'too_far');
});

test('공을 골대 쪽으로 차면 골이 들어가고 공이 중앙으로 돌아온다', () => {
  const w = fresh();
  const p = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  intoPlayground(w, TOKEN_A);
  w.activity(TOKEN_A, 'soccer');
  const field = w.field;
  // 왼쪽 골대 바로 앞에 서서(치팅이 아니라 좌표를 직접 넣는다 — 이동 상한을
  // 우회하려면 수십 번 move를 불러야 하고, 검증 대상은 골 판정이다) 왼쪽으로 찬다.
  p.x = field.x - field.size_x / 2 + 1.2;
  p.z = field.z;
  w.ball.x = p.x - 0.5;
  w.ball.z = field.z;
  const r = w.kick(TOKEN_A, { dx: -1, dz: 0 });
  assert.ok(r.kicked, `찰 수 있어야 한다: ${JSON.stringify(r)}`);

  let goal = null;
  for (let i = 0; i < 40 && !goal; i++) goal = w.tickBall(0.1);
  assert.ok(goal, '골라인을 넘었는데 골 판정이 없다');
  assert.equal(goal.side, 'left');
  assert.equal(goal.score.left, 1);
  assert.equal(w.ball.x, field.x, '골이 들어가면 공은 중앙으로 돌아온다');
  assert.equal(w.ball.vx, 0, '공이 멈춘다');
});

test('골대 폭을 벗어난 공은 골이 아니라 튕긴다', () => {
  const w = fresh();
  const p = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  intoPlayground(w, TOKEN_A);
  w.activity(TOKEN_A, 'soccer');
  const field = w.field;
  // 골대 폭(goal_width) 밖 — 골라인 근처지만 z가 크게 벗어난 자리.
  const zOff = field.goal_width / 2 + 1.5;
  p.x = field.x - field.size_x / 2 + 1.2;
  p.z = field.z + zOff;
  w.ball.x = p.x - 0.5;
  w.ball.z = field.z + zOff;
  w.kick(TOKEN_A, { dx: -1, dz: 0 });
  let goal = null;
  for (let i = 0; i < 40 && !goal; i++) goal = w.tickBall(0.1);
  assert.equal(goal, null, '골대 폭 밖인데 골로 인정됐다');
  assert.ok(w.ball.x >= field.x - field.size_x / 2 - 0.01, '공이 경기장 안에 남아야 한다');
});

test('걸어가 공에 닿으면 드리블로 밀린다(패스의 기본)', () => {
  const w = fresh();
  const p = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  intoPlayground(w, TOKEN_A);
  w.activity(TOKEN_A, 'soccer');
  const field = w.field;
  p.x = field.x - 1.0;
  p.z = field.z;
  w.ball.x = field.x - 0.7;
  w.ball.z = field.z;
  const before = w.ball.x;
  w.dribble(p);
  assert.ok(w.ball.vx > 0, '공이 진행 방향으로 밀려야 한다');
  w.tickBall(0.2);
  assert.ok(w.ball.x > before, `공이 앞으로 가야 한다 (${before} → ${w.ball.x})`);
});

test('축구를 하지 않는 사람은 공을 건드리지 못한다', () => {
  const w = fresh();
  const a = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  w.join({ token: TOKEN_B, name: '나', preset: 'm1' });
  intoPlayground(w, TOKEN_B);
  w.activity(TOKEN_B, 'soccer');   // 공을 내보내는 건 B
  const field = w.field;
  a.x = field.x;
  a.z = field.z;
  w.dribble(a);
  assert.equal(w.ball.vx, 0, '축구 중이 아닌 사람의 접촉으로는 공이 움직이지 않는다');
  assert.equal(w.kick(TOKEN_A, { dx: 1, dz: 0 }).error.code, 'not_soccer');
});


test('운동장 밖에서는 운동장 전용 운동을 서버가 거부한다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  // 스폰(0,0)은 운동장 밖이다.
  assert.equal(w.activity(TOKEN_A, 'bike').error.code, 'not_in_zone',
    '클라이언트만 막으면 변조한 클라이언트가 어디서나 자전거 속도를 쓴다');
  // 위 호출은 거부돼 레이트 리밋을 소모하지 않으므로 시간을 미룰 필요가 없다.
  assert.equal(w.activity(TOKEN_A, 'kickboard').activity.activity, 'kickboard',
    '킥보드는 어디서나 탈 수 있다(사용자 지정)');
});

test('재접속하면 운동 상태가 초기화된다', () => {
  const w = fresh();
  const p = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  p.x = Number(w.field.x);
  p.z = Number(w.field.z);
  w.activity(TOKEN_A, 'bike');
  assert.equal(p.activity, 'bike');
  w.leave(TOKEN_A);

  const again = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  assert.equal(again.activity, '',
    '새 클라이언트는 아무 운동도 하지 않는 상태로 시작한다 — 서버가 옛 상태를 들고 있으면 남들 화면에는 계속 자전거가 보이고 이동 상한도 열려 있다');
  assert.ok(again.trick === '' || again.trick === undefined);
  assert.ok(w.speedCapOf(again) < 7.0, `상한도 걷기로 돌아와야 한다 (${w.speedCapOf(again)})`);
});

test('이름만 바꿀 때는 운동 상태를 잃지 않는다', () => {
  const w = fresh();
  const p = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  p.x = Number(w.field.x);
  p.z = Number(w.field.z);
  w.activity(TOKEN_A, 'bike');
  // rename도 join을 거친다 — 접속이 끊기지 않았으면 초기화하지 않아야 한다.
  w.join({ token: TOKEN_A, name: '나', preset: 'f1' });
  assert.equal(p.activity, 'bike');
  assert.equal(p.name, '나');
});

test('운동 전환은 레이트 리밋이 있다 (단, 그만두기는 예외)', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  intoPlayground(w, TOKEN_A);
  const t0 = Date.now();
  // **값이 실제로 바뀌는** 연속 전환으로 확인한다(같은 값은 no-op으로 걸러진다).
  assert.ok(w.activity(TOKEN_A, 'bike', '', t0).activity);
  assert.equal(w.activity(TOKEN_A, 'inline', '', t0 + 50).throttled, true,
    '전원 브로드캐스트 + 스프라이트 재생성을 유발하므로 도배를 막아야 한다');
  // **그만두기는 스로틀하지 않는다.** 클라이언트가 운동장을 벗어나 스스로
  // 해제를 보낼 때 거부되면, 스로틀 응답이 옛 상태를 되돌려 보내 다시
  // 운동을 켜 버린다(경계에서 껐다 켜졌다 한다).
  assert.ok(w.activity(TOKEN_A, '', '', t0 + 60).activity,
    '해제는 즉시 받아들여야 한다');
  // 간격이 지나면 다시 시작할 수 있어야 한다(복구 경로).
  assert.ok(w.activity(TOKEN_A, 'kickboard', '', t0 + 400).activity);
});

test('아무것도 바뀌지 않는 운동 요청은 조용히 버린다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  const t0 = Date.now();
  assert.ok(w.activity(TOKEN_A, 'kickboard', '', t0).activity);
  // 같은 값을 다시 보내면 no-op — 전원 브로드캐스트를 유발할 이유가 없다.
  assert.equal(w.activity(TOKEN_A, 'kickboard', '', t0 + 500).noop, true);
  // 해제도 두 번째부터는 no-op이라, 스로틀을 면제해도 도배 통로가 되지 않는다.
  assert.ok(w.activity(TOKEN_A, '', '', t0 + 600).activity);
  assert.equal(w.activity(TOKEN_A, '', '', t0 + 610).noop, true);
});

test('중앙에서 한 번 차면 공이 골라인까지 간다', () => {
  const w = fresh();
  const p = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  p.x = Number(w.field.x);
  p.z = Number(w.field.z);
  w.activity(TOKEN_A, 'soccer');
  // 킥오프: 공은 중앙, 사람은 그 옆.
  p.x = Number(w.field.x) - 0.8;
  const r = w.kick(TOKEN_A, { dx: -1, dz: 0 });
  assert.ok(r.kicked, JSON.stringify(r));
  let goal = null;
  for (let i = 0; i < 80 && !goal; i++) goal = w.tickBall(0.1);
  assert.ok(goal,
    '중앙에서 한 번 차서 골라인에 닿지 않으면 킥오프마다 드리블로 밀고 가야 한다(kick_speed 확인)');
});


test('운동장을 벗어나면 서버가 운동을 해제한다', () => {
  const w = fresh();
  const p = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  p.x = Number(w.field.x);
  p.z = Number(w.field.z);
  w.activity(TOKEN_A, 'bike');
  assert.ok(w.speedCapOf(p) > 10, '자전거 상한이 열렸다');

  // 시작할 때만 검사하면, 운동장 안에서 켜고 나가 섬 전역을 자전거 상한으로
  // 돌아다닐 수 있다 — 이동할 때마다 다시 봐야 한다.
  let now = Date.now();
  let dismounted = null;
  for (let i = 0; i < 40 && !dismounted; i++) {
    now += 120;
    dismounted = w.move(TOKEN_A, { x: p.x, z: p.z + 1.2 }, now).dismounted;
  }
  assert.ok(dismounted, `운동장을 벗어났는데 해제되지 않았다 (z=${p.z})`);
  assert.equal(p.activity, '');
  assert.ok(w.speedCapOf(p) < 7, `상한도 걷기로 돌아와야 한다 (${w.speedCapOf(p)})`);
});

test('킥보드는 운동장을 벗어나도 유지된다', () => {
  const w = fresh();
  const p = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  w.activity(TOKEN_A, 'kickboard');
  let now = Date.now();
  for (let i = 0; i < 20; i++) {
    now += 120;
    w.move(TOKEN_A, { x: p.x + 1.2, z: p.z }, now);
  }
  assert.equal(p.activity, 'kickboard', '어디서나 탈 수 있는 운동은 해제되지 않는다');
});

test('close 없이 같은 토큰으로 다시 들어오면(기기 교체) 운동 상태가 초기화된다', () => {
  const w = fresh();
  const p = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  p.x = Number(w.field.x);
  p.z = Number(w.field.z);
  w.activity(TOKEN_A, 'bike');
  // leave()를 부르지 않는다 — 폰이 절전으로 끊길 때 close가 늦게 오거나 오지
  // 않는 경우다. 전송 계층이 "다른 소켓"이라고 알려 주면 초기화해야 한다.
  const again = w.join({
    token: TOKEN_A, name: '가', preset: 'f1', resetActivity: true,
  }).player;
  assert.equal(again.activity, '');
  assert.ok(w.speedCapOf(again) < 7);
});

test('축구 설정이 범위를 벗어나면 기본값으로 대체한다', () => {
  // friction이 음수면 Math.pow(음수, 0.1)이 NaN이 되고 공 좌표가 NaN으로
  // 퍼진다 — 공이 화면에서 사라지고 서버 재시작까지 복구되지 않는다.
  const w = fresh();
  assert.ok(w.soccerCfg.friction > 0 && w.soccerCfg.friction < 1);
  assert.ok(w.soccerCfg.kickSpeed > 0);
  assert.ok(w.soccerCfg.dribbleRange > 0);
});

// ---------------------------------------------------------------------------
// 놀이터(park) — 좌석 배정과 놀이기구 물리
// ---------------------------------------------------------------------------

/** 놀이터 안(중심)으로 옮긴다 — 놀이기구는 놀이터에서만 탈 수 있다. */
function intoPark(w, token) {
  const p = w.players.get(token);
  p.x = Number(w.park.x);
  p.z = Number(w.park.z);
  return p;
}

test('놀이기구는 놀이터에서만 탈 수 있다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  assert.equal(w.activity(TOKEN_A, 'swing', '0').error.code, 'not_in_zone');
  intoPark(w, TOKEN_A);
  assert.equal(w.activity(TOKEN_A, 'swing', '0', Date.now() + 400).activity.activity, 'swing');
});

test('같은 자리를 요청하면 빈 자리로 배정하고, 다 차면 거절한다', () => {
  const w = fresh();
  const tokens = [TOKEN_A, TOKEN_B, '33333333-3333-4333-8333-333333333333'];
  for (const t of tokens) {
    w.join({ token: t, name: '가', preset: 'f1' });
    intoPark(w, t);
  }
  // 그네는 2인 — 세 번째는 앉을 자리가 없다.
  const a = w.activity(tokens[0], 'swing', '0');
  const b = w.activity(tokens[1], 'swing', '0');
  assert.equal(a.activity.trick, '0');
  assert.equal(b.activity.trick, '1', '찬 자리를 요청하면 빈 자리로 옮겨 준다');
  const c = w.activity(tokens[2], 'swing', '0');
  assert.equal(c.error.code, 'seat_taken', '자리가 없으면 앉히지 않는다 — 겹쳐 앉으면 안 된다');
});

test('그네 진폭은 유효 범위의 정수만 받는다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  intoPark(w, TOKEN_A);
  const t0 = Date.now();
  assert.equal(w.activity(TOKEN_A, 'swing', '0:2', t0).activity.trick, '0:2');
  // 범위를 벗어나거나 형식이 다르면 버린다 — 그대로 방송되고, 받는 쪽은 처음
  // 보는 (운동, 기술) 조합마다 스프라이트를 새로 만든다.
  assert.equal(w.activity(TOKEN_A, 'swing', '0:99', t0 + 300).activity.trick, '0');
  // 형식이 다르면 진폭이 사라져 자리만 남는다 — 이미 그 상태라 no-op이 된다.
  assert.equal(w.activity(TOKEN_A, 'swing', 'a:b', t0 + 600).noop, true);
  assert.equal(w.players.get(TOKEN_A).trick, '0');
});

test('놀이기구에 앉으면 그 자리를 벗어날 수 없다', () => {
  const w = fresh();
  const p = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  intoPark(w, TOKEN_A);
  // 클라이언트는 좌석까지 **걸어간 뒤** 탄다 — 같은 상황을 만든다.
  const seat0 = w.seatPosition('carousel', 0);
  p.x = seat0.x;
  p.z = seat0.z;
  const r = w.activity(TOKEN_A, 'carousel', '0');
  // 기준은 **좌석 좌표**다(요청 당시 위치가 아니다) — 서버가 자리를 재배정할 수
  // 있으므로 앵커를 좌석에서 유도한다.
  const seatNo = Number.parseInt(r.activity.trick, 10);
  const seat = w.seatPosition('carousel', seatNo);
  assert.deepEqual(p.rideAnchor, seat, '앵커는 좌석 좌표여야 한다');
  let now = Date.now();
  for (let i = 0; i < 30; i += 1) {
    now += 120;
    w.move(TOKEN_A, { x: seat.x + 5, z: seat.z + 5 }, now);
  }
  const moved = Math.hypot(p.x - seat.x, p.z - seat.z);
  assert.ok(moved <= LIMITS.RIDE_LEASH + 0.01,
    `앉은 자리에서 ${LIMITS.RIDE_LEASH} 이상 벗어났다 (${moved.toFixed(2)}) — 놀이기구가 위치를 정해야 한다`);
});

test('미끄럼틀은 자리가 없어 위치가 고정되지 않는다(내려가야 하므로)', () => {
  const w = fresh();
  const p = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  intoPark(w, TOKEN_A);
  w.activity(TOKEN_A, 'slide', '');
  assert.equal(p.rideAnchor, null, '경로를 따라 내려가므로 좌석 고정을 걸면 안 된다');
  assert.ok(w.speedCapOf(p) > 10, `내려가는 속도가 나와야 한다 (${w.speedCapOf(p)})`);
});

test('타고 있는 사람만 놀이기구를 밀 수 있다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  intoPark(w, TOKEN_A);
  assert.equal(w.pushRide(TOKEN_A, 'seesaw').error.code, 'not_riding',
    '지나가면서 남의 기구를 흔들 수는 없다');
  w.activity(TOKEN_A, 'seesaw', '0');
  assert.equal(w.pushRide(TOKEN_A, 'seesaw').pushed, 'seesaw');
});

test('시소는 밀면 기울고 최대 각도를 넘지 않으며 수평으로 돌아온다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  intoPark(w, TOKEN_A);
  w.activity(TOKEN_A, 'seesaw', '0');
  w.pushRide(TOKEN_A, 'seesaw');
  let peak = 0;
  for (let i = 0; i < 40; i += 1) {
    w.tickPark(0.1);
    peak = Math.max(peak, Math.abs(w.seesaw.angle));
  }
  assert.ok(peak > 0.05, `밀었는데 기울지 않았다 (${peak})`);
  assert.ok(peak <= w.parkCfg.seesawMaxAngle + 0.001,
    `최대 각도를 넘었다 (${peak} > ${w.parkCfg.seesawMaxAngle}) — 한 번 밀 때마다 판이 끝까지 꺾이면 시소가 아니다`);

  // 아무도 안 타면 수평으로 돌아온다.
  w.activity(TOKEN_A, '', '', Date.now() + 1000);
  for (let i = 0; i < 200; i += 1) w.tickPark(0.1);
  assert.ok(Math.abs(w.seesaw.angle) < 0.02, `수평으로 돌아오지 않았다 (${w.seesaw.angle})`);
});

test('뺑뺑이는 밀면 돌고 마찰로 멈춘다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  intoPark(w, TOKEN_A);
  w.activity(TOKEN_A, 'carousel', '0');
  w.pushRide(TOKEN_A, 'carousel');
  assert.ok(w.carousel.speed > 0, '밀었는데 돌지 않았다');
  const before = w.carousel.angle;
  w.tickPark(0.1);
  assert.notEqual(w.carousel.angle, before);
  for (let i = 0; i < 400; i += 1) w.tickPark(0.1);
  assert.equal(w.carousel.speed, 0, '마찰로 멈춰야 한다');
});

test('놀이기구 상태는 스냅샷에 들어간다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  const snap = w.snapshot();
  assert.ok(snap.park != null, '새로 들어온 사람도 기울기·각도를 맞춰야 한다');
  assert.equal(typeof snap.park.seesaw, 'number');
});

test('거부된 탑승 요청은 좌석 고정을 남기지 않는다', () => {
  const w = fresh();
  const p = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  intoPark(w, TOKEN_A);
  const t0 = Date.now();
  // 첫 요청은 통과, 두 번째는 스로틀로 거부된다.
  w.activity(TOKEN_A, 'kickboard', '', t0);
  assert.equal(w.activity(TOKEN_A, 'swing', '0', t0 + 50).throttled, true);
  assert.equal(p.rideAnchor, null,
    '거부된 요청이 앵커를 남기면, 타지도 않았는데 그 지점을 벗어날 수 없다');

  // 존 밖에서 거부되는 경우도 마찬가지다.
  p.x = 0;
  p.z = 0;
  assert.equal(w.activity(TOKEN_A, 'swing', '0', t0 + 400).error.code, 'not_in_zone');
  assert.equal(p.rideAnchor, null);
});

test('미끄럼틀은 trick이 빈 문자열로 정규화된다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  intoPark(w, TOKEN_A);
  // 좌석이 없는 기구라 자리 번호가 의미 없다 — 클라이언트가 "0"을 보내도
  // ''로 되돌려 주면 클라이언트가 그 불일치를 탑승 재시작으로 오해한다.
  assert.equal(w.activity(TOKEN_A, 'slide', '').activity.trick, '');
});


test('자리를 재배정받으면 앵커도 그 자리로 옮겨진다', () => {
  const w = fresh();
  const tokens = [TOKEN_A, TOKEN_B];
  for (const tk of tokens) {
    w.join({ token: tk, name: '가', preset: 'f1' });
    intoPark(w, tk);
  }
  w.activity(TOKEN_A, 'swing', '0');
  const r = w.activity(TOKEN_B, 'swing', '0');   // 0번은 찼으므로 1번으로
  assert.equal(r.activity.trick, '1');
  // 앵커를 "요청 당시 위치"로 잡으면, 클라이언트는 1번 좌석으로 옮겨 앉는데
  // 서버는 0번 자리에 묶어 둬서 남들 화면에는 두 그네 사이 허공에 낀 채로
  // 보인다(리뷰 지적). 좌석 좌표에서 유도하면 그런 어긋남이 없다.
  const pb = w.players.get(TOKEN_B);
  assert.deepEqual(pb.rideAnchor, w.seatPosition('swing', 1));
  // **위치까지** 그 자리로 옮겨야 한다 — 앵커만 옮기면 서버 좌표가 옛 자리에
  // 남아 남들 화면에는 다른 사람과 겹친 자리에 서 있는 것으로 보인다.
  const seat1 = w.seatPosition('swing', 1);
  assert.ok(Math.hypot(pb.x - seat1.x, pb.z - seat1.z) < 0.02,
    `배정된 좌석으로 위치가 옮겨지지 않았다 (${pb.x},${pb.z}) vs (${seat1.x},${seat1.z})`);
});

test('trick만 바꿔도 앵커가 흐르지 않는다', () => {
  const w = fresh();
  const p = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
  intoPark(w, TOKEN_A);
  let now = Date.now();
  w.activity(TOKEN_A, 'swing', '0:0', now);
  const first = { ...p.rideAnchor };
  // 진폭을 바꿀 때마다 "현재 위치"로 재앵커하면, 매번 0.6씩 흘러 앉은 채로
  // 섬을 돌아다닐 수 있다(리뷰 지적).
  for (let i = 1; i <= 6; i += 1) {
    now += 300;
    w.move(TOKEN_A, { x: p.x + 2, z: p.z }, now);
    w.activity(TOKEN_A, 'swing', `0:${i % 3}`, now);
  }
  assert.deepEqual(p.rideAnchor, first, '앵커가 흘렀다 — 좌석 좌표에서 유도해야 멱등하다');
});
