extends Node3D
class_name World

## 월드맵. 화면 구성은 2.5D다: 지형·나무·조개는 3D 메시, 캐릭터는 3D 공간에
## 세운 2D 빌보드 스프라이트, HUD는 그 위에 얹은 2D CanvasLayer(docs/design.md §2.1).
##
## 맵 크기·스폰·모임 존은 data/world.json이 단일 출처다 — 초기값은 한 화면의
## 9배 면적(가로/세로 각 3배)이고, size_x/size_z만 고치면 커진다.
##
## 씬은 .tscn 대신 코드로 조립한다 — 프로토타입 단계에선 텍스트 씬 파일을
## 손으로 관리하는 비용이 더 크고, 헤드리스 실행으로 전체 구성을 검증할 수
## 있다(scripts/verify-project.sh).

const AUTOSAVE_INTERVAL_SEC := 10.0

## 카메라: 직교 투영 + 위에서 내려다보는 각도. yaw를 0으로 두면 화면 위쪽이
## 월드 -Z와 일치해 입력 매핑이 단순해진다(player.gd 주석 참고).
const CAMERA_PITCH_DEG := -38.0
const CAMERA_YAW_DEG := 0.0
const CAMERA_SIZE := 9.5
const CAMERA_DISTANCE := 16.0
const CAMERA_FOLLOW_SPEED := 6.0

## 존 진입 판정 주기(초). 매 프레임 거리를 재는 건 낭비다.
const ZONE_CHECK_INTERVAL := 0.25

## 화면에 남겨두는 채팅 줄 수.
const CHAT_LOG_LINES := 6
## 월드에 놓인 물건을 주울 수 있는 거리(월드 단위).
const PICKUP_DISTANCE := 1.6
## 드랍 아이템 메시 크기.
const DROP_MESH_RADIUS := 0.18

var _save: Dictionary = {}
var _slot_index := -1
var _slot: Dictionary = {}
var _preset: Dictionary = {}

var _items: Dictionary = {}
var _world_cfg: Dictionary = {}
var _world_size := Vector2(50.7, 28.5)
var _zones: Array = []
var _current_zone: String = ""

var _player: Player
var _gatherables: Array[Gatherable] = []
var _hud: Label
var _toast: Label
var _zone_label: Label
var _toast_timer := 0.0
var _autosave_timer := 0.0
var _hud_timer := 0.0
var _zone_timer := 0.0
var _camera: Camera3D

# --- 멀티플레이(docs/protocol.md) ---
var _net: Net
var _remotes: Dictionary = {}       # token -> RemotePlayer
var _drops: Dictionary = {}         # entity id -> Node3D
var _drop_items: Dictionary = {}    # entity id -> item_id (줍기 판정용)
var _presets: Dictionary = {}       # preset id -> 프리셋 Dictionary
var _emotes: Array = []
var _chat_log: Array[String] = []
var _chat_input: LineEdit
var _chat_label: Label
var _net_label: Label
var _my_extras: AvatarExtras
## 서버가 끊긴 동안 채집한 것. 다시 붙으면 서버로 흘려보낸다 — 안 하면 서버의
## welcome이 로컬 가방을 덮어써 오프라인 채집이 사라진다(docs/protocol.md §4).
var _pending_gathers: Dictionary = {}

## main.gd가 슬롯을 고른 뒤 호출한다.
func setup(save: Dictionary, slot_index: int, preset: Dictionary, world_cfg: Dictionary) -> void:
	_save = save
	_slot_index = slot_index
	_slot = SaveManager.slots_view(save)[slot_index]
	_preset = preset
	_world_cfg = world_cfg

func _ready() -> void:
	_items = DataFiles.load_dict("res://data/items.json").get("items", {})
	_world_size = Vector2(
		float(_world_cfg.get("size_x", 50.7)),
		float(_world_cfg.get("size_z", 28.5))
	)
	_zones = _world_cfg.get("zones", [])
	for p: Variant in DataFiles.load_dict("res://data/characters.json").get("presets", []):
		if typeof(p) == TYPE_DICTIONARY:
			_presets[String((p as Dictionary).get("id", ""))] = p
	_emotes = DataFiles.load_dict("res://data/emotes.json").get("emotes", [])
	_build_world()
	_apply_daily_respawn()
	_refresh_hud()
	_start_net()

