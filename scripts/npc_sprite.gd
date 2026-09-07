class_name NpcSprite
extends Sprite3D

## 이웃 동물 스프라이트. 플레이어와 같은 32×40 논리 규격의 **절차적 도트**다
## (에셋 파일 없음 — docs/design.md §5).
##
## 플레이어 스프라이트와 **같은 규칙**을 따른다(§5 "도트 캐릭터 규칙"):
##  - 논리 좌표는 32×40, 내부 이미지는 SCALE배(원이 매끄러워지고 논리 1픽셀보다
##    작은 디테일을 넣을 수 있다)
##  - 표정은 큰 눈 + 흰 하이라이트 + 볼 홍조
##  - **마지막에 실루엣 외곽선**을 두른다(풀색 배경에 색이 녹아 붙지 않게)
##
## 종별 차이는 **귀·주둥이·꼬리 3요소**로 만든다. 색은 구분용이고
## (`data/palette.json`의 `npc` 그룹), 실루엣이 종을 읽히게 해야 한다 —
## 색만 다르면 멀리서 다 같은 동물로 보인다.
##
## 플레이어와 구분되게 **몸을 더 낮고 넓게** 그린다(사람은 세로로 길다).
## 걷기 프레임은 만들지 않는다: NPC는 시간 함수로 천천히 떠다니고(npc.gd),
## 그 속도에서는 다리 애니메이션이 없어도 어색하지 않다. 대신 정면/측면 두 장을
## 만들고 왼쪽은 측면을 좌우 반전해 쓴다.

const W := 32
const H := 40
const SCALE := 2
const FINE_W := W * SCALE
const FINE_H := H * SCALE

## 머리 중심·반지름(논리 좌표). 표정·코 위치를 여기서 유도한다 — 절대 세밀
## 좌표로 박아 두면 SCALE을 바꿀 때 머리만 커지고 얼굴은 제자리에 남는다
## (리뷰 지적). 눈 크기 자체는 여전히 세밀 격자 기준이라 SCALE 2를 가정한다.
const HEAD := Vector2i(16, 13)
const HEAD_R := 9

var _species := "cat"
var _c_body: Color
var _c_accent: Color
var _c_eye: Color
var _c_outline: Color
var _c_eye_white: Color
var _c_blush: Color
var _front: Texture2D
var _side: Texture2D

func setup(species: String) -> void:
	_species = species
	# 팔레트에 종이 없으면 고양이 색으로 떨어진다 — 데이터 오타로 화면이 비는
	# 것보다 눈에 띄는 편이 낫다(Palette는 없는 키에 MISSING을 준다).
	var key := species
	if Palette.color("npc", "%s_body" % species) == Palette.MISSING:
		push_warning("[npc] 팔레트에 %s_body가 없습니다 — cat 색을 씁니다" % species)
		key = "cat"
	_c_body = Palette.color("npc", "%s_body" % key)
	_c_accent = Palette.color("npc", "%s_accent" % key)
	_c_eye = Palette.color("npc", "eye")
	# 외곽선·표정 색은 플레이어와 **공유한다** — 두 벌을 두면 화면에서 결이 갈린다.
	_c_outline = Palette.color("character", "outline")
	_c_eye_white = Palette.color("character", "eye_white")
	_c_blush = Palette.color("character", "blush")

	if SCALE != 2:
		push_warning("[npc] SCALE=%d인데 표정 크기는 2 전용입니다 — 얼굴이 어긋납니다" % SCALE)
	billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	# 내부 해상도가 SCALE배이므로 픽셀 크기를 그만큼 줄여야 월드 크기가 같다.
	pixel_size = 0.05 / float(SCALE)
	# 발이 바닥에 닿게 세운다(플레이어 스프라이트와 같은 방식: centered 유지 +
	# offset을 위로 절반). centered를 끄고 -H를 주면 3D에서는 땅에 묻힌다.
	offset = Vector2(0, FINE_H / 2.0)
	_front = _make(false)
	_side = _make(true)
	texture = _front

## 이동 방향에 맞춰 그림을 고른다. 멈춰 있으면 정면(플레이어를 본다).
func face(dir: Vector2) -> void:
	if absf(dir.x) > 0.15 and absf(dir.x) > absf(dir.y):
		texture = _side
		flip_h = dir.x < 0.0
	else:
		texture = _front
		flip_h = false

