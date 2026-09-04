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
## 기준 화면 비율(16:9). 세로 모드처럼 이보다 좁아지면 직교 size는 세로 기준이라
## 가로 시야가 급격히 줄어든다 — 비율만큼 size를 키워 가로 시야를 지킨다
## (회의 결정 ⑤, agy도 같은 결론). 다만 무한정 키우면 캐릭터가 점이 되므로
## 배율에 상한을 둔다.
const CAMERA_BASE_ASPECT := 16.0 / 9.0
const CAMERA_MAX_ZOOM_OUT := 1.8

## 존 진입 판정 주기(초). 매 프레임 거리를 재는 건 낭비다.
const ZONE_CHECK_INTERVAL := 0.25

## 하단 접속자 바에 표시할 인원 상한. 넘치면 "+N"으로 줄인다 — 좁은 화면에서
## 인원이 늘어나면 바가 화면을 넘어간다.
const ROSTER_MAX := 8
const ROSTER_MAX_NARROW := 4
## 접속자 바의 초상화 크기(px).
const ROSTER_PORTRAIT := Vector2(38, 46)

## 화면에 남겨두는 채팅 줄 수. 세로 모드처럼 화면이 짧으면 줄여서 월드를 가리지 않게 한다.
const CHAT_LOG_LINES := 6
const CHAT_LOG_LINES_SHORT := 3
## 화면 **폭**이 이보다 좁으면 "좁은 화면"으로 본다(px). 처음에는 높이로
## 판단했는데 폰 세로(412×839)는 높이가 충분해서 판정에 걸리지 않았고, 정작
## 문제는 좁은 폭에서 채팅 로그가 캐릭터를 가리는 것이었다(세로 실측).
const NARROW_SCREEN_WIDTH := 700.0
## HUD 안전 마진(px). 노치·둥근 모서리를 감안해 넉넉히 잡는다.
const HUD_MARGIN := 18.0
## 월드에 놓인 물건을 주울 수 있는 거리(월드 단위).
const PICKUP_DISTANCE := 1.6
## 드랍 아이템 메시 크기.
const DROP_MESH_RADIUS := 0.18

## 탭한 지점에서 이 거리 안에 대상이 있으면 "그 대상을 탭했다"로 본다(월드 단위).
## 손가락은 뭉툭하니 넉넉해야 하지만, 너무 크면 **나무 옆 땅을 탭했는데 나무를
## 집는다** — 1.3은 실제로 그렇게 느껴졌다(2026-09-04 사용자 보고). 나무 수관
## 반지름(0.95)에 손가락 여유만 더한 값으로 좁혔다.
const TAP_PICK_RADIUS := 1.0
## 대상에 다가갈 때 얼마나 가까이 설지 — 상호작용 사거리(1.6)보다 조금 안쪽.
const APPROACH_DISTANCE := 1.1
## 목표 지점 마커 크기.
const MARKER_RADIUS := 0.34

var _save: Dictionary = {}
var _slot_index := -1
var _slot: Dictionary = {}
var _preset: Dictionary = {}

var _items: Dictionary = {}
var _world_cfg: Dictionary = {}
var _world_size := Vector2(50.7, 28.5)
var _zones: Array = []
## 통과 불가 바위(data/world.json obstacles). 탭 이동 경로 계산과 수동 이동
## 충돌 처리에 같은 목록을 쓴다 — 두 곳이 다른 목록을 보면 "보이는 바위는
## 막는데 우회는 안 하는" 어긋남이 생긴다.
var _obstacles: Array = []
var _current_zone: String = ""

