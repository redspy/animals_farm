extends Node3D
class_name Player

## 목표 지점에 도착했을 때. world.gd가 이때 자동 채집/줍기를 실행한다.
signal arrived
## 수동 입력(방향키·조이스틱)으로 목표가 취소됐을 때. 이걸 알리지 않으면
## "무엇을 하려고 갔는지"(자동 채집 등)가 남아 있다가 **엉뚱한 시점에 실행**된다
## — 실제로 탭 이동이 끝날 때마다 근처 나무가 채집되는 버그가 났다
## (2026-09-04 사용자 보고).
signal move_cancelled

## 플레이어. 이동은 3D(XZ 평면)에서 하고, 보이는 몸은 2D 빌보드 스프라이트
## (PlayerSprite)다 — 이 조합이 2.5D 룩의 핵심이다(docs/design.md §2).
## 걷기 애니메이션 자체는 PlayerSprite가 담당하고, 여기서는 이동 방향만 넘긴다.

const SPEED := 4.2
## 운동 중 이동 속도. data/activities.json이 단일 출처이고 world.gd가 넣어 준다
## (서버도 같은 파일로 상한을 정한다 — 여기만 빠르면 서버가 계속 되돌린다).
var speed := SPEED
## 캐릭터 반경 — 섬 경계에서 이만큼 안쪽까지만 이동한다.
const RADIUS := 0.35
## 목표에 이만큼 가까워지면 도착으로 본다(월드 단위). 너무 작으면 부동소수
## 오차로 목표 주변을 진동한다.
const ARRIVE_EPSILON := 0.14
## 캐릭터 두 명이 이보다 가까워지지 않는다(월드 단위). 스프라이트 폭보다 좁게
## 잡아 서로 대화할 만큼은 붙을 수 있게 한다.
const SEPARATION := 0.8
## 겹침을 푸는 속도(초당). 순간이동으로 풀면 상대가 튀어 보인다.
const SEPARATION_SPEED := 2.5

## 발밑 그림자 크기(월드 단위) — 빌보드 스프라이트는 실제 그림자를 드리우기가
## 부자연스러워서, 2.5D에서 흔히 쓰는 방식대로 바닥에 타원 데칼을 깐다.
## 이게 없으면 캐릭터가 지면에 붙어 있지 않고 떠 보인다(2026-09-04 실측).
const SHADOW_RADIUS := 0.34

var sprite: PlayerSprite = null

var _half_x := 10.0
var _half_z := 6.0
var _preset: Dictionary = {}
## 터치 조이스틱 입력(world.gd가 매 프레임 넣어 준다). 키보드와 합산하지 않고
## **더 큰 쪽**을 쓴다 — 합산하면 둘을 같이 쓸 때 속도가 두 배가 된다.
var _touch_vector := Vector2.ZERO
## 이번 프레임에 실제로 움직였는지. world.gd가 "멈춘 순간"을 잡아 최종 좌표를
## 확정 전송하는 데 쓴다(미세 이동이 상대 화면에 반영되지 않는 문제).
var _moved_this_frame := false
## 조이스틱을 쓸지. 폰에서 사용자가 끌 수 있다(TouchControls 토글).
var joystick_enabled := true

## 탭/클릭으로 지정된 경로. 바위를 돌아가느라 경유지가 여러 개일 수 있다
## (scripts/path_planner.gd). 화면 좌표로 들고 있으면 카메라가 플레이어를
## 따라가면서 목표가 밀리므로 월드 좌표로 보관한다.
var _path: Array[Vector3] = []
## 통과할 수 없는 바위들(data/world.json의 obstacles). 수동 이동에서도 막힌다.
var _obstacles: Array = []
## 다른 캐릭터들의 위치(world.gd가 매 프레임 갱신). 겹치지 않게 밀어내는 데 쓴다.
var _others: Array = []

## world_size는 data/world.json의 size_x/size_z, preset은 data/characters.json의
## 프리셋 한 항목이다(외형만 결정하며 능력 차이는 없다).
func setup(world_size: Vector2, preset: Dictionary = {}, obstacles: Array = []) -> void:
	_half_x = maxf(world_size.x * 0.5 - RADIUS, RADIUS)
	_half_z = maxf(world_size.y * 0.5 - RADIUS, RADIUS)
	_preset = preset
	_obstacles = obstacles

func _ready() -> void:
	_add_ground_shadow()
	sprite = PlayerSprite.new()
	if not _preset.is_empty():
		# 프레임 생성이 _ready에서 일어나므로 트리에 붙기 전에 프리셋을 준다.
		sprite.setup(_preset)
	# PlayerSprite가 offset으로 원점을 발바닥에 맞춰 두므로 지면 높이(y=0)에
	# 그대로 놓는다 — 예전엔 중앙 기준이라 y를 눈대중으로 띄웠고 발이 떠 보였다.
	sprite.position = Vector3.ZERO
	add_child(sprite)

func _add_ground_shadow() -> void:
	var shadow := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = SHADOW_RADIUS
	mesh.height = SHADOW_RADIUS * 0.3
	mesh.radial_segments = 12
	mesh.rings = 3
	shadow.mesh = mesh
	shadow.position = Vector3(0, 0.03, 0)
	var m := StandardMaterial3D.new()
	m.albedo_color = Palette.color("world", "ground_shadow")
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shadow.material_override = m
	shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(shadow)

