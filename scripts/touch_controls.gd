extends CanvasLayer
class_name TouchControls

## 폰 브라우저용 터치 조작. 설계 근거는
## docs/meetings/2026-09-04-1150-폰-터치-조작-설계.md.
##
## 핵심 결정 세 가지:
## 1. 이동은 **플로팅 가상 조이스틱** — 왼쪽 하단 영역 어디를 눌러도 그 지점이
##    중심이 된다. 고정 조이스틱은 엄지 위치 편차 때문에 매번 눈으로 위치를
##    확인해야 해서 시선을 화면 아래로 끌어내린다.
## 2. 판매 버튼은 두지 않는다 — 되돌릴 수 없는 동작이라 오조작 한 번에 수집품이
##    사라진다. 가방 줄을 탭해 확인 시트를 거치게 한다.
## 3. 이모티콘은 롱프레스 휠이 아니라 하단 시트 — 모바일 웹에서 롱프레스는
##    브라우저의 텍스트 선택/컨텍스트 메뉴에 가로채인다.
##
## 멀티터치를 직접 다룬다(InputEventScreenTouch/Drag의 index 추적):
## 이동하면서 채집을 누르는 동시 입력이 흔하고, 마우스 에뮬레이션만으로는
## 손가락 두 개를 구분할 수 없다.

signal action_pressed          # 채집/줍기 (기존 Space)
signal chat_pressed
signal drop_pressed
signal emote_selected(emote_id: String)
signal sell_requested          # (남겨둠) 확인 시트에서 전부 판매를 확정한 경우
signal inventory_pressed       # 가방 화면 열기

## 터치 타깃 최소 크기. 44는 접근성 하한, 주 액션은 더 크게 잡는다.
const BTN_MAIN := 72.0
const BTN_MED := 56.0
const BTN_SMALL := 48.0
const MARGIN := 26.0
## 버튼 글자 크기 — 기본값은 72px 버튼에 넘쳐서 잘렸다(2026-09-04 세로 실측).
const BTN_FONT_SIZE := 18
## 조이스틱을 받는 영역: 화면 왼쪽 절반의 아래쪽. 이 안을 누르면 그 지점이 중심.
const STICK_AREA_W_RATIO := 0.5
const STICK_AREA_H_RATIO := 0.55
## 손가락이 이만큼 움직이면 최대 속도(픽셀). 작을수록 예민하다.
const STICK_RADIUS := 84.0
## 이 비율 미만의 기울기는 무시한다(엄지 떨림으로 캐릭터가 스르륵 움직이는 것 방지).
const STICK_DEADZONE := 0.18

var move_vector := Vector2.ZERO   # world/player가 매 프레임 읽는다

var _stick_touch_index := -1
var _stick_origin := Vector2.ZERO
var _stick_current := Vector2.ZERO
var _stick_visual: Control
var _emote_sheet: Control
var _sell_sheet: Control
var _emotes: Array = []
var _hooks: TestHooks

func setup(emotes: Array) -> void:
	_emotes = emotes

func _ready() -> void:
	_hooks = TestHooks.new()
	add_child(_hooks)
	# 조이스틱은 컨트롤이 아니라 영역이므로 대표 지점을 알려준다.
	var vp := get_viewport().get_visible_rect().size
	_hooks.track_point("stickCenter", Vector2(vp.x * 0.25, vp.y * 0.80))
	_build_buttons()
	_build_stick_visual()
	_build_emote_sheet()
	_build_sell_sheet()

# ---------------------------------------------------------------------------
# 버튼
# ---------------------------------------------------------------------------

