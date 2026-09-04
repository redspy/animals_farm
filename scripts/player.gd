extends Node3D
class_name Player

## 목표 지점에 도착했을 때. world.gd가 이때 자동 채집/줍기를 실행한다.
signal arrived

## 플레이어. 이동은 3D(XZ 평면)에서 하고, 보이는 몸은 2D 빌보드 스프라이트
## (PlayerSprite)다 — 이 조합이 2.5D 룩의 핵심이다(docs/design.md §2).
## 걷기 애니메이션 자체는 PlayerSprite가 담당하고, 여기서는 이동 방향만 넘긴다.

const SPEED := 4.2
## 캐릭터 반경 — 섬 경계에서 이만큼 안쪽까지만 이동한다.
const RADIUS := 0.35
## 목표에 이만큼 가까워지면 도착으로 본다(월드 단위). 너무 작으면 부동소수
## 오차로 목표 주변을 진동한다.
const ARRIVE_EPSILON := 0.14

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

## 탭/클릭으로 지정된 경로. 바위를 돌아가느라 경유지가 여러 개일 수 있다
## (scripts/path_planner.gd). 화면 좌표로 들고 있으면 카메라가 플레이어를
## 따라가면서 목표가 밀리므로 월드 좌표로 보관한다.
var _path: Array[Vector3] = []
## 통과할 수 없는 바위들(data/world.json의 obstacles). 수동 이동에서도 막힌다.
var _obstacles: Array = []

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

## 탭한 지점으로 걸어간다. 바위가 막으면 짧은 쪽으로 돌아가는 경유지가 생긴다.
## 마지막 경유지에 도착하면 arrived 시그널.
func move_to(target: Vector3) -> void:
	var clamped := Vector3(
		clampf(target.x, -_half_x, _half_x),
		0.0,
		clampf(target.z, -_half_z, _half_z)
	)
	_path = PathPlanner.plan(position, clamped, _obstacles, RADIUS)

func cancel_move_to() -> void:
	_path.clear()

func has_target() -> bool:
	return not _path.is_empty()

func target_position() -> Vector3:
	return _path[_path.size() - 1] if not _path.is_empty() else position

func _physics_process(delta: float) -> void:
	# 화면 기준 입력 → 월드 XZ. 카메라 yaw가 0이라 화면 위쪽이 -Z와 같다
	# (카메라를 회전시키면 이 매핑도 함께 고쳐야 한다 — main.gd CAMERA_YAW_DEG).
	var keys := Vector2(
		Input.get_axis("ui_left", "ui_right"),
		Input.get_axis("ui_up", "ui_down")
	)
	var dir := keys if keys.length() >= _touch_vector.length() else _touch_vector

	# 수동 입력이 들어오면 탭 경로를 버린다 — 손으로 조작하는 중에 캐릭터가
	# 예전 목표로 끌려가면 조작을 빼앗긴 느낌이 된다.
	if dir != Vector2.ZERO:
		_path.clear()
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
		var step := dir.normalized() * SPEED * delta * clampf(dir.length(), 0.0, 1.0)
		position.x = clampf(position.x + step.x, -_half_x, _half_x)
		position.z = clampf(position.z + step.y, -_half_z, _half_z)
		# 바위를 통과하지 못하게 표면 밖으로 되돌린다. 이동을 막는 대신 밀어내면
		# 바위에 붙어 미끄러지듯 지나가서 조작이 답답하지 않다.
		position = PathPlanner.push_out(position, _obstacles, RADIUS)
	if sprite != null:
		sprite.set_move_dir(dir)