var _player: Player
var _gatherables: Array[Gatherable] = []
var _hud: Label
var _bag_label: Label
var _hint_label: Label
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
var _chat: ChatInput
var _touch: TouchControls
var _chat_label: Label
var _net_label: Label
var _my_extras: AvatarExtras
## 탭 이동의 "도착하면 무엇을 할지". kind: ""(그냥 이동) | "gather" | "pickup"
var _tap_intent := {"kind": "", "id": ""}
## 자동 채집할 대상. "근처에서 아무거나"가 아니라 **탭한 그 대상**만 캔다.
var _tap_gatherable: Gatherable = null
var _marker: Node3D
## 하단 접속자 바(내 캐릭터 + 접속 중인 다른 캐릭터의 초상화·이름).
var _roster_box: HBoxContainer
var _hooks: TestHooks
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
	_obstacles = _world_cfg.get("obstacles", [])
	for p: Variant in DataFiles.load_dict("res://data/characters.json").get("presets", []):
		if typeof(p) == TYPE_DICTIONARY:
			_presets[String((p as Dictionary).get("id", ""))] = p
	_emotes = DataFiles.load_dict("res://data/emotes.json").get("emotes", [])
	_build_world()
	_apply_daily_respawn()
	_refresh_hud()
	_refresh_roster.call_deferred()
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
	_player.setup(_world_size, _preset, _obstacles)
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
	_build_marker()
	_player.arrived.connect(_on_player_arrived)
	_player.move_cancelled.connect(_on_move_cancelled)
	_update_camera(1.0)
	get_viewport().size_changed.connect(_on_viewport_resized)

	# E2E 테스트가 월드의 대상(나무 등) 화면 위치를 알 수 있게 공개한다.
	_hooks = TestHooks.new()
	add_child(_hooks)
	_publish_test_points()

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

	# 바위 조형물 — 통과 불가 장애물.
	for o: Variant in _obstacles:
		if typeof(o) != TYPE_DICTIONARY:
			continue
		var rock := Rock.new()
		rock.setup(o as Dictionary)
		add_child(rock)

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
	# 폰(터치 환경)에서는 방향광 그림자를 끈다 — WebGL2에서 실시간 그림자가
	# 발열·프레임 드랍의 가장 큰 원인이고, 캐릭터 접지감은 발밑 타원 데칼이
	# 따로 담당하므로 입체감이 크게 깨지지 않는다(회의 결정 ⑥, agy 동일 의견).
	light.shadow_enabled = not DisplayServer.is_touchscreen_available()
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
	cam.size = _camera_size_for_screen()
	cam.rotation_degrees = Vector3(CAMERA_PITCH_DEG, CAMERA_YAW_DEG, 0)
	cam.near = 0.1
	cam.far = 120.0
	add_child(cam)
	_camera = cam

## 직교 카메라의 size는 세로 기준이라, 세로 모드에서는 가로 시야가 급격히
## 좁아진다(390x844면 가로가 약 4.4 유닛밖에 안 된다). 기준 비율보다 좁아진
## 만큼 size를 키워 가로 시야를 지키고, 캐릭터가 점이 되지 않도록 상한을 둔다.
func _camera_size_for_screen() -> float:
	var vp := get_viewport()
	if vp == null:
		return CAMERA_SIZE
	var rect := vp.get_visible_rect().size
	if rect.x <= 0.0 or rect.y <= 0.0:
		return CAMERA_SIZE
	var aspect := rect.x / rect.y
	if aspect >= CAMERA_BASE_ASPECT:
		return CAMERA_SIZE
	var zoom := clampf(CAMERA_BASE_ASPECT / aspect, 1.0, CAMERA_MAX_ZOOM_OUT)
	return CAMERA_SIZE * zoom

## 탭한 목표를 바닥에 표시한다 — 마커가 없으면 "눌렀는데 반응이 없다"고 느낀다.
func _build_marker() -> void:
	_marker = Node3D.new()
	_marker.visible = false
	var mesh := MeshInstance3D.new()
	var ring := CylinderMesh.new()
	ring.top_radius = MARKER_RADIUS
	ring.bottom_radius = MARKER_RADIUS
	ring.height = 0.04
	ring.radial_segments = 20
	mesh.mesh = ring
	var m := StandardMaterial3D.new()
	m.albedo_color = Palette.color("ui", "move_marker")
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material_override = m
	mesh.position = Vector3(0, 0.05, 0)
	_marker.add_child(mesh)
	add_child(_marker)

