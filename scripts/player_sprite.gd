class_name PlayerSprite
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

# --- 운동(활동) ---
## 운동 중이면 이 값이 비어 있지 않다. 스프라이트를 통째로 다시 만들지 않도록
## (활동, 기술)별로 만든 프레임을 캐시한다 — 버튼을 연타해도 부담이 없다.
var _activity: String = ""
var _trick: String = ""
var _frames_cache: Dictionary = {}

var _c_rope: Color
var _c_bike_frame: Color
var _c_bike_wheel: Color
var _c_skate_boot: Color
var _c_skate_wheel: Color
var _c_board_deck: Color
var _c_board_bar: Color

## 운동별 착지/자세 기준 — 픽셀 좌표(32x40, 발바닥이 y=39).
## 바퀴 중심 높이. y=35에 반지름 5를 두면 스프라이트(40px) 아래가 잘려
## 바퀴가 반달처럼 보였다 — 33으로 올려 전부 들어오게 한다.
const WHEEL_Y := 33
const DECK_Y := 35

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

## 운동 모습으로 바꾼다. kind가 빈 문자열이면 원래 모습으로 돌아온다.
## trick은 줄넘기에만 쓰인다(모아 뛰기/이중 뛰기/토드/엇걸어 풀어 뛰기).
func set_activity(kind: String, trick: String = "") -> void:
	if kind == _activity and trick == _trick:
		return
	_activity = kind
	_trick = trick
	if not is_inside_tree():
		return   # _ready에서 어차피 만든다
	_apply_frames()

func activity() -> String:
	return _activity

## 지금 재생 중인 애니메이션을 유지한 채 프레임 묶음만 갈아 끼운다 —
## 갈아 끼우고 play()를 다시 부르지 않으면 이전 애니메이션 이름이 없어져
## 스프라이트가 사라진다.
func _apply_frames() -> void:
	var key := "%s|%s" % [_activity, _trick]
	if not _frames_cache.has(key):
		_frames_cache[key] = _generate_sprite_frames()
	var keep := animation
	sprite_frames = _frames_cache[key] as SpriteFrames
	if sprite_frames.has_animation(keep):
		play(keep)
	else:
		play("idle_" + _current_facing)

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

	_c_rope = Palette.color("character", "rope")
	_c_bike_frame = Palette.color("character", "bike_frame")
	_c_bike_wheel = Palette.color("character", "bike_wheel")
	_c_skate_boot = Palette.color("character", "skate_boot")
	_c_skate_wheel = Palette.color("character", "skate_wheel")
	_c_board_deck = Palette.color("character", "board_deck")
	_c_board_bar = Palette.color("character", "board_bar")

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
	_apply_frames()
	play("idle_" + _current_facing)

func _generate_sprite_frames() -> SpriteFrames:
	var frames: SpriteFrames = SpriteFrames.new()
	var anims: Array[String] = [
		"idle_down", "idle_up", "idle_left", "idle_right",
		"walk_down", "walk_up", "walk_left", "walk_right"
	]
	
	# 줄넘기는 **제자리에서도 움직여야** 한다 — idle이 한 장이면 멈춰 서서
	# 줄만 든 자세로 굳는다. 자전거·인라인·킥보드는 멈추면 정지 자세가 맞다.
	var idle_loops := _activity == "jumprope"
	for anim: String in anims:
		frames.add_animation(anim)
		frames.set_animation_loop(anim, anim.begins_with("walk_") or idle_loops)
		frames.set_animation_speed(anim, WALK_FPS)
		
	# down
	var down_frames: Array[Texture2D] = []
	for i in range(6): down_frames.append(_create_frame(Vector2i(0, 1), i, false))
	if idle_loops:
		for i in range(6): frames.add_frame("idle_down", down_frames[i])
	else:
		frames.add_frame("idle_down", down_frames[0])
	for i in range(6): frames.add_frame("walk_down", down_frames[i])
		
	# up
	var up_frames: Array[Texture2D] = []
	for i in range(6): up_frames.append(_create_frame(Vector2i(0, -1), i, false))
	if idle_loops:
		for i in range(6): frames.add_frame("idle_up", up_frames[i])
	else:
		frames.add_frame("idle_up", up_frames[0])
	for i in range(6): frames.add_frame("walk_up", up_frames[i])
		
	# right
	var right_frames: Array[Texture2D] = []
	for i in range(6): right_frames.append(_create_frame(Vector2i(1, 0), i, false))
	if idle_loops:
		for i in range(6): frames.add_frame("idle_right", right_frames[i])
	else:
		frames.add_frame("idle_right", right_frames[0])
	for i in range(6): frames.add_frame("walk_right", right_frames[i])
		
	# left
	var left_frames: Array[Texture2D] = []
	for i in range(6): left_frames.append(_create_frame(Vector2i(1, 0), i, true))
	if idle_loops:
		for i in range(6): frames.add_frame("idle_left", left_frames[i])
	else:
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
			
	# 운동 장비/자세는 몸을 다 그린 뒤에 덮어 그린다 — 자전거·킥보드는 다리를
	# 가려야 "타고 있는" 것으로 보이고, 줄은 몸 앞을 지나야 한다.
	if not _activity.is_empty():
		img = _apply_activity(img, dir, walk_phase)

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

