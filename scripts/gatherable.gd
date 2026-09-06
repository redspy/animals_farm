extends Node3D
class_name Gatherable

## 채집물 하나(나무/조개/잡초). 3D 프리미티브 메시로 만든 실제 3D 오브젝트다 —
## 캐릭터만 2D 빌보드 스프라이트이고 월드는 3D인 2.5D 구성(docs/design.md §2).
## 배치와 재생 시간은 data/gatherables.json이 단일 출처다.

signal gathered(item_id: String)

## 채집 가능 거리(월드 단위). 캐릭터 폭이 약 0.8이므로 한 걸음 거리쯤이다.
const INTERACT_DISTANCE := 1.6

var item_id: String = "wood"
var kind: String = "tree"
## 아이템을 확률 테이블(서버)이 정하는 종류인지 — 오프라인 채집을 막는 데 쓴다.
var table_driven := false
var respawn_sec: float = 30.0
## data/gatherables.json에서의 순서. 서버가 채집물을 식별하는 열쇠다
## (docs/protocol.md의 gather) — 서버와 클라이언트가 같은 데이터를 같은 순서로
## 읽는다는 전제이며, 다르면 엉뚱한 나무가 캐진다.
var index := -1

var _available := true
var _timer := 0.0
## 지금 시간·월에 잡을 것이 있는지(테이블 구동 종류만 의미가 있다).
var _in_season := true
var _season_timer := 0.0
const SEASON_CHECK_SEC := 5.0
var _grown: Node3D = null    # 채집 가능할 때 보이는 부분(나무 몸통은 항상 보임)

## limits는 data/gatherables.json의 "limits"를 그대로 받는다 — 유효범위를
## 코드에 하드코딩하면 데이터 파일이 단일 출처라는 규칙이 깨진다.
func setup(spawn: Dictionary, limits: Dictionary = {}, spawn_index: int = -1) -> void:
	index = spawn_index
	kind = String(spawn.get("kind", "tree"))
	# 낚시터·벌레 스폿은 item이 없다 — 무엇이 잡히는지는 **서버가** 확률
	# 테이블로 정한다(data/gatherables.json의 catch_tables). 종류 목록을
	# 하드코딩하지 않는 이유: 서버는 catch_tables의 키를 단일 출처로 쓰므로,
	# 여기에 ["fishing","bug"]를 박으면 세 번째 종류를 추가하는 순간 서버는
	# item을 비우고 클라이언트는 "wood"를 넣어 갈린다.
	table_driven = CatchTable.is_table_kind(kind)
	item_id = String(spawn.get("item", "" if table_driven else "wood"))
	respawn_sec = Balance.clamp_value(
		float(spawn.get("respawn_sec", 30.0)),
		limits.get("respawn_sec", null),
		# 라벨에 kind와 순번을 쓴다 — item_id는 테이블 구동 스폰에서 비어 있어서
		# 데이터 오타 경고가 ".respawn_sec"가 되고 어느 스폰인지 알 수 없었다.
		"%s[%d].respawn_sec" % [kind, spawn_index],
		"duration_sec"
	)
	position = Vector3(float(spawn.get("x", 0.0)), 0.0, float(spawn.get("z", 0.0)))
	_build_mesh()
	_refresh_season_visibility()
	# 시즌 판정이 필요 없는 종류(나무·조개·잡초)는 시간 검사를 돌리지 않는다.
	# 재생 타이머는 `hide_until`/`gather`에서 다시 켠다.
	set_process(table_driven)

