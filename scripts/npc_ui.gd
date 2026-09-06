extends CanvasLayer
class_name NpcUI

## 이웃 동물과의 대화창. **아래쪽 시트**로 띄운다 — 화면 중앙을 덮으면 대화
## 상대(동물)가 가려져서 누구와 말하는지 보이지 않는다.
##
## 이 화면은 정산하지 않고 **요청만 알린다**(가방 화면과 같은 규칙) — 차감과
## 보상은 서버가 계산한다(docs/protocol.md의 `npc_deliver`).

signal deliver_requested(npc_id: String)
signal closed

const PANEL_MIN_W := 520.0
const PANEL_MIN_H := 170.0

var _npc_id := ""
## 지금 건넬 수 있는지. **버튼 문구로 판정하지 않는다** — 문구를 바꾸면 조용히
## "닫기"처럼 동작한다(리뷰 지적).
var _can_deliver := false
var _title: Label
var _body: Label
var _action: Button
var _hooks: TestHooks

func _ready() -> void:
	_hooks = TestHooks.new()
	add_child(_hooks)
	# **가방 화면 위에 뜬다.** 같은 레이어(기본 1)에 두면 그리는 순서는 위여도
	# 입력은 먼저 만들어진 가방이 먹어서, 이 화면의 버튼을 눌러도 가방의
	# 버튼(판매 등)이 눌린다(실측: 색 견본을 탭했는데 물건이 팔렸다).
	layer = 5

	# 뒤를 탭하면 닫힌다(시트 밖 탭 = 닫기, 이모티콘 시트와 같은 규칙).
	var dim := Button.new()
	dim.flat = true
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.focus_mode = Control.FOCUS_NONE
	dim.pressed.connect(close)
	add_child(dim)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.offset_left = 12.0
	panel.offset_right = -12.0
	panel.offset_bottom = -12.0
	panel.custom_minimum_size = Vector2(UiScale.panel_width(PANEL_MIN_W), PANEL_MIN_H)
	var style := StyleBoxFlat.new()
	style.bg_color = Palette.color("npc", "bubble_bg")
	style.corner_radius_top_left = 12
	style.corner_radius_top_right = 12
	style.corner_radius_bottom_left = 12
	style.corner_radius_bottom_right = 12
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", UiScale.font(20))
	_title.add_theme_color_override("font_color", Palette.color("npc", "bubble_text"))
	box.add_child(_title)

	_body = Label.new()
	_body.add_theme_font_size_override("font_size", UiScale.font(16))
	_body.add_theme_color_override("font_color", Palette.color("npc", "bubble_text"))
	# 대사는 길 수 있다 — 접어서 보여준다(자르면 부탁 내용이 사라진다).
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.custom_minimum_size.y = UiScale.dim(46.0)
	box.add_child(_body)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.alignment = BoxContainer.ALIGNMENT_END
	box.add_child(row)

	_action = Button.new()
	_action.focus_mode = Control.FOCUS_NONE
	_action.custom_minimum_size = Vector2(UiScale.dim(150.0), UiScale.dim(44.0))
	_action.add_theme_font_size_override("font_size", UiScale.font(16))
	_action.pressed.connect(_on_action)
	row.add_child(_action)
	_hooks.track("npcAction", _action)

	var close_btn := Button.new()
	close_btn.text = "닫기"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.custom_minimum_size = Vector2(UiScale.dim(96.0), UiScale.dim(44.0))
	close_btn.add_theme_font_size_override("font_size", UiScale.font(16))
	close_btn.pressed.connect(close)
	row.add_child(close_btn)
	_hooks.track("npcClose", close_btn)

## 내용을 채운다. `can_deliver`가 참일 때만 버튼이 정산을 요청한다 — 부족한
## 상태에서 같은 버튼을 두면 눌러도 아무 일이 없는 버튼이 된다.
func show_talk(npc_id: String, npc_label: String, text: String, can_deliver: bool) -> void:
	_npc_id = npc_id
	_can_deliver = can_deliver
	if _title != null:
		_title.text = npc_label
	if _body != null:
		_body.text = text
	if _action != null:
		_action.text = "가져왔어" if can_deliver else "알겠어"
		_action.disabled = false

func _on_action() -> void:
	if _can_deliver and _action != null:
		# 연타로 두 번 보내지 않게 즉시 잠근다 — 서버도 400ms 간격 제한이
		# 있지만, 눌리는 버튼이 남아 있으면 "안 먹혔나?" 싶어 다시 누른다.
		_action.disabled = true
		deliver_requested.emit(_npc_id)
		return
	close()

func close() -> void:
	closed.emit()
	queue_free()