func set_touch_vector(v: Vector2) -> void:
	_touch_vector = v

## 다른 캐릭터 위치 목록(원격 캐릭터). 매 프레임 갱신된다.
func set_others(others: Array) -> void:
	_others = others

## 탭한 지점으로 걸어간다. 바위가 막으면 짧은 쪽으로 돌아가는 경유지가 생긴다.
## 마지막 경유지에 도착하면 arrived 시그널.
## 정해진 점들을 그대로 따라간다(놀이기구처럼 경로가 미리 정해진 이동).
## move_to와 달리 우회 계산을 하지 않는다 — 기구가 정한 길이 곧 정답이다.
func follow_path(points: Array) -> void:
	_path.clear()
	for p: Variant in points:
		if p is Vector3:
			_path.append(p as Vector3)

## 타고 있는 동안 직접 조작을 받지 않는다(기구가 위치를 정한다).
var input_locked := false

func move_to(target: Vector3) -> void:
	var clamped := Vector3(
		clampf(target.x, -_half_x, _half_x),
		0.0,
		clampf(target.z, -_half_z, _half_z)
	)
	# PathPlanner.plan은 **빈 배열을 반환하지 않는다**(우회를 못 찾아도 목표를
	# 그대로 붙인다) — 여기서 폴백을 둘 필요가 없다. 벽 모서리에 끼여 못 움직이는
	# 것은 push_out이 표면을 따라 잡아 주는 정상 동작이다.
	_path = PathPlanner.plan(position, clamped, _obstacles, RADIUS)

func cancel_move_to() -> void:
	_path.clear()

func has_target() -> bool:
	return not _path.is_empty()

func target_position() -> Vector3:
	return _path[_path.size() - 1] if not _path.is_empty() else position

## 이번 물리 프레임에 위치가 바뀌었는지.
func moved_recently() -> bool:
	return _moved_this_frame

func _physics_process(delta: float) -> void:
	var before := position
	# 화면 기준 입력 → 월드 XZ. 카메라 yaw가 0이라 화면 위쪽이 -Z와 같다
	# (카메라를 회전시키면 이 매핑도 함께 고쳐야 한다 — main.gd CAMERA_YAW_DEG).
	var keys := Vector2(
		Input.get_axis("ui_left", "ui_right"),
		Input.get_axis("ui_up", "ui_down")
	)
	var touch := _touch_vector if joystick_enabled else Vector2.ZERO
	var dir := keys if keys.length() >= touch.length() else touch
	# 놀이기구를 타는 동안에는 방향 입력을 무시한다 — 경로(미끄럼틀)나 좌석
	# 고정(그네·시소·뺑뺑이)이 위치를 정한다. 서버도 같은 규칙을 강제한다.
	if input_locked:
		dir = Vector2.ZERO

	# 수동 입력이 들어오면 탭 경로를 버린다 — 손으로 조작하는 중에 캐릭터가
	# 예전 목표로 끌려가면 조작을 빼앗긴 느낌이 된다.
	if dir != Vector2.ZERO:
		if not _path.is_empty():
			_path.clear()
			move_cancelled.emit()
	elif not _path.is_empty():
		var to_target := _path[0] - position
		to_target.y = 0.0
		if to_target.length() <= ARRIVE_EPSILON:
			_path.remove_at(0)
			if _path.is_empty():
				arrived.emit()
		else:
			dir = Vector2(to_target.x, to_target.z).normalized()

	if dir != Vector2.ZERO:
		# 조이스틱은 기울기(0~1)를 주므로 살살 밀면 천천히 걷는다. 키보드는
		# 항상 1이라 기존 속도와 같다.
		var step := dir.normalized() * speed * delta * clampf(dir.length(), 0.0, 1.0)
		position.x = clampf(position.x + step.x, -_half_x, _half_x)
		position.z = clampf(position.z + step.y, -_half_z, _half_z)
		# 바위를 통과하지 못하게 표면 밖으로 되돌린다. 이동을 막는 대신 밀어내면
		# 바위에 붙어 미끄러지듯 지나가서 조작이 답답하지 않다.
		position = PathPlanner.push_out(position, _obstacles, RADIUS)

	# 캐릭터 겹침은 **가만히 있을 때도** 푼다 — 모두 같은 지점에서 시작하고,
	# 남이 걸어와 겹치는 경우도 있다. 바위 밀림보다 먼저 풀고 나서 다시 바위
	# 밖으로 되돌린다(겹침을 피하다 바위 안으로 들어가는 것 방지).
	_moved_this_frame = not position.is_equal_approx(before)

	var separated := PathPlanner.separate(position, _others, SEPARATION, SEPARATION_SPEED * delta)
	if separated != position:
		position = PathPlanner.push_out(separated, _obstacles, RADIUS)
		position.x = clampf(position.x, -_half_x, _half_x)
		position.z = clampf(position.z, -_half_z, _half_z)
	if sprite != null:
		sprite.set_move_dir(dir)
