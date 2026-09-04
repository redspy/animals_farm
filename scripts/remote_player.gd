extends Node3D
class_name RemotePlayer

## 다른 기기에서 접속한 캐릭터. 서버가 10Hz로 보내는 위치를 목표점으로 삼고
## 그 사이를 보간해 움직인다 — 받은 좌표로 즉시 튀게 놓으면 뚝뚝 끊겨 보인다.
##
## 보간만 하고 예측(extrapolation)은 하지 않는다: 예측은 방향이 바뀔 때 캐릭터가
## 벽을 통과하거나 되돌아가는 그림을 만들고, 이 게임은 그 정도 지연이 문제되지
## 않는다(docs/protocol.md §0의 신뢰/정확도 선택과 같은 이유).

## 목표 위치까지 따라붙는 속도(초당 보간 비율).
const LERP_SPEED := 12.0
## 이보다 가까우면 걷기 애니메이션을 멈춘다(월드 단위).
const IDLE_EPSILON := 0.04

var token: String = ""
var sprite: PlayerSprite
var extras: AvatarExtras

var _target := Vector3.ZERO
var _dir_name: String = "down"

func setup(player: Dictionary, preset: Dictionary) -> void:
	token = String(player.get("token", ""))
	_target = Vector3(float(player.get("x", 0.0)), 0.0, float(player.get("z", 0.0)))
	position = _target
	_dir_name = String(player.get("dir", "down"))

	sprite = PlayerSprite.new()
	if not preset.is_empty():
		sprite.setup(preset)
	add_child(sprite)

	extras = AvatarExtras.new()
	add_child(extras)
	# AvatarExtras가 _ready 전 호출도 받아 두므로 순서를 신경 쓰지 않아도 된다.
	extras.set_name_text(String(player.get("name", "")))

func set_display_name(text: String) -> void:
	if extras != null:
		extras.set_name_text(text)

func apply_move(x: float, z: float, dir: String) -> void:
	_target = Vector3(x, 0.0, z)
	if dir in ["up", "down", "left", "right"]:
		_dir_name = dir

func _process(delta: float) -> void:
	var before := position
	position = position.lerp(_target, clampf(LERP_SPEED * delta, 0.0, 1.0))
	if sprite == null:
		return
	# 서버가 준 방향을 스프라이트에 그대로 반영하려면 방향 벡터로 바꿔야 한다.
	var moving := position.distance_to(before) > IDLE_EPSILON * delta * 60.0
	if moving:
		sprite.set_move_dir(_dir_to_vector(_dir_name))
	else:
		sprite.set_move_dir(Vector2.ZERO)

func _dir_to_vector(dir: String) -> Vector2:
	match dir:
		"up": return Vector2(0, -1)
		"left": return Vector2(-1, 0)
		"right": return Vector2(1, 0)
		_: return Vector2(0, 1)