func _flat_material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.roughness = 1.0
	return m

func _build_hud() -> void:
	# 3D 위에 얹는 2D UI — 2.5D 구성의 "2D" 한 축.
	#
	# 좌표는 전부 **앵커 + 마진**이다. 예전에는 Vector2(760, 12)처럼 절대좌표를
	# 박아서 폰 세로 모드(폭 390 등)에서는 화면 밖으로 잘려 상태를 볼 수 없었다
	# (회의 결정 ①, agy도 같은 지적).
	var layer := CanvasLayer.new()
	add_child(layer)

	# 색은 data/palette.json이 단일 출처(Palette). 여러 Label이 같은 색을 쓰므로
	# 프레임마다가 아니라 여기서 한 번만 읽는다.
	var text_color := Palette.color("ui", "hud_text")
	var outline_color := Palette.color("ui", "hud_outline")

	# HUD를 세 줄로 나눈다: 정보 / 가방(탭 가능) / 조작 안내.
	# 예전에는 라벨 하나가 세 줄을 다 갖고 MOUSE_FILTER_STOP이라 **좌상단 텍스트
	# 블록 전체**가 입력을 먹었다. 탭 이동을 붙이면 그 영역의 월드 탭이 판매
	# 확인으로 새므로, 탭 대상을 가방 줄로 좁힌다.
	var hud_box := VBoxContainer.new()
	hud_box.set_anchors_preset(Control.PRESET_TOP_LEFT)
	hud_box.offset_left = HUD_MARGIN
	hud_box.offset_top = HUD_MARGIN
	hud_box.add_theme_constant_override("separation", 2)
	hud_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(hud_box)

	_hud = _stack_label(hud_box, text_color, outline_color)
	_bag_label = _stack_label(hud_box, text_color, outline_color)
	# 가방 줄만 입력을 받는다 — 탭하면 판매 확인 시트가 뜬다.
	_bag_label.mouse_filter = Control.MOUSE_FILTER_STOP
	_bag_label.gui_input.connect(_on_bag_clicked)
	_hint_label = _stack_label(hud_box, text_color, outline_color)

	_net_label = _make_label(layer, Control.PRESET_TOP_RIGHT, Palette.color("ui", "warn_text"), outline_color)
	_net_label.offset_right = -HUD_MARGIN
	_net_label.offset_top = HUD_MARGIN
	_net_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_net_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_net_label.text = "서버 연결 중…"

	# 좁은 화면(폰 세로)에서는 화면 중앙에 두면 캐릭터를 가린다 — 아래쪽에 붙인다.
	var chat_preset := Control.PRESET_BOTTOM_LEFT if _is_narrow_screen() else Control.PRESET_CENTER_LEFT
	_chat_label = _make_label(layer, chat_preset, Palette.color("ui", "chat_text"), outline_color)
	_chat_label.offset_left = HUD_MARGIN
	if _is_narrow_screen():
		_chat_label.offset_bottom = -(HUD_MARGIN + 150.0)
		_chat_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_chat_label.add_theme_constant_override("line_spacing", 2)

	_zone_label = _make_label(layer, Control.PRESET_BOTTOM_LEFT, Palette.color("ui", "zone_text"), outline_color)
	_zone_label.offset_left = HUD_MARGIN
	_zone_label.offset_bottom = -(HUD_MARGIN + 46.0)
	_zone_label.grow_vertical = Control.GROW_DIRECTION_BEGIN

	_toast = _make_label(layer, Control.PRESET_BOTTOM_LEFT, text_color, outline_color)
	_toast.offset_left = HUD_MARGIN
	_toast.offset_bottom = -HUD_MARGIN
	_toast.grow_vertical = Control.GROW_DIRECTION_BEGIN

	# 하단 접속자 바 — 지금 이 월드에 누가 있는지 한눈에 보여준다.
	# mouse_filter를 IGNORE로 두는 이유: 바가 화면 하단을 가로지르는데 입력을
	# 먹으면 그 위를 탭했을 때 이동이 되지 않는다(조이스틱 영역과도 겹친다).
	var roster_panel := PanelContainer.new()
	roster_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	roster_panel.offset_left = HUD_MARGIN
	roster_panel.offset_right = -HUD_MARGIN
	roster_panel.offset_top = -(ROSTER_PORTRAIT.y + 34.0)
	roster_panel.offset_bottom = -2.0
	roster_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var roster_style := StyleBoxFlat.new()
	roster_style.bg_color = Palette.color("ui", "roster_bg")
	roster_style.corner_radius_top_left = 8
	roster_style.corner_radius_top_right = 8
	roster_style.content_margin_left = 8
	roster_style.content_margin_right = 8
	roster_style.content_margin_top = 4
	roster_style.content_margin_bottom = 4
	roster_panel.add_theme_stylebox_override("panel", roster_style)
	layer.add_child(roster_panel)

	_roster_box = HBoxContainer.new()
	_roster_box.add_theme_constant_override("separation", 10)
	_roster_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_roster_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	roster_panel.add_child(_roster_box)

	# 채팅 입력은 웹이면 DOM <input>, 아니면 LineEdit — ChatInput이 갈라 준다.
	_chat = ChatInput.new()
	_chat.submitted.connect(_on_chat_submitted)
	add_child(_chat)

	if DisplayServer.is_touchscreen_available():
		# 의심스러우면 띄운다 — 폰에서 안 뜨는 쪽이 치명적이다(회의 §10).
		_touch = TouchControls.new()
		_touch.setup(_emotes)
		_touch.action_pressed.connect(_try_interact)
		_touch.chat_pressed.connect(_open_chat_input)
		_touch.drop_pressed.connect(_drop_one)
		_touch.emote_selected.connect(_send_emote)
		_touch.sell_requested.connect(_sell_all)
		add_child(_touch)

