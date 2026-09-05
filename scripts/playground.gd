class_name Playground
extends Node3D

## 운동장 — 달걀 모양 트랙과 축구장.
##
## 크기는 `data/world.json`의 `playground`가 단일 출처다(트랙과 축구장이 각각
## 섬 면적의 1/6). 코드에 숫자를 박으면 밸런스 데이터 규칙(AGENTS.md)을 어기고,
## 서버도 같은 파일을 읽으므로 두 곳이 갈린다.
##
## 왜 텍스처가 아니라 메시인가: 트랙 레인 경계가 선명해야 "여기가 자전거 레인,
## 여기가 인라인 레인"이 한눈에 읽힌다. 텍스처로 깔면 21×14 유닛을 덮는 데
## 큰 이미지가 필요하고 확대하면 경계가 뭉개진다. 링 하나가 삼각형 몇십 개라
## 폰에서도 부담이 없다.
##
## 레인 배치(사용자 지정): **바깥 둘레가 초록(자전거), 안쪽이 빨강(인라인).**

## 달걀 모양의 정도. 0이면 정타원, 크면 한쪽 끝이 좁아진다.
const RING_SEGMENTS := 96
## 바닥 데칼 높이 — 섬 표면(y=0)과 겹치면 z-파이팅으로 지글거린다.
const Y_TRACK := 0.02
const Y_FIELD := 0.02
const Y_LINE := 0.035
const LANE_LINE_W := 0.12
## 골대
const GOAL_HEIGHT := 1.7
const POST_THICK := 0.14
## 공
const BALL_RADIUS := 0.3

var _cfg: Dictionary = {}
var _track: Dictionary = {}
var _field: Dictionary = {}
var _soccer_root: Node3D = null
var _ball: Node3D = null
var _ball_target := Vector3.ZERO

func setup(cfg: Dictionary) -> void:
	_cfg = cfg
	_track = cfg.get("track", {})
	_field = cfg.get("field", {})

func _ready() -> void:
	if _track.is_empty() or _field.is_empty():
		push_warning("playground 설정이 없어 운동장을 만들지 못했다(data/world.json)")
		return
	_build_track()
	_build_field()
	_build_soccer_props()

# ---------------------------------------------------------------------------
# 트랙
# ---------------------------------------------------------------------------

## 달걀 곡선. t는 반지름 비율(0~1), th는 각도.
## z 반지름을 cos(th)로 살짝 줄여 한쪽 끝이 좁은 달걀이 된다.
func _egg_point(t: float, th: float) -> Vector3:
	var a := float(_track.get("outer_a", 10.0))
	var b := float(_track.get("outer_b", 7.0))
	var egg := float(_track.get("egg", 0.0))
	var cx := float(_track.get("x", 0.0))
	var cz := float(_track.get("z", 0.0))
	var c := cos(th)
	return Vector3(cx + t * a * c, 0.0, cz + t * b * sin(th) * (1.0 - egg * c))

func _build_track() -> void:
	var a := float(_track.get("outer_a", 10.0))
	var lane := float(_track.get("lane", 2.2))
	# 레인 경계를 반지름 비율로 바꾼다 — 타원이라 "바깥에서 lane만큼"은
	# 각도에 따라 폭이 달라지지만, 비율로 자르면 트랙처럼 균일하게 보인다.
	var t_bike_in := clampf((a - lane) / a, 0.05, 0.99)
	var t_inline_in := clampf((a - lane * 2.0) / a, 0.02, t_bike_in - 0.02)

	# 안쪽 잔디 → 인라인(빨강) → 자전거(초록) 순으로 깔아 위에 오는 것이 이긴다.
	_add_ring(0.0, t_inline_in, Palette.color("world", "track_infield"), Y_TRACK)
	_add_ring(t_inline_in, t_bike_in, Palette.color("world", "track_inline"), Y_TRACK + 0.002)
	_add_ring(t_bike_in, 1.0, Palette.color("world", "track_bike"), Y_TRACK + 0.004)
	# 레인 구분선 — 두 레인의 색이 비슷하지 않아도, 선이 있으면 "트랙"으로 읽힌다.
	var line := Palette.color("world", "track_line")
	_add_ring(t_bike_in, t_bike_in + LANE_LINE_W / a, line, Y_LINE)
	_add_ring(t_inline_in, t_inline_in + LANE_LINE_W / a, line, Y_LINE)
	_add_ring(1.0 - LANE_LINE_W / a, 1.0, line, Y_LINE)