# ---------------------------------------------------------------------------
# 운동(활동) 그리기
#
# 설계: 몸을 다 그린 뒤 **덮어 그린다.** 자전거·킥보드는 다리 자리를 장비가
# 차지해야 "타고 있는" 것으로 읽히고, 줄넘기 줄은 몸 앞을 지나야 한다.
# 몸 그리기 코드(4방향 분기)를 활동마다 복사하지 않는 것이 목적이다.
#
# 방향은 dir.x == 1(오른쪽)과 up/down 두 갈래만 그린다 — 왼쪽은 오른쪽 프레임을
# 좌우 반전한 것이라(_create_frame의 flip) 따로 그릴 필요가 없다.
# ---------------------------------------------------------------------------

func _apply_activity(img: Image, dir: Vector2i, phase: int) -> Image:
	var side := dir.x == 1
	match _activity:
		"jumprope":
			return _draw_jumprope(img, side, phase)
		"soccer":
			_draw_soccer(img, side, phase)
		"bike":
			_draw_bike(img, side, phase)
		"inline":
			return _draw_inline(img, side, phase)
		"kickboard":
			_draw_kickboard(img, side, phase)
		"slide", "swing", "seesaw":
			# 놀이기구는 흔들림·회전·높이를 **노드 오프셋**으로 표현하므로
			# (scripts/park.gd) 스프라이트는 정지 자세가 맞다.
			_draw_sitting(img, side)
		"carousel":
			_draw_gripping(img, side)
	return img

# --- 줄넘기 ------------------------------------------------------------------

## 줄의 위상. 이중 뛰기는 한 번 뛰는 동안 줄이 두 바퀴 돈다.
func _rope_phase(phase: int) -> int:
	return (phase * 2) % 6 if _trick == "double" else phase

## 뛰어오르는 높이(픽셀). 이중 뛰기는 더 높이 뛰어야 두 바퀴가 들어간다.
func _jump_lift(phase: int) -> int:
	var high := _trick == "double"
	match phase:
		1: return 5 if high else 3
		2: return 7 if high else 5
		3: return 6 if high else 4
		4: return 3 if high else 2
	return 0

