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

test('채집은 서버 가방에 반영되고 레이트 리밋이 걸린다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  const t0 = 5_000_000;
  assert.equal(w.gather(TOKEN_A, 'wood', t0).inventory.wood, 1);
  assert.equal(w.gather(TOKEN_A, 'wood', t0 + 50).error.code, 'rate_limited');
  assert.equal(w.gather(TOKEN_A, 'wood', t0 + 300).inventory.wood, 2);
  assert.equal(w.gather(TOKEN_A, '없는아이템', t0 + 800).error.code, 'bad_item');
});

test('채집 → 드랍 → 다른 사람 줍기까지 서버 가방으로 이어진다', () => {
  const w = fresh();
  w.join({ token: TOKEN_A, name: '가', preset: 'f1' });
  w.join({ token: TOKEN_B, name: '나', preset: 'm1' });
  // 예전에는 채집이 클라이언트에만 반영돼 서버 가방이 비어 드랍이 항상
  // 거부됐다(2026-09-04 2탭 실측). 이 테스트가 그 회귀를 막는다.
  w.gather(TOKEN_A, 'wood', 6_000_000);
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
