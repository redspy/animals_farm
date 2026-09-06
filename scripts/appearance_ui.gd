extends CanvasLayer
class_name AppearanceUI

## 꾸미기 화면 + **토큰 이전**.
##
## 두 기능을 한 화면에 둔 이유: 둘 다 "내 캐릭터 자체"에 관한 것이고, 최상위
## 버튼을 늘리면 오른쪽 위 버튼 열이 또 길어진다(세로 예산 — docs/design.md).
## 진입은 가방 화면의 `[꾸미기]`다(도감과 같은 결).
##
## 외형은 **고르는 즉시 내 캐릭터에 반영**한다(미리보기 = 실제). 다만 서버로
## 보내는 것은 `[닫기]`로 확정할 때뿐이다 — 색을 훑는 동안 방송을 도배하지
## 않는다. `[되돌리기]`는 열었을 때 상태로 복원한다.
##
## 선택지는 **서버가 보낸 목록**(`appearanceChoices`)만 그린다. 화이트리스트의
## 단일 출처가 서버이므로, 화면이 임의 값을 만들면 저장이 거절된다.

signal previewed(custom: Dictionary)      ## 고르는 즉시(내 화면만)
signal committed(custom: Dictionary)      ## 확정(서버로 보낸다)
signal token_import_requested(token: String)
signal closed

const PANEL_MIN := Vector2(560.0, 440.0)
const SWATCH := Vector2(52.0, 40.0)

## 토큰을 가려서 보여준다 — 어깨너머로 캐릭터를 잃는 것을 막는다.
const TOKEN_HEAD := 6
const TOKEN_TAIL := 4

var _choices: Dictionary = {}
var _custom: Dictionary = {}
var _initial: Dictionary = {}
var _effective: Dictionary = {}
var _token := ""
var _revealed := false
var _token_label: Label = null
var _hint_label: Label = null
var _import_field: LineEdit = null
var _import_confirm: Button = null
var _import_pending := false
var _rows: Dictionary = {}
var _hooks: TestHooks

## 머리 모양은 색이 아니라 형태라 이름을 보여준다.
const HAIR_LABELS := {
	"hair_short": "짧은 머리",
	"hair_long": "긴 머리",
	"hair_twin": "양갈래",
	"hair_bob": "단발",
	"hair_cap": "모자",
}

## `effective`는 **프리셋에 커스텀을 덮은 지금 외형**이다. 커스텀만 받으면
## 아직 바꾼 적 없는 항목에 아무 표시도 안 되어, 지금 무엇을 입고 있는지
## 화면에서 알 수 없다(실측: 빨간 옷인데 어떤 견본도 선택돼 보이지 않았다).
func setup(choices: Dictionary, custom: Dictionary, effective: Dictionary, token: String) -> void:
	_choices = choices
	_custom = custom.duplicate(true)
	_initial = custom.duplicate(true)
	_effective = effective.duplicate(true)
	_token = token

func _ready() -> void:
	_hooks = TestHooks.new()
	add_child(_hooks)
	# **가방 화면 위에 뜬다.** 같은 레이어(기본 1)에 두면 그리는 순서는 위여도
	# 입력은 먼저 만들어진 가방이 먹어서, 이 화면의 버튼을 눌러도 가방의
	# 버튼(판매 등)이 눌린다(실측: 색 견본을 탭했는데 물건이 팔렸다).
	layer = 5

	var dim := Button.new()
	dim.flat = true
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.focus_mode = Control.FOCUS_NONE
	dim.pressed.connect(close)
	add_child(dim)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.custom_minimum_size = Vector2(UiScale.panel_width(PANEL_MIN.x), PANEL_MIN.y)
	var style := StyleBoxFlat.new()
	style.bg_color = Palette.color("ui", "select_bg")
	style.corner_radius_top_left = 10
	style.corner_radius_top_right = 10
	style.corner_radius_bottom_left = 10
	style.corner_radius_bottom_right = 10
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	var title := Label.new()
	title.text = "꾸미기"
	title.add_theme_font_size_override("font_size", UiScale.font(20))
	title.add_theme_color_override("font_color", Palette.color("ui", "hud_text"))
	box.add_child(title)

	_add_row(box, "머리", "hair")
	_add_row(box, "피부", "skin")
	_add_row(box, "옷", "outfit")

	box.add_child(HSeparator.new())
	_build_token_section(box)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	buttons.alignment = BoxContainer.ALIGNMENT_END
	box.add_child(buttons)

	var revert := Button.new()
	revert.text = "되돌리기"
	revert.focus_mode = Control.FOCUS_NONE
	revert.custom_minimum_size = Vector2(UiScale.dim(120.0), UiScale.dim(42.0))
	revert.add_theme_font_size_override("font_size", UiScale.font(15))
	revert.pressed.connect(_on_revert)
	buttons.add_child(revert)
	_hooks.track("lookRevert", revert)

	var close_btn := Button.new()
	close_btn.text = "닫기"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.custom_minimum_size = Vector2(UiScale.dim(110.0), UiScale.dim(42.0))
	close_btn.add_theme_font_size_override("font_size", UiScale.font(15))
	close_btn.pressed.connect(close)
	buttons.add_child(close_btn)
	_hooks.track("lookClose", close_btn)