func _draw_jumprope(img: Image, side: bool, phase: int) -> Image:
	# 손 위치(줄을 쥔 곳). 옆모습은 한 손만 보인다.
	var hand_l := Vector2i(5, 26)
	var hand_r := Vector2i(27, 26)
	if side:
		hand_l = Vector2i(11, 26)
		hand_r = Vector2i(21, 26)

	# 모아 뛰기: 두 발을 붙인다. 발이 벌어져 있으면 "모아"가 안 보인다.
	if _trick == "together" and not side:
		_draw_rect(img, Rect2i(12, LEG_BASE_Y, 8, 7), _c_bottom)
		_draw_rect(img, Rect2i(12, LEG_BASE_Y + 7, 8, 3), _c_shoe)

	# 몸 전체를 들어 올린다(뛰는 중) — 줄은 땅 기준이라 들어 올린 뒤에 그린다.
	var lifted := _shift_up(img, _jump_lift(phase))

	# 줄: 위상에 따라 몸 뒤/위/앞을 지난다. 32px 안에서 곡선을 그리면 뭉개지므로
	# 위상별로 "지금 줄이 어디쯤인지"만 분명하게 보여 준다.
	var rp := _rope_phase(phase)
	match rp:
		0:
			# 발 아래 — 막 넘어간 순간
			_draw_line(lifted, Vector2i(hand_l.x, 39), Vector2i(hand_r.x, 39), _c_rope, 2)
			_draw_line(lifted, hand_l, Vector2i(hand_l.x - 2, 39), _c_rope, 1)
			_draw_line(lifted, hand_r, Vector2i(hand_r.x + 2, 39), _c_rope, 1)
		1, 2:
			# 뒤로 올라가는 중 — 양옆으로 보인다
			var top := 20 if rp == 1 else 10
			_draw_line(lifted, hand_l, Vector2i(hand_l.x - 3, top), _c_rope, 1)
			_draw_line(lifted, hand_r, Vector2i(hand_r.x + 3, top), _c_rope, 1)
		3:
			# 머리 위
			_draw_line(lifted, Vector2i(hand_l.x - 3, 2), Vector2i(hand_r.x + 3, 2), _c_rope, 2)
			_draw_line(lifted, hand_l, Vector2i(hand_l.x - 3, 3), _c_rope, 1)
			_draw_line(lifted, hand_r, Vector2i(hand_r.x + 3, 3), _c_rope, 1)
		4, 5:
			# 앞으로 내려오는 중 — 몸 앞을 지난다
			var low := 12 if rp == 4 else 30
			_draw_line(lifted, hand_l, Vector2i(hand_l.x - 1, low), _c_rope, 1)
			_draw_line(lifted, hand_r, Vector2i(hand_r.x + 1, low), _c_rope, 1)
			_draw_line(lifted, Vector2i(hand_l.x - 1, low), Vector2i(hand_r.x + 1, low), _c_rope, 2)

	# 기술별 추가 표현
	if _trick == "cross" and rp <= 2:
		# 엇걸어 뛰기: 팔을 엇걸어 줄이 몸 앞에서 X를 만든다(3~5는 풀어 뛰기).
		_draw_line(lifted, hand_l, Vector2i(hand_r.x, 14), _c_rope, 1)
		_draw_line(lifted, hand_r, Vector2i(hand_l.x, 14), _c_rope, 1)
	elif _trick == "toad":
		# 토드: 한 팔을 다리 아래로 넣어 줄이 무릎 사이를 지난다.
		_draw_line(lifted, hand_l, Vector2i(16, 34), _c_rope, 1)
		_draw_rect(lifted, Rect2i(hand_l.x, 27, 3, 6), _c_skin)
	# 줄을 쥔 손
	_draw_rect(lifted, Rect2i(hand_l.x - 1, hand_l.y - 1, 3, 3), _c_skin)
	_draw_rect(lifted, Rect2i(hand_r.x - 1, hand_r.y - 1, 3, 3), _c_skin)
	return lifted

# --- 축구 --------------------------------------------------------------------

func _draw_soccer(img: Image, side: bool, phase: int) -> void:
	# 정강이 보호대 — 축구 중임을 한눈에 알 수 있는 최소 표시.
	var guard := Palette.color("world", "field_line")
	if side:
		_draw_rect(img, Rect2i(13, LEG_BASE_Y + 3, 5, 2), guard)
	else:
		_draw_rect(img, Rect2i(11, LEG_BASE_Y + 3, 4, 2), guard)
		_draw_rect(img, Rect2i(17, LEG_BASE_Y + 3, 4, 2), guard)
	# 차는 자세: 멈춘 프레임(0)에서 앞발을 내민다.
	if phase == 0:
		if side:
			_draw_rect(img, Rect2i(19, LEG_BASE_Y + 4, 7, 4), _c_bottom)
			_draw_rect(img, Rect2i(24, LEG_BASE_Y + 4, 4, 3), _c_shoe)
		else:
			_draw_rect(img, Rect2i(17, LEG_BASE_Y + 6, 5, 4), _c_shoe)

# --- 자전거 ------------------------------------------------------------------

