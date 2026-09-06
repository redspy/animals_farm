class_name NpcSprite
extends Sprite3D

## 이웃 동물 스프라이트. 플레이어와 같은 32×40 규격의 **절차적 도트**다
## (에셋 파일 없음 — docs/design.md §5).
##
## 종별 차이를 **귀·주둥이·꼬리 3요소**로만 만든다. 색은 구분용이고
## (`data/palette.json`의 `npc` 그룹), 실루엣이 종을 읽히게 해야 한다 —
## 색만 다르면 멀리서 다 같은 동물로 보인다.
##
## 플레이어와 구분되게 **몸을 더 낮고 넓게** 그린다(사람은 세로로 길다).
## 걷기 프레임은 만들지 않는다: NPC는 시간 함수로 천천히 떠다니고(npc.gd),
## 그 속도에서는 다리 애니메이션이 없어도 어색하지 않다. 대신 정면/측면 두 장을
## 만들고 왼쪽은 측면을 좌우 반전해 쓴다.

const W := 32
const H := 40

var _species := "cat"
var _c_body: Color
var _c_accent: Color
var _c_eye: Color
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

	billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	pixel_size = 0.05
	# 발이 바닥에 닿게 세운다. **플레이어 스프라이트와 같은 방식**을 써야 한다:
	# centered(기본 true)를 유지하고 offset을 위로 절반만 올린다. centered를
	# 끄고 -H를 주면 3D에서는 아래로 2유닛 내려가 땅 밑에 묻힌다(실측: 이름표만
	# 보이고 몸이 사라졌다).
	offset = Vector2(0, H / 2.0)
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
	var img := Image.create_empty(W, H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))

	# --- 몸 ---
	# 사람보다 낮고 넓게(폭 18 vs 12). 네 발로 서 있는 실루엣이 아니라
	# 이족 인형 느낌으로 두는 이유: 좌석·놀이기구 등 사람용 연출을 나중에
	# 그대로 쓸 수 있고, 이 크기에서 네 발은 뭉개진다.
	_rect(img, Rect2i(7, 22, 18, 13), _c_body)
	_rect(img, Rect2i(11, 26, 10, 9), _c_accent)      # 배 무늬
	# 발
	_rect(img, Rect2i(8, 35, 6, 4), _c_body)
	_rect(img, Rect2i(18, 35, 6, 4), _c_body)

	# --- 머리 ---
	_circle(img, Vector2i(16, 13), 9, _c_body)

	match _species:
		"bear":
			# 곰: 둥근 귀 두 개 + 넓은 주둥이.
			_circle(img, Vector2i(8, 5), 4, _c_body)
			_circle(img, Vector2i(24, 5), 4, _c_body)
			_circle(img, Vector2i(8, 5), 2, _c_accent)
			_circle(img, Vector2i(24, 5), 2, _c_accent)
			_circle(img, Vector2i(16, 17), 5, _c_accent)
			_rect(img, Rect2i(15, 15, 3, 2), _c_eye)   # 코
		"duck":
			# 오리: 귀 없음 + 부리(포인트색). 머리 위 깃털 한 가닥.
			_rect(img, Rect2i(15, 2, 2, 4), _c_body)
			if side:
				_rect(img, Rect2i(24, 14, 7, 4), _c_accent)
				_rect(img, Rect2i(24, 17, 6, 2), _c_accent)
			else:
				_rect(img, Rect2i(12, 15, 8, 4), _c_accent)
				_rect(img, Rect2i(13, 19, 6, 2), _c_accent)
		_:
			# 고양이: 뾰족한 귀(삼각형) + 작은 주둥이.
			for i in 4:
				_rect(img, Rect2i(7 + i, 4 + i, 4 - i + 1, 2), _c_body)
				_rect(img, Rect2i(21 + (3 - i), 4 + i, 4 - i + 1, 2), _c_body)
			_circle(img, Vector2i(16, 17), 4, _c_accent)
			_rect(img, Rect2i(15, 16, 2, 2), _c_eye)

	# --- 눈 ---
	if side:
		_rect(img, Rect2i(20, 11, 2, 3), _c_eye)
	else:
		_rect(img, Rect2i(12, 11, 2, 3), _c_eye)
		_rect(img, Rect2i(18, 11, 2, 3), _c_eye)

	# --- 꼬리(측면에서만 보인다) ---
	if side:
		match _species:
			"bear":
				_circle(img, Vector2i(5, 30), 3, _c_body)
			"duck":
				_rect(img, Rect2i(2, 24, 6, 4), _c_body)
				_rect(img, Rect2i(1, 22, 4, 3), _c_accent)
			_:
				# 고양이 꼬리: 위로 휜 곡선.
				for i in 7:
					_rect(img, Rect2i(4 - int(i / 3), 30 - i * 2, 3, 3), _c_body)

	var tex := ImageTexture.create_from_image(img)
	return tex

func _rect(img: Image, r: Rect2i, c: Color) -> void:
	for y in range(maxi(r.position.y, 0), mini(r.end.y, H)):
		for x in range(maxi(r.position.x, 0), mini(r.end.x, W)):
			img.set_pixel(x, y, c)

func _circle(img: Image, center: Vector2i, radius: int, c: Color) -> void:
	for y in range(maxi(center.y - radius, 0), mini(center.y + radius + 1, H)):
		for x in range(maxi(center.x - radius, 0), mini(center.x + radius + 1, W)):
			var dx := float(x - center.x)
			var dy := float(y - center.y)
			if dx * dx + dy * dy <= float(radius * radius):
				img.set_pixel(x, y, c)