func _build_world() -> void:
	_build_environment()

	var spawn_data := DataFiles.load_dict("res://data/gatherables.json")
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
	_player.setup(_world_size, _preset)
	# 슬롯이 기억하고 있던 위치에서 시작한다("이름이 지정됐던 캐릭터는 위치정보를
	# 기억한다" — 컨셉). 서버에 붙으면 서버 값이 우선이다(docs/protocol.md §4).
	var pos: Dictionary = _slot.get("pos", {})
	_player.position = Vector3(float(pos.get("x", 0.0)), 0.0, float(pos.get("z", 0.0)))
	add_child(_player)

	# 내 캐릭터도 남들과 같은 이름표·말풍선을 쓴다 — 나만 다르게 보이면
	# "실시간으로 잘 보이는지"를 검증할 수 없다.
	_my_extras = AvatarExtras.new()
	_player.add_child(_my_extras)
	_my_extras.set_name_text(String(_slot.get("name", "")))

	_build_hud()
	_update_camera(1.0)

func _build_environment() -> void:
	# 바다: 맵보다 넓은 평면을 살짝 아래에 깔아 섬이 물 위에 뜬 것처럼 보이게 한다.
	var sea := MeshInstance3D.new()
	var sea_mesh := PlaneMesh.new()
	sea_mesh.size = Vector2(_world_size.x * 2.0, _world_size.y * 2.0)
	sea.mesh = sea_mesh
	sea.position = Vector3(0, -0.35, 0)
	sea.material_override = _flat_material(Palette.color("world", "sea"))
	add_child(sea)

	# 섬: 살짝 두께가 있는 박스로 해서 측면이 보이게 — 완전 평면보다 입체감이 산다.
	var ground := MeshInstance3D.new()
	var ground_mesh := BoxMesh.new()
	ground_mesh.size = Vector3(_world_size.x, 0.6, _world_size.y)
	ground.mesh = ground_mesh
	ground.position = Vector3(0, -0.3, 0)
	ground.material_override = _flat_material(Palette.color("world", "island_grass"))
	add_child(ground)

	# 모래 테두리: 섬보다 살짝 크고 낮은 박스.
	var sand := MeshInstance3D.new()
	var sand_mesh := BoxMesh.new()
	sand_mesh.size = Vector3(_world_size.x + 2.4, 0.5, _world_size.y + 2.4)
	sand.mesh = sand_mesh
	sand.position = Vector3(0, -0.32, 0)
	sand.material_override = _flat_material(Palette.color("world", "sand"))
	add_child(sand)

	# 모임 존: 바닥에 원판을 깔아 "여기 들어가면 뭔가 있다"를 보이게 한다.
	for z: Variant in _zones:
		if typeof(z) != TYPE_DICTIONARY:
			continue
		var zone := z as Dictionary
		var disc := MeshInstance3D.new()
		var disc_mesh := CylinderMesh.new()
		disc_mesh.top_radius = float(zone.get("radius", 3.0))
		disc_mesh.bottom_radius = float(zone.get("radius", 3.0))
		disc_mesh.height = 0.06
		disc_mesh.radial_segments = 24
		disc.mesh = disc_mesh
		disc.position = Vector3(float(zone.get("x", 0.0)), 0.04, float(zone.get("z", 0.0)))
		var m := StandardMaterial3D.new()
		m.albedo_color = Palette.color("world", "zone_floor")
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		disc.material_override = m
		add_child(disc)

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
	e.background_color = Palette.color("world", "sky")
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Palette.color("world", "ambient")
	e.ambient_light_energy = 0.35
	env.environment = e
	add_child(env)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = CAMERA_SIZE
	cam.rotation_degrees = Vector3(CAMERA_PITCH_DEG, CAMERA_YAW_DEG, 0)
	cam.near = 0.1
	cam.far = 120.0
	add_child(cam)
	_camera = cam

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

	# 색은 data/palette.json이 단일 출처(Palette). 여러 Label이 같은 색을 쓰므로
	# 프레임마다가 아니라 여기서 한 번만 읽는다.
	var text_color := Palette.color("ui", "hud_text")
	var outline_color := Palette.color("ui", "hud_outline")

	_hud = Label.new()
	_hud.position = Vector2(16, 12)
	_hud.add_theme_color_override("font_color", text_color)
	_hud.add_theme_color_override("font_outline_color", outline_color)
	_hud.add_theme_constant_override("outline_size", 4)
	_hud.add_theme_constant_override("line_spacing", 4)
	layer.add_child(_hud)

	_zone_label = Label.new()
	_zone_label.position = Vector2(16, 440)
	_zone_label.add_theme_color_override("font_color", Palette.color("ui", "zone_text"))
	_zone_label.add_theme_color_override("font_outline_color", outline_color)
	_zone_label.add_theme_constant_override("outline_size", 4)
	layer.add_child(_zone_label)

	_chat_label = Label.new()
	_chat_label.position = Vector2(16, 250)
	_chat_label.add_theme_color_override("font_color", Palette.color("ui", "chat_text"))
	_chat_label.add_theme_color_override("font_outline_color", outline_color)
	_chat_label.add_theme_constant_override("outline_size", 4)
	_chat_label.add_theme_constant_override("line_spacing", 2)
	layer.add_child(_chat_label)

	_net_label = Label.new()
	_net_label.position = Vector2(760, 12)
	_net_label.add_theme_color_override("font_color", Palette.color("ui", "warn_text"))
	_net_label.add_theme_color_override("font_outline_color", outline_color)
	_net_label.add_theme_constant_override("outline_size", 4)
	_net_label.text = "서버 연결 중…"
	layer.add_child(_net_label)

	# 채팅 입력창은 평소 숨겨두고 T로 연다 — 항상 떠 있으면 방향키 입력을 먹는다.
	_chat_input = LineEdit.new()
	_chat_input.position = Vector2(16, 500)
	_chat_input.size = Vector2(600, 30)
	_chat_input.max_length = 200
	_chat_input.placeholder_text = "메시지 입력 후 Enter (Esc 취소)"
	_chat_input.visible = false
	_chat_input.text_submitted.connect(_on_chat_submitted)
	layer.add_child(_chat_input)

	_toast = Label.new()
	_toast.position = Vector2(16, 470)
	_toast.add_theme_color_override("font_color", text_color)
	_toast.add_theme_color_override("font_outline_color", outline_color)
	_toast.add_theme_constant_override("outline_size", 4)
	layer.add_child(_toast)