func _draw_bike(img: Image, side: bool, phase: int) -> void:
	# 페달 각도 — 6프레임으로 한 바퀴. 다리가 원을 그리면 "패달을 밟는" 것으로 읽힌다.
	var th := TAU * float(phase) / 6.0
	if side:
		var rear := Vector2i(8, WHEEL_Y)
		var front := Vector2i(25, WHEEL_Y)
		var crank := Vector2i(16, WHEEL_Y - 1)
		# 다리 자리를 자전거가 차지해야 "타고 있는" 것으로 보인다 → 먼저 지운다.
		_clear_rect(img, Rect2i(6, WHEEL_Y - 6, 22, 40 - (WHEEL_Y - 6)))
		for hub: Vector2i in [rear, front]:
			# 어두운 타이어만 그리면 어두운 신발·발판과 붙어 바퀴로 보이지 않는다
			# (실측). 바깥 1px을 밝은 림으로 두르고 허브도 밝게 찍는다.
			_draw_ring(img, hub, 5, 1, _c_board_bar)
			_draw_ring(img, hub, 4, 2, _c_bike_wheel)
			_draw_rect(img, Rect2i(hub.x - 1, hub.y - 1, 2, 2), _c_board_bar)
		# 프레임: 뒷바퀴 → 안장 → 앞바퀴 → 핸들
		_draw_line(img, rear, Vector2i(15, WHEEL_Y - 7), _c_bike_frame, 2)
		_draw_line(img, Vector2i(15, WHEEL_Y - 7), front, _c_bike_frame, 2)
		_draw_line(img, crank, Vector2i(15, WHEEL_Y - 7), _c_bike_frame, 2)
		_draw_line(img, front, Vector2i(24, WHEEL_Y - 9), _c_bike_frame, 2)
		_draw_rect(img, Rect2i(21, WHEEL_Y - 10, 6, 2), _c_bike_frame)   # 핸들바
		# 페달과 다리
		var pedal := crank + Vector2i(int(round(cos(th) * 4.0)), int(round(sin(th) * 4.0)))
		_draw_line(img, Vector2i(15, WHEEL_Y - 8), pedal, _c_bottom, 3)
		_draw_rect(img, Rect2i(pedal.x - 1, pedal.y, 4, 2), _c_shoe)
		# 뒤쪽 다리(반대 위상)
		var pedal2 := crank - Vector2i(int(round(cos(th) * 4.0)), int(round(sin(th) * 4.0)))
		_draw_line(img, Vector2i(14, WHEEL_Y - 8), pedal2, _c_bottom_dark, 2)
	else:
		# 앞/뒤에서 본 모습: 바퀴가 겹쳐 보이므로 하나만 그리고 핸들을 넓게 둔다.
		_clear_rect(img, Rect2i(6, WHEEL_Y - 6, 22, 40 - (WHEEL_Y - 6)))
		_draw_ring(img, Vector2i(16, WHEEL_Y + 1), 4, 2, _c_bike_wheel)
		_draw_rect(img, Rect2i(15, WHEEL_Y - 9, 2, 9), _c_bike_frame)
		_draw_rect(img, Rect2i(9, WHEEL_Y - 10, 14, 2), _c_bike_frame)   # 핸들바
		# 두 다리를 좌우 페달에
		var off := int(round(sin(th) * 2.0))
		_draw_rect(img, Rect2i(11, WHEEL_Y - 8 + off, 4, 7), _c_bottom)
		_draw_rect(img, Rect2i(17, WHEEL_Y - 8 - off, 4, 7), _c_bottom)
		_draw_rect(img, Rect2i(11, WHEEL_Y - 1 + off, 4, 2), _c_shoe)
		_draw_rect(img, Rect2i(17, WHEEL_Y - 1 - off, 4, 2), _c_shoe)

# --- 인라인 ------------------------------------------------------------------