func _is_narrow_screen() -> bool:
	var vp := get_viewport()
	if vp == null:
		return false
	return vp.get_visible_rect().size.x < NARROW_SCREEN_WIDTH

## HUD 스택 안에 들어가는 한 줄.
func _stack_label(box: VBoxContainer, color: Color, outline: Color) -> Label:
	var l := Label.new()
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", outline)
	l.add_theme_constant_override("outline_size", 4)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(l)
	return l

func _make_label(layer: CanvasLayer, preset: int, color: Color, outline: Color) -> Label:
	var l := Label.new()
	l.set_anchors_preset(preset)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", outline)
	l.add_theme_constant_override("outline_size", 4)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(l)
	return l

## 가방 줄을 탭하면 판매 확인을 띄운다. 터치 UI가 없는 환경에서는 기존 S 키가
## 그대로 즉시 판매한다.
func _on_bag_clicked(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if _touch != null:
		_touch.show_sell_confirm()

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
	# 조작 안내는 실제 조작 수단에 맞춘다 — 폰에서 "[방향키] 이동"은 아무 의미가
	# 없고, 오히려 터치 UI를 못 찾게 만든다.
	var hint := "가고 싶은 곳을 탭 · 나무/물건/사람을 탭하면 다가가서 자동 처리 · 왼쪽 아래를 끌면 직접 이동 · 가방 줄 탭하면 판매" \
		if _touch != null \
		else "[클릭] 그 지점으로 이동(대상 탭 시 자동 채집/줍기)  [방향키] 이동  [Space] 채집/줍기  [S] 판매  [T] 채팅  [1~%d] 이모티콘  [Q] 버리기" % maxi(_emotes.size(), 1)
	_hud.text = "%s  |  %s\n벨: %d" % [who, GameClock.label(), int(_slot.get("bells", 0))]
	_bag_label.text = bag
	_hint_label.text = hint

## 하단 접속자 바를 다시 만든다. 접속/퇴장/이름변경 때마다 호출된다.
##
## 초상화는 각 캐릭터의 PlayerSprite가 런타임에 만든 프레임을 그대로 재사용한다
## (idle_down 0번). 초상화를 따로 그리면 캐릭터 외형이 바뀔 때 두 곳을 고쳐야
## 하고, 프리셋이 늘어날 때마다 어긋난다.
func _refresh_roster() -> void:
	if _roster_box == null:
		return
	for c in _roster_box.get_children():
		_roster_box.remove_child(c)
		c.queue_free()
	if _hooks != null:
		# 사라진 항목 키가 남아 있으면 테스트가 인원 수를 잘못 센다.
		for i in ROSTER_MAX:
			_hooks.untrack("rosterEntry%d" % (i + 1))

	var limit := ROSTER_MAX_NARROW if _is_narrow_screen() else ROSTER_MAX
	var entries: Array = []
	# 나를 항상 맨 앞에.
	entries.append({
		"name": String(_slot.get("name", "")),
		"sprite": _player.sprite if _player != null else null,
		"me": true,
	})
	for token: String in _remotes.keys():
		var r := _remotes[token] as RemotePlayer
		entries.append({"name": r.display_name(), "sprite": r.sprite, "me": false})

	var shown := mini(entries.size(), limit)
	for i in shown:
		var entry_ui := _roster_entry(entries[i] as Dictionary)
		_roster_box.add_child(entry_ui)
		# E2E 테스트가 "몇 명이 표시되는지"를 볼 수 있게 항목 좌표를 공개한다.
		if _hooks != null:
			_hooks.track("rosterEntry%d" % (i + 1), entry_ui)
	if entries.size() > shown:
		var more := Label.new()
		more.text = "+%d" % (entries.size() - shown)
		more.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		more.add_theme_color_override("font_color", Palette.color("ui", "hud_text"))
		more.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_roster_box.add_child(more)

func _roster_entry(entry: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var portrait := TextureRect.new()
	portrait.custom_minimum_size = ROSTER_PORTRAIT
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	# 픽셀 스프라이트라 보간하면 뭉개진다.
	portrait.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sprite: PlayerSprite = entry.get("sprite")
	if sprite != null and is_instance_valid(sprite) and sprite.sprite_frames != null \
			and sprite.sprite_frames.has_animation("idle_down") \
			and sprite.sprite_frames.get_frame_count("idle_down") > 0:
		portrait.texture = sprite.sprite_frames.get_frame_texture("idle_down", 0)
	box.add_child(portrait)

	var label := Label.new()
	var who := String(entry.get("name", ""))
	label.text = who if not who.is_empty() else "(이름 없음)"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color",
		Palette.color("ui", "roster_me") if bool(entry.get("me", false)) else Palette.color("ui", "hud_text"))
	label.add_theme_color_override("font_outline_color", Palette.color("ui", "hud_outline"))
	label.add_theme_constant_override("outline_size", 3)
	box.add_child(label)
	return box

## 채팅 로그는 최근 CHAT_LOG_LINES줄만 화면에 남긴다 — 더 쌓아두면 화면을
## 가리고, 스크롤 가능한 채팅창은 P6(UI 정리)에서 다룬다.
func _append_chat(line: String) -> void:
	_chat_log.append(line)
	var limit := CHAT_LOG_LINES
	if _is_narrow_screen():
		limit = CHAT_LOG_LINES_SHORT
	while _chat_log.size() > limit:
		_chat_log.remove_at(0)
	if _chat_label != null:
		_chat_label.text = "\n".join(_chat_log)

func _show_toast(text: String) -> void:
	_toast.text = text
	_toast_timer = 2.5

func _unhandled_input(event: InputEvent) -> void:
	# 채팅 입력 중이거나 시트가 열려 있으면 게임 조작을 받지 않는다 —
	# 안 그러면 "s"를 치는 순간 물건이 팔리고, 시트 뒤에서 캐릭터가 움직인다.
	if _chat != null and _chat.is_open():
		return
	if _touch != null and _touch.is_sheet_open():
		return

	# 월드 탭/클릭 → 그 지점으로 이동(대상을 탭하면 다가가서 자동 처리).
	# 터치도 기본 설정에서 마우스 이벤트로 에뮬레이트되므로 한 경로로 처리한다.
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_on_world_tapped(mb.position)
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
	_send_emote(String((emote as Dictionary).get("id", "")))

## 키보드 숫자키와 터치 시트가 같은 경로를 쓴다.
func _send_emote(emote_id: String) -> void:
	if emote_id.is_empty():
		return
	# 내 화면에는 즉시 보여주고(반응성) 서버에도 알린다. 서버가 거절하면
	# 남들에게만 안 보이는데, 그 경우는 error 메시지로 화면에 뜬다.
	if _my_extras != null:
		_my_extras.show_emote(_emote_glyph(emote_id))
	if _net != null:
		_net.send_emote(emote_id)

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
	if _chat != null:
		_chat.open()

func _on_chat_submitted(text: String) -> void:
	if _net == null or not _net.connected:
		# 혼자 플레이 중에도 입력이 사라지지 않게 내 화면에는 남긴다.
		_append_chat("(연결 없음) %s: %s" % [String(_slot.get("name", "")), text])
		if _my_extras != null:
			_my_extras.show_chat(text)
		return
	_net.send_chat(text)

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
	_refresh_roster()

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
	# 스프라이트 프레임은 _ready에서 만들어지므로 한 프레임 뒤에 초상화를 읽는다.
	_refresh_roster.call_deferred()

func _on_player_left(token: String) -> void:
	if not _remotes.has(token):
		return
	(_remotes[token] as Node).queue_free()
	_remotes.erase(token)
	_refresh_roster()

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
		_refresh_roster()

func _on_server_error(code: String, message: String) -> void:
	# 서버 거절을 조용히 삼키면 "왜 안 되는지" 알 수 없다 — 화면에 띄운다.
	_show_toast("서버: %s" % message)
	push_warning("서버 오류(%s): %s" % [code, message])

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

## 화면 좌표를 지면(y=0) 위의 월드 좌표로 바꾼다. 직교 카메라라 광선이
## 평행하지만 평면 교차는 동일하게 동작한다(헤드리스로 실측 확인).
func _screen_to_ground(screen_pos: Vector2) -> Variant:
	if _camera == null:
		return null
	var origin := _camera.project_ray_origin(screen_pos)
	var dir := _camera.project_ray_normal(screen_pos)
	return Plane(Vector3.UP, 0.0).intersects_ray(origin, dir)

func _on_world_tapped(screen_pos: Vector2) -> void:
	# 조이스틱 영역의 터치는 이동 지시가 아니다 — 그 영역은 조이스틱이 쓴다.
	if _touch != null and _touch.is_in_stick_area(screen_pos):
		return
	var hit: Variant = _screen_to_ground(screen_pos)
	if hit == null:
		return
	var point: Vector3 = hit

	# 탭한 지점 근처에 대상이 있으면 그 대상을 향한다 — 단순히 좌표로만 가면
	# "나무 옆 정확한 자리에 서기"를 사람이 해야 하고, 그게 폰에서 가장 번거롭다.
	var g := _gatherable_near(point)
	if g != null:
		_tap_intent = {"kind": "gather", "id": ""}
		_tap_gatherable = g
		_player.move_to(_approach_point(g.global_position))
		_show_marker(g.global_position)
		return

	var drop_id := _drop_near(point)
	if not drop_id.is_empty():
		_tap_intent = {"kind": "pickup", "id": drop_id}
		_tap_gatherable = null
		_player.move_to(_approach_point((_drops[drop_id] as Node3D).position))
		_show_marker((_drops[drop_id] as Node3D).position)
		return

	var remote := _remote_near(point)
	if remote != null:
		# 다른 캐릭터는 대화 거리까지만 다가간다(겹쳐 서면 서로 가린다).
		_clear_tap_intent()
		_player.move_to(_approach_point(remote.position))
		_show_marker(remote.position)
		return

	_clear_tap_intent()
	_player.move_to(point)
	_show_marker(point)

## 대상 앞 APPROACH_DISTANCE 지점 — 대상 위로 겹쳐 서지 않게 한다.
func _approach_point(target: Vector3) -> Vector3:
	var from := _player.position
	var to_target := target - from
	to_target.y = 0.0
	if to_target.length() <= APPROACH_DISTANCE:
		return from   # 이미 사거리 안이면 움직이지 않는다
	return target - to_target.normalized() * APPROACH_DISTANCE

func _gatherable_near(point: Vector3) -> Gatherable:
	var best := TAP_PICK_RADIUS
	var found: Gatherable = null
	for g in _gatherables:
		if not g.is_available():
			continue
		var d := Vector2(g.position.x, g.position.z).distance_to(Vector2(point.x, point.z))
		if d <= best:
			best = d
			found = g
	return found

func _drop_near(point: Vector3) -> String:
	var best := TAP_PICK_RADIUS
	var found := ""
	for id: String in _drops.keys():
		var node: Node3D = _drops[id]
		var d := Vector2(node.position.x, node.position.z).distance_to(Vector2(point.x, point.z))
		if d <= best:
			best = d
			found = id
	return found

func _remote_near(point: Vector3) -> RemotePlayer:
	var best := TAP_PICK_RADIUS
	var found: RemotePlayer = null
	for token: String in _remotes.keys():
		var r := _remotes[token] as RemotePlayer
		var d := Vector2(r.position.x, r.position.z).distance_to(Vector2(point.x, point.z))
		if d <= best:
			best = d
			found = r
	return found

## 탭으로 정해둔 "도착하면 할 일"을 지운다. 목표가 취소됐는데 이걸 남겨두면
## 다음에 도착하는 순간 엉뚱하게 실행된다(사용자 보고 버그의 원인).
func _clear_tap_intent() -> void:
	_tap_intent = {"kind": "", "id": ""}
	_tap_gatherable = null

func _show_marker(at: Vector3) -> void:
	if _marker == null:
		return
	_marker.position = Vector3(at.x, 0.0, at.z)
	_marker.visible = true

## 목표에 도착하면 탭할 때 정한 동작을 실행한다. 도중에 대상이 사라졌으면
## (남이 먼저 주웠거나 채집물이 사라졌으면) 조용히 넘긴다 — 도착 자체는 정상이다.
func _on_player_arrived() -> void:
	if _marker != null:
		_marker.visible = false
	var kind := String(_tap_intent.get("kind", ""))
	var id := String(_tap_intent.get("id", ""))
	var target := _tap_gatherable
	_clear_tap_intent()
	match kind:
		"gather":
			# 탭한 그 대상만 캔다. "근처에서 아무거나"로 두면 지나가다 옆 나무를
			# 캐게 된다.
			if target != null and is_instance_valid(target) and target.can_interact(_player.position):
				target.gather()
			elif target != null:
				_show_toast("조금 더 가까이 가야 합니다")
		"pickup":
			if _drops.has(id) and _net != null and _net.connected:
				_net.send_pickup(id)
			elif not _drops.has(id):
				_show_toast("아쉽게도 물건이 사라졌습니다")

## 수동 조작으로 목표를 버렸으면 "도착하면 할 일"도 함께 버린다.
func _on_move_cancelled() -> void:
	_clear_tap_intent()
	if _marker != null:
		_marker.visible = false

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

## E2E 테스트가 "나무를 탭"할 수 있도록 가까운 채집물의 화면 좌표를 공개한다.
## 월드 좌표만 알아도 화면 좌표를 계산할 수 없어(카메라가 따라다닌다) 테스트가
## 대상을 탭할 방법이 없다.
func _publish_test_points() -> void:
	if _hooks == null or _camera == null:
		return
	_hooks.track_dynamic("nearestGatherable", func() -> Vector2:
		var g := _nearest_available_gatherable()
		if g == null:
			return Vector2(-1, -1)
		return _camera.unproject_position(g.global_position + Vector3(0, 0.6, 0))
	)
	_hooks.track_dynamic("nearestDrop", func() -> Vector2:
		var best := INF
		var found: Node3D = null
		for id: String in _drops.keys():
			var node: Node3D = _drops[id]
			var d := _player.position.distance_to(node.position)
			if d < best:
				best = d
				found = node
		if found == null:
			return Vector2(-1, -1)
		return _camera.unproject_position(found.position + Vector3(0, 0.3, 0))
	)
	_hooks.track_dynamic("nearestRemote", func() -> Vector2:
		var best := INF
		var found: RemotePlayer = null
		for token: String in _remotes.keys():
			var r := _remotes[token] as RemotePlayer
			var d := _player.position.distance_to(r.position)
			if d < best:
				best = d
				found = r
		if found == null:
			return Vector2(-1, -1)
		return _camera.unproject_position(found.position + Vector3(0, 0.9, 0))
	)
	_hooks.track_dynamic("beyondNearestRock", func() -> Vector2:
		var rock := _nearest_rock()
		if rock.is_empty():
			return Vector2(-1, -1)
		var center := Vector3(float(rock["x"]), 0.0, float(rock["z"]))
		var away := (center - _player.position)
		away.y = 0.0
		if away.length() < 0.01:
			return Vector2(-1, -1)
		# 바위 중심을 지나 반대편으로 (반지름 + 여유)만큼 더 간 지점.
		var beyond := center + away.normalized() * (float(rock["radius"]) + 1.6)
		return _camera.unproject_position(beyond)
	)
	_hooks.track_dynamic("groundRight", func() -> Vector2:
		return _camera.unproject_position(_player.position + Vector3(3.0, 0, 0))
	)

func _nearest_rock() -> Dictionary:
	var best := INF
	var found := {}
	for o: Variant in _obstacles:
		if typeof(o) != TYPE_DICTIONARY:
			continue
		var obs := o as Dictionary
		var d := _player.position.distance_to(Vector3(float(obs.get("x", 0.0)), 0.0, float(obs.get("z", 0.0))))
		if d < best:
			best = d
			found = obs
	return found

func _nearest_available_gatherable() -> Gatherable:
	var best := INF
	var found: Gatherable = null
	for g in _gatherables:
		if not g.is_available():
			continue
		var d := _player.position.distance_to(g.position)
		if d < best:
			best = d
			found = g
	return found

## 슬롯에 현재 상태(위치·벨·가방)를 반영해 저장한다.
func _persist() -> void:
	_slot["pos"] = {"x": snappedf(_player.position.x, 0.01), "z": snappedf(_player.position.z, 0.01)}
	_slot["last_played_unix"] = int(Time.get_unix_time_from_system())
	SaveManager.put_slot(_save, _slot_index, _slot)
	SaveManager.save(_save)

## 폰을 돌리면(세로↔가로) 뷰포트 비율이 바뀌므로 카메라 size를 다시 계산한다.
func _on_viewport_resized() -> void:
	if _camera != null:
		_camera.size = _camera_size_for_screen()

func _process(delta: float) -> void:
	_update_camera(CAMERA_FOLLOW_SPEED * delta)

	if _player != null and _marker != null and _marker.visible and not _player.has_target():
		# 수동 입력으로 목표가 취소된 경우 — 마커를 남겨두면 유령이 된다.
		_marker.visible = false
	if _player != null:
		# 다른 캐릭터 위치를 넘겨 겹치지 않게 한다. 원격 캐릭터는 서버 좌표를
		# 보간해 움직이므로 그 위치를 그대로 쓴다.
		var others: Array = []
		for token: String in _remotes.keys():
			others.append((_remotes[token] as RemotePlayer).position)
		_player.set_others(others)

		# 터치 조이스틱 입력을 플레이어에 넘긴다(키보드와 병행 — player.gd가
		# 더 큰 쪽을 쓴다). 시트가 열려 있으면 이동을 멈춘다.
		var touch_vec := Vector2.ZERO
		if _touch != null and not _touch.is_sheet_open():
			touch_vec = _touch.move_vector
		_player.set_touch_vector(touch_vec)
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