## 마지막 접속 이후 하루 이상 지났으면 채집물 전체를 되살린다.
func _apply_daily_respawn() -> void:
	var days := GameClock.days_since(int(_slot.get("last_played_unix", 0)))
	if days <= 0:
		return
	for g in _gatherables:
		g.force_respawn()
	_show_toast("%d일이 지났습니다 — 섬이 새로 자랐어요" % days)

func _on_gathered(item_id: String) -> void:
	# 가방의 단일 출처는 서버다(드랍/줍기가 서버 권위이므로 채집도 같은 곳에
	# 반영해야 한다). 화면 반응성을 위해 로컬에도 즉시 더하고, 서버 응답이
	# 오면 그 값으로 맞춘다.
	var inv: Dictionary = _slot.get("inventory", {})
	inv[item_id] = int(inv.get(item_id, 0)) + 1
	_slot["inventory"] = inv
	_show_toast("%s 채집!" % _label_of(item_id))
	_refresh_hud()
	if _net != null and _net.connected:
		_net.send_gather(item_id)
	else:
		_pending_gathers[item_id] = int(_pending_gathers.get(item_id, 0)) + 1

func _sell_all() -> void:
	var inv: Dictionary = _slot.get("inventory", {})
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
	_slot["bells"] = int(_slot.get("bells", 0)) + total
	_slot["inventory"] = unsold
	if unsold.is_empty():
		_show_toast("%d벨에 판매했습니다" % total)
	else:
		_show_toast("%d벨에 판매했습니다 (가격 미상 %d종은 남겨둠)" % [total, unsold.size()])
	_refresh_hud()
	_persist()

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
	var inv: Dictionary = _slot.get("inventory", {})
	var parts: Array[String] = []
	for item_id: String in inv.keys():
		parts.append("%s x%d" % [_label_of(item_id), int(inv[item_id])])
	var bag := "가방: 비었음" if parts.is_empty() else "가방: " + ", ".join(parts)
	var who := String(_slot.get("name", "(이름 없음)"))
	_hud.text = "%s  |  %s\n벨: %d\n%s\n[방향키] 이동  [Space] 채집/줍기  [S] 판매  [T] 채팅  [1~%d] 이모티콘  [Q] 버리기" % [
		who, GameClock.label(), int(_slot.get("bells", 0)), bag, maxi(_emotes.size(), 1)
	]

