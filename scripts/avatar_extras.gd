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

var _name_label: Label3D
var _bubble: Label3D
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
	_bubble = _make_label(BUBBLE_HEIGHT, BUBBLE_FONT_SIZE, Palette.color("ui", "chat_text"))
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
	_bubble.visible = true
	_bubble_timer = seconds

func _process(delta: float) -> void:
	if _bubble_timer <= 0.0:
		return
	_bubble_timer -= delta
	if _bubble_timer <= 0.0 and _bubble != null:
		_bubble.visible = false
		_bubble.text = ""
