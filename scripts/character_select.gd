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

## 이름 입력용 DOM 요소 id.
##
## 왜 DOM인가: Godot `LineEdit`은 웹에서 OS 키보드를 띄우지 못한다. 안드로이드
## 크롬은 엔진의 가상 키보드 우회가 어느 정도 통하지만 **iOS 사파리에서는
## 키보드가 아예 뜨지 않아 이름을 입력할 수 없었다**(사용자 보고 2026-09-05).
## 실제 `<input>`을 필드 위에 겹쳐 두면 사용자가 그것을 직접 탭하게 되므로,
## 브라우저가 제스처를 그대로 인정해 키보드가 뜬다(채팅 입력과 같은 이유).
const NAME_DOM_ID := "af-name-input"
var _name_edit: LineEdit = null
var _name_dom := false
var _js_name_submit: JavaScriptObject = null

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
	_root.custom_minimum_size = Vector2(_panel_width(), 0)
	_root.add_theme_constant_override("separation", 8)
	center.add_child(_root)

	_show_slot_list()

## 패널 폭. 560px은 데스크톱 기준이라 폰의 논리 폭(411px)을 넘어 잘린다
## (2026-09-05, UiScale로 1 UI 단위 = 1 CSS 픽셀이 된 뒤 드러났다).
func _panel_width() -> float:
	return UiScale.panel_width(PANEL_WIDTH)

func _clear_root() -> void:
	# 화면이 바뀌면 겹쳐 둔 DOM 입력도 치운다 — 안 치우면 슬롯 목록 위에
	# 입력창이 남는다.
	_hide_name_dom()
	_name_edit = null
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
		enter.custom_minimum_size = Vector2(
			maxf(_panel_width() - UiScale.dim(104.0) - 16.0 - PORTRAIT.x * 0.7, 120.0), ROW_HEIGHT)
		# custom_minimum_size는 **하한**이라, 글자가 길면 그 폭이 줄을 밀어내
		# 패널이 화면을 넘어간다(폰에서 "이름 삭제" 버튼이 화면 밖으로 나갔다,
		# 2026-09-05 리뷰 지적). 넘칠 땐 벌리지 말고 자른다.
		enter.clip_text = true
		enter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var narrow := UiScale.is_narrow()
		if slot.is_empty():
			# 좁은 화면에서는 짧게 — 긴 문장은 어차피 잘린다.
			enter.text = "%d. 빈 슬롯" % (i + 1) if narrow else "%d. 빈 슬롯 — 새 캐릭터 만들기" % (i + 1)
		else:
			var name_text: String = String(slot.get("name", ""))
			var preset_label := _preset_label(String(slot.get("preset", "")))
			if name_text.is_empty():
				# v1 세이브에서 넘어온 "이름 없는 기존 진행도"도 여기로 온다.
				enter.text = "%d. (이름 없음) — %s · %d벨" % [i + 1, preset_label, int(slot.get("bells", 0))]
			elif narrow:
				enter.text = "%d. %s · %d벨" % [i + 1, name_text, int(slot.get("bells", 0))]
			else:
				enter.text = "%d. %s — %s · %d벨" % [i + 1, name_text, preset_label, int(slot.get("bells", 0))]
		enter.pressed.connect(_on_slot_pressed.bind(i))
		row.add_child(enter)
		_mark("slot%d" % (i + 1), enter)

		var del := Button.new()
		del.custom_minimum_size = Vector2(UiScale.dim(104.0), ROW_HEIGHT)
		del.clip_text = true
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
		b.custom_minimum_size = Vector2(maxf(_panel_width() - PORTRAIT.x - 20.0, 120.0), PORTRAIT.y)
		b.clip_text = true
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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

# ---------------------------------------------------------------------------
# 이름 입력용 DOM <input> (웹 전용)
# ---------------------------------------------------------------------------

func _use_name_dom() -> bool:
	return OS.has_feature("web") and JavaScriptBridge.get_interface("document") != null