func _add_row(box: VBoxContainer, label_text: String, key: String) -> void:
	var options: Array = _choices.get(key, [])
	if options.is_empty():
		return
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	box.add_child(row)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = UiScale.dim(56.0)
	label.add_theme_font_size_override("font_size", UiScale.font(15))
	label.add_theme_color_override("font_color", Palette.color("ui", "hud_text"))
	row.add_child(label)

	var buttons: Array[Button] = []
	var index := 0
	for opt: Variant in options:
		var value := String(opt)
		index += 1
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(UiScale.dim(SWATCH.x), UiScale.dim(SWATCH.y))
		if key == "hair":
			# 머리는 색이 아니라 형태 — 이름을 쓴다.
			b.text = String(HAIR_LABELS.get(value, value))
			b.custom_minimum_size.x = UiScale.dim(96.0)
			b.clip_text = true
			b.add_theme_font_size_override("font_size", UiScale.font(13))
		else:
			# 색 견본: 버튼 배경을 그 색으로 칠한다(글자 없이 색만 보여준다).
			var sw := StyleBoxFlat.new()
			sw.bg_color = Palette.color("character", value)
			sw.corner_radius_top_left = 6
			sw.corner_radius_top_right = 6
			sw.corner_radius_bottom_left = 6
			sw.corner_radius_bottom_right = 6
			b.add_theme_stylebox_override("normal", sw)
			b.add_theme_stylebox_override("hover", sw)
			var picked := sw.duplicate() as StyleBoxFlat
			picked.border_width_left = 3
			picked.border_width_right = 3
			picked.border_width_top = 3
			picked.border_width_bottom = 3
			picked.border_color = Palette.color("ui", "hud_text")
			b.add_theme_stylebox_override("pressed", picked)
		b.pressed.connect(_on_pick.bind(key, value))
		row.add_child(b)
		buttons.append(b)
		_hooks.track("look_%s_%d" % [key, index], b)
	_rows[key] = {"options": options, "buttons": buttons}
	_refresh_row(key)

## 지금 고른 값에 표시를 맞춘다.
func _refresh_row(key: String) -> void:
	var row: Dictionary = _rows.get(key, {})
	if row.is_empty():
		return
	var options: Array = row["options"]
	var buttons: Array = row["buttons"]
	# 커스텀에 없으면 프리셋 값(지금 입고 있는 것)을 표시한다.
	var current := String(_custom.get(key, _effective.get(key, "")))
	for i in buttons.size():
		(buttons[i] as Button).button_pressed = String(options[i]) == current

func _on_pick(key: String, value: String) -> void:
	_custom[key] = value
	_refresh_row(key)
	# 미리보기 = 실제. 고르는 즉시 내 캐릭터에 반영한다(서버로는 안 보낸다).
	previewed.emit(_custom.duplicate(true))

func _on_revert() -> void:
	_custom = _initial.duplicate(true)
	for key: String in _rows.keys():
		_refresh_row(key)
	previewed.emit(_custom.duplicate(true))

# ---------------------------------------------------------------------------
# 토큰 이전
#
# 토큰이 곧 신원이다(docs/protocol.md §1) — 브라우저 저장소를 지우면 캐릭터를
# 잃고, 토큰을 옮기면 다른 기기에서 같은 캐릭터로 접속할 수 있다. 그래서 이
# 화면의 목적은 두 가지다: **잃지 않게 적어 둘 수 있게 하는 것**과, 옮겨 오는 것.
# ---------------------------------------------------------------------------

