extends CanvasLayer
class_name DexUI

## 도감. 두 탭으로 나눈다: **아이템**(무엇을 몇 개 만났는지)과 **이웃**(누구의
## 부탁을 오늘 도왔는지).
##
## 화면을 새로 늘리지 않고 탭으로 나눈 이유: 최상위 버튼이 하나 더 생기면
## 오른쪽 위 버튼 열이 또 길어진다(세로 예산 — docs/design.md).
##
## 획득 수의 단일 출처는 **서버**다(`dex`). 클라이언트가 세면 오프라인에서
## 늘린 값이 재접속에 덮여 사라지고, 그게 "도감이 줄었다"로 보인다.

signal closed

const PANEL_MIN := Vector2(560.0, 420.0)
const CELL_MIN := Vector2(150.0, 62.0)

var _items_meta: Dictionary = {}
var _dex: Dictionary = {}
var _npcs: Array = []
var _npc_state: Dictionary = {}
var _grid: GridContainer
var _npc_box: VBoxContainer
var _summary: Label
var _tab_items: Button
var _tab_npcs: Button
var _hooks: TestHooks

func setup(items_meta: Dictionary, dex: Dictionary, npcs: Array, npc_state: Dictionary) -> void:
	_items_meta = items_meta
	_dex = dex
	_npcs = npcs
	_npc_state = npc_state
	# **열려 있는 동안 다시 부르면 실제로 다시 그려야 한다.** 값만 대입하고
	# _fill()을 _ready에서 한 번만 돌리면, resync로 상태가 바뀌어도 화면은
	# 낡은 채로 남는다(리뷰 지적: 사실상 죽은 코드였다).
	#
	# 단 **바뀐 게 없으면 다시 그리지 않는다.** 채집·줍기마다 셀 16개를
	# queue_free하고 새로 만들면 도감을 열어 둔 채 채집할 때 매번 재생성된다.
	if is_node_ready() and _signature() != _drawn:
		_fill()

func _ready() -> void:
	_hooks = TestHooks.new()
	add_child(_hooks)

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

	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	box.add_child(tabs)
	_tab_items = _make_tab("아이템", true)
	_tab_npcs = _make_tab("이웃", false)
	tabs.add_child(_tab_items)
	tabs.add_child(_tab_npcs)
	_hooks.track("dexTabItems", _tab_items)
	_hooks.track("dexTabNpcs", _tab_npcs)

	_summary = Label.new()
	_summary.add_theme_font_size_override("font_size", UiScale.font(15))
	box.add_child(_summary)

	# 스크롤을 두는 이유: 아이템 종류가 늘어나면(낚시·벌레로 이미 12종을 넘었다)
	# 폰 화면에서는 격자가 패널을 넘어간다.
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = UiScale.dim(300.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)

	var inner := VBoxContainer.new()
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(inner)

	_grid = GridContainer.new()
	# 좁은 화면에서는 2열, 넓으면 3열 — 셀 폭이 좁아지면 이름이 잘린다.
	_grid.columns = 2 if UiScale.is_narrow() else 3
	_grid.add_theme_constant_override("h_separation", 8)
	_grid.add_theme_constant_override("v_separation", 8)
	inner.add_child(_grid)

	_npc_box = VBoxContainer.new()
	_npc_box.add_theme_constant_override("separation", 8)
	_npc_box.visible = false
	inner.add_child(_npc_box)

	var close_btn := Button.new()
	close_btn.text = "닫기"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.custom_minimum_size.y = UiScale.dim(44.0)
	close_btn.add_theme_font_size_override("font_size", UiScale.font(16))
	close_btn.pressed.connect(close)
	box.add_child(close_btn)
	_hooks.track("dexClose", close_btn)

	_fill()