## t0~t1 사이의 고리(또는 t0=0이면 채워진 면)를 만든다.
func _add_ring(t0: float, t1: float, color: Color, y: float) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var step := TAU / float(RING_SEGMENTS)
	for i in RING_SEGMENTS:
		var th0 := float(i) * step
		var th1 := float(i + 1) * step
		if t0 <= 0.0001:
			# 채워진 면: 중심과 두 점으로 삼각형
			_tri(st, _egg_point(0.0, th0), _egg_point(t1, th0), _egg_point(t1, th1))
		else:
			var o0 := _egg_point(t1, th0)
			var o1 := _egg_point(t1, th1)
			var i0 := _egg_point(t0, th0)
			var i1 := _egg_point(t0, th1)
			_tri(st, i0, o0, o1)
			_tri(st, i0, o1, i1)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _decal_material(color)
	mi.position = Vector3(0, y, 0)
	add_child(mi)

func _tri(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3) -> void:
	for p: Vector3 in [p0, p1, p2]:
		st.set_normal(Vector3.UP)
		st.add_vertex(p)

# ---------------------------------------------------------------------------
# 축구장
# ---------------------------------------------------------------------------

func _build_field() -> void:
	var w := float(_field.get("size_x", 20.0))
	var h := float(_field.get("size_z", 12.0))
	var cx := float(_field.get("x", 0.0))
	var cz := float(_field.get("z", 0.0))

	var grass := MeshInstance3D.new()
	var gm := PlaneMesh.new()
	gm.size = Vector2(w, h)
	grass.mesh = gm
	grass.position = Vector3(cx, Y_FIELD, cz)
	grass.material_override = _decal_material(Palette.color("world", "field_grass"))
	add_child(grass)

	var line := Palette.color("world", "field_line")
	var lw := 0.16
	# 터치라인·골라인
	_add_line(Vector3(cx, Y_LINE, cz - h / 2.0), Vector2(w, lw), line)
	_add_line(Vector3(cx, Y_LINE, cz + h / 2.0), Vector2(w, lw), line)
	_add_line(Vector3(cx - w / 2.0, Y_LINE, cz), Vector2(lw, h), line)
	_add_line(Vector3(cx + w / 2.0, Y_LINE, cz), Vector2(lw, h), line)
	# 중앙선 + 센터서클
	_add_line(Vector3(cx, Y_LINE, cz), Vector2(lw, h), line)
	_add_circle_line(Vector3(cx, Y_LINE, cz), 2.4, lw, line)

func _add_line(pos: Vector3, size: Vector2, color: Color) -> void:
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = size
	mi.mesh = pm
	mi.position = pos
	mi.material_override = _decal_material(color)
	add_child(mi)

func _add_circle_line(center: Vector3, radius: float, width: float, color: Color) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seg := 40
	for i in seg:
		var th0 := TAU * float(i) / float(seg)
		var th1 := TAU * float(i + 1) / float(seg)
		var r0 := radius - width * 0.5
		var r1 := radius + width * 0.5
		var p00 := Vector3(cos(th0) * r0, 0, sin(th0) * r0)
		var p01 := Vector3(cos(th1) * r0, 0, sin(th1) * r0)
		var p10 := Vector3(cos(th0) * r1, 0, sin(th0) * r1)
		var p11 := Vector3(cos(th1) * r1, 0, sin(th1) * r1)
		_tri(st, p00, p10, p11)
		_tri(st, p00, p11, p01)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _decal_material(color)
	mi.position = center
	add_child(mi)

# ---------------------------------------------------------------------------
# 골대와 공 — 축구를 하는 사람이 있을 때만 보인다(사용자 요청:
# "축구 버튼을 누르면 축구 골대와 축구공이 나와").
# ---------------------------------------------------------------------------

