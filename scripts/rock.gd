extends Node3D
class_name Rock

## 바위 조형물. 통과할 수 없는 장애물이며, 충돌·우회 계산에서는 **원 하나**로만
## 다룬다(data/world.json의 radius) — 보이는 모양은 여러 덩어리여도 판정은 원이다.
## 보이는 모양과 판정이 다르면 "분명히 비켜 갔는데 걸린다"는 느낌이 생기므로,
## 메시는 radius 안에 들어오도록 만든다.

## 덩어리 하나의 면 수 — 낮게 잡아 각이 지게(바위처럼) 보이게 한다.
const FACETS := 7
const RINGS := 4

var radius := 1.2

func setup(data: Dictionary) -> void:
	radius = maxf(float(data.get("radius", 1.2)), 0.3)
	position = Vector3(float(data.get("x", 0.0)), 0.0, float(data.get("z", 0.0)))
	var style := String(data.get("style", "single"))
	if style == "cluster":
		_build_cluster()
	else:
		_build_single()

func _build_single() -> void:
	# 판정 원(radius)보다 살짝 작게 — 눈에 보이는 것보다 판정이 넓어야
	# "스쳤는데 안 걸렸다"는 느낌 대신 "닿으면 걸린다"가 된다.
	_add_stone(Vector3.ZERO, radius * 0.86, Palette.color("world", "rock"), 0.0)

func _build_cluster() -> void:
	# 큰 덩어리 하나 + 작은 덩어리 둘. 모두 판정 원 안에 들어오게 배치한다.
	_add_stone(Vector3.ZERO, radius * 0.7, Palette.color("world", "rock"), 0.0)
	_add_stone(Vector3(radius * 0.42, 0.0, radius * 0.2), radius * 0.42,
		Palette.color("world", "rock_dark"), 18.0)
	_add_stone(Vector3(-radius * 0.36, 0.0, -radius * 0.3), radius * 0.34,
		Palette.color("world", "rock_dark"), -24.0)

func _add_stone(offset: Vector3, size: float, color: Color, tilt_deg: float) -> void:
	var mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = size
	# 위아래로 눌러 바위처럼 앉은 모양을 만든다.
	sphere.height = size * 1.5
	sphere.radial_segments = FACETS
	sphere.rings = RINGS
	mesh.mesh = sphere
	mesh.position = offset + Vector3(0, size * 0.55, 0)
	mesh.rotation_degrees = Vector3(0, tilt_deg, tilt_deg * 0.25)
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.roughness = 1.0
	mesh.material_override = m
	add_child(mesh)
