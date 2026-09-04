import os

filepath = "/Users/soul/Source/animals_farm/scripts/player_sprite.gd"

code = """class_name PlayerSprite
extends AnimatedSprite3D

# --- 상수 ---
const SPRITE_WIDTH: int = 32
const SPRITE_HEIGHT: int = 40
const PIXEL_SIZE_CONST: float = 0.05
const WALK_FPS: float = 10.0
const BOB_OFFSET: int = 2
const SHADE_COEFF: float = 0.7

# 캐릭터 상태 및 색상
var _preset: Dictionary = {}
var _is_setup: bool = false

var _c_skin: Color
var _c_skin_dark: Color
var _c_torso: Color
var _c_torso_dark: Color
var _c_bottom: Color
var _c_bottom_dark: Color
var _c_hair: Color
var _c_shoe: Color
var _c_shoe_dark: Color
var _c_eye: Color

var _hair_style: String = "none"
var _gender: String = "male"

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

# --- 공개 API ---
func setup(preset: Dictionary) -> void:
	_preset = preset
	_is_setup = true

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
func _ready() -> void:
	if not _is_setup:
		push_warning("setup()이 호출되지 않았습니다. 기본 외형으로 동작합니다.")
		_c_skin = Palette.color("character", "skin")
		_c_skin_dark = Palette.color("character", "skin_dark")
		_c_torso = Palette.color("character", "shirt")
		_c_torso_dark = Palette.color("character", "shirt") # Fallback didn't have torso dark originally
		_c_bottom = Palette.color("character", "pants")
		_c_bottom_dark = Palette.color("character", "pants_dark")
		_hair_style = "none"
		_gender = "male"
	else:
		var skin_key: String = _preset.get("skin", "skin")
		var outfit_key: String = _preset.get("outfit", "shirt")
		_hair_style = _preset.get("hair", "hair_short")
		_gender = _preset.get("gender", "male")
		
		_c_skin = Palette.color("character", skin_key)
		_c_skin_dark = Color(_c_skin.r * SHADE_COEFF, _c_skin.g * SHADE_COEFF, _c_skin.b * SHADE_COEFF, _c_skin.a)
		
		_c_torso = Palette.color("character", outfit_key)
		_c_torso_dark = Color(_c_torso.r * SHADE_COEFF, _c_torso.g * SHADE_COEFF, _c_torso.b * SHADE_COEFF, _c_torso.a)
		
		_c_bottom = _c_torso
		_c_bottom_dark = _c_torso_dark

	_c_hair = Palette.color("character", "hair")
	_c_shoe = Palette.color("character", "shoe")
	_c_shoe_dark = Palette.color("character", "shoe_dark")
	_c_eye = Palette.color("character", "eye")

	# 3D 환경에서 2.5D 빌보드 스프라이트로 설정
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
	for i in range(6): down_frames.append(_create_frame(Vector2i(0, 1), i, false))
	frames.add_frame("idle_down", down_frames[0])
	for i in range(6): frames.add_frame("walk_down", down_frames[i])
		
	# up
	var up_frames: Array[Texture2D] = []
	for i in range(6): up_frames.append(_create_frame(Vector2i(0, -1), i, false))
	frames.add_frame("idle_up", up_frames[0])
	for i in range(6): frames.add_frame("walk_up", up_frames[i])
		
	# right
	var right_frames: Array[Texture2D] = []
	for i in range(6): right_frames.append(_create_frame(Vector2i(1, 0), i, false))
	frames.add_frame("idle_right", right_frames[0])
	for i in range(6): frames.add_frame("walk_right", right_frames[i])
		
	# left
	var left_frames: Array[Texture2D] = []
	for i in range(6): left_frames.append(_create_frame(Vector2i(1, 0), i, true))
	frames.add_frame("idle_left", left_frames[0])
	for i in range(6): frames.add_frame("walk_left", left_frames[i])
		
	return frames

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
		_draw_rect(img, Rect2i(back_arm_x, arm_base_y, 4, 7), _c_skin_dark)
		# 뒤쪽 다리 (Left)
		_draw_rect(img, Rect2i(back_leg_x, leg_l_y, 4, 7), _c_bottom_dark)
		_draw_rect(img, Rect2i(back_leg_x, leg_l_y + 7, 5, 3), _c_shoe_dark)
		
		# 몸통
		_draw_rect(img, Rect2i(BODY_RIGHT_X, BODY_Y + bob, BODY_RIGHT_W, BODY_H), _c_torso)
		
		# 치마 (female)
		if _gender == "female":
			_draw_rect(img, Rect2i(BODY_RIGHT_X - 1, BODY_Y + bob + 6, BODY_RIGHT_W + 2, 3), _c_torso)
			_draw_rect(img, Rect2i(BODY_RIGHT_X - 2, BODY_Y + bob + 9, BODY_RIGHT_W + 4, 3), _c_torso)
		
		# 머리 (크고 둥글게)
		_draw_circle(img, Vector2i(HEAD_CENTER_X, HEAD_CENTER_Y + bob), HEAD_RADIUS, _c_skin)
		_draw_rect(img, Rect2i(19, HEAD_CENTER_Y - 1 + bob, 2, 3), _c_eye) # 눈
		
		_draw_hair(img, dir, bob)
		
		# 앞쪽 다리 (Right)
		_draw_rect(img, Rect2i(front_leg_x, leg_r_y, 4, 7), _c_bottom)
		_draw_rect(img, Rect2i(front_leg_x, leg_r_y + 7, 5, 3), _c_shoe)
		
		# 앞쪽 팔 (Right)
		_draw_rect(img, Rect2i(front_arm_x, arm_base_y, 4, 7), _c_skin)
		
	else: # Up or Down view
		var leg_l_x: int = 11 - leg_l_spread
		var leg_r_x: int = 17 + leg_r_spread
		var arm_l_y: int = arm_base_y + arm_l_spread
		var arm_r_y: int = arm_base_y + arm_r_spread
		var leg_l_y: int = leg_base_y + leg_l_y_lift
		var leg_r_y: int = leg_base_y + leg_r_y_lift
		
		# 다리
		_draw_rect(img, Rect2i(leg_l_x, leg_l_y, 4, 7), _c_bottom)
		_draw_rect(img, Rect2i(leg_l_x, leg_l_y + 7, 4, 3), _c_shoe)
		_draw_rect(img, Rect2i(leg_r_x, leg_r_y, 4, 7), _c_bottom)
		_draw_rect(img, Rect2i(leg_r_x, leg_r_y + 7, 4, 3), _c_shoe)
		
		# 팔
		_draw_rect(img, Rect2i(7, arm_l_y, 4, 7), _c_skin)
		_draw_rect(img, Rect2i(21, arm_r_y, 4, 7), _c_skin)
		
		# 몸통
		_draw_rect(img, Rect2i(BODY_X, BODY_Y + bob, BODY_W, BODY_H), _c_torso)
		
		# 치마 (female)
		if _gender == "female":
			_draw_rect(img, Rect2i(BODY_X - 1, BODY_Y + bob + 6, BODY_W + 2, 3), _c_torso)
			_draw_rect(img, Rect2i(BODY_X - 2, BODY_Y + bob + 9, BODY_W + 4, 3), _c_torso)
		
		# 머리
		_draw_circle(img, Vector2i(HEAD_CENTER_X, HEAD_CENTER_Y + bob), HEAD_RADIUS, _c_skin)
		
		if dir.y == 1: # Down view (눈 표시)
			_draw_rect(img, Rect2i(12, HEAD_CENTER_Y - 1 + bob, 2, 3), _c_eye)
			_draw_rect(img, Rect2i(18, HEAD_CENTER_Y - 1 + bob, 2, 3), _c_eye)
			
		_draw_hair(img, dir, bob)
			
	# 왼쪽을 볼 경우 전체 이미지를 좌우 반전
	if flip:
		img.flip_x()
		
	var tex: ImageTexture = ImageTexture.create_from_image(img)
	if tex == null:
		push_error("텍스처 생성 실패")
		return ImageTexture.new()
	return tex

func _draw_hair(img: Image, dir: Vector2i, bob: int) -> void:
	if _hair_style == "none":
		return
		
	var hc_x: int = HEAD_CENTER_X
	var hc_y: int = HEAD_CENTER_Y + bob
	
	if dir.y == -1: # Up view 머리 뒤통수 덮기
		_draw_circle(img, Vector2i(hc_x, hc_y), HEAD_RADIUS, _c_hair if _hair_style != "hair_cap" else _c_torso)
	
	if _hair_style == "hair_cap":
		_draw_circle(img, Vector2i(hc_x, hc_y - 3), HEAD_RADIUS - 1, _c_torso)
		if dir.x == 1:
			_draw_rect(img, Rect2i(hc_x, hc_y - 4, 12, 2), _c_torso)
		elif dir.y == 1:
			_draw_rect(img, Rect2i(hc_x - 10, hc_y - 4, 20, 2), _c_torso)
		return
		
	_draw_circle(img, Vector2i(hc_x, hc_y - 3), HEAD_RADIUS - 1, _c_hair)
	
	if _hair_style == "hair_long":
		if dir.x == 1:
			_draw_rect(img, Rect2i(hc_x - 8, hc_y, 6, 12), _c_hair)
		else:
			_draw_rect(img, Rect2i(hc_x - 9, hc_y, 4, 12), _c_hair)
			_draw_rect(img, Rect2i(hc_x + 5, hc_y, 4, 12), _c_hair)
			if dir.y == -1:
				_draw_rect(img, Rect2i(hc_x - 5, hc_y, 10, 12), _c_hair)
	elif _hair_style == "hair_twin":
		if dir.x == 1:
			_draw_rect(img, Rect2i(hc_x - 7, hc_y, 4, 10), _c_hair)
		else:
			_draw_rect(img, Rect2i(hc_x - 12, hc_y - 2, 5, 10), _c_hair)
			_draw_rect(img, Rect2i(hc_x + 7, hc_y - 2, 5, 10), _c_hair)
	elif _hair_style == "hair_bob":
		if dir.x == 1:
			_draw_rect(img, Rect2i(hc_x - 8, hc_y, 8, 6), _c_hair)
		else:
			_draw_rect(img, Rect2i(hc_x - 9, hc_y, 18, 6), _c_hair)
	elif _hair_style == "hair_short":
		if dir.x == 1:
			_draw_rect(img, Rect2i(hc_x - 8, hc_y, 6, 4), _c_hair)
		else:
			_draw_rect(img, Rect2i(hc_x - 8, hc_y, 16, 4), _c_hair)

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
"""

with open(filepath, "w", encoding="utf-8") as f:
    f.write(code)

print("Updated script.")