func _setup_name_dom() -> void:
	_name_dom = true
	_js_name_submit = JavaScriptBridge.create_callback(_on_name_dom_submit)
	var win := JavaScriptBridge.get_interface("window")
	win.afNameSubmit = _js_name_submit
	JavaScriptBridge.eval("""
		(function(){
			var el = document.getElementById('%s');
			if (!el) {
				el = document.createElement('input');
				el.id = '%s';
				el.type = 'text';
				el.autocomplete = 'off';
				el.autocapitalize = 'off';
				el.maxLength = %d;
				el.addEventListener('keydown', function(ev){
					if (ev.key === 'Enter') {
						// IME 조합 중의 Enter는 조합 확정이다 — 전송하면 한글이 잘린다.
						if (ev.isComposing) return;
						ev.preventDefault();
						window.afNameSubmit(el.value);
					}
					ev.stopPropagation();
				});
				el.addEventListener('keyup', function(ev){ ev.stopPropagation(); });
				el.addEventListener('keypress', function(ev){ ev.stopPropagation(); });
				document.body.appendChild(el);
			}
			el.value = '';
			el.placeholder = '이름';
			// 16px 미만이면 iOS가 포커스 시 화면을 확대해 레이아웃이 어긋난다.
			el.style.cssText = [
				'position:fixed', 'display:block', 'box-sizing:border-box',
				'padding:6px 10px', 'font-size:17px', 'border:2px solid rgba(255,255,255,0.55)',
				'border-radius:8px', 'background:rgba(18,38,31,0.96)', 'color:#fff',
				'z-index:2147483646', 'outline:none', 'text-align:center'
			].join(';');
		})();
	""" % [NAME_DOM_ID, NAME_DOM_ID, SaveManager.NAME_MAX_LEN], true)
	# 지금은 컨테이너 레이아웃이 아직 계산되지 않아 실패할 수 있다 — 그러면
	# 입력창이 필드 위가 아니라 페이지 좌상단에 남아, 탭해도 포커스가 걸리지
	# 않는다(그 사이 탭이 캔버스로 새어 이름이 빈 채 제출됐다, 실측).
	# 자리가 안정될 때까지는 _process가 매 프레임 다시 놓는다.
	_name_dom_rect = _place_name_dom()

## LineEdit 자리에 DOM 입력을 겹쳐 둔다. 화면 회전·창 크기 변경으로 자리가
## 바뀌므로 주기적으로 다시 맞춘다 — 한 번만 놓으면 회전 후 엉뚱한 곳에 남는다.
## 놓은 자리를 돌려준다(실패하면 빈 Rect2).
func _place_name_dom() -> Rect2:
	if not _name_dom or _name_edit == null or not is_instance_valid(_name_edit):
		return Rect2()
	var vp := get_viewport()
	if vp == null:
		return Rect2()
	var size := vp.get_visible_rect().size
	if size.x <= 0.0 or size.y <= 0.0:
		return Rect2()
	var r := _name_edit.get_global_rect()
	if r.size.x <= 0.0:
		# 컨테이너 레이아웃이 아직 계산되지 않았다 — 다음 프레임에 다시 본다.
		return Rect2()
	JavaScriptBridge.eval("""
		(function(){
			var el = document.getElementById('%s');
			var c = document.querySelector('canvas');
			if (!el || !c) return;
			var b = c.getBoundingClientRect();
			if (!(b.width > 0)) return;
			el.style.left = (b.left + %f * b.width) + 'px';
			el.style.top = (b.top + %f * b.height) + 'px';
			el.style.width = (%f * b.width) + 'px';
			el.style.height = (%f * b.height) + 'px';
		})();
	""" % [
		NAME_DOM_ID,
		r.position.x / size.x, r.position.y / size.y,
		r.size.x / size.x, r.size.y / size.y,
	], true)
	return r

## DOM 위치 갱신 주기(초).
##
## 매 프레임 하면 안 된다: getBoundingClientRect 읽기 + style 쓰기가 섞여
## 브라우저 레이아웃을 초당 60번 강제로 계산하게 만든다(같은 이유로
## ui_scale.gd는 DPR을 캐시하고 touch_controls.gd는 0.5초 주기로 게시한다).
## 캐릭터 선택은 폰에서 첫 화면이라 프레임 드랍이 바로 보인다.
const NAME_DOM_INTERVAL := 0.4
## 같은 자리를 이만큼 연속으로 얻으면 "안정됐다"고 본다.
const NAME_DOM_STABLE_FRAMES := 3
var _name_dom_timer := 0.0
var _name_dom_rect := Rect2()
var _name_dom_stable := 0

