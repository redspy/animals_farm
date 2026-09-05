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
## 조이스틱 사용 여부가 바뀔 때. 세이브에 남겨 다음 접속에도 유지한다.
signal joystick_toggled(enabled: bool)

## 터치 타깃 최소 크기. 44는 접근성 하한, 주 액션은 더 크게 잡는다.
const BTN_MAIN := 72.0
const BTN_MED := 56.0
const BTN_SMALL := 48.0
const MARGIN := 26.0
## 버튼 글자 크기 — 기본값은 72px 버튼에 넘쳐서 잘렸다(2026-09-04 세로 실측).
## 좁은 화면에서는 UiScale이 한 단계 키우지만, 작은 버튼은 그만큼 키우면 또
## 잘린다(2026-09-05: 48px 버튼의 "버림"이 "버"로 잘렸다) — 버튼 폭에 맞춰
## 깎는다. 한글 두 글자가 들어가려면 글자 크기가 폭의 약 1/2.6 이하여야 한다.
const BTN_FONT_SIZE := 18
const BTN_FONT_WIDTH_RATIO := 2.6
## 조이스틱 on/off 버튼 폭. 글자를 키우면 "스틱 OFF"가 잘리므로 같이 넓힌다.
const JOYSTICK_BTN_WIDTH := 118.0
## 이모티콘 시트 한 칸의 최대 크기와 하한(px). 실제 크기는 남는 폭에서 역산한다.
const EMOTE_CELL := Vector2(96.0, 76.0)
const EMOTE_CELL_MIN := 56.0
const SHEET_GAP := 10.0
const SHEET_PADDING := 12.0
## 조이스틱을 받는 영역: 화면 왼쪽 절반의 아래쪽. 이 안을 누르면 그 지점이 중심.
const STICK_AREA_W_RATIO := 0.5
const STICK_AREA_H_RATIO := 0.55
## 손가락이 이만큼 움직이면 최대 속도(픽셀). 작을수록 예민하다.
const STICK_RADIUS := 84.0
## 이 비율 미만의 기울기는 무시한다(엄지 떨림으로 캐릭터가 스르륵 움직이는 것 방지).
const STICK_DEADZONE := 0.18

var move_vector := Vector2.ZERO   # world/player가 매 프레임 읽는다
## 조이스틱을 쓸지. 끄면 이동은 탭-투-무브로만 한다 — 엄지로 화면을 가리는 게
## 싫거나 탭 이동만으로 충분한 사람이 있다(사용자 요청).
var joystick_enabled := true
var _joystick_button: Button
## 채팅 버튼. iOS 키보드용 핫스팟을 게시하려면 위치를 알아야 한다.
var _chat_button: Button = null

var _stick_touch_index := -1
var _stick_origin := Vector2.ZERO
var _stick_current := Vector2.ZERO
var _stick_visual: Control
var _emote_sheet: Control
var _sell_sheet: Control
var _emotes: Array = []
var _hooks: TestHooks

func setup(emotes: Array, joystick_on: bool = true) -> void:
	_emotes = emotes
	joystick_enabled = joystick_on

func _ready() -> void:
	_hooks = TestHooks.new()
	add_child(_hooks)
	# 채팅 버튼 위치를 셸에 알려 iOS에서 키보드가 뜨게 한다(web/shell.html의
	# afHotspots 주석 참고). 웹이 아니면 할 일이 없다.
	set_process(OS.has_feature("web"))
	# 조이스틱은 컨트롤이 아니라 영역이므로 대표 지점을 알려준다.
	var vp := get_viewport().get_visible_rect().size
	_hooks.track_point("stickCenter", Vector2(vp.x * 0.25, vp.y * 0.80))
	_build_buttons()
	_build_stick_visual()
	_build_emote_sheet()
	_build_sell_sheet()

## 채팅 버튼 영역을 캔버스 비율로 셸에 게시한다.
##
## 왜 주기적으로 하는가: 화면 회전·키보드 등장으로 버튼 위치가 바뀌고, 한 번만
## 게시하면 그때부터 엉뚱한 자리를 누를 때 키보드가 뜬다. 0.5초 간격이면
## 사람이 버튼을 찾아 누르는 사이에 항상 최신값이 된다.
const HOTSPOT_INTERVAL := 0.5
var _hotspot_timer := 0.0

