extends Node2D
class_name Gatherable

## 채집물 하나(나무/조개/잡초). 데이터(data/gatherables.json)로 배치되고,
## 채집 후 respawn_sec 뒤에 되살아난다.

signal gathered(item_id: String)

var item_id: String = "wood"
var kind: String = "tree"
var respawn_sec: float = 30.0

var _available := true
var _timer := 0.0
var _color := Color.WHITE
var _radius := 18.0

const INTERACT_RADIUS := 44.0

## limits는 data/gatherables.json의 "limits"를 그대로 받는다 — 유효범위를
## 코드에 하드코딩하면 데이터 파일이 단일 출처라는 규칙이 깨진다(2026-09-03
## pre-commit Codex 감사 지적).
func setup(spawn: Dictionary, limits: Dictionary = {}) -> void:
	kind = String(spawn.get("kind", "tree"))
	item_id = String(spawn.get("item", "wood"))
	respawn_sec = Balance.clamp_value(
		float(spawn.get("respawn_sec", 30.0)),
		limits.get("respawn_sec", null),
		"%s.respawn_sec" % item_id,
		"duration_sec"
	)
	position = Vector2(float(spawn.get("x", 0.0)), float(spawn.get("y", 0.0)))
	match kind:
		"tree":
			_color = Color(0.20, 0.55, 0.25)
			_radius = 22.0
		"shell":
			_color = Color(0.95, 0.85, 0.70)
			_radius = 12.0
		_:
			_color = Color(0.45, 0.70, 0.35)
			_radius = 10.0

func is_available() -> bool:
	return _available

func can_interact(from: Vector2) -> bool:
	return _available and from.distance_to(position) <= INTERACT_RADIUS

func gather() -> bool:
	if not _available:
		return false
	_available = false
	_timer = respawn_sec
	queue_redraw()
	gathered.emit(item_id)
	return true

## 하루가 지나면 전부 되살아난다(GameClock.days_since 기반, main.gd에서 호출).
func force_respawn() -> void:
	if not _available:
		_available = true
		_timer = 0.0
		queue_redraw()

func _process(delta: float) -> void:
	if _available:
		return
	_timer -= delta
	if _timer <= 0.0:
		_available = true
		queue_redraw()

func _draw() -> void:
	if _available:
		draw_circle(Vector2.ZERO, _radius, _color)
		if kind == "tree":
			draw_rect(Rect2(-3, 0, 6, 18), Color(0.42, 0.28, 0.18))
	else:
		# 채집된 상태는 그루터기만 남긴다 — 화면에서 사라지면 위치 학습이 안 됨.
		draw_circle(Vector2.ZERO, _radius * 0.4, Color(0.42, 0.28, 0.18, 0.6))