func _process(delta: float) -> void:
	if not _name_dom:
		return
	# **자리가 안정될 때까지는 매 프레임 다시 놓는다.**
	#
	# 한 번 성공하면 끝내면 안 된다: 컨테이너 레이아웃은 여러 프레임에 걸쳐
	# 값이 바뀌고(실측: 폭 80 → 700), 중간값으로 놓고 멈추면 입력창이 필드에서
	# 벗어난 자리에 남는다 — 사용자가 필드를 눌러도 캔버스가 눌려 포커스가
	# 걸리지 않는다. 안정된 뒤에는 회전·창 크기 변경만 따라가면 되므로 주기를
	# 늘린다(매 프레임 getBoundingClientRect + style 쓰기는 브라우저 레이아웃을
	# 초당 60번 강제로 계산하게 만든다).
	if _name_dom_stable < NAME_DOM_STABLE_FRAMES:
		var placed := _place_name_dom()
		if placed.size.x <= 0.0:
			return
		if placed.is_equal_approx(_name_dom_rect):
			_name_dom_stable += 1
		else:
			_name_dom_stable = 0
			_name_dom_rect = placed
		return
	_name_dom_timer += delta
	if _name_dom_timer < NAME_DOM_INTERVAL:
		return
	_name_dom_timer = 0.0
	var again := _place_name_dom()
	# 화면이 바뀌어 자리가 달라졌으면 다시 안정될 때까지 매 프레임 따라간다.
	if again.size.x > 0.0 and not again.is_equal_approx(_name_dom_rect):
		_name_dom_rect = again
		_name_dom_stable = 0

func _name_dom_value() -> String:
	var got: Variant = JavaScriptBridge.eval("""
		(function(){
			var el = document.getElementById('%s');
			return el ? el.value : '';
		})();
	""" % NAME_DOM_ID, true)
	return String(got) if got != null else ""

func _set_name_dom_placeholder(text: String) -> void:
	if not _name_dom:
		return
	JavaScriptBridge.eval("""
		(function(){
			var el = document.getElementById('%s');
			if (el) el.placeholder = '%s';
		})();
	""" % [NAME_DOM_ID, text], true)

func _hide_name_dom() -> void:
	if not _name_dom:
		return
	_name_dom = false
	_name_dom_stable = 0
	_name_dom_rect = Rect2()
	JavaScriptBridge.eval("""
		(function(){
			var el = document.getElementById('%s');
			if (el) { el.blur(); el.style.display = 'none'; }
		})();
	""" % NAME_DOM_ID, true)

func _on_name_dom_submit(_args: Array) -> void:
	if _name_edit != null and is_instance_valid(_name_edit):
		_on_name_confirmed(_name_edit)

func _exit_tree() -> void:
	_hide_name_dom()

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
	_name_edit = edit
	if _use_name_dom():
		# 웹에서는 이 LineEdit은 **자리와 모양만** 잡는다(위에 실제 <input>이
		# 덮인다). 편집 가능하게 두면 두 곳에 글자가 따로 들어간다.
		edit.editable = false
		_setup_name_dom()
	else:
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
	# (웹에서는 DOM 입력의 keydown이 같은 경로를 부른다.)
	edit.text_submitted.connect(func(_t: String) -> void: _on_name_confirmed(edit))

	var back := Button.new()
	back.text = "뒤로"
	back.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	back.pressed.connect(_show_preset_picker)
	_root.add_child(back)

func _on_name_confirmed(edit: LineEdit) -> void:
	var raw := _name_dom_value() if _name_dom else edit.text
	var name_text := SaveManager.sanitize_name(raw)
	if name_text.is_empty():
		edit.placeholder_text = "이름을 한 자 이상 입력하세요"
		_set_name_dom_placeholder("이름을 한 자 이상 입력하세요")
		return
	_hide_name_dom()

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