func _draw_inline(img: Image, side: bool, phase: int) -> Image:
	# 자세: 상체를 앞으로 기울인다(사용자 요청 "자세를 취하면서").
	# 상체를 앞으로 3px 기울인다(2px는 실측에서 알아보기 어려웠다).
	var leaned := _lean_upper(img, 3 if side else 0, 26)
	if side:
		# 부츠 두 짝. 붙여 놓으면 널빤지 하나로 보이므로 **사이를 띄운다**.
		var swing := 2 if phase % 2 == 0 else -2
		var front_x := 16 + swing
		var back_x := 7 - swing
		for boot_x: int in [front_x, back_x]:
			_draw_rect(leaned, Rect2i(boot_x, 33, 7, 4), _c_skate_boot)
			# 바퀴 3개(사이를 1px 띄워 개수가 보이게)
			for i in 3:
				_draw_rect(leaned, Rect2i(boot_x + i * 2 + 1, 37, 2, 2), _c_skate_wheel)
	else:
		var spread := 3 if phase % 2 == 0 else 1
		for foot_x: int in [11 - spread, 17 + spread]:
			_draw_rect(leaned, Rect2i(foot_x, 34, 5, 3), _c_skate_boot)
			for i in 2:
				_draw_rect(leaned, Rect2i(foot_x + i * 2, 37, 2, 2), _c_skate_wheel)
	return leaned

# --- 킥보드 ------------------------------------------------------------------

func _draw_kickboard(img: Image, side: bool, phase: int) -> void:
	# 바퀴는 **두 개**(사용자 지정): 앞뒤로 하나씩.
	if side:
		# 바퀴 **두 개**(사용자 지정). 발판보다 **먼저** 밝게 그리고 발판을 위에
		# 덮는다 — 어두운 바퀴를 어두운 발판 위에 그리면 한 덩어리로 보인다.
		for wheel: Vector2i in [Vector2i(11, 36), Vector2i(24, 36)]:
			_draw_circle(img, wheel, 3, _c_board_bar)
			_draw_rect(img, Rect2i(wheel.x - 1, wheel.y - 1, 2, 2), _c_bike_wheel)
		_draw_rect(img, Rect2i(10, DECK_Y, 15, 2), _c_board_deck)      # 발판
		_draw_rect(img, Rect2i(23, 24, 2, 13), _c_board_bar)            # 조향 기둥
		_draw_rect(img, Rect2i(20, 23, 8, 2), _c_board_bar)             # 핸들
		# 한 발은 발판, 다른 발은 땅을 민다.
		_draw_rect(img, Rect2i(15, DECK_Y - 5, 4, 5), _c_bottom)
		_draw_rect(img, Rect2i(14, DECK_Y - 1, 5, 2), _c_shoe)
		var push := 4 if phase % 3 == 0 else 8
		_draw_rect(img, Rect2i(8, DECK_Y - 3, push, 3), _c_bottom_dark)
		_draw_rect(img, Rect2i(8, DECK_Y, 4, 2), _c_shoe_dark)
	else:
		_draw_circle(img, Vector2i(16, 36), 3, _c_board_bar)
		_draw_rect(img, Rect2i(15, 35, 2, 2), _c_bike_wheel)
		_draw_rect(img, Rect2i(12, DECK_Y + 1, 8, 2), _c_board_deck)
		_draw_rect(img, Rect2i(15, 24, 2, 13), _c_board_bar)
		_draw_rect(img, Rect2i(10, 23, 12, 2), _c_board_bar)
		var off := 1 if phase % 3 == 0 else 3
		_draw_rect(img, Rect2i(12, DECK_Y - 4, 4, 5), _c_bottom)
		_draw_rect(img, Rect2i(18, DECK_Y - 4 - off, 4, 5), _c_bottom_dark)

# --- 놀이기구 자세 ------------------------------------------------------------

## 앉은 자세(미끄럼틀·그네·시소 공통).
##
## 몸을 다시 그리지 않는 이유: 4방향 × 6프레임을 자세마다 새로 그리면 관리
## 비용이 커진다. **다리만 앞으로 접어** 덮어 그리면 이 크기(32x40)에서는
## 충분히 "앉았다"로 읽힌다.
func _draw_sitting(img: Image, side: bool) -> void:
	_clear_rect(img, Rect2i(6, LEG_BASE_Y, 20, 40 - LEG_BASE_Y))
	if side:
		# 옆모습: 허벅지가 앞으로, 정강이가 아래로.
		_draw_rect(img, Rect2i(15, LEG_BASE_Y + 1, 9, 4), _c_bottom)
		_draw_rect(img, Rect2i(21, LEG_BASE_Y + 5, 4, 5), _c_bottom_dark)
		_draw_rect(img, Rect2i(20, LEG_BASE_Y + 9, 6, 3), _c_shoe)
	else:
		# 앞/뒤: 무릎이 화면 쪽으로 오므로 다리를 짧고 넓게.
		for leg_x: int in [10, 18]:
			_draw_rect(img, Rect2i(leg_x, LEG_BASE_Y + 1, 5, 5), _c_bottom)
			_draw_rect(img, Rect2i(leg_x, LEG_BASE_Y + 6, 5, 3), _c_shoe)