func _build_buttons() -> void:
	# 우하단부터 위로 쌓는다 — 엄지에 가까운 자리가 주 액션.
	_add_button("채집", BTN_MAIN, Vector2(-(MARGIN + BTN_MAIN), -(MARGIN + BTN_MAIN)),
		func() -> void: action_pressed.emit())
	_add_button("채팅", BTN_MED, Vector2(-(MARGIN + BTN_MED), -(MARGIN + BTN_MAIN + 12.0 + BTN_MED)),
		func() -> void: chat_pressed.emit())
	_add_button("감정", BTN_MED, Vector2(-(MARGIN + BTN_MAIN + 12.0 + BTN_MED), -(MARGIN + BTN_MED)),
		func() -> void: _toggle_emote_sheet(true))
	_add_button("버림", BTN_SMALL, Vector2(-(MARGIN + BTN_MED), -(MARGIN + BTN_MAIN + 12.0 + BTN_MED + 12.0 + BTN_SMALL)),
		func() -> void: drop_pressed.emit())
	# 가방 버튼 — 무엇을 팔지/버릴지 고르는 화면을 연다. 상시 노출되는 판매
	# 버튼을 두지 않는 이유는 그대로다(되돌릴 수 없는 동작).
	_add_button("가방", BTN_MED, Vector2(-(MARGIN + BTN_MAIN + 12.0 + BTN_MED), -(MARGIN + BTN_MED + 12.0 + BTN_MED)),
		func() -> void: inventory_pressed.emit())

