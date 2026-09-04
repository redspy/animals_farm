extends CanvasLayer
class_name CharacterSelect

## 시작 화면: 기기별 캐릭터 슬롯 5칸을 보여주고, 빈 칸이면 프리셋을 골라 이름을
## 붙이게 하고, 이름이 있는 칸이면 그 캐릭터로 월드에 들어간다.
##
## 컨셉(docs/roadmap.md P1): "하나를 고르면 이름을 붙일 수 있고, 그 캐릭터는
## 이름 삭제 전까지 이름을 기억한다" — 그래서 이름을 지우는 것이 곧 캐릭터를
## 버리는 것이고, 그때 서버 신원(토큰)도 함께 사라진다는 점을 화면에서 알린다.

## 슬롯이 고정 5칸이 아니라 SaveManager.SLOT_COUNT를 따라가고, 프리셋도
## data/characters.json 개수를 따라간다 — 둘 다 "확장 가능"의 실제 구현이다.
signal slot_chosen(index: int, slot: Dictionary)

const PANEL_WIDTH := 560.0
const ROW_HEIGHT := 44.0
## 프리셋 목록에 보여줄 초상화 크기(px). 외형을 글자로만 고르게 하면 "미나가
## 어떻게 생겼는지" 알 수 없다(사용자 요청).
const PORTRAIT := Vector2(46, 56)

var _save: Dictionary = {}
var _presets: Array = []
var _spawn := Vector2.ZERO

var _root: VBoxContainer
## E2E 테스트가 탭할 지점(슬롯/프리셋/이름칸/시작 버튼). 테스트 seam 설명은
## scripts/test_hooks.gd 참고.
var _hooks: TestHooks
var _pending_index := -1          # 프리셋/이름 입력 중인 슬롯
var _pending_preset: String = ""

func setup(save: Dictionary, presets: Array, spawn: Vector2) -> void:
	_save = save
	_presets = presets
	_spawn = spawn

func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Palette.color("ui", "select_bg")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	_hooks = TestHooks.new()
	add_child(_hooks)

	_root = VBoxContainer.new()
	_root.custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	_root.add_theme_constant_override("separation", 8)
	center.add_child(_root)

	_show_slot_list()

func _clear_root() -> void:
	# queue_free는 프레임 끝에 처리되므로 자식이 즉시 사라지지 않는다 — 이 상태로
	# 새 화면을 만들면 get_child_count()가 이전 화면 노드까지 세서 인덱스가 밀린다
	# (테스트 훅의 preset1 키가 preset8로 밀려 나갔다, 2026-09-04 실측).
	for c in _root.get_children():
		_root.remove_child(c)
		c.queue_free()
	if _hooks != null:
		_hooks.clear()

func _mark(key: String, control: Control) -> void:
	if _hooks != null:
		_hooks.track(key, control)

