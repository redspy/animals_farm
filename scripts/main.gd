extends Node2D

## 프로토타입 코어 루프 1사이클: 마을을 돌아다니며 채집 → 인벤토리 → 판매(벨)
## → 자동 저장. 동물의 숲 모티브의 최소 골격이며, 이웃 동물/집 꾸미기/도감은
## docs/design.md §1의 다음 단계다.
##
## 씬은 .tscn 대신 코드로 조립한다 — 프로토타입 단계에선 텍스트 씬 파일을
## 손으로 관리하는 비용이 더 크고, 헤드리스 실행으로 전체 구성을 검증할 수
## 있다(scripts/verify-project.sh).

const ISLAND := Rect2(Vector2(40, 60), Vector2(880, 440))
const AUTOSAVE_INTERVAL_SEC := 10.0

var _save: Dictionary = {}
var _items: Dictionary = {}
var _player: Player
var _gatherables: Array[Gatherable] = []
var _hud: Label
var _toast: Label
var _toast_timer := 0.0
var _autosave_timer := 0.0
var _hud_timer := 0.0

func _ready() -> void:
	_save = SaveManager.load_save()
	_items = _load_json("res://data/items.json").get("items", {})
	_build_world()
	_apply_daily_respawn()
	_refresh_hud()

func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("데이터 파일 없음: %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("데이터 파일 파싱 실패: %s" % path)
		return {}
	return parsed as Dictionary

func _build_world() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.52, 0.76, 0.44)
	bg.size = Vector2(960, 540)
	bg.z_index = -10
	add_child(bg)

	var sea := ColorRect.new()
	sea.color = Color(0.36, 0.68, 0.82)
	sea.position = Vector2(0, 500)
	sea.size = Vector2(960, 40)
	sea.z_index = -9
	add_child(sea)

	for spawn: Variant in _load_json("res://data/gatherables.json").get("spawns", []):
		if typeof(spawn) != TYPE_DICTIONARY:
			continue
		var g := Gatherable.new()
		g.setup(spawn as Dictionary)
		g.gathered.connect(_on_gathered)
		add_child(g)
		_gatherables.append(g)

	_player = Player.new()
	_player.set_bounds(ISLAND)
	_player.position = ISLAND.get_center()
	add_child(_player)

	_hud = Label.new()
	_hud.position = Vector2(16, 12)
	_hud.add_theme_color_override("font_color", Color(0.12, 0.20, 0.14))
	add_child(_hud)

	_toast = Label.new()
	_toast.position = Vector2(16, 470)
	_toast.add_theme_color_override("font_color", Color(1, 1, 1))
	add_child(_toast)

## 마지막 접속 이후 하루 이상 지났으면 채집물 전체를 되살린다.
func _apply_daily_respawn() -> void:
	var days := GameClock.days_since(int(_save.get("last_played_unix", 0)))
	if days <= 0:
		return
	for g in _gatherables:
		g.force_respawn()
	_show_toast("%d일이 지났습니다 — 섬이 새로 자랐어요" % days)

func _on_gathered(item_id: String) -> void:
	var inv: Dictionary = _save.get("inventory", {})
	inv[item_id] = int(inv.get(item_id, 0)) + 1
	_save["inventory"] = inv
	_show_toast("%s 채집!" % _label_of(item_id))
	_refresh_hud()

func _sell_all() -> void:
	var inv: Dictionary = _save.get("inventory", {})
	if inv.is_empty():
		_show_toast("팔 물건이 없습니다")
		return
	var total := 0
	for item_id: String in inv.keys():
		total += int(inv[item_id]) * _price_of(item_id)
	_save["bells"] = int(_save.get("bells", 0)) + total
	_save["inventory"] = {}
	_show_toast("%d벨에 판매했습니다" % total)
	_refresh_hud()
	SaveManager.save(_save)

func _label_of(item_id: String) -> String:
	var meta: Dictionary = _items.get(item_id, {})
	return String(meta.get("label", item_id))

## 가격은 data/items.json이 유일한 출처이며, 유효범위(price_range)를 벗어난
## 값은 데이터 오타로 보고 클램프한다 — 밸런스 데이터가 코드 동작을 조용히
## 망가뜨리지 않게 하기 위함(AGENTS.md 밸런스 규칙).
func _price_of(item_id: String) -> int:
	var meta: Dictionary = _items.get(item_id, {})
	var price := int(meta.get("sell_price", 0))
	var range_raw: Variant = meta.get("price_range", null)
	if typeof(range_raw) == TYPE_ARRAY and (range_raw as Array).size() == 2:
		var lo := int((range_raw as Array)[0])
		var hi := int((range_raw as Array)[1])
		if price < lo or price > hi:
			push_warning("%s 가격 %d이 유효범위 [%d, %d] 밖 — 클램프" % [item_id, price, lo, hi])
		price = clampi(price, lo, hi)
	return price

func _refresh_hud() -> void:
	var inv: Dictionary = _save.get("inventory", {})
	var parts: Array[String] = []
	for item_id: String in inv.keys():
		parts.append("%s x%d" % [_label_of(item_id), int(inv[item_id])])
	var bag := "가방: 비었음" if parts.is_empty() else "가방: " + ", ".join(parts)
	_hud.text = "%s\n벨: %d\n%s\n[방향키] 이동  [Space/Enter] 채집  [S] 전부 판매" % [
		GameClock.label(), int(_save.get("bells", 0)), bag
	]

func _show_toast(text: String) -> void:
	_toast.text = text
	_toast_timer = 2.5

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept"):
		_try_gather()
	elif event is InputEventKey and event.pressed and not event.echo and (event as InputEventKey).keycode == KEY_S:
		_sell_all()

func _try_gather() -> void:
	var nearest: Gatherable = null
	var best := INF
	for g in _gatherables:
		if not g.can_interact(_player.position):
			continue
		var d := _player.position.distance_to(g.position)
		if d < best:
			best = d
			nearest = g
	if nearest == null:
		_show_toast("주변에 채집할 것이 없습니다")
		return
	nearest.gather()

func _process(delta: float) -> void:
	if _toast_timer > 0.0:
		_toast_timer -= delta
		if _toast_timer <= 0.0:
			_toast.text = ""
	_autosave_timer += delta
	if _autosave_timer >= AUTOSAVE_INTERVAL_SEC:
		_autosave_timer = 0.0
		SaveManager.save(_save)
	# HUD 문자열을 매 프레임 새로 만들면 웹에서 불필요한 할당/GC가 쌓인다 —
	# 시계 갱신은 1초 간격이면 충분하고, 벨/가방은 변경 시점에 즉시 갱신된다.
	_hud_timer += delta
	if _hud_timer >= 1.0:
		_hud_timer = 0.0
		_refresh_hud()

func _notification(what: int) -> void:
	# 브라우저 탭을 닫을 때도 저장되도록 종료 알림을 잡는다.
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		SaveManager.save(_save)