func _build_token_section(box: VBoxContainer) -> void:
	var head := Label.new()
	head.text = "내 토큰 (이 캐릭터의 열쇠)"
	head.add_theme_font_size_override("font_size", UiScale.font(16))
	head.add_theme_color_override("font_color", Palette.color("ui", "hud_text"))
	box.add_child(head)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	box.add_child(row)

	_token_label = Label.new()
	_token_label.text = _masked_token()
	_token_label.add_theme_font_size_override("font_size", UiScale.font(14))
	_token_label.add_theme_color_override("font_color", Palette.color("ui", "row_text"))
	_token_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_token_label.clip_text = true
	row.add_child(_token_label)

	var reveal := Button.new()
	reveal.text = "전체 보기"
	reveal.focus_mode = Control.FOCUS_NONE
	reveal.custom_minimum_size = Vector2(UiScale.dim(110.0), UiScale.dim(38.0))
	reveal.add_theme_font_size_override("font_size", UiScale.font(13))
	reveal.pressed.connect(func() -> void:
		_revealed = not _revealed
		reveal.text = "가리기" if _revealed else "전체 보기"
		_token_label.text = _masked_token())
	row.add_child(reveal)
	_hooks.track("tokenReveal", reveal)

	var copy := Button.new()
	copy.text = "복사"
	copy.focus_mode = Control.FOCUS_NONE
	copy.custom_minimum_size = Vector2(UiScale.dim(86.0), UiScale.dim(38.0))
	copy.add_theme_font_size_override("font_size", UiScale.font(13))
	copy.pressed.connect(_on_copy)
	row.add_child(copy)
	_hooks.track("tokenCopy", copy)

	_hint_label = Label.new()
	_hint_label.add_theme_font_size_override("font_size", UiScale.font(13))
	_hint_label.add_theme_color_override("font_color", Palette.color("ui", "warn_text"))
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_hint_label)

	var import_row := HBoxContainer.new()
	import_row.add_theme_constant_override("separation", 6)
	box.add_child(import_row)

	_import_field = LineEdit.new()
	_import_field.placeholder_text = "다른 기기의 토큰을 붙여넣기"
	_import_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_import_field.add_theme_font_size_override("font_size", UiScale.font(14))
	import_row.add_child(_import_field)
	_hooks.track("tokenField", _import_field)

	_import_confirm = Button.new()
	_import_confirm.text = "불러오기"
	_import_confirm.focus_mode = Control.FOCUS_NONE
	_import_confirm.custom_minimum_size = Vector2(UiScale.dim(120.0), UiScale.dim(38.0))
	_import_confirm.add_theme_font_size_override("font_size", UiScale.font(13))
	_import_confirm.pressed.connect(_on_import)
	import_row.add_child(_import_confirm)
	_hooks.track("tokenImport", _import_confirm)

func _masked_token() -> String:
	if _token.length() <= TOKEN_HEAD + TOKEN_TAIL:
		return _token
	if _revealed:
		return _token
	return "%s…%s" % [_token.substr(0, TOKEN_HEAD), _token.substr(_token.length() - TOKEN_TAIL)]

func _on_copy() -> void:
	DisplayServer.clipboard_set(_token)
	# 클립보드는 권한·비보안 컨텍스트에서 실패한다 — 실패해도 사용자가 직접
	# 읽어 적을 수 있게 전체를 펼쳐 준다.
	_revealed = true
	if _token_label != null:
		_token_label.text = _masked_token()

## **파괴적 동작이라 2단 확인**한다. 첫 누름은 경고로 바꾸기만 하고, 두 번째
## 누름에서 실제로 요청한다 — 이 기기의 현재 캐릭터는 목록에서 사라진다.
func _on_import() -> void:
	var text := _import_field.text.strip_edges() if _import_field != null else ""
	if text.is_empty():
		_toast("토큰을 붙여넣으세요")
		return
	if not _import_pending:
		_import_pending = true
		_import_confirm.text = "정말 불러오기?"
		_toast("이 기기의 현재 캐릭터는 목록에서 사라집니다")
		return
	token_import_requested.emit(text)

## 이 화면 안의 안내는 부모(world)의 토스트를 쓰지 않고 **전용 라벨**로 보여준다.
## 모달 뒤의 토스트는 가려서 읽히지 않고, 토큰 라벨을 덮어 쓰면 방금 확인하려던
## 토큰이 사라진다(실측).
func _toast(text: String) -> void:
	if _hint_label != null:
		_hint_label.text = text

func close() -> void:
	# 확정은 닫을 때 한 번만 서버로 보낸다.
	if _custom != _initial:
		committed.emit(_custom.duplicate(true))
	closed.emit()
	queue_free()

## **확정하지 않고** 닫는다(토큰 이전처럼 이 캐릭터가 바뀌는 경우).
##
## 왜 필요한가: close()는 바뀐 외형을 committed로 보내는데, 토큰을 갈아끼운
## 뒤에 그것이 나가면 **새 토큰 슬롯에 옛 외형이 저장되고 옛 소켓으로 전송**된다.
func discard() -> void:
	closed.emit()
	queue_free()

## 불러오기가 거절됐을 때 2단 확인을 처음 상태로 되돌린다 — 그러지 않으면
## 다음 붙여넣기는 한 번 누름으로 즉시 실행된다(확인이 무력화된다).
func reset_import() -> void:
	_import_pending = false
	if _import_confirm != null:
		_import_confirm.text = "불러오기"