func _title(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", Palette.color("ui", "hud_text"))
	_root.add_child(l)

func _show_slot_list() -> void:
	_clear_root()
	_title("캐릭터를 고르세요 (이 기기에 %d칸)" % SaveManager.SLOT_COUNT)

	var slots := SaveManager.slots_view(_save)
	for i in SaveManager.SLOT_COUNT:
		var slot: Dictionary = slots[i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		_root.add_child(row)

		# 이미 만든 캐릭터는 슬롯 줄에도 얼굴을 보여준다.
		var slot_portrait := TextureRect.new()
		slot_portrait.custom_minimum_size = Vector2(PORTRAIT.x * 0.7, PORTRAIT.y * 0.7)
		slot_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		slot_portrait.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		if not slot.is_empty():
			var preset_for_slot := _preset_by_id(String(slot.get("preset", "")))
			if not preset_for_slot.is_empty():
				slot_portrait.texture = _preset_portrait(preset_for_slot)
		row.add_child(slot_portrait)

		var enter := Button.new()
		enter.custom_minimum_size = Vector2(PANEL_WIDTH - 120.0 - PORTRAIT.x * 0.7, ROW_HEIGHT)
		if slot.is_empty():
			enter.text = "%d. 빈 슬롯 — 새 캐릭터 만들기" % (i + 1)
		else:
			var name_text: String = String(slot.get("name", ""))
			var preset_label := _preset_label(String(slot.get("preset", "")))
			if name_text.is_empty():
				# v1 세이브에서 넘어온 "이름 없는 기존 진행도"도 여기로 온다.
				enter.text = "%d. (이름 없음) — %s · %d벨" % [i + 1, preset_label, int(slot.get("bells", 0))]
			else:
				enter.text = "%d. %s — %s · %d벨" % [i + 1, name_text, preset_label, int(slot.get("bells", 0))]
		enter.pressed.connect(_on_slot_pressed.bind(i))
		row.add_child(enter)
		_mark("slot%d" % (i + 1), enter)

		var del := Button.new()
		del.custom_minimum_size = Vector2(104.0, ROW_HEIGHT)
		del.text = "이름 삭제"
		del.disabled = slot.is_empty()
		del.pressed.connect(_on_delete_pressed.bind(i))
		row.add_child(del)
		_mark("delete%d" % (i + 1), del)

func _preset_by_id(preset_id: String) -> Dictionary:
	for p: Variant in _presets:
		if typeof(p) == TYPE_DICTIONARY and String((p as Dictionary).get("id", "")) == preset_id:
			return p as Dictionary
	return {}

func _preset_label(preset_id: String) -> String:
	for p: Variant in _presets:
		if typeof(p) == TYPE_DICTIONARY and String((p as Dictionary).get("id", "")) == preset_id:
			return String((p as Dictionary).get("label", preset_id))
	return "외형 미지정" if preset_id.is_empty() else preset_id

func _on_slot_pressed(index: int) -> void:
	var slots := SaveManager.slots_view(_save)
	var slot: Dictionary = slots[index]
	# 이름과 외형이 모두 정해진 칸이면 바로 입장한다.
	if not slot.is_empty() and not String(slot.get("name", "")).is_empty() \
			and not String(slot.get("preset", "")).is_empty():
		slot_chosen.emit(index, slot)
		return
	_pending_index = index
	_pending_preset = String(slot.get("preset", ""))
	_show_preset_picker()

func _on_delete_pressed(index: int) -> void:
	_pending_index = index
	_clear_root()
	var slots := SaveManager.slots_view(_save)
	var slot: Dictionary = slots[index]
	_title("'%s' 이름을 삭제할까요?" % String(slot.get("name", "(이름 없음)")))

	var warn := Label.new()
	warn.text = "이름을 지우면 이 캐릭터를 버리는 것이 됩니다.\n서버에 저장된 신원(토큰)과의 연결도 끊겨서\n같은 캐릭터로 다시 들어올 수 없습니다."
	warn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	warn.add_theme_color_override("font_color", Palette.color("ui", "warn_text"))
	_root.add_child(warn)

	var yes := Button.new()
	yes.text = "삭제한다"
	yes.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	yes.pressed.connect(_confirm_delete)
	_root.add_child(yes)

	var no := Button.new()
	no.text = "취소"
	no.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	no.pressed.connect(_show_slot_list)
	_root.add_child(no)

func _confirm_delete() -> void:
	SaveManager.clear_slot(_save, _pending_index)
	SaveManager.save(_save)
	_pending_index = -1
	_show_slot_list()

func _show_preset_picker() -> void:
	_clear_root()
	_title("외형을 고르세요")
	var index := 0
	for p: Variant in _presets:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var preset := p as Dictionary
		index += 1
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		_root.add_child(row)

		# 초상화: 실제 캐릭터 스프라이트가 런타임에 만든 프레임을 그대로 쓴다 —
		# 별도 그림을 두면 외형을 고칠 때 두 곳이 어긋난다.
		var portrait := TextureRect.new()
		portrait.custom_minimum_size = PORTRAIT
		portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		portrait.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		portrait.texture = _preset_portrait(preset)
		row.add_child(portrait)

		var b := Button.new()
		b.custom_minimum_size = Vector2(PANEL_WIDTH - PORTRAIT.x - 20.0, PORTRAIT.y)
		var gender_text := "여" if String(preset.get("gender", "")) == "female" else "남"
		b.text = "%s (%s)" % [String(preset.get("label", "")), gender_text]
		b.pressed.connect(_on_preset_pressed.bind(String(preset.get("id", ""))))
		row.add_child(b)
		# 자식 개수가 아니라 프리셋 순번을 쓴다 — 개수는 화면 전환 잔여 노드에
		# 오염될 수 있다.
		_mark("preset%d" % index, b)

	var back := Button.new()
	back.text = "뒤로"
	back.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	back.pressed.connect(_show_slot_list)
	_root.add_child(back)

## 프리셋 초상화. PlayerSprite를 임시로 만들어 idle_down 프레임을 꺼낸다.
## 트리에 붙이지 않으면 _ready가 돌지 않아 프레임이 없으므로, 잠깐 붙였다가
## 텍스처만 챙기고 버린다.
func _preset_portrait(preset: Dictionary) -> Texture2D:
	var sprite := PlayerSprite.new()
	sprite.setup(preset)
	sprite.visible = false
	add_child(sprite)
	var tex: Texture2D = null
	if sprite.sprite_frames != null and sprite.sprite_frames.has_animation("idle_down") \
			and sprite.sprite_frames.get_frame_count("idle_down") > 0:
		tex = sprite.sprite_frames.get_frame_texture("idle_down", 0)
	remove_child(sprite)
	sprite.queue_free()
	if tex == null:
		push_warning("프리셋 %s의 초상화를 만들지 못했다" % String(preset.get("id", "")))
	return tex

func _on_preset_pressed(preset_id: String) -> void:
	_pending_preset = preset_id
	_show_name_input()

func _show_name_input() -> void:
	_clear_root()
	_title("이름을 지어주세요 (최대 %d자)" % SaveManager.NAME_MAX_LEN)

	var edit := LineEdit.new()
	edit.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	edit.max_length = SaveManager.NAME_MAX_LEN
	edit.placeholder_text = "이름"
	_root.add_child(edit)
	edit.grab_focus()
	_mark("nameField", edit)

	var hint := Label.new()
	hint.text = "이 이름은 삭제할 때까지 기억됩니다."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_color_override("font_color", Palette.color("ui", "hud_text"))
	_root.add_child(hint)

	var ok := Button.new()
	ok.text = "시작"
	ok.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	ok.pressed.connect(_on_name_confirmed.bind(edit))
	_root.add_child(ok)
	_mark("startButton", ok)

	# 엔터로도 확정되게 — 이름 입력 후 마우스로 버튼을 찾아가는 건 번거롭다.
	edit.text_submitted.connect(func(_t: String) -> void: _on_name_confirmed(edit))

	var back := Button.new()
	back.text = "뒤로"
	back.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	back.pressed.connect(_show_preset_picker)
	_root.add_child(back)

func _on_name_confirmed(edit: LineEdit) -> void:
	var name_text := SaveManager.sanitize_name(edit.text)
	if name_text.is_empty():
		edit.placeholder_text = "이름을 한 자 이상 입력하세요"
		return

	var slots := SaveManager.slots_view(_save)
	var slot: Dictionary = slots[_pending_index]
	if slot.is_empty():
		slot = SaveManager.new_slot(_pending_preset, name_text, _spawn)
	else:
		# 기존 슬롯(예: v1에서 올라온 진행도)에 이름·외형만 채운다 — 토큰과
		# 벨/가방은 유지해야 진행도가 사라지지 않는다.
		slot["name"] = name_text
		slot["preset"] = _pending_preset
		if String(slot.get("token", "")).is_empty():
			slot["token"] = SaveManager.new_slot("", "", Vector2.ZERO)["token"]
	SaveManager.put_slot(_save, _pending_index, slot)
	_save["last_slot"] = _pending_index
	SaveManager.save(_save)
	slot_chosen.emit(_pending_index, slot)