func _build_mesh() -> void:
	match kind:
		"tree":
			# 몸통은 채집해도 남는다 — 위치를 기억할 수 있게 해야 다시 찾아온다.
			var trunk := MeshInstance3D.new()
			var trunk_mesh := CylinderMesh.new()
			trunk_mesh.top_radius = 0.14
			trunk_mesh.bottom_radius = 0.2
			trunk_mesh.height = 1.1
			trunk_mesh.radial_segments = 8
			trunk.mesh = trunk_mesh
			trunk.position = Vector3(0, 0.55, 0)
			trunk.material_override = _material(Palette.color("world", "tree_trunk"))
			add_child(trunk)

			_grown = Node3D.new()
			add_child(_grown)
			var canopy := MeshInstance3D.new()
			var canopy_mesh := SphereMesh.new()
			canopy_mesh.radius = 0.95
			canopy_mesh.height = 1.7
			canopy_mesh.radial_segments = 12
			canopy_mesh.rings = 6
			canopy.mesh = canopy_mesh
			canopy.position = Vector3(0, 1.7, 0)
			canopy.material_override = _material(Palette.color("world", "tree_canopy"))
			_grown.add_child(canopy)
		"shell":
			_grown = Node3D.new()
			add_child(_grown)
			var shell := MeshInstance3D.new()
			var shell_mesh := SphereMesh.new()
			shell_mesh.radius = 0.22
			shell_mesh.height = 0.26
			shell_mesh.radial_segments = 10
			shell_mesh.rings = 4
			shell.mesh = shell_mesh
			shell.position = Vector3(0, 0.1, 0)
			shell.material_override = _material(Palette.color("world", "shell"))
			_grown.add_child(shell)
		"fishing":
			# 낚시터는 **물빛 원판 + 잔물결 링 2개**다. 채집해도 자리는 남아야
			# 하므로(다시 찾아올 수 있게) 원판은 항상 보이고, 링만 감춘다.
			var pond := MeshInstance3D.new()
			var pond_mesh := CylinderMesh.new()
			pond_mesh.top_radius = 0.95
			pond_mesh.bottom_radius = 0.95
			pond_mesh.height = 0.06
			pond_mesh.radial_segments = 16
			pond.mesh = pond_mesh
			pond.position = Vector3(0, 0.03, 0)
			pond.material_override = _material(Palette.color("world", "fishing_water"))
			add_child(pond)

			_grown = Node3D.new()
			add_child(_grown)
			var ripple_color := Palette.color("world", "fishing_ripple")
			for i in 2:
				var ring := MeshInstance3D.new()
				var ring_mesh := TorusMesh.new()
				ring_mesh.inner_radius = 0.22 + 0.26 * i
				ring_mesh.outer_radius = 0.28 + 0.26 * i
				ring_mesh.rings = 12
				ring_mesh.ring_segments = 6
				ring.mesh = ring_mesh
				ring.position = Vector3(0, 0.07, 0)
				ring.material_override = _material(ripple_color)
				_grown.add_child(ring)
		"bug":
			# 벌레 스폿은 꽃 3점 + 그 위 벌레 한 마리. 꽃은 남고 벌레만 사라진다.
			var stem_color := Palette.color("world", "flower_stem")
			var petal_color := Palette.color("world", "flower_petal")
			for i in 3:
				var stem := MeshInstance3D.new()
				var stem_mesh := BoxMesh.new()
				stem_mesh.size = Vector3(0.05, 0.34, 0.05)
				stem.mesh = stem_mesh
				stem.position = Vector3(-0.22 + 0.22 * i, 0.17, 0.08 * i)
				stem.material_override = _material(stem_color)
				add_child(stem)
				var petal := MeshInstance3D.new()
				var petal_mesh := SphereMesh.new()
				petal_mesh.radius = 0.11
				petal_mesh.height = 0.14
				petal_mesh.radial_segments = 8
				petal_mesh.rings = 3
				petal.mesh = petal_mesh
				petal.position = Vector3(-0.22 + 0.22 * i, 0.38, 0.08 * i)
				petal.material_override = _material(petal_color)
				add_child(petal)

			_grown = Node3D.new()
			add_child(_grown)
			var bug := MeshInstance3D.new()
			var bug_mesh := SphereMesh.new()
			bug_mesh.radius = 0.1
			bug_mesh.height = 0.16
			bug_mesh.radial_segments = 8
			bug_mesh.rings = 4
			bug.mesh = bug_mesh
			bug.position = Vector3(0, 0.62, 0)
			bug.material_override = _material(Palette.color("world", "bug_body"))
			_grown.add_child(bug)
		_:
			_grown = Node3D.new()
			add_child(_grown)
			# 잡초는 얇은 판 3장을 엇갈려 세워 풀 느낌만 낸다(그레이박스).
			# 잡초 색은 3장이 같으므로 루프 밖에서 한 번만 읽는다.
			var weed_color := Palette.color("world", "weed")
			for i in 3:
				var blade := MeshInstance3D.new()
				var blade_mesh := BoxMesh.new()
				blade_mesh.size = Vector3(0.06, 0.42, 0.06)
				blade.mesh = blade_mesh
				blade.position = Vector3(-0.12 + 0.12 * i, 0.21, 0.05 * i)
				blade.rotation_degrees = Vector3(0, 0, -12 + 12 * i)
				blade.material_override = _material(weed_color)
				_grown.add_child(blade)