func _process(delta: float) -> void:
	_hotspot_timer += delta
	if _hotspot_timer < HOTSPOT_INTERVAL:
		return
	_hotspot_timer = 0.0
	_publish_chat_hotspot()

func _publish_chat_hotspot() -> void:
	if _chat_button == null or not is_instance_valid(_chat_button):
		return
	var vp := get_viewport()
	if vp == null:
		return
	var size := vp.get_visible_rect().size
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var r := _chat_button.get_global_rect()
	# 손가락이 버튼 경계에 살짝 걸쳐도 키보드가 뜨도록 조금 넓게 잡는다.
	var pad := 6.0
	JavaScriptBridge.eval("""
		(function(){
			// afHotspots는 셸(web/shell.html)이 만든다 — 여기서 만들면 로드
			// 순서가 뒤집힐 때 두 참조가 갈라진다.
			if (window.afHotspots) {
				window.afHotspots.chat = [%f, %f, %f, %f, 'af-chat-input'];
			}
		})();
	""" % [
		maxf((r.position.x - pad) / size.x, 0.0),
		maxf((r.position.y - pad) / size.y, 0.0),
		(r.size.x + pad * 2.0) / size.x,
		(r.size.y + pad * 2.0) / size.y,
	], true)

# ---------------------------------------------------------------------------
# 버튼
# ---------------------------------------------------------------------------

func _build_buttons() -> void:
	# 우하단부터 위로 쌓는다 — 엄지에 가까운 자리가 주 액션.
	_add_button("채집", BTN_MAIN, Vector2(-(MARGIN + BTN_MAIN), -(MARGIN + BTN_MAIN)),
		func() -> void: action_pressed.emit())
	_chat_button = _add_button("채팅", BTN_MED,
		Vector2(-(MARGIN + BTN_MED), -(MARGIN + BTN_MAIN + 12.0 + BTN_MED)),
		func() -> void: chat_pressed.emit())
	_add_button("감정", BTN_MED, Vector2(-(MARGIN + BTN_MAIN + 12.0 + BTN_MED), -(MARGIN + BTN_MED)),
		func() -> void: _toggle_emote_sheet(true))
	_add_button("버림", BTN_SMALL, Vector2(-(MARGIN + BTN_MED), -(MARGIN + BTN_MAIN + 12.0 + BTN_MED + 12.0 + BTN_SMALL)),
		func() -> void: drop_pressed.emit())
	# 가방 버튼 — 무엇을 팔지/버릴지 고르는 화면을 연다. 상시 노출되는 판매
	# 버튼을 두지 않는 이유는 그대로다(되돌릴 수 없는 동작).
	_add_button("가방", BTN_MED, Vector2(-(MARGIN + BTN_MAIN + 12.0 + BTN_MED), -(MARGIN + BTN_MED + 12.0 + BTN_MED)),
		func() -> void: inventory_pressed.emit())
	# 조이스틱 on/off — 왼쪽 위(조이스틱 영역 밖, 엄지에서 먼 자리)에 둔다.
	# 자주 누르는 버튼이 아니고, 조이스틱 영역에 두면 조작과 겹친다.
	_joystick_button = Button.new()
	var toggle_w := UiScale.dim(JOYSTICK_BTN_WIDTH)
	_joystick_button.custom_minimum_size = Vector2(toggle_w, BTN_SMALL)
	_joystick_button.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_joystick_button.offset_left = MARGIN
	_joystick_button.offset_bottom = -MARGIN
	_joystick_button.offset_top = -(MARGIN + BTN_SMALL)
	_joystick_button.offset_right = MARGIN + toggle_w
	_joystick_button.focus_mode = Control.FOCUS_NONE
	_joystick_button.add_theme_font_size_override("font_size", UiScale.font(BTN_FONT_SIZE))
	_joystick_button.clip_text = true
	_joystick_button.pressed.connect(_toggle_joystick)
	add_child(_joystick_button)
	_refresh_joystick_button()
	if _hooks != null:
		_hooks.track("joystickToggle", _joystick_button)

