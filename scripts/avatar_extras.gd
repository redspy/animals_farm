extends Node3D
class_name AvatarExtras

## 캐릭터 머리 위에 붙는 이름표 · 채팅 말풍선 · 이모티콘.
## 내 캐릭터와 다른 기기의 캐릭터가 같은 표현을 쓰도록 한 곳에 모았다 —
## 나만 보이거나 남만 보이는 표현이 생기면 "실시간으로 잘 보이는지"를
## 검증할 수 없다(컨셉 요구사항).

const NAME_HEIGHT := 2.35
const BUBBLE_HEIGHT := 2.95
const NAME_FONT_SIZE := 28
const BUBBLE_FONT_SIZE := 30
## 3D 공간에서의 글자 크기. 0.0035로는 화면에서 6px 정도라 실측으로 읽을 수
## 없었다(2026-09-04 2탭 스크린샷) — 카메라(직교 size 9.5, 540px)에서 약 16px이
## 되도록 키운다.
const LABEL_PIXEL_SIZE := 0.010
const CHAT_SHOW_SEC := 5.0
const EMOTE_SHOW_SEC := 2.5
const CHAT_WRAP_WIDTH := 420.0
## 말풍선 배경 여백(월드 단위). 글자 폭을 재서 이만큼 키운 판을 뒤에 깐다.
const BUBBLE_PADDING := Vector2(0.22, 0.14)
## 글자 폭을 재지 못할 때 쓰는 배경 크기(월드 단위).
const BUBBLE_FALLBACK := Vector2(1.6, 0.5)

var _name_label: Label3D
var _bubble: Label3D
## 말풍선 배경(흰 판) + 아래쪽 꼬리. 말하는 느낌을 주려면 글자만으로는 부족하고,
## 배경 없이는 밝은 지형 위에서 글자가 잘 안 읽힌다(사용자 요청).
var _bubble_bg: MeshInstance3D
var _bubble_tail: MeshInstance3D
var _bubble_timer := 0.0
## _ready 이전에 set_name_text가 불릴 수 있어(add_child 직후 호출) 값을 들고 있다가
## 라벨이 만들어질 때 적용한다 — 예전엔 ready 시그널에 연결해서 세팅했는데,
## 이미 트리에 붙은 노드는 ready가 즉시 지나가 내 이름표만 비어 있었다(실측).
var _pending_name := ""
var _pending_bubble := ""
var _pending_bubble_sec := 0.0

func _ready() -> void:
	_name_label = _make_label(NAME_HEIGHT, NAME_FONT_SIZE, Palette.color("ui", "hud_text"))
	add_child(_name_label)
	# 배경을 먼저 만들고 글자를 그 앞에 둔다(render_priority로 순서를 고정).
	_bubble_bg = _make_bubble_quad(Palette.color("ui", "bubble_bg"), 0)
	add_child(_bubble_bg)
	_bubble_tail = _make_bubble_quad(Palette.color("ui", "bubble_bg"), 0)
	add_child(_bubble_tail)

	_bubble = _make_label(BUBBLE_HEIGHT, BUBBLE_FONT_SIZE, Palette.color("ui", "bubble_text"))
	_bubble.outline_size = 0            # 흰 배경 위에서는 외곽선이 지저분하다
	_bubble.render_priority = 2
	_bubble.visible = false
	add_child(_bubble)

	_name_label.text = _pending_name
	if not _pending_bubble.is_empty():
		_show_bubble(_pending_bubble, _pending_bubble_sec)
		_pending_bubble = ""

func _make_label(height: float, font_size: int, color: Color) -> Label3D:
	var l := Label3D.new()
	l.position = Vector3(0, height, 0)
	# 캐릭터 스프라이트와 같은 규칙: Y축만 카메라를 따라가야 기울어 보이지 않는다.
	l.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	l.font_size = font_size
	l.outline_size = 10
	l.modulate = color
	l.outline_modulate = Palette.color("ui", "hud_outline")
	l.pixel_size = LABEL_PIXEL_SIZE
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.width = CHAT_WRAP_WIDTH
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# 나무 뒤에 가려 이름이 안 보이면 누가 누군지 알 수 없다 — 항상 위에 그린다.
	l.no_depth_test = true
	l.render_priority = 1
	return l

## 말풍선 배경으로 쓰는 흰 판. 빌보드를 글자와 같은 방식으로 두어야 같이 돈다.
func _make_bubble_quad(color: Color, priority: int) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = BUBBLE_FALLBACK
	mesh.mesh = quad
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	# 나무 뒤에 가려 말풍선이 안 보이면 대화가 끊긴 것처럼 느껴진다.
	m.no_depth_test = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material_override = m
	mesh.render_priority = priority
	mesh.visible = false
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mesh

## 글자 크기에 맞춰 배경 판과 꼬리를 배치한다.
func _fit_bubble_background(text: String) -> void:
	if _bubble_bg == null or _bubble == null:
		return
	var size := BUBBLE_FALLBACK
	var font: Font = _bubble.font if _bubble.font != null else ThemeDB.get_default_theme().default_font
	if font != null:
		# Label3D는 픽셀 크기 × pixel_size로 월드 크기가 정해진다. 줄바꿈을 고려해
		# 폭은 wrap 한도로 자르고, 높이는 줄 수로 계산한다.
		var px := font.get_multiline_string_size(
			text, HORIZONTAL_ALIGNMENT_CENTER, CHAT_WRAP_WIDTH, BUBBLE_FONT_SIZE
		)
		size = Vector2(
			minf(px.x, CHAT_WRAP_WIDTH) * LABEL_PIXEL_SIZE,
			px.y * LABEL_PIXEL_SIZE
		)
	size += BUBBLE_PADDING * 2.0
	(_bubble_bg.mesh as QuadMesh).size = size
	_bubble_bg.position = Vector3(0, BUBBLE_HEIGHT, -0.01)
	# 꼬리: 작은 정사각형을 아래로 붙여 말하는 방향을 가리킨다.
	var tail := size.y * 0.42
	(_bubble_tail.mesh as QuadMesh).size = Vector2(tail, tail)
	_bubble_tail.position = Vector3(0, BUBBLE_HEIGHT - size.y * 0.5 - tail * 0.35, -0.011)
	_bubble_tail.rotation_degrees = Vector3(0, 0, 45)

func set_name_text(text: String) -> void:
	_pending_name = text
	if _name_label != null:
		_name_label.text = text

func show_chat(text: String) -> void:
	_show_bubble(text, CHAT_SHOW_SEC)

func show_emote(glyph: String) -> void:
	# 이모티콘은 글리프 하나를 크게 띄운다(data/emotes.json의 glyph).
	_show_bubble(glyph, EMOTE_SHOW_SEC)

func _show_bubble(text: String, seconds: float) -> void:
	if _bubble == null:
		# 아직 _ready 전 — 라벨이 생기면 띄운다.
		_pending_bubble = text
		_pending_bubble_sec = seconds
		return
	_bubble.text = text
	_fit_bubble_background(text)
	_bubble.visible = true
	if _bubble_bg != null:
		_bubble_bg.visible = true
	if _bubble_tail != null:
		_bubble_tail.visible = true
	_bubble_timer = seconds

func _process(delta: float) -> void:
	if _bubble_timer <= 0.0:
		return
	_bubble_timer -= delta
	if _bubble_timer <= 0.0 and _bubble != null:
		_bubble.visible = false
		_bubble.text = ""
		if _bubble_bg != null:
			_bubble_bg.visible = false
		if _bubble_tail != null:
			_bubble_tail.visible = false
