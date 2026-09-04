// 캔버스 게임을 정확히 탭하기 위한 헬퍼.
//
// 게임이 `window.afTest = { vw, vh, points: { key: [x, y] } }` 로 UI 위치를
// Godot 뷰포트 좌표로 알려준다(scripts/test_hooks.gd). 여기서 캔버스의
// getBoundingClientRect를 곱해 CSS 픽셀로 바꾼다 — 스트레치 배율이나 DPR을
// 테스트가 알 필요가 없어진다.
//
// 이 seam이 없을 때는 좌표를 비율로 짐작했고, 데스크톱에서 맞춘 값이 폰
// 세로에서 전부 어긋나 슬롯 선택부터 실패했다(2026-09-04 실측).

export async function godotPoint(page, key, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const pt = await page.evaluate((k) => {
      const t = window.afTest;
      const c = document.querySelector('canvas');
      if (!t || !c || !t.points || !t.points[k]) return null;
      const r = c.getBoundingClientRect();
      const [gx, gy] = t.points[k];
      return {
        x: r.left + (gx / t.vw) * r.width,
        y: r.top + (gy / t.vh) * r.height,
      };
    }, key);
    if (pt && Number.isFinite(pt.x) && Number.isFinite(pt.y)) return pt;
    await page.waitForTimeout(150);
  }
  throw new Error(`UI 지점 '${key}'을 ${timeoutMs}ms 안에 찾지 못했습니다 (window.afTest 확인)`);
}

/** 터치 기기: touchscreen.tap, 데스크톱: mouse click */
export async function tapGodot(page, key, { touch = false } = {}) {
  const pt = await godotPoint(page, key);
  if (touch) await page.touchscreen.tap(pt.x, pt.y);
  else await page.mouse.click(pt.x, pt.y);
  return pt;
}

/** 조이스틱처럼 끌어야 하는 입력 — CDP로 터치 시퀀스를 직접 보낸다. */
export async function dragTouch(cdp, from, to, { steps = 12, holdMs = 120, page = null } = {}) {
  const tp = (x, y) => ({ x, y, radiusX: 12, radiusY: 12, force: 1 });
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [tp(from.x, from.y)] });
  for (let i = 1; i <= steps; i++) {
    const x = from.x + ((to.x - from.x) * i) / steps;
    const y = from.y + ((to.y - from.y) * i) / steps;
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [tp(x, y)] });
    if (page) await page.waitForTimeout(holdMs);
  }
  return {
    async hold(ms) {
      const t0 = Date.now();
      while (Date.now() - t0 < ms) {
        await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [tp(to.x, to.y)] });
        if (page) await page.waitForTimeout(80);
      }
    },
    async release() {
      await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
    },
  };
}