## 버튼 폭 안에 두 글자가 들어가는 최대 글자 크기.
func _btn_font_size(button_size: float) -> int:
	return mini(UiScale.font(BTN_FONT_SIZE), int(floor(button_size / BTN_FONT_WIDTH_RATIO)))

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
	b.add_theme_font_size_override("font_size", _btn_font_size(size))
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

func _toggle_joystick() -> void:
	joystick_enabled = not joystick_enabled
	if not joystick_enabled:
		_release_stick()
	_refresh_joystick_button()
	joystick_toggled.emit(joystick_enabled)

func _refresh_joystick_button() -> void:
	if _joystick_button != null:
		_joystick_button.text = "스틱 ON" if joystick_enabled else "스틱 OFF"

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
	# 조이스틱을 껐으면 그 영역도 평범한 월드 탭으로 쓸 수 있어야 한다 —
	# 안 그러면 화면 왼쪽 아래를 눌러도 아무 일도 일어나지 않는다.
	return joystick_enabled and _in_stick_area(pos)

func _in_stick_area(pos: Vector2) -> bool:
	var vp := get_viewport().get_visible_rect().size
	return pos.x <= vp.x * STICK_AREA_W_RATIO and pos.y >= vp.y * (1.0 - STICK_AREA_H_RATIO)

func _input(event: InputEvent) -> void:
	# 시트가 열려 있으면 조이스틱을 잡지 않는다(시트 밖 탭으로 닫기 위함).
	if _emote_sheet != null and _emote_sheet.visible:
		return
	if _sell_sheet != null and _sell_sheet.visible:
		return

	if not joystick_enabled:
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

	# 버튼 크기는 **화면에 남는 폭에서 역산한다**. 고정값에 좁은 화면 배율을
	# 곱했더니 3열이 화면을 넘어(3×130+간격 = 409 > 가용 359) 마지막 열이 화면
	# 밖으로 밀려 탭이 안 됐다(2026-09-05 리뷰 지적, 폰 411px 기준).
	var cols := 3
	var rows := maxi(int(ceil(float(_emotes.size()) / float(cols))), 1)
	var avail := get_viewport().get_visible_rect().size.x - MARGIN * 2.0 - SHEET_PADDING * 2.0
	var cell_w := clampf(
		(avail - float(cols - 1) * SHEET_GAP) / float(cols), EMOTE_CELL_MIN, UiScale.dim(EMOTE_CELL.x))
	var cell_h := minf(UiScale.dim(EMOTE_CELL.y), cell_w * 0.8)
	var sheet_h := float(rows) * cell_h + float(rows - 1) * SHEET_GAP + SHEET_PADDING * 2.0

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	panel.offset_top = -(MARGIN + sheet_h)
	panel.offset_bottom = -MARGIN
	panel.offset_left = MARGIN
	panel.offset_right = -MARGIN
	_emote_sheet.add_child(panel)

	var grid := GridContainer.new()
	# 6종이면 3×2. 데이터가 늘면 열 수를 유지하고 행이 늘어난다.
	grid.columns = cols
	grid.add_theme_constant_override("h_separation", int(SHEET_GAP))
	grid.add_theme_constant_override("v_separation", int(SHEET_GAP))
	panel.add_child(grid)

	for e: Variant in _emotes:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var emote := e as Dictionary
		var b := Button.new()
		b.text = "%s\n%s" % [String(emote.get("glyph", "?")), String(emote.get("label", ""))]
		b.custom_minimum_size = Vector2(cell_w, cell_h)
		# 글자가 칸보다 길면 칸을 벌리지 말고 잘라야 한다 — custom_minimum_size는
		# 하한이라, 이게 없으면 글자 폭이 칸을 밀어내 시트가 화면을 넘는다.
		b.clip_text = true
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
	# PRESET_CENTER는 앵커만 화면 중앙에 두고, 크기는 grow 방향으로 자란다.
	# 기본값(END)이면 중앙에서 **오른쪽/아래로만** 자라 패널이 한쪽으로 치우치고,
	# 폰에서는 화면 밖으로 나갔다(2026-09-05 실측). 양쪽으로 자라게 한다.
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.custom_minimum_size = Vector2(UiScale.panel_width(420.0), 190)
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
