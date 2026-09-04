class_name PlayerSprite
extends AnimatedSprite3D

# --- 상수 ---
const SPRITE_WIDTH: int = 32
const SPRITE_HEIGHT: int = 40
const PIXEL_SIZE_CONST: float = 0.05
const WALK_FPS: float = 10.0
const BOB_OFFSET: int = 2

# 캐릭터 색상
const COLOR_SKIN: Color = Color(1.0, 0.85, 0.7)
const COLOR_SKIN_DARK: Color = Color(0.8, 0.65, 0.5)
const COLOR_SHIRT: Color = Color(0.2, 0.6, 0.8)
const COLOR_PANTS: Color = Color(0.1, 0.2, 0.4)
const COLOR_PANTS_DARK: Color = Color(0.05, 0.1, 0.2)
const COLOR_SHOE: Color = Color(0.15, 0.1, 0.05)
const COLOR_SHOE_DARK: Color = Color(0.05, 0.0, 0.0)
const COLOR_EYE: Color = Color(0.0, 0.0, 0.0)

# 캐릭터 크기 및 위치 기준점
const HEAD_CENTER_X: int = 16
const HEAD_CENTER_Y: int = 11
const HEAD_RADIUS: int = 9

const BODY_X: int = 10
const BODY_RIGHT_X: int = 12
const BODY_Y: int = 19
const BODY_W: int = 12
const BODY_RIGHT_W: int = 8
const BODY_H: int = 11

const ARM_FRONT_Y: int = 20
const LEG_BASE_Y: int = 29

# --- 상태 ---
var _current_facing: String = "down"

func _ready() -> void:
	# 3D 환경에서 2.5D 빌보드 스프라이트로 설정
	# 카메라 피치에 영향받지 않고 Y축 회전만 카메라를 향하도록 변경 (캐릭터가 뒤로 눕는 현상 방지)
	billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	pixel_size = PIXEL_SIZE_CONST
	
	# 노드 원점이 캐릭터 발바닥이 되도록 스프라이트를 위로 반만큼 올림 (픽셀 단위)
	offset = Vector2(0, SPRITE_HEIGHT / 2.0)
	
	# 빌보드가 방향광 그림자를 드리우면 공중에 뜬 얼룩처럼 보이므로 그림자 끄기
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	
	# 코드로 생성된 프레임 할당
	sprite_frames = _generate_sprite_frames()
	play("idle_down")

# --- 공개 API ---
func set_move_dir(dir: Vector2) -> void:
	if dir == Vector2.ZERO:
		var anim: String = "idle_" + _current_facing
		if animation != anim:
			play(anim)
	else:
		var target_facing: String = _current_facing
		if absf(dir.x) > absf(dir.y):
			target_facing = "right" if dir.x > 0 else "left"
		else:
			target_facing = "down" if dir.y > 0 else "up"
			
		_current_facing = target_facing
		var anim: String = "walk_" + target_facing
		
		# 재생 중인 애니메이션과 다르거나 재생이 멈췄을 때만 갱신 (프레임 튀는 현상 방지)
		if animation != anim or not is_playing():
			play(anim)

func facing() -> String:
	return _current_facing

# --- 내부 로직 ---
func _generate_sprite_frames() -> SpriteFrames:
	var frames: SpriteFrames = SpriteFrames.new()
	
	var anims: Array[String] = [
		"idle_down", "idle_up", "idle_left", "idle_right",
		"walk_down", "walk_up", "walk_left", "walk_right"
	]
	
	for anim: String in anims:
		frames.add_animation(anim)
		frames.set_animation_loop(anim, anim.begins_with("walk_"))
		frames.set_animation_speed(anim, WALK_FPS)
		
	# down
	var down_frames: Array[Texture2D] = []
	for i in range(6):
		down_frames.append(_create_frame(Vector2i(0, 1), i, false))
	frames.add_frame("idle_down", down_frames[0])
	for i in range(6):
		frames.add_frame("walk_down", down_frames[i])
		
	# up
	var up_frames: Array[Texture2D] = []
	for i in range(6):
		up_frames.append(_create_frame(Vector2i(0, -1), i, false))
	frames.add_frame("idle_up", up_frames[0])
	for i in range(6):
		frames.add_frame("walk_up", up_frames[i])
		
	# right
	var right_frames: Array[Texture2D] = []
	for i in range(6):
		right_frames.append(_create_frame(Vector2i(1, 0), i, false))
	frames.add_frame("idle_right", right_frames[0])
	for i in range(6):
		frames.add_frame("walk_right", right_frames[i])
		
	# left (오른쪽 프레임을 좌우 반전하여 사용)
	var left_frames: Array[Texture2D] = []
	for i in range(6):
		left_frames.append(_create_frame(Vector2i(1, 0), i, true))
	frames.add_frame("idle_left", left_frames[0])
	for i in range(6):
		frames.add_frame("walk_left", left_frames[i])
		
	return frames