func _make(side: bool) -> Texture2D:
	var img := Image.create_empty(FINE_W, FINE_H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var body_dark := _c_body.lerp(Color.BLACK, 0.18)

	# --- 몸 ---
	# 사람보다 낮고 넓게(폭 18 vs 12). 네 발이 아니라 이족 인형 실루엣으로 두는
	# 이유: 좌석·놀이기구 등 사람용 연출을 그대로 쓸 수 있고, 이 크기에서 네 발은
	# 뭉개진다.
	# 몸통은 **머리와 겹치게** 시작하고 위쪽 모서리를 둥글게 깎는다. 사각형을
	# 머리 아래에 딱 붙여 놓으면 "공 위에 상자를 올린" 것처럼 이음선이 보인다
	# (확대 시트로 확인).
	_rect(img, Rect2i(8, 20, 16, 15), _c_body)
	_fine_circle(img, Vector2i(8 * SCALE + 3 * SCALE, 20 * SCALE + 3 * SCALE), 3 * SCALE, _c_body)
	_fine_circle(img, Vector2i(24 * SCALE - 3 * SCALE, 20 * SCALE + 3 * SCALE), 3 * SCALE, _c_body)
	_fine_clear_corner(img, Rect2i(8, 20, 16, 6))
	# 배 무늬도 모서리를 깎는다 — 사각형이면 앞치마를 두른 것처럼 딱딱하다.
	_rect(img, Rect2i(11, 25, 10, 10), _c_accent)
	_fine_clear_corner_color(img, Rect2i(11, 25, 10, 10), _c_body)
	_rect(img, Rect2i(8, 34, 16, 1), body_dark)       # 몸 아래 그늘 한 줄
	# 발
	_rect(img, Rect2i(9, 35, 6, 4), _c_body)
	_rect(img, Rect2i(17, 35, 6, 4), _c_body)

	# --- 머리 ---
	_circle(img, HEAD, HEAD_R, _c_body)
	_fine_arc_bottom(img, HEAD, HEAD_R, _c_body.lerp(Color.BLACK, 0.12))
	# 세밀 좌표 기준 머리 중심 — 표정·코를 여기서 잰다.
	var fc := HEAD * SCALE + Vector2i(SCALE / 2, SCALE / 2)
	var fr := HEAD_R * SCALE
	var eye_y := fc.y - 3
	var eye_dx := 7

	match _species:
		"bear":
			# 곰: 둥근 귀 두 개 + 넓은 주둥이.
			_circle(img, Vector2i(8, 5), 4, _c_body)
			_circle(img, Vector2i(24, 5), 4, _c_body)
			_circle(img, Vector2i(8, 5), 2, _c_accent)
			_circle(img, Vector2i(24, 5), 2, _c_accent)
			_circle(img, Vector2i(16, 17), 5, _c_accent)
			_fine_rect(img, Rect2i(fc.x - 3, fc.y + 4, 4, 3), _c_eye)      # 코
		"duck":
			# 오리: 귀 없음 + 부리(포인트색). 머리 위 깃털 한 가닥.
			_rect(img, Rect2i(15, 2, 2, 4), _c_body)
			if side:
				_rect(img, Rect2i(24, 15, 7, 3), _c_accent)
				_rect(img, Rect2i(24, 17, 6, 2), _c_accent.lerp(Color.BLACK, 0.18))
			else:
				_rect(img, Rect2i(12, 16, 8, 3), _c_accent)
				_rect(img, Rect2i(13, 18, 6, 2), _c_accent.lerp(Color.BLACK, 0.18))
		_:
			# 고양이: 뾰족한 귀(삼각형) + 작은 주둥이.
			for i in 4:
				_rect(img, Rect2i(7 + i, 4 + i, 4 - i + 1, 2), _c_body)
				_rect(img, Rect2i(21 + (3 - i), 4 + i, 4 - i + 1, 2), _c_body)
			_circle(img, Vector2i(16, 17), 4, _c_accent)
			_fine_rect(img, Rect2i(fc.x - 2, fc.y + 6, 3, 2), _c_eye)      # 코

	# --- 표정: 큰 눈 + 하이라이트 + 볼 ---
	if side:
		_eye(img, Vector2i(fc.x + eye_dx + 1, eye_y), 1)
		_fine_rect(img, Rect2i(fc.x + 1, eye_y + 6, 3, 1), _c_blush)
	else:
		_eye(img, Vector2i(fc.x - eye_dx, eye_y), -1)
		_eye(img, Vector2i(fc.x + eye_dx, eye_y), 1)
		_fine_rect(img, Rect2i(fc.x - fr + 2, eye_y + 6, 3, 1), _c_blush)
		_fine_rect(img, Rect2i(fc.x + fr - 4, eye_y + 6, 3, 1), _c_blush)

	# --- 꼬리(측면에서만 보인다) ---
	if side:
		match _species:
			"bear":
				_circle(img, Vector2i(5, 30), 3, _c_body)
			"duck":
				_rect(img, Rect2i(2, 24, 6, 4), _c_body)
				_rect(img, Rect2i(1, 22, 4, 3), _c_accent)
			_:
				# 고양이 꼬리: **뒤로 낮게** 휜 곡선. 위로 세우면 머리 높이까지
				# 올라가 팔처럼 보였다(확대 시트로 확인).
				for i in 6:
					_rect(img, Rect2i(6 - i, 31 - int(i / 2) * 2, 3, 3), _c_body)

	_outline(img)
	return ImageTexture.create_from_image(img)

## 눈 한쪽 — 플레이어와 같은 구성(흰자 한 겹 + 큰 눈동자 + 하이라이트 한 점).
func _eye(img: Image, center: Vector2i, side: int) -> void:
	# 원 두 겹으로 만들면 반지름 2~3에서는 **다이아몬드**로 보인다(확대 시트로
	# 확인) — 흰자만 원으로 두고 눈동자는 사각으로 채운다.
	_fine_circle(img, center, 3, _c_eye_white)
	_fine_rect(img, Rect2i(center.x - 1, center.y - 2, 3, 4), _c_eye)
	_fine_rect(img, Rect2i(center.x + (1 if side >= 0 else -1), center.y - 2, 1, 1), _c_eye_white)

# --- 프리미티브(논리 좌표 → 세밀 격자) -------------------------------------

func _rect(img: Image, r: Rect2i, c: Color) -> void:
	_fine_rect(img, Rect2i(r.position * SCALE, r.size * SCALE), c)

func _fine_rect(img: Image, r: Rect2i, c: Color) -> void:
	for y in range(maxi(r.position.y, 0), mini(r.end.y, FINE_H)):
		for x in range(maxi(r.position.x, 0), mini(r.end.x, FINE_W)):
			img.set_pixel(x, y, c)

## 사각형 윗변의 **양쪽 모서리 두 칸**을 지운다(둥근 어깨 느낌).
func _fine_clear_corner(img: Image, r: Rect2i) -> void:
	var f := Rect2i(r.position * SCALE, r.size * SCALE)
	for i in range(SCALE * 2):
		for j in range(SCALE * 2 - i):
			_clear_px(img, f.position.x + j, f.position.y + i)
			_clear_px(img, f.end.x - 1 - j, f.position.y + i)

## 모서리를 **지우지 않고 다른 색으로** 깎는다(몸 안쪽 무늬용).
func _fine_clear_corner_color(img: Image, r: Rect2i, c: Color) -> void:
	var f := Rect2i(r.position * SCALE, r.size * SCALE)
	for i in range(SCALE):
		for j in range(SCALE - i):
			_fine_rect(img, Rect2i(f.position.x + j, f.position.y + i, 1, 1), c)
			_fine_rect(img, Rect2i(f.end.x - 1 - j, f.position.y + i, 1, 1), c)

func _clear_px(img: Image, x: int, y: int) -> void:
	if x >= 0 and x < FINE_W and y >= 0 and y < FINE_H:
		img.set_pixel(x, y, Color(0, 0, 0, 0))

func _circle(img: Image, center: Vector2i, radius: int, c: Color) -> void:
	_fine_circle(img, center * SCALE + Vector2i(SCALE / 2, SCALE / 2), radius * SCALE, c)

func _fine_circle(img: Image, center: Vector2i, radius: int, c: Color) -> void:
	for y in range(maxi(center.y - radius, 0), mini(center.y + radius + 1, FINE_H)):
		for x in range(maxi(center.x - radius, 0), mini(center.x + radius + 1, FINE_W)):
			var dx := float(x - center.x)
			var dy := float(y - center.y)
			if dx * dx + dy * dy <= float(radius * radius):
				img.set_pixel(x, y, c)

## 원의 **아래 한 줄**만 어둡게(턱 그늘). 반지름 절반 원으로 덮으면 얼굴 아래가
## 통째로 회색이 되어 지저분해 보인다(플레이어에서 실측).
func _fine_arc_bottom(img: Image, center: Vector2i, radius: int, c: Color) -> void:
	var fc := center * SCALE + Vector2i(SCALE / 2, SCALE / 2)
	var fr := radius * SCALE
	for y in range(fc.y + fr - SCALE, fc.y + fr + 1):
		for x in range(fc.x - fr, fc.x + fr + 1):
			if x < 0 or x >= FINE_W or y < 0 or y >= FINE_H:
				continue
			var dx := float(x - fc.x)
			var dy := float(y - fc.y)
			if dx * dx + dy * dy <= float(fr * fr):
				img.set_pixel(x, y, c)

## 실루엣 외곽선. 알파만 버퍼에서 한 번 읽고 테두리 픽셀만 칠한다 —
## 픽셀마다 get_pixel로 이웃을 조회하면 스프라이트 생성이 몇 분 걸린다(실측).
func _outline(img: Image) -> void:
	var data := img.get_data()
	var alpha := PackedByteArray()
	alpha.resize(FINE_W * FINE_H)
	for i in range(FINE_W * FINE_H):
		alpha[i] = data[i * 4 + 3]
	for y in FINE_H:
		var row := y * FINE_W
		for x in FINE_W:
			if alpha[row + x] > 2:
				continue
			var touch := false
			if x > 0 and alpha[row + x - 1] > 2:
				touch = true
			elif x < FINE_W - 1 and alpha[row + x + 1] > 2:
				touch = true
			elif y > 0 and alpha[row - FINE_W + x] > 2:
				touch = true
			elif y < FINE_H - 1 and alpha[row + FINE_W + x] > 2:
				touch = true
			if touch:
				img.set_pixel(x, y, _c_outline)
