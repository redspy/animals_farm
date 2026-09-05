class_name Park
extends Node3D

## 놀이터 — 모래 바닥과 놀이기구 네 개(미끄럼틀·그네·뺑뺑이·시소).
##
## 좌표·크기는 `data/world.json`의 `park`, 물리·연출 값은
## `data/activities.json`의 `park`가 단일 출처다. 서버도 같은 파일을 읽는다.
##
## **핵심 제약**: 캐릭터에는 Y축이 없다(`position.y`는 항상 0이고 서버도 2D로
## 검증한다). 그래서 높이는 전부 **스프라이트 오프셋**으로 표현하고, 논리 위치는
## 바닥에 붙어 있다. 놀이기구를 타는 사람의 논리 위치는 좌석에 고정되고
## (서버가 RIDE_LEASH로 강제한다) 보이는 위치만 흔들리거나 돈다.
##
## 동기화 비용을 나눈 기준:
## - **시소·뺑뺑이**: 밀 때마다 값이 바뀌므로 서버가 각도를 소유하고 방송한다.
## - **그네**: 흔들림이 주기 운동이라 `f(시각)`으로 각자 계산한다(진폭만
##   activity의 trick으로 동기화). 위상이 사람마다 조금 다를 수 있지만 주기
##   운동이라 눈에 걸리지 않고, 대역폭이 0이다.
## - **미끄럼틀**: 높이를 **위치의 함수**로 만들어(height_at) 동기화가 없다 —
##   내려가는 사람의 위치는 어차피 이동으로 방송된다.

## 기구를 탭했을 때 "이 기구를 타려는 것"으로 볼 최대 거리.
const MOUNT_PICK_RADIUS := 1.6
## 바닥 데칼 높이(섬 표면과 겹치면 z-파이팅으로 지글거린다).
const Y_SAND := 0.03
const Y_EDGE := 0.025

var _cfg: Dictionary = {}
var _phys: Dictionary = {}
var _slide: Dictionary = {}
var _swing: Dictionary = {}
var _carousel: Dictionary = {}
var _seesaw: Dictionary = {}

var _seesaw_plank: Node3D = null
var _carousel_deck: Node3D = null
var _seesaw_angle := 0.0
var _carousel_angle := 0.0

func setup(cfg: Dictionary, phys: Dictionary) -> void:
	_cfg = cfg
	_phys = phys
	_slide = cfg.get("slide", {})
	_swing = cfg.get("swing", {})
	_carousel = cfg.get("carousel", {})
	_seesaw = cfg.get("seesaw", {})

func _ready() -> void:
	if _cfg.is_empty():
		push_warning("park 설정이 없어 놀이터를 만들지 못했다(data/world.json)")
		return
	_build_sand()
	_build_slide()
	_build_swing()
	_build_carousel()
	_build_seesaw()

# ---------------------------------------------------------------------------
# 바닥 — 모래(사용자 지정)
# ---------------------------------------------------------------------------

func _build_sand() -> void:
	var w := float(_cfg.get("size_x", 16.0))
	var h := float(_cfg.get("size_z", 9.0))
	var cx := float(_cfg.get("x", 0.0))
	var cz := float(_cfg.get("z", 0.0))
	# 테두리를 살짝 크게 깔아 모래가 잔디로 자연스럽게 이어지게 한다.
	_add_plane(Vector3(cx, Y_EDGE, cz), Vector2(w + 1.2, h + 1.2),
		Palette.color("world", "park_edge"))
	_add_plane(Vector3(cx, Y_SAND, cz), Vector2(w, h),
		Palette.color("world", "park_sand"))

