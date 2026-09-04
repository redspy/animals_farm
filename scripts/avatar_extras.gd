extends Node3D
class_name AvatarExtras

## 캐릭터 머리 위에 붙는 이름표 · 채팅 말풍선 · 이모티콘.
## 내 캐릭터와 다른 기기의 캐릭터가 같은 표현을 쓰도록 한 곳에 모았다 —
## 나만 보이거나 남만 보이는 표현이 생기면 "실시간으로 잘 보이는지"를
## 검증할 수 없다(컨셉 요구사항).

const NAME_HEIGHT := 2.35
const BUBBLE_HEIGHT := 3.05
const NAME_FONT_SIZE := 28
const BUBBLE_FONT_SIZE := 30
## 3D 공간에서의 글자 크기. 카메라(직교 size 9.5, 540px)에서 약 16px이 되도록.
const LABEL_PIXEL_SIZE := 0.010
const CHAT_SHOW_SEC := 5.0
const CHAT_WRAP_WIDTH := 420.0
## 말풍선 배경 여백(px). 글자 폭을 재서 이만큼 키운 텍스처를 만든다.
const BUBBLE_PAD := Vector2(34, 26)

## 감정 표현: 큰 이모지가 **공중으로 떠오르며 사라진다**(사용자 요청).
const EMOTE_FONT_SIZE := 110
const EMOTE_PIXEL_SIZE := 0.012
const EMOTE_START_HEIGHT := 2.5
const EMOTE_RISE := 1.9
const EMOTE_DURATION := 1.5
## 떠오르는 동안의 좌우 흔들림(월드 단위) — 곧게만 올라가면 딱딱하다.
const EMOTE_SWAY := 0.22

var _name_label: Label3D
var _bubble: Label3D
## 말풍선 배경. QuadMesh(각진 판) 대신 **둥근 모서리·테두리·꼬리를 그린 텍스처**를
## 쓴다(사용자 요청: 더 귀여운 디자인).
var _bubble_bg: Sprite3D
var _bubble_timer := 0.0
## _ready 이전에 호출될 수 있어(add_child 직후) 값을 들고 있다가 적용한다.
var _pending_name := ""
var _pending_bubble := ""
var _pending_bubble_sec := 0.0
var _pending_emote := ""

func _ready() -> void:
	_name_label = _make_label(NAME_HEIGHT, NAME_FONT_SIZE, Palette.color("ui", "hud_text"))
	add_child(_name_label)

	_bubble_bg = Sprite3D.new()
	_bubble_bg.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	_bubble_bg.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	_bubble_bg.pixel_size = LABEL_PIXEL_SIZE
	_bubble_bg.no_depth_test = true
	_bubble_bg.render_priority = 1
	_bubble_bg.visible = false
	add_child(_bubble_bg)

	_bubble = _make_label(BUBBLE_HEIGHT, BUBBLE_FONT_SIZE, Palette.color("ui", "bubble_text"))
	_bubble.outline_size = 0            # 밝은 배경 위에서는 외곽선이 지저분하다
	_bubble.render_priority = 2
	_bubble.visible = false
	add_child(_bubble)

	_name_label.text = _pending_name
	if not _pending_bubble.is_empty():
		_show_bubble(_pending_bubble, _pending_bubble_sec)
		_pending_bubble = ""
	if not _pending_emote.is_empty():
		show_emote(_pending_emote)
		_pending_emote = ""

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

## 글자 크기를 재서 그 크기의 둥근 말풍선 텍스처를 만들어 붙인다.
func _fit_bubble_background(text: String) -> void:
	if _bubble_bg == null or _bubble == null:
		return
	var font: Font = _bubble.font if _bubble.font != null else ThemeDB.get_default_theme().default_font
	var px := Vector2(180, 40)
	if font != null:
		px = font.get_multiline_string_size(
			text, HORIZONTAL_ALIGNMENT_CENTER, CHAT_WRAP_WIDTH, BUBBLE_FONT_SIZE
		)
	var w := int(round(minf(px.x, CHAT_WRAP_WIDTH) + BUBBLE_PAD.x * 2.0))
	var h := int(round(px.y + BUBBLE_PAD.y * 2.0)) + BubbleTexture.TAIL_H
	_bubble_bg.texture = BubbleTexture.get_texture(
		w, h, Palette.color("ui", "bubble_bg"), Palette.color("ui", "bubble_border")
	)
	# 텍스처의 꼬리가 아래를 향하므로, 글자는 몸통 중앙에 오도록 배경을 살짝 내린다.
	var tail_world := float(BubbleTexture.TAIL_H) * LABEL_PIXEL_SIZE
	_bubble_bg.position = Vector3(0, BUBBLE_HEIGHT - tail_world * 0.5, -0.01)

func set_name_text(text: String) -> void:
	_pending_name = text
	if _name_label != null:
		_name_label.text = text

func show_chat(text: String) -> void:
	_show_bubble(text, CHAT_SHOW_SEC)

## 감정 표현: 큰 이모지를 만들어 **공중으로 떠오르며 사라지게** 한다.
## 말풍선을 재사용하지 않는 이유: 채팅 중에 감정을 표현하면 말이 지워지고,
## 크기도 말풍선에 갇혀 작게 보인다.
func show_emote(glyph: String) -> void:
	if not is_inside_tree():
		_pending_emote = glyph
		return
	var label := Label3D.new()
	label.text = glyph
	label.font_size = EMOTE_FONT_SIZE
	label.pixel_size = EMOTE_PIXEL_SIZE
	label.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	label.no_depth_test = true
	label.render_priority = 3
	label.outline_size = 12
	label.outline_modulate = Palette.color("ui", "emote_glow")
	label.position = Vector3(0, EMOTE_START_HEIGHT, 0)
	add_child(label)

	# 떠오르며 커지고 흐려진다. 좌우로 살짝 흔들어 생기를 준다.
	var sway := EMOTE_SWAY if randf() < 0.5 else -EMOTE_SWAY
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "position",
		Vector3(sway, EMOTE_START_HEIGHT + EMOTE_RISE, 0), EMOTE_DURATION) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(label, "scale", Vector3(1.35, 1.35, 1.35), EMOTE_DURATION) \
		.set_ease(Tween.EASE_OUT)
	# 마지막 40%에서만 사라지기 시작해, 뜨자마자 흐려지지 않게 한다.
	tween.tween_property(label, "modulate:a", 0.0, EMOTE_DURATION * 0.4) \
		.set_delay(EMOTE_DURATION * 0.6)
	tween.chain().tween_callback(label.queue_free)

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
