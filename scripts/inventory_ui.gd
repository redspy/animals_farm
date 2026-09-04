extends CanvasLayer
class_name InventoryUI

## 가방 화면. 아이템을 골라 **1개 버리기 / 그 종류 판매 / 전부 판매**를 한다.
##
## 왜 필요한가: 예전에는 `Q`가 "가방 첫 항목 1개"를 버리고 `S`가 전부 팔았다.
## 무엇이 팔릴지 고를 수 없어서, 모아둔 조개를 나무와 함께 통째로 파는 사고가
## 나기 쉬웠다. 판매는 되돌릴 수 없으므로 고르는 화면이 있어야 한다.
##
## 판매·버리기 자체는 하지 않고 **요청만 알린다** — 실제 처리는 서버가 하고
## (docs/protocol.md) world.gd가 중개한다.

signal drop_requested(item_id: String)
signal sell_requested(item_id: String)
signal sell_all_requested
signal closed

const PANEL_MIN := Vector2(460, 300)
const ROW_HEIGHT := 46.0
const BTN_WIDTH := 92.0

var _items_meta: Dictionary = {}
var _list: VBoxContainer
var _summary: Label
var _sell_all_btn: Button
var _hooks: TestHooks

func setup(items_meta: Dictionary) -> void:
	_items_meta = items_meta

func _ready() -> void:
	_hooks = TestHooks.new()
	add_child(_hooks)

	# 뒤를 탭하면 닫힌다.
	var dim := Button.new()
	dim.flat = true
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.focus_mode = Control.FOCUS_NONE
	dim.pressed.connect(close)
	add_child(dim)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	# PRESET_CENTER는 앵커만 화면 중앙에 두고, 크기는 grow 방향으로 자란다.
	# 기본값(END)이면 중앙에서 **오른쪽/아래로만** 자라 패널이 한쪽으로 치우치고,
	# 폰에서는 화면 밖으로 나갔다(2026-09-05 실측). 양쪽으로 자라게 한다.
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
	title.text = "가방"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Palette.color("ui", "hud_text"))
	box.add_child(title)

	_summary = Label.new()
	_summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_summary.add_theme_color_override("font_color", Palette.color("ui", "hud_text"))
	box.add_child(_summary)

	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 6)
	box.add_child(_list)

	_sell_all_btn = Button.new()
	_sell_all_btn.text = "전부 판매"
	_sell_all_btn.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	_sell_all_btn.focus_mode = Control.FOCUS_NONE
	_sell_all_btn.pressed.connect(func() -> void: sell_all_requested.emit())
	box.add_child(_sell_all_btn)
	_hooks.track("invSellAll", _sell_all_btn)

	var close_btn := Button.new()
	close_btn.text = "닫기"
	close_btn.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.pressed.connect(close)
	box.add_child(close_btn)
	_hooks.track("invClose", close_btn)

func close() -> void:
	closed.emit()
	queue_free()

## 서버가 보내온 가방 내용으로 목록을 다시 만든다.
func refresh(inventory: Dictionary, bells: int) -> void:
	if _list == null:
		return
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	for i in 12:
		_hooks.untrack("invItem%d" % (i + 1))
		_hooks.untrack("invDrop%d" % (i + 1))
		_hooks.untrack("invSell%d" % (i + 1))

	_summary.text = "벨: %d" % bells
	if inventory.is_empty():
		var empty := Label.new()
		empty.text = "가방이 비었습니다"
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.add_theme_color_override("font_color", Palette.color("ui", "hud_text"))
		_list.add_child(empty)
		_sell_all_btn.disabled = true
		return
	_sell_all_btn.disabled = false

	var index := 0
	for item_id: String in inventory.keys():
		index += 1
		var count := int(inventory[item_id])
		var meta: Dictionary = _items_meta.get(item_id, {})
		var label_text := String(meta.get("label", item_id))
		var price := int(meta.get("sell_price", 0))

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		_list.add_child(row)

		var narrow := UiScale.is_narrow()
		# 폰에서는 줄에 들어갈 폭이 없다 — 버튼 글자와 가격 표기를 함께 줄인다.
		# 셋 다 그대로 두면 이름 줄이 "나무 x1 (기"처럼 잘려 가격이 안 보인다.
		var btn_w := UiScale.dim(BTN_WIDTH) if not narrow else BTN_WIDTH
		var name_label := Label.new()
		name_label.text = "%s x%d · %d벨" % [label_text, count, price] if narrow \
			else "%s x%d  (개당 %d벨)" % [label_text, count, price]
		name_label.custom_minimum_size = Vector2(
			maxf(UiScale.panel_width(PANEL_MIN.x) - btn_w * 2 - 40, 80.0), ROW_HEIGHT)
		# 글자가 길면 줄을 밀어내 패널이 화면을 넘는다(하한일 뿐이므로) — 자른다.
		name_label.clip_text = true
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_label.add_theme_color_override("font_color", Palette.color("ui", "hud_text"))
		row.add_child(name_label)
		_hooks.track("invItem%d" % index, name_label)

		var drop_btn := Button.new()
		drop_btn.text = "버림" if narrow else "1개 버림"
		drop_btn.custom_minimum_size = Vector2(btn_w, ROW_HEIGHT)
		drop_btn.clip_text = true
		drop_btn.focus_mode = Control.FOCUS_NONE
		drop_btn.pressed.connect(func() -> void: drop_requested.emit(item_id))
		row.add_child(drop_btn)
		_hooks.track("invDrop%d" % index, drop_btn)

		var sell_btn := Button.new()
		sell_btn.text = "판매"
		sell_btn.custom_minimum_size = Vector2(btn_w, ROW_HEIGHT)
		sell_btn.clip_text = true
		sell_btn.focus_mode = Control.FOCUS_NONE
		sell_btn.pressed.connect(func() -> void: sell_requested.emit(item_id))
		row.add_child(sell_btn)
		_hooks.track("invSell%d" % index, sell_btn)
