extends Node3D

## 프로토타입 코어 루프 1사이클: 마을을 돌아다니며 채집 → 가방 → 판매(벨)
## → 자동 저장. 동물의 숲 모티브의 최소 골격이며, 이웃 동물/집 꾸미기/도감은
## docs/design.md §1의 다음 단계다.
##
## 화면 구성은 2.5D다: 지형·나무·조개는 3D 메시, 캐릭터는 3D 공간에 세운 2D
## 빌보드 스프라이트, HUD는 그 위에 얹은 2D CanvasLayer.
##
## 씬은 .tscn 대신 코드로 조립한다 — 프로토타입 단계에선 텍스트 씬 파일을
## 손으로 관리하는 비용이 더 크고, 헤드리스 실행으로 전체 구성을 검증할 수
## 있다(scripts/verify-project.sh).

const AUTOSAVE_INTERVAL_SEC := 10.0

## 카메라: 직교 투영 + 위에서 내려다보는 각도. yaw를 0으로 두면 화면 위쪽이
## 월드 -Z와 일치해 입력 매핑이 단순해진다(player.gd 주석 참고).
const CAMERA_PITCH_DEG := -38.0
const CAMERA_YAW_DEG := 0.0
## 직교 투영 세로 크기. 작을수록 확대된다 — 동물의 숲처럼 캐릭터가 화면에서
## 충분히 커 보이도록 섬 전체를 담지 않고 주변만 보여준다.
const CAMERA_SIZE := 9.5
const CAMERA_DISTANCE := 16.0
## 카메라가 플레이어를 따라가는 속도(초당 보간 비율). 즉시 붙지 않게 해서
## 걷는 느낌을 준다.
const CAMERA_FOLLOW_SPEED := 6.0

var _save: Dictionary = {}
var _items: Dictionary = {}
var _island_size := Vector2(20.0, 12.0)
var _player: Player
var _gatherables: Array[Gatherable] = []
var _hud: Label
var _toast: Label
var _toast_timer := 0.0
var _autosave_timer := 0.0
var _hud_timer := 0.0
var _camera: Camera3D

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
	var spawn_data := _load_json("res://data/gatherables.json")
	var island: Dictionary = spawn_data.get("island", {})
	_island_size = Vector2(
		float(island.get("size_x", 20.0)),
		float(island.get("size_z", 12.0))
	)

	_build_environment()

	var limits: Dictionary = spawn_data.get("limits", {})
	for spawn: Variant in spawn_data.get("spawns", []):
		if typeof(spawn) != TYPE_DICTIONARY:
			continue
		var g := Gatherable.new()
		g.setup(spawn as Dictionary, limits)
		g.gathered.connect(_on_gathered)
		add_child(g)
		_gatherables.append(g)

	_player = Player.new()
	_player.setup(_island_size)
	add_child(_player)

	_build_hud()

func _build_environment() -> void:
	# 바다: 섬보다 넓은 평면을 살짝 아래에 깔아 섬이 물 위에 뜬 것처럼 보이게 한다.
	var sea := MeshInstance3D.new()
	var sea_mesh := PlaneMesh.new()
	sea_mesh.size = Vector2(_island_size.x * 3.0, _island_size.y * 3.0)
	sea.mesh = sea_mesh
	sea.position = Vector3(0, -0.35, 0)
	sea.material_override = _flat_material(Color(0.13, 0.42, 0.66))
	add_child(sea)

	# 섬: 살짝 두께가 있는 박스로 해서 측면이 보이게 — 완전 평면보다 입체감이 산다.
	var ground := MeshInstance3D.new()
	var ground_mesh := BoxMesh.new()
	ground_mesh.size = Vector3(_island_size.x, 0.6, _island_size.y)
	ground.mesh = ground_mesh
	ground.position = Vector3(0, -0.3, 0)
	ground.material_override = _flat_material(Color(0.40, 0.66, 0.32))
	add_child(ground)

	# 모래 테두리: 섬보다 살짝 크고 낮은 박스.
	var sand := MeshInstance3D.new()
	var sand_mesh := BoxMesh.new()
	sand_mesh.size = Vector3(_island_size.x + 1.6, 0.5, _island_size.y + 1.6)
	sand.mesh = sand_mesh
	sand.position = Vector3(0, -0.32, 0)
	sand.material_override = _flat_material(Color(0.87, 0.79, 0.56))
	add_child(sand)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-52, -38, 0)
	# 1.1은 실측 결과 색이 전부 하얗게 날아갔다 — 색이 살아 있도록 낮춘다.
	light.light_energy = 0.85
	# 그림자가 있어야 2D 캐릭터가 3D 지형 위에 서 있는 것처럼 읽힌다.
	light.shadow_enabled = true
	add_child(light)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.60, 0.83, 0.94)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.72, 0.78, 0.85)
	e.ambient_light_energy = 0.35
	env.environment = e
	add_child(env)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = CAMERA_SIZE
	cam.rotation_degrees = Vector3(CAMERA_PITCH_DEG, CAMERA_YAW_DEG, 0)
	# 회전 방향으로 뒤로 물러난 위치 — 직교 투영이라 거리는 원근에 영향이 없고
	# 클리핑에만 영향을 준다.
	cam.near = 0.1
	cam.far = 80.0
	add_child(cam)
	_camera = cam
	_update_camera(1.0)   # 첫 프레임부터 플레이어를 담고 있어야 한다