## 채팅 로그는 최근 CHAT_LOG_LINES줄만 화면에 남긴다 — 더 쌓아두면 화면을
## 가리고, 스크롤 가능한 채팅창은 P6(UI 정리)에서 다룬다.
func _append_chat(line: String) -> void:
	_chat_log.append(line)
	while _chat_log.size() > CHAT_LOG_LINES:
		_chat_log.remove_at(0)
	if _chat_label != null:
		_chat_label.text = "\n".join(_chat_log)

func _show_toast(text: String) -> void:
	_toast.text = text
	_toast_timer = 2.5

func _unhandled_input(event: InputEvent) -> void:
	# 채팅 입력 중에는 게임 조작을 받지 않는다 — 안 그러면 "s"를 치면 물건이 팔린다.
	if _chat_input != null and _chat_input.visible:
		if event is InputEventKey and event.pressed and (event as InputEventKey).keycode == KEY_ESCAPE:
			_close_chat_input()
		return

	if event.is_action_pressed("ui_accept"):
		_try_interact()
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match (event as InputEventKey).keycode:
		KEY_S:
			_sell_all()
		KEY_T:
			_open_chat_input()
		KEY_Q:
			_drop_one()
		_:
			_try_emote_key((event as InputEventKey).keycode)

## 숫자키 1~N을 data/emotes.json 순서에 매핑한다(개수는 데이터가 정한다).
func _try_emote_key(keycode: int) -> void:
	var index := keycode - KEY_1
	if index < 0 or index >= _emotes.size():
		return
	var emote: Variant = _emotes[index]
	if typeof(emote) != TYPE_DICTIONARY:
		return
	var id := String((emote as Dictionary).get("id", ""))
	var glyph := String((emote as Dictionary).get("glyph", "?"))
	# 내 화면에는 즉시 보여주고(반응성) 서버에도 알린다. 서버가 거절하면
	# 남들에게만 안 보이는데, 그 경우는 error 메시지로 화면에 뜬다.
	if _my_extras != null:
		_my_extras.show_emote(glyph)
	if _net != null:
		_net.send_emote(id)

## Space: 주변에 놓인 물건이 있으면 줍고, 없으면 채집한다.
func _try_interact() -> void:
	var nearest_drop := _nearest_drop()
	if not nearest_drop.is_empty():
		if _net != null and _net.connected:
			_net.send_pickup(nearest_drop)
		else:
			_show_toast("서버에 연결돼 있지 않아 물건을 주울 수 없습니다")
		return
	_try_gather()

func _nearest_drop() -> String:
	var best := INF
	var found := ""
	for id: String in _drops.keys():
		var node: Node3D = _drops[id]
		var d := _player.position.distance_to(node.position)
		if d <= PICKUP_DISTANCE and d < best:
			best = d
			found = id
	return found

