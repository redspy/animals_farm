extends Node2D
class_name Player

## 플레이어 이동. 웹에서 입력 지연 체감을 줄이려고 물리 프레임에서 즉시
## 반영하고, 가감속 없이 단순 등속으로 움직인다(프로토타입 기준).

const SPEED := 190.0
const RADIUS := 12.0

var _bounds := Rect2(Vector2.ZERO, Vector2(960, 540))

func set_bounds(r: Rect2) -> void:
	_bounds = r

func _physics_process(delta: float) -> void:
	var dir := Vector2(
		Input.get_axis("ui_left", "ui_right"),
		Input.get_axis("ui_up", "ui_down")
	)
	if dir != Vector2.ZERO:
		position += dir.normalized() * SPEED * delta
		position.x = clampf(position.x, _bounds.position.x + RADIUS, _bounds.end.x - RADIUS)
		position.y = clampf(position.y, _bounds.position.y + RADIUS, _bounds.end.y - RADIUS)

func _draw() -> void:
	draw_circle(Vector2.ZERO, RADIUS, Color(0.98, 0.80, 0.45))
	draw_circle(Vector2(0, -4), RADIUS * 0.55, Color(0.30, 0.22, 0.16))