# 프레임 이미지 생성 함수 (메모리 절약을 위해 _ready 에서만 호출됨)
func _create_frame(dir: Vector2i, walk_phase: int, flip: bool) -> Texture2D:
	var img: Image = Image.create_empty(SPRITE_WIDTH, SPRITE_HEIGHT, false, Image.FORMAT_RGBA8)
	if img == null:
		push_error("이미지 생성 실패")
		return ImageTexture.new()
		
	var bob: int = 0
	var leg_l_y_lift: int = 0
	var leg_r_y_lift: int = 0
	var leg_l_spread: int = 0
	var leg_r_spread: int = 0
	var arm_l_spread: int = 0
	var arm_r_spread: int = 0

	match walk_phase:
		0:
			bob = BOB_OFFSET
		1:
			leg_l_y_lift = -3
			leg_l_spread = 3
			leg_r_spread = -2
			arm_l_spread = -3
			arm_r_spread = 3
		2:
			leg_l_y_lift = -4
			leg_l_spread = 4
			leg_r_spread = -3
			arm_l_spread = -4
			arm_r_spread = 4
		3:
			bob = BOB_OFFSET
		4:
			leg_r_y_lift = -3
			leg_l_spread = -2
			leg_r_spread = 3
			arm_l_spread = 3
			arm_r_spread = -3
		5:
			leg_r_y_lift = -4
			leg_l_spread = -3
			leg_r_spread = 4
			arm_l_spread = 4
			arm_r_spread = -4

	var leg_base_y: int = LEG_BASE_Y
	var arm_base_y: int = ARM_FRONT_Y + bob
	
	if dir.x == 1: # Right view
		var back_leg_x: int = 13 + leg_l_spread
		var front_leg_x: int = 13 + leg_r_spread
		var back_arm_x: int = 14 + arm_l_spread
		var front_arm_x: int = 14 + arm_r_spread
		var leg_l_y: int = leg_base_y + leg_l_y_lift
		var leg_r_y: int = leg_base_y + leg_r_y_lift
		
		# 뒤쪽 팔 (Left)
		_draw_rect(img, Rect2i(back_arm_x, arm_base_y, 4, 7), COLOR_SKIN_DARK)
		# 뒤쪽 다리 (Left)
		_draw_rect(img, Rect2i(back_leg_x, leg_l_y, 4, 7), COLOR_PANTS_DARK)
		_draw_rect(img, Rect2i(back_leg_x, leg_l_y + 7, 5, 3), COLOR_SHOE_DARK)
		
		# 몸통
		_draw_rect(img, Rect2i(BODY_RIGHT_X, BODY_Y + bob, BODY_RIGHT_W, BODY_H), COLOR_SHIRT)
		
		# 머리 (크고 둥글게)
		_draw_circle(img, Vector2i(HEAD_CENTER_X, HEAD_CENTER_Y + bob), HEAD_RADIUS, COLOR_SKIN)
		_draw_rect(img, Rect2i(19, HEAD_CENTER_Y - 1 + bob, 2, 3), COLOR_EYE) # 눈
		
		# 앞쪽 다리 (Right)
		_draw_rect(img, Rect2i(front_leg_x, leg_r_y, 4, 7), COLOR_PANTS)
		_draw_rect(img, Rect2i(front_leg_x, leg_r_y + 7, 5, 3), COLOR_SHOE)
		
		# 앞쪽 팔 (Right)
		_draw_rect(img, Rect2i(front_arm_x, arm_base_y, 4, 7), COLOR_SKIN)
		
	else: # Up or Down view
		var leg_l_x: int = 11 - leg_l_spread
		var leg_r_x: int = 17 + leg_r_spread
		var arm_l_y: int = arm_base_y + arm_l_spread
		var arm_r_y: int = arm_base_y + arm_r_spread
		var leg_l_y: int = leg_base_y + leg_l_y_lift
		var leg_r_y: int = leg_base_y + leg_r_y_lift
		
		# 다리
		_draw_rect(img, Rect2i(leg_l_x, leg_l_y, 4, 7), COLOR_PANTS)
		_draw_rect(img, Rect2i(leg_l_x, leg_l_y + 7, 4, 3), COLOR_SHOE)
		_draw_rect(img, Rect2i(leg_r_x, leg_r_y, 4, 7), COLOR_PANTS)
		_draw_rect(img, Rect2i(leg_r_x, leg_r_y + 7, 4, 3), COLOR_SHOE)
		
		# 팔
		_draw_rect(img, Rect2i(7, arm_l_y, 4, 7), COLOR_SKIN)
		_draw_rect(img, Rect2i(21, arm_r_y, 4, 7), COLOR_SKIN)
		
		# 몸통
		_draw_rect(img, Rect2i(BODY_X, BODY_Y + bob, BODY_W, BODY_H), COLOR_SHIRT)
		
		# 머리
		_draw_circle(img, Vector2i(HEAD_CENTER_X, HEAD_CENTER_Y + bob), HEAD_RADIUS, COLOR_SKIN)
		
		if dir.y == 1: # Down view (눈 표시)
			_draw_rect(img, Rect2i(12, HEAD_CENTER_Y - 1 + bob, 2, 3), COLOR_EYE)
			_draw_rect(img, Rect2i(18, HEAD_CENTER_Y - 1 + bob, 2, 3), COLOR_EYE)
			
	# 왼쪽을 볼 경우 전체 이미지를 좌우 반전
	if flip:
		img.flip_x()
		
	var tex: ImageTexture = ImageTexture.create_from_image(img)
	if tex == null:
		push_error("텍스처 생성 실패")
		return ImageTexture.new()
	return tex

func _draw_circle(img: Image, center: Vector2i, radius: int, color: Color) -> void:
	for y: int in range(center.y - radius, center.y + radius + 1):
		for x: int in range(center.x - radius, center.x + radius + 1):
			if x >= 0 and x < SPRITE_WIDTH and y >= 0 and y < SPRITE_HEIGHT:
				var dx: float = float(x - center.x)
				var dy: float = float(y - center.y)
				if dx * dx + dy * dy <= float(radius * radius):
					img.set_pixel(x, y, color)

func _draw_rect(img: Image, rect: Rect2i, color: Color) -> void:
	for y: int in range(rect.position.y, rect.end.y):
		for x: int in range(rect.position.x, rect.end.x):
			if x >= 0 and x < SPRITE_WIDTH and y >= 0 and y < SPRITE_HEIGHT:
				img.set_pixel(x, y, color)