## Q: 가방에서 아무거나 1개를 발밑에 놓는다. 어떤 것을 놓을지 고르는 UI는
## 인벤토리 화면(P6)에서 붙인다 — 지금은 드랍/줍기 왕복을 검증하는 게 목적이다.
func _drop_one() -> void:
	var inv: Dictionary = _slot.get("inventory", {})
	if inv.is_empty():
		_show_toast("버릴 물건이 없습니다")
		return
	if _net == null or not _net.connected:
		_show_toast("서버에 연결돼 있지 않아 물건을 놓을 수 없습니다")
		return
	var item_id := String(inv.keys()[0])
	# 가방 표시는 서버의 inventory 응답으로 갱신한다 — 여기서 미리 줄이면
	# 서버가 거절했을 때 화면과 실제가 갈린다.
	_net.send_drop(item_id, _player.position)

func _open_chat_input() -> void:
	if _chat_input == null:
		return
	_chat_input.visible = true
	_chat_input.text = ""
	_chat_input.grab_focus()

func _close_chat_input() -> void:
	if _chat_input == null:
		return
	_chat_input.visible = false
	_chat_input.release_focus()

func _on_chat_submitted(text: String) -> void:
	var clean := text.strip_edges()
	_close_chat_input()
	if clean.is_empty():
		return
	if _net == null or not _net.connected:
		# 혼자 플레이 중에도 입력이 사라지지 않게 내 화면에는 남긴다.
		_append_chat("(연결 없음) %s: %s" % [String(_slot.get("name", "")), clean])
		if _my_extras != null:
			_my_extras.show_chat(clean)
		return
	_net.send_chat(clean)

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

## 모임 존 진입/이탈 감지. 지금은 안내만 하고, 미니게임은 P5에서 붙인다
## (docs/roadmap.md). 판정을 클라이언트가 하고 있다는 점은 protocol.md §3에
## 명시된 신뢰 경계 안이다 — 결과가 걸린 상호작용을 붙일 때 서버로 옮겨야 한다.
func _check_zone() -> void:
	var here := ""
	var label := ""
	var p := Vector2(_player.position.x, _player.position.z)
	for z: Variant in _zones:
		if typeof(z) != TYPE_DICTIONARY:
			continue
		var zone := z as Dictionary
		var c := Vector2(float(zone.get("x", 0.0)), float(zone.get("z", 0.0)))
		if p.distance_to(c) <= float(zone.get("radius", 3.0)):
			here = String(zone.get("id", ""))
			label = String(zone.get("label", here))
			break
	if here == _current_zone:
		return
	_current_zone = here
	if here.is_empty():
		_zone_label.text = ""
	else:
		_zone_label.text = "[%s] 모임 장소 — 미니게임 준비 중" % label
		_show_toast("%s에 들어왔습니다" % label)

# ---------------------------------------------------------------------------
# 멀티플레이 (docs/protocol.md)
# ---------------------------------------------------------------------------

func _start_net() -> void:
	_net = Net.new()
	add_child(_net)
	_net.opened.connect(_on_net_opened)
	_net.closed.connect(_on_net_closed)
	_net.welcomed.connect(_on_welcome)
	_net.snapshot_received.connect(_on_snapshot)
	_net.player_joined.connect(_on_player_joined)
	_net.player_left.connect(_on_player_left)
	_net.moves_received.connect(_on_moves)
	_net.chat_received.connect(_on_chat)
	_net.emote_received.connect(_on_emote)
	_net.item_added.connect(_on_item_added)
	_net.item_removed.connect(_on_item_removed)
	_net.inventory_received.connect(_on_inventory)
	_net.rename_received.connect(_on_rename)
	_net.server_error.connect(_on_server_error)
	_net.start(String(_slot.get("token", "")), String(_slot.get("name", "")), String(_slot.get("preset", "")))

func _on_net_opened() -> void:
	_net_label.text = "서버 연결됨"
	# 오프라인 동안 채집한 것을 흘려보낸다(순서는 중요하지 않다).
	for item_id: String in _pending_gathers.keys():
		for _i in int(_pending_gathers[item_id]):
			_net.send_gather(item_id)
	_pending_gathers.clear()

