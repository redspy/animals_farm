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

test('알 수 없는 운동은 거부하고, 빈 문자열은 그만두기다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  assert.equal(w.activity(TOKEN_A, '수영').error.code, 'bad_activity');
  assert.equal(w.activity(TOKEN_A, 'bike').activity.activity, 'bike');
  assert.equal(w.activity(TOKEN_A, '').activity.activity, '', '빈 문자열이면 원래 모습');
});

test('줄넘기 기술은 줄넘기에만 붙고, 없는 기술은 버린다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  assert.equal(w.activity(TOKEN_A, 'jumprope', 'double').activity.trick, 'double');
  assert.equal(w.activity(TOKEN_A, 'jumprope', '공중제비').activity.trick, '',
    '없는 기술은 무시한다 — 거부하면 오래된 클라이언트가 줄넘기를 아예 못 한다');
  assert.equal(w.activity(TOKEN_A, 'bike', 'double').activity.trick, '',
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
  const t0 = Date.now();
  w.move(TOKEN_A, { x: 0, z: 0 }, t0);
  // 0.5초에 3유닛 = 6유닛/초 — 걷기 상한(6.72)에는 걸리지 않지만
  // 자전거(12.16)와는 확실히 구분되는 값으로 검증한다.
  w.activity(TOKEN_A, 'bike');
  w.move(TOKEN_A, { x: 5.5, z: 0 }, t0 + 500);
  assert.ok(p.x > 5.0, `자전거로 0.5초에 5유닛 이상 이동해야 한다 (x=${p.x})`);

  w.activity(TOKEN_A, '');
  const walkStart = p.x;
  w.move(TOKEN_A, { x: walkStart + 5.5, z: 0 }, t0 + 1000);
  assert.ok(p.x - walkStart < 3.6,
    `걷기로는 0.5초에 3.4유닛(=6.72*0.5)까지만 이동해야 한다 (이동 ${p.x - walkStart})`);
});

test('축구를 시작하면 공이 나오고, 아무도 안 하면 사라진다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  assert.equal(w.ballState(), null, '처음에는 공이 없다');
  w.activity(TOKEN_A, 'soccer');
  assert.ok(w.ballState() != null, '축구를 시작하면 공이 나온다');
  assert.equal(w.snapshot().ball != null, true, '새로 들어온 사람도 공을 본다');
  w.activity(TOKEN_A, '');
  assert.equal(w.ballState(), null, '아무도 축구를 하지 않으면 공을 치운다');
});

test('축구 중이 아니거나 공이 멀면 차지 못한다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  assert.equal(w.kick(TOKEN_A, { dx: 1, dz: 0 }).error.code, 'no_ball');
  w.activity(TOKEN_A, 'soccer');
  // 스폰 지점은 축구장 중앙에서 멀다.
  assert.equal(w.kick(TOKEN_A, { dx: 1, dz: 0 }).error.code, 'too_far');
});

test('공을 골대 쪽으로 차면 골이 들어가고 공이 중앙으로 돌아온다', () => {
  const w = fresh();
  const p = w.join({ token: TOKEN_A, name: '가', preset: 'f1' }).player;
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
  w.activity(TOKEN_B, 'soccer');   // 공을 내보내는 건 B
  const field = w.field;
  a.x = field.x;
  a.z = field.z;
  w.dribble(a);
  assert.equal(w.ball.vx, 0, '축구 중이 아닌 사람의 접촉으로는 공이 움직이지 않는다');
  assert.equal(w.kick(TOKEN_A, { dx: 1, dz: 0 }).error.code, 'not_soccer');
});
