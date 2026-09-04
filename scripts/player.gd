extends Node3D
class_name Player

## 플레이어. 이동은 3D(XZ 평면)에서 하고, 보이는 몸은 2D 빌보드 스프라이트
## (PlayerSprite)다 — 이 조합이 2.5D 룩의 핵심이다(docs/design.md §2).
## 걷기 애니메이션 자체는 PlayerSprite가 담당하고, 여기서는 이동 방향만 넘긴다.

const SPEED := 4.2
## 캐릭터 반경 — 섬 경계에서 이만큼 안쪽까지만 이동한다.
const RADIUS := 0.35

## 발밑 그림자 크기(월드 단위) — 빌보드 스프라이트는 실제 그림자를 드리우기가
## 부자연스러워서, 2.5D에서 흔히 쓰는 방식대로 바닥에 타원 데칼을 깐다.
## 이게 없으면 캐릭터가 지면에 붙어 있지 않고 떠 보인다(2026-09-04 실측).
const SHADOW_RADIUS := 0.34

var sprite: PlayerSprite = null

var _half_x := 10.0
var _half_z := 6.0

func setup(island_size: Vector2) -> void:
	_half_x = maxf(island_size.x * 0.5 - RADIUS, RADIUS)
	_half_z = maxf(island_size.y * 0.5 - RADIUS, RADIUS)

func _ready() -> void:
	_add_ground_shadow()
	sprite = PlayerSprite.new()
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
	m.albedo_color = Color(0, 0, 0, 0.28)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shadow.material_override = m
	shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(shadow)

func _physics_process(delta: float) -> void:
	# 화면 기준 입력 → 월드 XZ. 카메라 yaw가 0이라 화면 위쪽이 -Z와 같다
	# (카메라를 회전시키면 이 매핑도 함께 고쳐야 한다 — main.gd CAMERA_YAW_DEG).
	var dir := Vector2(
		Input.get_axis("ui_left", "ui_right"),
		Input.get_axis("ui_up", "ui_down")
	)
	if dir != Vector2.ZERO:
		var step := dir.normalized() * SPEED * delta
		position.x = clampf(position.x + step.x, -_half_x, _half_x)
		position.z = clampf(position.z + step.y, -_half_z, _half_z)
	if sprite != null:
		sprite.set_move_dir(dir)