func _on_net_closed(reason: String) -> void:
	_net_label.text = "서버 끊김 — 혼자 플레이 (재연결 시도 중)"
	push_warning("서버 연결 종료: %s" % reason)
	# 남아 있던 다른 캐릭터/물건은 지운다 — 끊긴 뒤에도 남겨두면 유령이 된다.
	for token: String in _remotes.keys():
		(_remotes[token] as Node).queue_free()
	_remotes.clear()
	for id: String in _drops.keys():
		(_drops[id] as Node).queue_free()
	_drops.clear()
	_drop_items.clear()

## 서버가 기억하는 위치·가방이 내 로컬 값보다 우선이다(docs/protocol.md §4).
func _on_welcome(you: Dictionary, world_cfg: Dictionary) -> void:
	var pos := Vector3(float(you.get("x", _player.position.x)), 0.0, float(you.get("z", _player.position.z)))
	_player.position = pos
	_update_camera(1.0)
	if typeof(you.get("inventory")) == TYPE_DICTIONARY:
		_slot["inventory"] = you["inventory"]
		_refresh_hud()
	var sx := float(world_cfg.get("size_x", _world_size.x))
	var sz := float(world_cfg.get("size_z", _world_size.y))
	if not is_equal_approx(sx, _world_size.x) or not is_equal_approx(sz, _world_size.y):
		# 서버와 클라이언트가 다른 data/world.json을 보고 있다는 뜻 — 배포가
		# 어긋난 상태이므로 조용히 넘기지 않는다.
		push_warning("서버 월드 크기(%.1f x %.1f)가 클라이언트(%.1f x %.1f)와 다르다" % [sx, sz, _world_size.x, _world_size.y])
	_append_chat("서버에 접속했습니다")

func _on_snapshot(players: Array, items: Array) -> void:
	for p: Variant in players:
		if typeof(p) == TYPE_DICTIONARY:
			_on_player_joined(p as Dictionary)
	for i: Variant in items:
		if typeof(i) == TYPE_DICTIONARY:
			_on_item_added(i as Dictionary)

func _on_player_joined(player: Dictionary) -> void:
	var token := String(player.get("token", ""))
	if token.is_empty() or token == String(_slot.get("token", "")):
		return   # 나 자신은 원격으로 만들지 않는다
	if _remotes.has(token):
		return
	var remote := RemotePlayer.new()
	remote.setup(player, _presets.get(String(player.get("preset", "")), {}))
	add_child(remote)
	_remotes[token] = remote
	_append_chat("%s 님이 들어왔습니다" % String(player.get("name", "")))

func _on_player_left(token: String) -> void:
	if not _remotes.has(token):
		return
	(_remotes[token] as Node).queue_free()
	_remotes.erase(token)

func _on_moves(moves: Array) -> void:
	for m: Variant in moves:
		if typeof(m) != TYPE_DICTIONARY:
			continue
		var move := m as Dictionary
		var token := String(move.get("token", ""))
		if not _remotes.has(token):
			continue
		(_remotes[token] as RemotePlayer).apply_move(
			float(move.get("x", 0.0)), float(move.get("z", 0.0)), String(move.get("dir", "down"))
		)

func _on_chat(msg: Dictionary) -> void:
	var token := String(msg.get("token", ""))
	var text := String(msg.get("text", ""))
	_append_chat("%s: %s" % [String(msg.get("name", "")), text])
	if token == String(_slot.get("token", "")):
		if _my_extras != null:
			_my_extras.show_chat(text)
	elif _remotes.has(token):
		var remote := _remotes[token] as RemotePlayer
		if remote.extras != null:
			remote.extras.show_chat(text)

func _on_emote(msg: Dictionary) -> void:
	var token := String(msg.get("token", ""))
	var glyph := _emote_glyph(String(msg.get("emote", "")))
	if token == String(_slot.get("token", "")):
		return   # 내 것은 입력 시점에 이미 띄웠다
	if _remotes.has(token):
		var remote := _remotes[token] as RemotePlayer
		if remote.extras != null:
			remote.extras.show_emote(glyph)

