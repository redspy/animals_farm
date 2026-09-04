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
	position = Vector3(float(data.get("x", 0.0)), 0.0, float(data.get("z", 0.0)))
	if String(data.get("shape", "circle")) == "box":
		_build_wall(
			Vector2(float(data.get("size_x", 1.0)), float(data.get("size_z", 1.0)))
		)
		return
	radius = maxf(float(data.get("radius", 1.2)), 0.3)
	var style := String(data.get("style", "single"))
	if style == "cluster":
		_build_cluster()
	else:
		_build_single()

## 석벽 — 판정 박스와 같은 크기로 세우고, 위에 얇은 갓돌을 올려 벽처럼 보이게 한다.
func _build_wall(size: Vector2) -> void:
	var height := 1.5
	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(size.x, height, size.y)
	body.mesh = box
	body.position = Vector3(0, height * 0.5, 0)
	body.material_override = _material(Palette.color("world", "wall"))
	add_child(body)

	var cap := MeshInstance3D.new()
	var cap_box := BoxMesh.new()
	# 갓돌은 판정 박스보다 조금 넓게 — 판정이 좁아 보이는 쪽이 안전하다.
	cap_box.size = Vector3(size.x + 0.18, 0.16, size.y + 0.18)
	cap.mesh = cap_box
	cap.position = Vector3(0, height + 0.08, 0)
	cap.material_override = _material(Palette.color("world", "wall_dark"))
	add_child(cap)

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

## 조형물 공통 재질. 웹(GL Compatibility)에서 가볍게 유지 — 스페큘러를 끄고
## 확산광만 쓴다.
##
## (이끼를 없애면서 파일 끝을 자를 때 이 함수까지 함께 잘려 나가 석벽 추가 시
## 컴파일이 깨졌다 — 2026-09-04. 함수를 지울 때는 호출부를 함께 확인할 것.)
func _material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.roughness = 1.0
	return m
