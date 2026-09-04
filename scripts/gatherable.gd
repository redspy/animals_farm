extends Node3D
class_name Gatherable

## 채집물 하나(나무/조개/잡초). 3D 프리미티브 메시로 만든 실제 3D 오브젝트다 —
## 캐릭터만 2D 빌보드 스프라이트이고 월드는 3D인 2.5D 구성(docs/design.md §2).
## 배치와 재생 시간은 data/gatherables.json이 단일 출처다.

signal gathered(item_id: String)

## 채집 가능 거리(월드 단위). 캐릭터 폭이 약 0.8이므로 한 걸음 거리쯤이다.
const INTERACT_DISTANCE := 1.6

var item_id: String = "wood"
var kind: String = "tree"
var respawn_sec: float = 30.0

var _available := true
var _timer := 0.0
var _grown: Node3D = null    # 채집 가능할 때 보이는 부분(나무 몸통은 항상 보임)

## limits는 data/gatherables.json의 "limits"를 그대로 받는다 — 유효범위를
## 코드에 하드코딩하면 데이터 파일이 단일 출처라는 규칙이 깨진다.
func setup(spawn: Dictionary, limits: Dictionary = {}) -> void:
	kind = String(spawn.get("kind", "tree"))
	item_id = String(spawn.get("item", "wood"))
	respawn_sec = Balance.clamp_value(
		float(spawn.get("respawn_sec", 30.0)),
		limits.get("respawn_sec", null),
		"%s.respawn_sec" % item_id,
		"duration_sec"
	)
	position = Vector3(float(spawn.get("x", 0.0)), 0.0, float(spawn.get("z", 0.0)))
	_build_mesh()

func _build_mesh() -> void:
	match kind:
		"tree":
			# 몸통은 채집해도 남는다 — 위치를 기억할 수 있게 해야 다시 찾아온다.
			var trunk := MeshInstance3D.new()
			var trunk_mesh := CylinderMesh.new()
			trunk_mesh.top_radius = 0.14
			trunk_mesh.bottom_radius = 0.2
			trunk_mesh.height = 1.1
			trunk_mesh.radial_segments = 8
			trunk.mesh = trunk_mesh
			trunk.position = Vector3(0, 0.55, 0)
			trunk.material_override = _material(Color(0.42, 0.28, 0.18))
			add_child(trunk)

			_grown = Node3D.new()
			add_child(_grown)
			var canopy := MeshInstance3D.new()
			var canopy_mesh := SphereMesh.new()
			canopy_mesh.radius = 0.95
			canopy_mesh.height = 1.7
			canopy_mesh.radial_segments = 12
			canopy_mesh.rings = 6
			canopy.mesh = canopy_mesh
			canopy.position = Vector3(0, 1.7, 0)
			canopy.material_override = _material(Color(0.18, 0.52, 0.24))
			_grown.add_child(canopy)
		"shell":
			_grown = Node3D.new()
			add_child(_grown)
			var shell := MeshInstance3D.new()
			var shell_mesh := SphereMesh.new()
			shell_mesh.radius = 0.22
			shell_mesh.height = 0.26
			shell_mesh.radial_segments = 10
			shell_mesh.rings = 4
			shell.mesh = shell_mesh
			shell.position = Vector3(0, 0.1, 0)
			shell.material_override = _material(Color(0.96, 0.87, 0.74))
			_grown.add_child(shell)
		_:
			_grown = Node3D.new()
			add_child(_grown)
			# 잡초는 얇은 판 3장을 엇갈려 세워 풀 느낌만 낸다(그레이박스).
			for i in 3:
				var blade := MeshInstance3D.new()
				var blade_mesh := BoxMesh.new()
				blade_mesh.size = Vector3(0.06, 0.42, 0.06)
				blade.mesh = blade_mesh
				blade.position = Vector3(-0.12 + 0.12 * i, 0.21, 0.05 * i)
				blade.rotation_degrees = Vector3(0, 0, -12 + 12 * i)
				blade.material_override = _material(Color(0.36, 0.66, 0.30))
				_grown.add_child(blade)

func _material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	# 웹(GL Compatibility)에서 가볍게 유지 — 스페큘러를 끄고 확산광만 쓴다.
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.roughness = 1.0
	return m

func is_available() -> bool:
	return _available

func can_interact(from: Vector3) -> bool:
	if not _available:
		return false
	# 높이 차이는 무시하고 바닥 평면(XZ)에서만 거리를 잰다.
	var a := Vector2(from.x, from.z)
	var b := Vector2(global_position.x, global_position.z)
	return a.distance_to(b) <= INTERACT_DISTANCE

func gather() -> bool:
	if not _available:
		return false
	_available = false
	_timer = respawn_sec
	if _grown != null:
		_grown.visible = false
	gathered.emit(item_id)
	return true

## 하루가 지나면 전부 되살아난다(GameClock.days_since 기반, main.gd에서 호출).
func force_respawn() -> void:
	if _available:
		return
	_available = true
	_timer = 0.0
	if _grown != null:
		_grown.visible = true

func _process(delta: float) -> void:
	if _available:
		return
	_timer -= delta
	if _timer <= 0.0:
		force_respawn()