func _emote_glyph(emote_id: String) -> String:
	for e: Variant in _emotes:
		if typeof(e) == TYPE_DICTIONARY and String((e as Dictionary).get("id", "")) == emote_id:
			return String((e as Dictionary).get("glyph", "?"))
	return "?"

func _on_item_added(item: Dictionary) -> void:
	var id := String(item.get("id", ""))
	if id.is_empty() or _drops.has(id):
		return
	var node := Node3D.new()
	node.position = Vector3(float(item.get("x", 0.0)), 0.0, float(item.get("z", 0.0)))
	var mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = DROP_MESH_RADIUS
	sphere.height = DROP_MESH_RADIUS * 2.0
	sphere.radial_segments = 10
	sphere.rings = 5
	mesh.mesh = sphere
	mesh.position = Vector3(0, DROP_MESH_RADIUS, 0)
	var m := StandardMaterial3D.new()
	m.albedo_color = Palette.color("world", "drop_item")
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mesh.material_override = m
	node.add_child(mesh)
	var tag := Label3D.new()
	tag.text = _label_of(String(item.get("item", "")))
	tag.position = Vector3(0, 0.75, 0)
	tag.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	tag.font_size = 24
	tag.outline_size = 8
	tag.pixel_size = 0.0035
	tag.no_depth_test = true
	node.add_child(tag)
	add_child(node)
	_drops[id] = node
	_drop_items[id] = String(item.get("item", ""))

func _on_item_removed(id: String, by: String) -> void:
	if not _drops.has(id):
		return
	(_drops[id] as Node).queue_free()
	var item_id: String = _drop_items.get(id, "")
	_drops.erase(id)
	_drop_items.erase(id)
	if by == String(_slot.get("token", "")):
		_show_toast("%s 줍기!" % _label_of(item_id))

func _on_inventory(inventory: Dictionary) -> void:
	# 가방의 최종 판정은 서버다(중복 획득 방지, docs/protocol.md §3).
	_slot["inventory"] = inventory
	_refresh_hud()
	_persist()

func _on_rename(token: String, new_name: String) -> void:
	if _remotes.has(token):
		(_remotes[token] as RemotePlayer).set_display_name(new_name)

func _on_server_error(code: String, message: String) -> void:
	# 서버 거절을 조용히 삼키면 "왜 안 되는지" 알 수 없다 — 화면에 띄운다.
	_show_toast("서버: %s" % message)
	push_warning("서버 오류(%s): %s" % [code, message])

## 슬롯에 현재 상태(위치·벨·가방)를 반영해 저장한다.
func _persist() -> void:
	_slot["pos"] = {"x": snappedf(_player.position.x, 0.01), "z": snappedf(_player.position.z, 0.01)}
	_slot["last_played_unix"] = int(Time.get_unix_time_from_system())
	SaveManager.put_slot(_save, _slot_index, _slot)
	SaveManager.save(_save)

func _process(delta: float) -> void:
	_update_camera(CAMERA_FOLLOW_SPEED * delta)

	if _net != null and _player != null and _player.sprite != null:
		_net.send_move(_player.position, _player.sprite.facing())

	if _toast_timer > 0.0:
		_toast_timer -= delta
		if _toast_timer <= 0.0:
			_toast.text = ""

	_zone_timer += delta
	if _zone_timer >= ZONE_CHECK_INTERVAL:
		_zone_timer = 0.0
		_check_zone()

	_autosave_timer += delta
	if _autosave_timer >= AUTOSAVE_INTERVAL_SEC:
		_autosave_timer = 0.0
		_persist()

	# HUD 문자열을 매 프레임 새로 만들면 웹에서 불필요한 할당/GC가 쌓인다 —
	# 시계 갱신은 1초 간격이면 충분하고, 벨/가방은 변경 시점에 즉시 갱신된다.
	_hud_timer += delta
	if _hud_timer >= 1.0:
		_hud_timer = 0.0
		_refresh_hud()

func _notification(what: int) -> void:
	# 브라우저 탭을 닫을 때도 저장되도록 종료 알림을 잡는다.
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		if _player != null:
			_persist()
