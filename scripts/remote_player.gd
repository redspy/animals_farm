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
	# 운동 중인 캐릭터가 이미 있을 수 있다(내가 나중에 들어온 경우) — 스냅샷/
	# join에 실려 오는 activity를 그대로 반영한다.
	set_activity(String(player.get("activity", "")), String(player.get("trick", "")))
	# AvatarExtras가 _ready 전 호출도 받아 두므로 순서를 신경 쓰지 않아도 된다.
	set_display_name(String(player.get("name", "")))

var _display_name := ""

func set_display_name(text: String) -> void:
	_display_name = text
	if extras != null:
		extras.set_name_text(text)

## 하단 접속자 바가 이름을 읽는다 — 이름표(AvatarExtras)에서 역으로 꺼내면
## 표시 문자열에 의존하게 되므로 값을 따로 들고 있는다.
func display_name() -> String:
	return _display_name

## 남의 운동 모습. 서버가 브로드캐스트한 값을 그대로 스프라이트에 넘긴다.
func set_activity(kind: String, trick: String) -> void:
	_activity = kind
	_trick = trick
	if sprite != null:
		sprite.set_activity(kind, trick)

func activity() -> String:
	return _activity

## 놀이기구 자리·진폭이 담긴다("자리:진폭"). 보이는 위치 계산에 쓴다.
func trick() -> String:
	return _trick

var _trick := ""

var _activity := ""

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