## 손잡이를 잡고 선 자세(뺑뺑이).
func _draw_gripping(img: Image, side: bool) -> void:
	var bar := Palette.color("world", "carousel_bar")
	if side:
		# 몸 앞에 세로 손잡이.
		_draw_rect(img, Rect2i(23, 18, 2, 12), bar)
		_draw_rect(img, Rect2i(21, 19, 4, 3), _c_skin)
	else:
		_draw_rect(img, Rect2i(7, 19, 18, 2), bar)
		_draw_rect(img, Rect2i(7, 18, 3, 4), _c_skin)
		_draw_rect(img, Rect2i(22, 18, 3, 4), _c_skin)

# ---------------------------------------------------------------------------
# 그리기 도우미
# ---------------------------------------------------------------------------

## 이미지를 위로 dy만큼 올린다(뛰어오르기). 원본을 자르지 않으려면 새 이미지에
## 옮겨 그려야 한다 — Image에는 "이동" 연산이 없다.
func _shift_up(img: Image, dy: int) -> Image:
	if dy <= 0:
		return img
	var out := Image.create_empty(SPRITE_WIDTH, SPRITE_HEIGHT, false, Image.FORMAT_RGBA8)
	out.blit_rect(img, Rect2i(0, dy, SPRITE_WIDTH, SPRITE_HEIGHT - dy), Vector2i(0, 0))
	return out

## y < split 영역(상체)만 dx만큼 옮긴다 — 인라인의 앞으로 기운 자세.
func _lean_upper(img: Image, dx: int, split: int) -> Image:
	if dx == 0:
		return img
	var out := Image.create_empty(SPRITE_WIDTH, SPRITE_HEIGHT, false, Image.FORMAT_RGBA8)
	out.blit_rect(img, Rect2i(0, split, SPRITE_WIDTH, SPRITE_HEIGHT - split), Vector2i(0, split))
	out.blit_rect(img, Rect2i(0, 0, SPRITE_WIDTH, split), Vector2i(dx, 0))
	return out

func _clear_rect(img: Image, rect: Rect2i) -> void:
	_draw_rect(img, rect, Color(0, 0, 0, 0))

## 굵이가 있는 선(브레젠험 대신 간격 보간 — 32px 스프라이트에서는 충분하다).
func _draw_line(img: Image, from: Vector2i, to: Vector2i, color: Color, thick: int = 1) -> void:
	var steps := maxi(absi(to.x - from.x), absi(to.y - from.y))
	if steps == 0:
		_draw_rect(img, Rect2i(from.x, from.y, thick, thick), color)
		return
	for i in range(steps + 1):
		var f := float(i) / float(steps)
		var x := int(round(lerpf(float(from.x), float(to.x), f)))
		var y := int(round(lerpf(float(from.y), float(to.y), f)))
		_draw_rect(img, Rect2i(x, y, thick, thick), color)

## 가운데가 빈 원(바퀴). 채운 원을 두 번 그려 안쪽을 지우면 뒤에 있는 것까지
## 지워지므로, 링을 직접 판정해 그린다.
func _draw_ring(img: Image, center: Vector2i, radius: int, thick: int, color: Color) -> void:
	var r2 := float(radius * radius)
	var inner := float((radius - thick) * (radius - thick))
	for y: int in range(center.y - radius, center.y + radius + 1):
		for x: int in range(center.x - radius, center.x + radius + 1):
			if x < 0 or x >= SPRITE_WIDTH or y < 0 or y >= SPRITE_HEIGHT:
				continue
			var dx := float(x - center.x)
			var dy := float(y - center.y)
			var d := dx * dx + dy * dy
			if d <= r2 and d >= inner:
				img.set_pixel(x, y, color)
