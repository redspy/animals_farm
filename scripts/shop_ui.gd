extends CanvasLayer
class_name ShopUI

## 가게 화면. 가게 주인(`shop: true`)을 탭하면 부탁 대화창 대신 이것이 열린다.
##
## 이 화면은 **정산하지 않고 요청만 알린다**(가방·부탁 화면과 같은 규칙) — 가격과
## 잔액 판정, 차감은 전부 서버가 한다(docs/protocol.md의 `buy`). 클라이언트가
## 차감하면 재접속에 서버 값으로 덮여 "샀는데 없는" 상태가 된다.
##
## 아이가 쓰는 화면이라 **지금 얼마 있는지**를 제일 크게 둔다 — "얼마 남았지"를
## 물어보지 않고 알 수 있어야 한다.

signal buy_requested(good_id: String)
signal closed

const PANEL_MIN := Vector2(560.0, 420.0)
const ROW_HEIGHT := 46.0
const SWATCH := 30.0

var _goods: Array = []
var _owned: Array = []
var _bells := 0
var _list: VBoxContainer
var _bells_label: Label
var _hooks: TestHooks

## 가게를 연다. `owned`는 이미 산 상품 id들 — 그 줄은 사는 버튼 대신 "보유"로 잠근다.
func setup(goods: Array, owned: Array, bells: int) -> void:
	_goods = goods
	_owned = owned
	_bells = bells
	if is_node_ready():
		_fill()

## 산 직후 서버 응답으로 갱신한다(화면을 닫지 않고 그 자리에서 잠긴다).
func apply_bought(owned: Array, bells: int) -> void:
	_owned = owned
	_bells = bells
	if is_node_ready():
		_fill()

func _ready() -> void:
	_hooks = TestHooks.new()
	add_child(_hooks)
	# **가방 화면 위에 뜬다.** 같은 레이어(기본 1)면 그리는 순서는 위여도 입력은
	# 먼저 만들어진 화면이 먹는다(도감·꾸미기와 같은 이유).
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
	title.text = "너굴 가게"
	title.add_theme_font_size_override("font_size", UiScale.font(20))
	title.add_theme_color_override("font_color", Palette.color("ui", "hud_text"))
	box.add_child(title)

	# **잔액을 제일 크게.** 아이가 "얼마 남았지"를 바로 본다.
	_bells_label = Label.new()
	_bells_label.add_theme_font_size_override("font_size", UiScale.font(18))
	_bells_label.add_theme_color_override("font_color", Palette.color("ui", "row_text"))
	box.add_child(_bells_label)

	# 상품이 늘어나면 폰에서 패널을 넘어간다(도감과 같은 이유로 스크롤을 둔다).
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = UiScale.dim(300.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)

	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 6)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)

	var close_btn := Button.new()
	close_btn.text = "닫기"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.custom_minimum_size.y = UiScale.dim(44.0)
	close_btn.add_theme_font_size_override("font_size", UiScale.font(16))
	close_btn.pressed.connect(close)
	box.add_child(close_btn)
	_hooks.track("shopClose", close_btn)

	_fill()

func _fill() -> void:
	if _list == null:
		return
	_bells_label.text = "내 벨: %d" % _bells
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()

	var narrow := UiScale.is_narrow()
	var index := 0
	for g: Variant in _goods:
		if typeof(g) != TYPE_DICTIONARY:
			continue
		var good := g as Dictionary
		var id := String(good.get("id", ""))
		var price := int(good.get("price", 0))
		var has_it := _owned.has(id)
		index += 1

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		_list.add_child(row)

		# 색 견본 — 글을 못 읽는 아이도 **무엇을 사는지** 알 수 있어야 한다.
		var swatch := ColorRect.new()
		swatch.color = Palette.color("character", String(good.get("value", "")))
		swatch.custom_minimum_size = Vector2(UiScale.dim(SWATCH), UiScale.dim(SWATCH))
		row.add_child(swatch)

		var name_label := Label.new()
		name_label.text = "%s · %d벨" % [String(good.get("label", id)), price]
		name_label.add_theme_font_size_override("font_size", UiScale.font(16 if narrow else 17))
		name_label.custom_minimum_size = Vector2(UiScale.dim(200.0), UiScale.dim(ROW_HEIGHT))
		name_label.clip_text = true
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_label.add_theme_color_override("font_color", Palette.color("ui", "row_text"))
		row.add_child(name_label)
		_hooks.track("shopItem%d" % index, name_label)

		var buy_btn := Button.new()
		buy_btn.focus_mode = Control.FOCUS_NONE
		buy_btn.custom_minimum_size = Vector2(UiScale.dim(96.0), UiScale.dim(ROW_HEIGHT))
		buy_btn.add_theme_font_size_override("font_size", UiScale.font(15))
		if has_it:
			# 산 것은 **누를 수 없게** 둔다 — 눌러도 서버가 거절할 뿐이고, 아이는
			# 눌리는 버튼을 "되는 것"으로 읽는다.
			buy_btn.text = "보유"
			buy_btn.disabled = true
		else:
			buy_btn.text = "사기"
			# 벨이 모자라도 **누를 수는 있게** 둔다 — 서버가 얼마 모자란지 알려준다.
			buy_btn.pressed.connect(func() -> void: buy_requested.emit(id))
		row.add_child(buy_btn)
		_hooks.track("shopBuy%d" % index, buy_btn)

func close() -> void:
	closed.emit()
	queue_free()
