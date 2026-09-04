extends RefCounted
class_name BubbleTexture

## 말풍선 배경 텍스처를 **코드로 그린다**(둥근 모서리 + 테두리 + 꼬리).
##
## 왜 텍스처인가: QuadMesh는 사각형이라 흰 판을 깔면 각진 상자가 된다. 둥근
## 모서리는 이미지로만 표현되고, 9-slice로 늘리면 모서리가 찌그러진다. 그래서
## 말풍선 크기가 정해질 때 그 크기의 텍스처를 직접 그린다.
##
## 같은 크기를 반복해서 그리지 않도록 캐시한다 — 채팅은 짧은 문장이 반복되므로
## 몇 개만 만들어 두면 재사용된다.

## 모서리 반경(px). 크면 더 동글동글해진다.
const CORNER := 22
const BORDER := 3
## 꼬리(아래쪽 삼각형) 크기(px).
const TAIL_W := 26
const TAIL_H := 16
## 텍스처 캐시 상한 — 무한정 쌓이면 메모리를 먹는다.
const CACHE_MAX := 24

static var _cache: Dictionary = {}

## width/height는 픽셀. 꼬리 높이는 height에 포함된다.
static func get_texture(width: int, height: int, fill: Color, border: Color) -> ImageTexture:
	var w := clampi(width, CORNER * 2 + 8, 1024)
	var h := clampi(height, CORNER * 2 + TAIL_H + 8, 512)
	var key := "%d:%d:%s:%s" % [w, h, fill.to_html(), border.to_html()]
	if _cache.has(key):
		return _cache[key]
	if _cache.size() >= CACHE_MAX:
		_cache.clear()   # 단순 비우기 — LRU까지 갈 규모가 아니다
	var tex := ImageTexture.create_from_image(_draw(w, h, fill, border))
	_cache[key] = tex
	return tex

static func _draw(w: int, h: int, fill: Color, border: Color) -> Image:
	var img := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var body_h := h - TAIL_H

	for y in body_h:
		for x in w:
			var d := _rounded_distance(x, y, w, body_h, CORNER)
			if d > 0.0:
				continue
			# 경계에서 BORDER 픽셀 안쪽까지는 테두리 색으로 칠한다.
			img.set_pixel(x, y, border if d > -float(BORDER) else fill)

	# 꼬리: 아래로 좁아지는 삼각형. 몸통과 같은 색이라 이어져 보인다.
	var cx := w / 2
	for row in TAIL_H:
		var y := body_h + row
		# 아래로 갈수록 좁아진다.
		var half := int(round(float(TAIL_W) * 0.5 * (1.0 - float(row) / float(TAIL_H))))
		for x in range(cx - half, cx + half + 1):
			if x < 0 or x >= w or y < 0 or y >= h:
				continue
			var edge := x <= cx - half + BORDER - 1 or x >= cx + half - BORDER + 1
			img.set_pixel(x, y, border if edge and row > 1 else fill)
	return img

## 둥근 사각형의 부호 있는 거리(음수면 안쪽). 모서리를 원으로 깎는다.
static func _rounded_distance(x: int, y: int, w: int, h: int, radius: int) -> float:
	var px := float(x) + 0.5
	var py := float(y) + 0.5
	var r := float(radius)
	var cx := clampf(px, r, float(w) - r)
	var cy := clampf(py, r, float(h) - r)
	var dx := px - cx
	var dy := py - cy
	if dx == 0.0 and dy == 0.0:
		# 사각형 안쪽 — 가장 가까운 변까지의 거리(음수).
		return -minf(minf(px, float(w) - px), minf(py, float(h) - py))
	return sqrt(dx * dx + dy * dy) - r