## 색이 같으면 머티리얼을 **공유한다**.
##
## 왜: 호출마다 새로 만들면 채집물 58곳 × 메시 2~7개 = 머티리얼 100개가 넘고,
## 웹(GL Compatibility)에서 머티리얼은 곧 상태 변경/드로우콜이라 폰 프레임에
## 보인다(리뷰 지적). 색 종류는 10개 미만이다.
static var _mat_cache: Dictionary = {}

func _material(color: Color) -> StandardMaterial3D:
	var key := color.to_rgba32()
	var cached: Variant = _mat_cache.get(key)
	if cached != null:
		return cached
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	# 웹(GL Compatibility)에서 가볍게 유지 — 스페큘러를 끄고 확산광만 쓴다.
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.roughness = 1.0
	_mat_cache[key] = m
	return m

## ⚠️ 캐시된 머티리얼은 **인스턴스 사이에서 공유된다.** 나중에 개별 채집물을
## 강조하려고 `material_override.albedo_color`를 바꾸면 같은 색 전부가 바뀐다 —
## 그때는 `duplicate()`한 사본을 써야 한다.

func is_available() -> bool:
	return _available

## 지금 실제로 잡을 수 있는지 — 재생 완료 **그리고** 시간·월 조건 충족.
##
## `is_available()`과 나누어 둔 이유: 탭 대상 선별과 토스트 문구가 두 사유를
## 구분해야 한다. "아직 자라지 않았다"와 "지금은 아무것도 없다"는 다른 상황이고,
## 시즌 밖 스폿을 탭 대상으로 남기면 발밑에 두고 "조금 더 가까이 가야 합니다"가
## 무한 반복된다(리뷰 지적 — 꽃은 남고 벌레만 숨기 때문에 여전히 탭된다).
func is_catchable_now() -> bool:
	return _available and _in_season

## 지금 시간·월에 잡을 것이 있는지(테이블 구동 종류만 의미가 있다).
func is_in_season() -> bool:
	return _in_season

func can_interact(from: Vector3) -> bool:
	if not _available or not _in_season:
		return false
	# 높이 차이는 무시하고 바닥 평면(XZ)에서만 거리를 잰다.
	var a := Vector2(from.x, from.z)
	var b := Vector2(global_position.x, global_position.z)
	return a.distance_to(b) <= INTERACT_DISTANCE

func gather() -> bool:
	if not _available:
		return false
	set_process(true)   # 재생 타이머를 돌려야 한다
	# **빈 아이템은 애초에 캐지 않는다.** 낚시터·벌레는 무엇이 잡히는지 서버가
	# 정하므로(item_id가 비어 있다) 오프라인에서 캐면 자리만 소모하고 아무것도
	# 주지 않는다. 호출자 쪽 가드만 두면 세 번째 호출자가 생길 때 조용히 회귀한다.
	if item_id.is_empty():
		return false
	_available = false
	_timer = respawn_sec
	if _grown != null:
		_grown.visible = false
	gathered.emit(item_id)
	return true

## 서버가 알려준 재생 시각까지 감춘다. 서버에 붙어 있는 동안에는 로컬 타이머가
## 아니라 이 값이 진실이다 — 두 시계가 다르면 어떤 사람에게는 있고 어떤 사람에게는
## 없는 나무가 생긴다.
func hide_until(seconds_from_now: float) -> void:
	set_process(true)   # 재생 타이머를 돌려야 한다
	_available = false
	_timer = maxf(seconds_from_now, 0.0)
	if _grown != null:
		_grown.visible = false

## 하루가 지나면 전부 되살아난다(GameClock.days_since 기반, main.gd에서 호출).
func force_respawn() -> void:
	if _available:
		return
	_available = true
	_timer = 0.0
	if _grown != null:
		_grown.visible = _in_season if table_driven else true
	set_process(table_driven)

## 지금 시간·월에 잡을 것이 있는지 확인해 **표시**를 맞춘다.
##
## 왜 필요한가: 서버는 조건 밖이면 거절하는데, 화면에 벌레가 그대로 있으면
## 플레이어는 걸어가서 거절당하고 이유를 알 수 없다(리뷰 지적).
func _refresh_season_visibility() -> void:
	if not table_driven or _grown == null:
		return
	_in_season = CatchTable.any_available(kind)
	if _available:
		_grown.visible = _in_season

func _process(delta: float) -> void:
	# 시간대 판정은 자주 볼 필요가 없다(시각이 분 단위로 바뀐다).
	_season_timer -= delta
	if _season_timer <= 0.0:
		_season_timer = SEASON_CHECK_SEC
		_refresh_season_visibility()
	if _available:
		return
	_timer -= delta
	if _timer <= 0.0:
		force_respawn()