func _make_tab(text: String, active: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.button_pressed = active
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(UiScale.dim(110.0), UiScale.dim(40.0))
	b.add_theme_font_size_override("font_size", UiScale.font(16))
	b.pressed.connect(func() -> void: _select_tab(text == "아이템"))
	return b

func _select_tab(items: bool) -> void:
	if _tab_items != null:
		_tab_items.button_pressed = items
	if _tab_npcs != null:
		_tab_npcs.button_pressed = not items
	if _grid != null:
		_grid.visible = items
	if _npc_box != null:
		_npc_box.visible = not items
	_fill_summary()

## 지금 그려진 내용을 식별하는 문자열 — 바뀌었는지만 알면 되므로 가볍게 만든다.
func _signature() -> String:
	var parts: Array[String] = []
	for id: Variant in _items_meta.keys():
		var c := int(_dex.get(String(id), 0))
		if c > 0:
			parts.append("%s:%d" % [String(id), c])
	for id: Variant in _npc_state.keys():
		var s: Dictionary = _npc_state[id]
		parts.append("%s:%s" % [String(id), "1" if bool(s.get("done", false)) else "0"])
	return ",".join(parts)

var _drawn := ""

func _fill() -> void:
	# **보고 있던 탭을 유지한다.** _fill 끝에서 무조건 아이템 탭으로 되돌리면,
	# 이웃 탭을 보는 중에 나무 한 번 캐면 탭이 튄다(리뷰 지적).
	var was_items := _grid == null or _grid.visible
	_drawn = _signature()
	# --- 아이템 탭 ---
	for c in _grid.get_children():
		_grid.remove_child(c)
		c.queue_free()
	var index := 0
	for id: Variant in _items_meta.keys():
		var item_id := String(id)
		var meta: Dictionary = _items_meta[item_id]
		var count := int(_dex.get(item_id, 0))
		index += 1
		var cell := PanelContainer.new()
		cell.custom_minimum_size = Vector2(UiScale.dim(CELL_MIN.x), UiScale.dim(CELL_MIN.y))
		var cell_style := StyleBoxFlat.new()
		cell_style.bg_color = Palette.color("ui", "row_bg")
		cell_style.corner_radius_top_left = 8
		cell_style.corner_radius_top_right = 8
		cell_style.corner_radius_bottom_left = 8
		cell_style.corner_radius_bottom_right = 8
		cell_style.content_margin_left = 8
		cell_style.content_margin_right = 8
		cell_style.content_margin_top = 6
		cell_style.content_margin_bottom = 6
		cell.add_theme_stylebox_override("panel", cell_style)
		_grid.add_child(cell)

		var lines := VBoxContainer.new()
		lines.add_theme_constant_override("separation", 2)
		cell.add_child(lines)

		var name_label := Label.new()
		name_label.add_theme_font_size_override("font_size", UiScale.font(16))
		# **미획득은 이름을 감춘다.** 다 보여주면 도감이 목록표가 되고, 찾는
		# 재미가 없다. 대신 몇 칸이 남았는지는 위 요약이 알려준다.
		name_label.text = String(meta.get("label", item_id)) if count > 0 else "???"
		name_label.add_theme_color_override("font_color",
			Palette.color("ui", "row_text") if count > 0 else Palette.color("ui", "row_dim"))
		lines.add_child(name_label)

		var sub := Label.new()
		sub.add_theme_font_size_override("font_size", UiScale.font(13))
		sub.add_theme_color_override("font_color", Palette.color("ui", "row_dim"))
		# 단위를 "개"로 통일한다 — 물고기·벌레·나무가 섞여 있어 마리/개를
		# 가리려면 아이템마다 단위 필드가 필요하고, 그만한 값이 없다.
		sub.text = "%d개 · %d벨" % [count, int(meta.get("sell_price", 0))] if count > 0 else "아직 못 만났다"
		lines.add_child(sub)
		_hooks.track("dexItem%d" % index, cell)

	# --- 이웃 탭 ---
	for c in _npc_box.get_children():
		_npc_box.remove_child(c)
		c.queue_free()
	var n_index := 0
	for n: Variant in _npcs:
		if typeof(n) != TYPE_DICTIONARY:
			continue
		var npc := n as Dictionary
		var npc_id := String(npc.get("id", ""))
		var state: Dictionary = _npc_state.get(npc_id, {})
		n_index += 1
		var row := Label.new()
		row.add_theme_font_size_override("font_size", UiScale.font(16))
		row.add_theme_color_override("font_color", Palette.color("ui", "row_text"))
		var request: Variant = state.get("request", null)
		var status := "오늘 도와줬다" if bool(state.get("done", false)) else "부탁 없음"
		if not bool(state.get("done", false)) and typeof(request) == TYPE_DICTIONARY:
			var req := request as Dictionary
			var item_id := String(req.get("item", ""))
			var meta: Dictionary = _items_meta.get(item_id, {})
			status = "%s %d개 부탁 중 (보상 %d벨)" % [
				String(meta.get("label", item_id)), int(req.get("count", 0)),
				int(state.get("reward", 0))]
		row.text = "%s — %s" % [String(npc.get("label", npc_id)), status]
		_npc_box.add_child(row)
		_hooks.track("dexNpc%d" % n_index, row)

	_select_tab(was_items)

func _fill_summary() -> void:
	if _summary == null:
		return
	if _npc_box != null and _npc_box.visible:
		var helped := 0
		for id: Variant in _npc_state.keys():
			if bool((_npc_state[id] as Dictionary).get("done", false)):
				helped += 1
		_summary.text = "오늘 도운 이웃 %d / %d" % [helped, _npcs.size()]
		return
	var found := 0
	for id: Variant in _items_meta.keys():
		if int(_dex.get(String(id), 0)) > 0:
			found += 1
	_summary.text = "도감 %d / %d 종" % [found, _items_meta.size()]

func close() -> void:
	closed.emit()
	queue_free()