## offset은 우하단 앵커 기준(음수가 왼쪽/위쪽). 앵커를 쓰는 이유: 절대좌표는
## 세로 모드나 좁은 화면에서 화면 밖으로 나간다(기존 HUD가 그랬다).
func _add_button(text: String, size: float, offset: Vector2, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(size, size)
	b.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	b.offset_left = offset.x
	b.offset_top = offset.y
	b.offset_right = offset.x + size
	b.offset_bottom = offset.y + size
	b.focus_mode = Control.FOCUS_NONE   # 버튼이 포커스를 먹으면 키보드 입력이 막힌다
	# 글자가 버튼을 넘쳐 잘리지 않게 한다.
	b.add_theme_font_size_override("font_size", BTN_FONT_SIZE)
	b.clip_text = true
	b.add_theme_color_override("font_color", Palette.color("ui", "hud_text"))
	b.pressed.connect(on_press)
	add_child(b)
	# E2E 테스트가 정확히 탭할 수 있게 위치를 공개한다(scripts/test_hooks.gd).
	_mark(text, b)
	return b

# ---------------------------------------------------------------------------
# 플로팅 조이스틱
# ---------------------------------------------------------------------------

## 버튼 라벨을 테스트 키로 바꾼다(라벨을 고쳐도 테스트가 깨지지 않도록 매핑).
const TEST_KEYS := {
	"채집": "actionButton",
	"채팅": "chatButton",
	"감정": "emoteButton",
	"버림": "dropButton",
	"가방": "bagButton",
}

func _mark(label: String, control: Control) -> void:
	var key: String = TEST_KEYS.get(label, "")
	if key.is_empty() or _hooks == null:
		return
	_hooks.track(key, control)

func _build_stick_visual() -> void:
	_stick_visual = Control.new()
	_stick_visual.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stick_visual.set_anchors_preset(Control.PRESET_FULL_RECT)
	_stick_visual.draw.connect(_draw_stick)
	add_child(_stick_visual)

func _draw_stick() -> void:
	if _stick_touch_index == -1:
		return
	var base := Palette.color("ui", "stick_base")
	var knob := Palette.color("ui", "stick_knob")
	_stick_visual.draw_circle(_stick_origin, STICK_RADIUS, base)
	_stick_visual.draw_circle(_stick_current, STICK_RADIUS * 0.42, knob)

## world.gd가 "이 탭이 조이스틱 영역인가"를 묻는다 — 그 영역의 탭은 이동
## 지시가 아니라 조이스틱 조작이다.
func is_in_stick_area(pos: Vector2) -> bool:
	return _in_stick_area(pos)

func _in_stick_area(pos: Vector2) -> bool:
	var vp := get_viewport().get_visible_rect().size
	return pos.x <= vp.x * STICK_AREA_W_RATIO and pos.y >= vp.y * (1.0 - STICK_AREA_H_RATIO)

func _input(event: InputEvent) -> void:
	# 시트가 열려 있으면 조이스틱을 잡지 않는다(시트 밖 탭으로 닫기 위함).
	if _emote_sheet != null and _emote_sheet.visible:
		return
	if _sell_sheet != null and _sell_sheet.visible:
		return

	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			if _stick_touch_index == -1 and _in_stick_area(touch.position):
				_stick_touch_index = touch.index
				_stick_origin = touch.position
				_stick_current = touch.position
				_stick_visual.queue_redraw()
		elif touch.index == _stick_touch_index:
			_release_stick()
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if drag.index != _stick_touch_index:
			return
		_stick_current = drag.position
		_update_move_vector()
		_stick_visual.queue_redraw()

func _release_stick() -> void:
	_stick_touch_index = -1
	move_vector = Vector2.ZERO
	_stick_visual.queue_redraw()

func _update_move_vector() -> void:
	var delta := _stick_current - _stick_origin
	var length := delta.length()
	if length <= STICK_RADIUS * STICK_DEADZONE:
		move_vector = Vector2.ZERO
		return
	# 반경을 넘어도 1.0로 클램프 — 손가락을 멀리 끌어도 더 빨라지지 않는다.
	move_vector = delta.normalized() * minf(length / STICK_RADIUS, 1.0)

# ---------------------------------------------------------------------------
# 하단 시트 (이모티콘 / 판매 확인)
# ---------------------------------------------------------------------------

func _make_sheet() -> Control:
	var sheet := Control.new()
	sheet.visible = false
	sheet.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(sheet)

	# 시트 밖을 탭하면 닫힌다.
	var dim := Button.new()
	dim.flat = true
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.focus_mode = Control.FOCUS_NONE
	dim.pressed.connect(func() -> void: sheet.visible = false)
	sheet.add_child(dim)
	return sheet

func _build_emote_sheet() -> void:
	_emote_sheet = _make_sheet()

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	panel.offset_top = -220.0
	panel.offset_bottom = -MARGIN
	panel.offset_left = MARGIN
	panel.offset_right = -MARGIN
	_emote_sheet.add_child(panel)

	var grid := GridContainer.new()
	# 6종이면 3×2. 데이터가 늘면 열 수를 유지하고 행이 늘어난다.
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	panel.add_child(grid)

	for e: Variant in _emotes:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var emote := e as Dictionary
		var b := Button.new()
		b.text = "%s\n%s" % [String(emote.get("glyph", "?")), String(emote.get("label", ""))]
		b.custom_minimum_size = Vector2(96, 76)
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(func() -> void:
			emote_selected.emit(String(emote.get("id", "")))
			_emote_sheet.visible = false
		)
		grid.add_child(b)
		if _hooks != null:
			_hooks.track("emoteItem%d" % grid.get_child_count(), b)

func _build_sell_sheet() -> void:
	_sell_sheet = _make_sheet()

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(420, 190)
	_sell_sheet.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	var label := Label.new()
	label.text = "가방에 있는 물건을 전부 팔까요?\n판매는 되돌릴 수 없습니다."
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", Palette.color("ui", "warn_text"))
	box.add_child(label)

	var yes := Button.new()
	yes.text = "전부 판매"
	yes.custom_minimum_size = Vector2(0, BTN_MED)
	yes.focus_mode = Control.FOCUS_NONE
	yes.pressed.connect(func() -> void:
		_sell_sheet.visible = false
		sell_requested.emit()
	)
	box.add_child(yes)

	var no := Button.new()
	no.text = "취소"
	no.custom_minimum_size = Vector2(0, BTN_MED)
	no.focus_mode = Control.FOCUS_NONE
	no.pressed.connect(func() -> void: _sell_sheet.visible = false)
	box.add_child(no)

func _toggle_emote_sheet(show_it: bool) -> void:
	if _emote_sheet != null:
		_emote_sheet.visible = show_it
	if show_it:
		_release_stick()

## world.gd가 가방 줄 탭을 받아 호출한다.
func show_sell_confirm() -> void:
	if _sell_sheet != null:
		_sell_sheet.visible = true
	_release_stick()

## 시트가 열려 있는 동안에는 게임 조작을 받지 않아야 한다.
func is_sheet_open() -> bool:
	return (_emote_sheet != null and _emote_sheet.visible) \
		or (_sell_sheet != null and _sell_sheet.visible)