func _build_soccer_props() -> void:
	_soccer_root = Node3D.new()
	_soccer_root.visible = false
	add_child(_soccer_root)

	var w := float(_field.get("size_x", 20.0))
	var cx := float(_field.get("x", 0.0))
	var cz := float(_field.get("z", 0.0))
	_add_goal(Vector3(cx - w / 2.0, 0.0, cz), 1.0)
	_add_goal(Vector3(cx + w / 2.0, 0.0, cz), -1.0)

	_ball = Node3D.new()
	var mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = BALL_RADIUS
	sphere.height = BALL_RADIUS * 2.0
	sphere.radial_segments = 14
	sphere.rings = 7
	mesh.mesh = sphere
	mesh.material_override = _flat_material(Palette.color("world", "ball"))
	_ball.add_child(mesh)
	# 무늬: 위쪽에 어두운 원판을 얹어 굴러가는 게 보이게 한다(구는 단색이면
	# 회전이 안 보인다).
	var patch := MeshInstance3D.new()
	var pm := CylinderMesh.new()
	pm.top_radius = BALL_RADIUS * 0.45
	pm.bottom_radius = BALL_RADIUS * 0.45
	pm.height = 0.02
	patch.mesh = pm
	patch.material_override = _flat_material(Palette.color("world", "ball_dark"))
	patch.position = Vector3(0, BALL_RADIUS * 0.92, 0)
	_ball.add_child(patch)
	_ball.position = Vector3(cx, BALL_RADIUS, cz)
	_ball_target = _ball.position
	_soccer_root.add_child(_ball)

## 골대. dir는 골대가 열린 방향(+1이면 +x쪽으로 열림).
func _add_goal(at: Vector3, dir: float) -> void:
	var gw := float(_field.get("goal_width", 4.4))
	var gd := float(_field.get("goal_depth", 1.1))
	var post := _flat_material(Palette.color("world", "goal_post"))

	for side: float in [-1.0, 1.0]:
		var p := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(POST_THICK, GOAL_HEIGHT, POST_THICK)
		p.mesh = bm
		p.material_override = post
		p.position = at + Vector3(0, GOAL_HEIGHT / 2.0, side * gw / 2.0)
		_soccer_root.add_child(p)

	var bar := MeshInstance3D.new()
	var bar_mesh := BoxMesh.new()
	bar_mesh.size = Vector3(POST_THICK, POST_THICK, gw + POST_THICK)
	bar.mesh = bar_mesh
	bar.material_override = post
	bar.position = at + Vector3(0, GOAL_HEIGHT, 0)
	_soccer_root.add_child(bar)

	# 그물: 골대 **뒤판 한 장 + 옆판 두 장**으로 대신한다. 골대 안쪽을 채우는
	# 상자로 두면 반투명이 두 번 겹쳐 흐린 안개 상자처럼 보였다(2026-09-05 실측).
	var net := MeshInstance3D.new()
	var nm := BoxMesh.new()
	nm.size = Vector3(0.12, GOAL_HEIGHT, gw)
	net.mesh = nm
	var m := StandardMaterial3D.new()
	m.albedo_color = Palette.color("world", "goal_net")
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	net.material_override = m
	net.position = at + Vector3(dir * -gd, GOAL_HEIGHT / 2.0, 0)
	_soccer_root.add_child(net)

	for side: float in [-1.0, 1.0]:
		var wing := MeshInstance3D.new()
		var wm := BoxMesh.new()
		wm.size = Vector3(gd, GOAL_HEIGHT, 0.12)
		wing.mesh = wm
		wing.material_override = m
		wing.position = at + Vector3(dir * -gd / 2.0, GOAL_HEIGHT / 2.0, side * gw / 2.0)
		_soccer_root.add_child(wing)

func set_soccer_visible(on: bool) -> void:
	if _soccer_root != null:
		_soccer_root.visible = on

func soccer_visible() -> bool:
	return _soccer_root != null and _soccer_root.visible

## 서버가 보낸 공 위치. 10Hz로 오므로 그대로 넣으면 뚝뚝 끊긴다 — 목표만
## 기록하고 _process에서 따라가게 한다(남의 캐릭터와 같은 방식).
func set_ball(x: float, z: float) -> void:
	_ball_target = Vector3(x, BALL_RADIUS, z)

func ball_position() -> Vector3:
	return _ball.position if _ball != null else Vector3.ZERO

func _process(delta: float) -> void:
	if _ball == null or not soccer_visible():
		return
	_ball.position = _ball.position.lerp(_ball_target, clampf(delta * 14.0, 0.0, 1.0))
	# 굴러가는 느낌 — 이동 방향과 거리에 비례해 굴린다.
	var to := _ball_target - _ball.position
	if to.length() > 0.001:
		_ball.rotate_z(-to.x / BALL_RADIUS * delta * 6.0)
		_ball.rotate_x(to.z / BALL_RADIUS * delta * 6.0)

# ---------------------------------------------------------------------------

func _decal_material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.roughness = 1.0
	# 바닥 데칼은 양면으로 둔다 — 링 메시의 감김 방향을 신경 쓰지 않아도 된다.
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

func _flat_material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.roughness = 1.0
	return m