func _flat_material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.roughness = 1.0
	return m

func _build_hud() -> void:
	# 3D 위에 얹는 2D UI — 2.5D 구성의 "2D" 한 축.
	var layer := CanvasLayer.new()
	add_child(layer)

	_hud = Label.new()
	_hud.position = Vector2(16, 12)
	_hud.add_theme_color_override("font_color", Color(1, 1, 1))
	_hud.add_theme_color_override("font_outline_color", Color(0.08, 0.16, 0.12, 0.9))
	_hud.add_theme_constant_override("outline_size", 4)
	_hud.add_theme_constant_override("line_spacing", 4)
	layer.add_child(_hud)

	_toast = Label.new()
	_toast.position = Vector2(16, 470)
	_toast.add_theme_color_override("font_color", Color(1, 1, 1))
	_toast.add_theme_color_override("font_outline_color", Color(0.08, 0.16, 0.12, 0.9))
	_toast.add_theme_constant_override("outline_size", 4)
	layer.add_child(_toast)

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
	var unsold := {}
	for item_id: String in inv.keys():
		var price := _price_of(item_id)
		if price < 0:
			# 가격을 모르는 아이템은 팔지 않고 가방에 남긴다(손실 방지).
			unsold[item_id] = inv[item_id]
			continue
		total += int(inv[item_id]) * price
	_save["bells"] = int(_save.get("bells", 0)) + total
	_save["inventory"] = unsold
	if unsold.is_empty():
		_show_toast("%d벨에 판매했습니다" % total)
	else:
		_show_toast("%d벨에 판매했습니다 (가격 미상 %d종은 남겨둠)" % [total, unsold.size()])
	_refresh_hud()
	SaveManager.save(_save)

func _label_of(item_id: String) -> String:
	var meta: Dictionary = _items.get(item_id, {})
	return String(meta.get("label", item_id))

## 가격은 data/items.json이 유일한 출처이며, 유효범위(price_range)를 벗어난
## 값은 데이터 오타로 보고 클램프한다. 클램프/경고 규칙은 Balance가 소유해
## 채집물 쪽과 동일하게 동작한다.
func _price_of(item_id: String) -> int:
	if not _items.has(item_id):
		# 알 수 없는 아이템을 0벨로 조용히 처리하면 판매 시 가방에서 사라져
		# 플레이어 손실이 된다 — 판매 대상에서 제외하고 경고를 남긴다.
		push_warning("data/items.json에 없는 아이템: %s — 판매 제외" % item_id)
		return -1
	var meta: Dictionary = _items[item_id]
	return int(Balance.clamp_value(
		float(meta.get("sell_price", 0)),
		meta.get("price_range", null),
		"%s.sell_price" % item_id,
		"price"
	))

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

## 카메라를 플레이어 위로 옮긴다. weight=1.0이면 즉시 스냅.
func _update_camera(weight: float) -> void:
	if _camera == null or _player == null:
		return
	# basis.z는 카메라가 바라보는 반대 방향이라, 그만큼 뒤로 물러난 위치가
	# 플레이어를 화면 중앙에 두는 카메라 위치가 된다.
	var target := _player.position + _camera.transform.basis.z * CAMERA_DISTANCE
	_camera.position = _camera.position.lerp(target, clampf(weight, 0.0, 1.0))

func _process(delta: float) -> void:
	_update_camera(CAMERA_FOLLOW_SPEED * delta)
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