func _add_plane(pos: Vector3, size: Vector2, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = size
	mi.mesh = pm
	mi.position = pos
	mi.material_override = _decal_material(color)
	add_child(mi)
	return mi

# ---------------------------------------------------------------------------
# 미끄럼틀
# ---------------------------------------------------------------------------

func slide_ladder() -> Vector3:
	return Vector3(float(_slide.get("ladder_x", 0.0)), 0.0, float(_slide.get("ladder_z", 0.0)))

func slide_top() -> Vector3:
	return Vector3(float(_slide.get("top_x", 0.0)), 0.0, float(_slide.get("top_z", 0.0)))

func slide_exit() -> Vector3:
	return Vector3(float(_slide.get("exit_x", 0.0)), 0.0, float(_slide.get("exit_z", 0.0)))

func slide_height() -> float:
	return float(_slide.get("height", 2.0))

## 타는 경로: 사다리 → 위 → 출구. Player.move_to가 쓰는 것과 같은 형식이다.
func slide_path() -> Array[Vector3]:
	var out: Array[Vector3] = []
	out.append(slide_top())
	out.append(slide_exit())
	return out

## **높이를 위치의 함수로 준다.** 이렇게 해야 남의 화면에서도 같은 높이로 보인다
## (진행도를 따로 동기화할 필요가 없다 — 위치는 어차피 방송된다).
func height_at(pos: Vector3) -> float:
	var ladder := slide_ladder()
	var top := slide_top()
	var exit_p := slide_exit()
	# **내려가는 구간을 먼저 본다.** 사다리와 미끄럼면이 같은 직선 위에 있어서
	# (같은 x), 진행도를 0~1로 자르면 상단을 지난 지점도 올라가는 구간에 t=1로
	# 걸린다 — 내려가기 시작한 1유닛 동안 최고 높이에 붙어 있다가 뚝 떨어졌다
	# (리뷰 지적). 그래서 자르지 않고 **구간 안에 있는지**로 판정한다.
	var down := _progress_on(pos, top, exit_p)
	if down >= 0.0:
		return slide_height() * (1.0 - down)
	var climb := _progress_on(pos, ladder, top)
	if climb >= 0.0:
		return slide_height() * climb
	return 0.0

## 선분 위 진행도(0~1). 선분에서 너무 멀면 -1.
func _progress_on(pos: Vector3, from: Vector3, to: Vector3) -> float:
	var seg := Vector2(to.x - from.x, to.z - from.z)
	var len2 := seg.length_squared()
	if len2 < 0.0001:
		return -1.0
	var rel := Vector2(pos.x - from.x, pos.z - from.z)
	# 자르지 않는다 — 구간 **밖**이면 -1을 돌려줘야 한다(위 height_at 주석).
	var t := rel.dot(seg) / len2
	if t < -0.02 or t > 1.02:
		return -1.0
	t = clampf(t, 0.0, 1.0)
	if rel.distance_to(seg * t) > float(_slide.get("width", 1.0)) * 0.9:
		return -1.0
	return t

func _build_slide() -> void:
	if _slide.is_empty():
		return
	var frame := _flat_material(Palette.color("world", "slide_frame"))
	var surface := _flat_material(Palette.color("world", "slide_surface"))
	var ladder := slide_ladder()
	var top := slide_top()
	var exit_p := slide_exit()
	var height := slide_height()
	var width := float(_slide.get("width", 1.0))

	# 기둥 네 개(위 발판을 받친다)
	for dx: float in [-width * 0.5, width * 0.5]:
		for target: Vector3 in [ladder, top]:
			_add_box(Vector3(target.x + dx, height * 0.5, target.z),
				Vector3(0.12, height, 0.12), frame)
	# 위 발판
	_add_box(Vector3(top.x, height, top.z), Vector3(width + 0.2, 0.12, 1.2), frame)
	# 사다리 발판들
	var steps := 4
	for i in steps:
		var y := height * float(i + 1) / float(steps + 1)
		_add_box(Vector3(ladder.x, y, ladder.z), Vector3(width, 0.08, 0.16), frame)

	# 미끄러지는 면 — 위 발판에서 출구까지 기울어진 판
	var span := Vector2(exit_p.x - top.x, exit_p.z - top.z)
	var run := span.length()
	if run > 0.01:
		# **오일러 각을 직접 계산하지 않는다.** 진행 방향과 경사를 각각 atan2로
		# 넣으면 축 순서·부호에 따라 반대로 기울어진다(실측: 경사면이 위로
		# 솟았다). 위 발판 끝에서 출구 바닥을 바라보게 하면 한 번에 맞는다.
		var high := Vector3(top.x, height, top.z)
		var low := Vector3(exit_p.x, 0.0, exit_p.z)
		var mid := (high + low) * 0.5
		var length := high.distance_to(low)
		var slope := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(width, 0.1, length)
		slope.mesh = bm
		slope.material_override = surface
		add_child(slope)
		# look_at은 -Z를 목표로 향하게 한다 — 길이가 Z축인 박스와 맞는다.
		slope.look_at_from_position(mid, low, Vector3.UP)
		# 옆 난간
		var side_dir := Vector3(span.y, 0.0, -span.x).normalized()
		for side: float in [-1.0, 1.0]:
			var rail := MeshInstance3D.new()
			var rm := BoxMesh.new()
			rm.size = Vector3(0.1, 0.34, length)
			rail.mesh = rm
			rail.material_override = frame
			add_child(rail)
			var at := mid + side_dir * (width * 0.5 * side) + Vector3(0, 0.2, 0)
			rail.look_at_from_position(at, at + (low - high), Vector3.UP)

# ---------------------------------------------------------------------------
# 그네
# ---------------------------------------------------------------------------

func swing_seats() -> int:
	return maxi(int(_swing.get("seats", 2)), 1)

func swing_seat_position(seat: int) -> Vector3:
	var cx := float(_swing.get("x", 0.0))
	var cz := float(_swing.get("z", 0.0))
	var gap := float(_swing.get("seat_gap", 1.6))
	var count := swing_seats()
	# 좌석을 **z축으로** 나란히 두고 흔들림은 x축으로 만든다.
	# 왜: 카메라가 기울어 있어(pitch 55°) z 방향 움직임은 화면에서 눌려 보인다 —
	# z로 흔들면 그네가 흔들리는지 알기 어려웠다(실측).
	var offset := (float(seat) - (float(count) - 1.0) * 0.5) * gap
	return Vector3(cx, 0.0, cz + offset)

func _build_swing() -> void:
	if _swing.is_empty():
		return
	var frame := _flat_material(Palette.color("world", "swing_frame"))
	var rope_mat := _flat_material(Palette.color("world", "swing_rope"))
	var seat_mat := _flat_material(Palette.color("world", "swing_seat"))
	var height := float(_swing.get("height", 2.4))
	var count := swing_seats()
	var near := swing_seat_position(0)
	var far := swing_seat_position(count - 1)
	var bar_len := absf(far.z - near.z) + 1.6

	# A프레임 두 쌍 — 흔드는 방향(x)으로 다리를 벌려 세운다.
	for at: Vector3 in [near, far]:
		for dx: float in [-0.6, 0.6]:
			var leg := MeshInstance3D.new()
			var lm := BoxMesh.new()
			lm.size = Vector3(0.12, height, 0.12)
			leg.mesh = lm
			leg.material_override = frame
			leg.position = Vector3(at.x + dx, height * 0.5, at.z)
			leg.rotation = Vector3(0, 0, atan2(dx, height))
			add_child(leg)
	# 위 가로대(z축)
	_add_box(Vector3(near.x, height, (near.z + far.z) * 0.5),
		Vector3(0.14, 0.14, bar_len), frame)
	# 줄과 안장(정지 상태 기준 — 흔들림은 캐릭터 오프셋으로 표현한다)
	for seat in count:
		var pos := swing_seat_position(seat)
		var rope := float(_swing.get("rope", 1.9))
		for dz: float in [-0.22, 0.22]:
			_add_box(Vector3(pos.x, height - rope * 0.5, pos.z + dz),
				Vector3(0.05, rope, 0.05), rope_mat)
		_add_box(Vector3(pos.x, height - rope, pos.z), Vector3(0.34, 0.08, 0.6), seat_mat)

# ---------------------------------------------------------------------------
# 뺑뺑이(회전무대)
# ---------------------------------------------------------------------------

func carousel_center() -> Vector3:
	return Vector3(float(_carousel.get("x", 0.0)), 0.0, float(_carousel.get("z", 0.0)))

func carousel_radius() -> float:
	return float(_carousel.get("radius", 2.0))

func carousel_slots() -> int:
	return maxi(int(_carousel.get("slots", 4)), 1)

## 슬롯의 **논리 위치**(고정). 보이는 위치는 rider_offset이 돌린다.
func carousel_slot_position(slot: int) -> Vector3:
	var center := carousel_center()
	var th := TAU * float(slot) / float(carousel_slots())
	# 테두리에서 안쪽으로 들어와 서는 거리 — **서버도 같은 값으로 좌석을 계산**
	# 하므로(좌석 고정) 데이터에서 읽어야 한다. 여기만 상수로 두면 값을 바꿀 때
	# 앉은 자리가 어긋난다.
	var r := carousel_radius() - float(_carousel.get("slot_inset", 0.35))
	return center + Vector3(cos(th) * r, 0.0, sin(th) * r)

func _build_carousel() -> void:
	if _carousel.is_empty():
		return
	var center := carousel_center()
	var r := carousel_radius()
	_carousel_deck = Node3D.new()
	_carousel_deck.position = center
	add_child(_carousel_deck)

	var deck := MeshInstance3D.new()
	var dm := CylinderMesh.new()
	dm.top_radius = r
	dm.bottom_radius = r * 0.95
	dm.height = 0.22
	dm.radial_segments = 20
	deck.mesh = dm
	deck.material_override = _flat_material(Palette.color("world", "carousel_deck"))
	deck.position = Vector3(0, 0.11, 0)
	_carousel_deck.add_child(deck)

	# 손잡이 — 슬롯마다 하나. 돌아가는 게 보이는 유일한 단서라 꼭 필요하다.
	# 서는 자리(slot_inset)와 같은 반지름에 둔다 — 상수로 두면 slot_inset을
	# 바꿀 때 타는 사람이 손잡이에서 떨어져 선다.
	var bar := _flat_material(Palette.color("world", "carousel_bar"))
	var grip_r := r - float(_carousel.get("slot_inset", 0.35))
	for slot in carousel_slots():
		var th := TAU * float(slot) / float(carousel_slots())
		var at := Vector3(cos(th) * grip_r, 0.0, sin(th) * grip_r)
		var post := MeshInstance3D.new()
		var pm := BoxMesh.new()
		pm.size = Vector3(0.1, 0.95, 0.1)
		post.mesh = pm
		post.material_override = bar
		post.position = at + Vector3(0, 0.6, 0)
		_carousel_deck.add_child(post)
		var top_bar := MeshInstance3D.new()
		var tm := BoxMesh.new()
		tm.size = Vector3(0.5, 0.09, 0.09)
		top_bar.mesh = tm
		top_bar.material_override = bar
		top_bar.position = at + Vector3(0, 1.05, 0)
		top_bar.rotation.y = -th
		_carousel_deck.add_child(top_bar)

	# 가운데 기둥
	_add_box(center + Vector3(0, 0.55, 0), Vector3(0.16, 1.1, 0.16), bar)

# ---------------------------------------------------------------------------
# 시소
# ---------------------------------------------------------------------------

func seesaw_center() -> Vector3:
	return Vector3(float(_seesaw.get("x", 0.0)), 0.0, float(_seesaw.get("z", 0.0)))

func seesaw_arm() -> float:
	return float(_seesaw.get("arm", 1.6))

## 자리 0은 -x쪽, 자리 1은 +x쪽.
##
## x축으로 두는 이유: 기울기가 화면에서 바로 보여야 한다. z축으로 두면 카메라
## pitch 때문에 눌려서 누가 위에 있는지 알기 어려웠다(실측).
func seesaw_seat_position(seat: int) -> Vector3:
	var sign_x := -1.0 if seat == 0 else 1.0
	return seesaw_center() + Vector3(seesaw_arm() * sign_x, 0.0, 0.0)

func _build_seesaw() -> void:
	if _seesaw.is_empty():
		return
	var center := seesaw_center()
	var height := float(_seesaw.get("height", 0.7))
	# 받침
	_add_box(center + Vector3(0, height * 0.5, 0), Vector3(0.5, height, 0.6),
		_flat_material(Palette.color("world", "seesaw_pivot")))
	# 판(기울어진다) — 회전축이 받침 위에 오도록 부모 노드를 둔다.
	_seesaw_plank = Node3D.new()
	_seesaw_plank.position = center + Vector3(0, height, 0)
	add_child(_seesaw_plank)
	var plank := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(seesaw_arm() * 2.0 + 0.4, 0.12, 0.7)
	plank.mesh = bm
	plank.material_override = _flat_material(Palette.color("world", "seesaw_plank"))
	_seesaw_plank.add_child(plank)
	# 양쪽 손잡이
	for seat in 2:
		var sign_x := -1.0 if seat == 0 else 1.0
		var grip := MeshInstance3D.new()
		var gm := BoxMesh.new()
		gm.size = Vector3(0.09, 0.3, 0.5)
		grip.mesh = gm
		grip.material_override = _flat_material(Palette.color("world", "carousel_bar"))
		grip.position = Vector3(seesaw_arm() * sign_x * 0.72, 0.2, 0)
		_seesaw_plank.add_child(grip)

# ---------------------------------------------------------------------------
# 서버 상태 반영
# ---------------------------------------------------------------------------

func set_state(state: Dictionary) -> void:
	_seesaw_angle = float(state.get("seesaw", 0.0))
	_carousel_angle = float(state.get("carousel", 0.0))
	if _seesaw_plank != null:
		# +각이면 자리 1(+x)이 올라간다. 판이 x축이므로 Z축 회전이다.
		_seesaw_plank.rotation.z = _seesaw_angle
	if _carousel_deck != null:
		_carousel_deck.rotation.y = _carousel_angle

func seesaw_angle() -> float:
	return _seesaw_angle

func carousel_angle() -> float:
	return _carousel_angle

# ---------------------------------------------------------------------------
# 타고 있는 사람의 **보이는 위치 오프셋**
# ---------------------------------------------------------------------------

## kind/seat/논리 위치로 스프라이트를 얼마나 옮겨 그릴지 정한다.
## 남의 캐릭터에도 같은 함수를 쓰므로 화면이 일치한다.
func rider_offset(kind: String, seat: int, logical: Vector3, amp_step: int) -> Vector3:
	match kind:
		"slide":
			return Vector3(0, height_at(logical), 0)
		"swing":
			var rope := float(_swing.get("rope", 1.9))
			var height := float(_swing.get("height", 2.4))
			var steps: Array = _phys.get("swing_amp_steps", [0.28, 0.55, 0.85])
			var amp := float(steps[clampi(amp_step, 0, steps.size() - 1)]) if steps.size() > 0 else 0.5
			var period := maxf(float(_phys.get("swing_period_sec", 2.2)), 0.2)
			var phase := TAU * (float(Time.get_ticks_msec()) / 1000.0) / period
			var th := amp * sin(phase)
			# 안장 높이에서 시작해 진자처럼 **x축으로** 오간다.
			var seat_y := height - rope
			return Vector3(sin(th) * rope, seat_y + rope - cos(th) * rope, 0.0)
		"carousel":
			var center := carousel_center()
			var rel := logical - center
			# **Godot의 Y축 회전과 같은 부호를 써야 한다.** 발판은 rotation.y로
			# 돌리는데(+θ) 여기서 전치(−θ)를 쓰면 사람이 반대로 돌아, 밀자마자
			# 자기 손잡이에서 두 배 속도로 멀어진다(리뷰 지적).
			# Basis.from_euler(0, θ, 0): (x·cosθ + z·sinθ, y, −x·sinθ + z·cosθ)
			var rotated := Vector3(
				rel.x * cos(_carousel_angle) + rel.z * sin(_carousel_angle),
				0.0,
				-rel.x * sin(_carousel_angle) + rel.z * cos(_carousel_angle))
			# 발판 높이만큼 올라선다.
			return rotated - rel + Vector3(0, 0.22, 0)
		"seesaw":
			var arm := seesaw_arm()
			var height := float(_seesaw.get("height", 0.7))
			var sign_x := -1.0 if seat == 0 else 1.0
			var y := height + arm * sign_x * sin(_seesaw_angle)
			var x := arm * sign_x * (cos(_seesaw_angle) - 1.0)
			return Vector3(x, y, 0.0)
	return Vector3.ZERO

# ---------------------------------------------------------------------------
# 탭 대상 찾기
# ---------------------------------------------------------------------------

## 탭한 지점 근처의 탈 것. 없으면 빈 Dictionary.
## 반환: {kind, seat, position} — position은 걸어가서 앉을 **논리 좌표**다.
func mount_near(point: Vector3) -> Dictionary:
	var best := MOUNT_PICK_RADIUS
	var found := {}
	for m: Dictionary in mount_points():
		var d := Vector2(point.x - m["position"].x, point.z - m["position"].z).length()
		if d < best:
			best = d
			found = m
	return found

func mount_points() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not _slide.is_empty():
		out.append({"kind": "slide", "seat": 0, "position": slide_ladder()})
	if not _swing.is_empty():
		for seat in swing_seats():
			out.append({"kind": "swing", "seat": seat, "position": swing_seat_position(seat)})
	if not _carousel.is_empty():
		for slot in carousel_slots():
			out.append({"kind": "carousel", "seat": slot, "position": carousel_slot_position(slot)})
	if not _seesaw.is_empty():
		for seat in 2:
			out.append({"kind": "seesaw", "seat": seat, "position": seesaw_seat_position(seat)})
	return out

## 그 기구의 좌석 좌표(서버가 배정한 자리로 앉을 때 쓴다).
func seat_position(kind: String, seat: int) -> Vector3:
	match kind:
		"slide":
			return slide_ladder()
		"swing":
			return swing_seat_position(seat)
		"carousel":
			return carousel_slot_position(seat)
		"seesaw":
			return seesaw_seat_position(seat)
	return Vector3.ZERO

# ---------------------------------------------------------------------------

func _add_box(pos: Vector3, size: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
	return mi

func _decal_material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.roughness = 1.0
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

func _flat_material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.roughness = 1.0
	return m
