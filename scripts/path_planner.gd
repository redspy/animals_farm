extends RefCounted
class_name PathPlanner

## 직선 경로가 바위에 막히면 **짧은 쪽으로 돌아가는** 경로를 만든다.
##
## 지원하는 장애물 모양: **원**(`shape: "circle"`, radius)과 **축 정렬 박스**
## (`shape: "box"`, size_x/size_z). 둘 다 data/world.json이 소유한다.
##
## 왜 NavigationServer3D 내비메시가 아닌가(2026-09-04 실측 근거):
## 런타임 베이크 자체는 된다(폴리곤 생성 확인, 6ms). 그런데 베이크한 내비메시를
## 맵에 올려도 `map_get_closest_point`가 원점을 돌려주고 `map_get_path`가 빈
## 배열을 주는 상태가 재현됐다 — 맵은 active이고 region은 1개로 잡히는데
## 폴리곤이 실제로 등록되지 않았다. 게다가 Godot 자신이 "런타임 메시 파싱은
## GPU→CPU 전송으로 렌더를 막는다"고 경고한다(웹 nothreads에서 특히 부담).
## 그래서 지금은 **기하 계산으로 원·박스를 직접 회피**하고, 내비메시는 다음
## 조건이 생길 때 다시 검토한다: (a) 임의 다각형/곡선 장애물, (b) 층·경사로 등
## 다층 지형, (c) 장애물 수가 수백 개.
##
## 좌표는 XZ 평면만 쓴다(y는 항상 0).

## 우회를 몇 번까지 반복할지. 바위가 연달아 놓여 있으면 여러 번 필요하지만,
## 상한이 없으면 배치가 나쁠 때 무한 루프가 된다.
const MAX_DETOURS := 4
## 모서리 접촉을 "막힘"으로 보지 않기 위한 판정 여유.
const CORNER_EPS := 0.05
## 호 하나를 최대 몇 점으로 쪼갤지. 이 상한이 있어야 "경로 길이가 유한하다"는
## 보장이 생긴다(최대 MAX_DETOURS × ARC_MAX_POINTS + 1).
const ARC_MAX_POINTS := 10
## 바위 표면에서 이만큼 더 떨어져 지나간다 — 딱 접선으로 지나가면 부동소수
## 오차로 표면을 스치며 밀려난다.
const CLEARANCE := 0.25

## obstacles: [{ "x", "z", "shape"("circle"|"box"), "radius" 또는 "size_x"/"size_z" }, ...]
## 반환: 목표까지의 경유지 배열(마지막 원소가 목표). 막히지 않으면 [to] 하나.
##
## 방식: 막는 원을 **접선으로 올라타 호를 따라 돌아** 반대편 접점에서 목표로
## 향한다. 처음에는 원 중심을 선분에 투영한 점에서 좌우로 밀어낸 경유지 하나만
## 썼는데, 그러면 (a) 출발/목표로 향하는 구간이 모서리를 스쳐 원을 파고들고
## (b) 좌우 후보가 대칭이 되어 "짧은 쪽" 판정이 무의미해졌다(테스트에서 실측).
static func plan(from: Vector3, to: Vector3, obstacles: Array, agent_radius: float) -> Array[Vector3]:
	var path: Array[Vector3] = []
	var start := Vector2(from.x, from.z)
	var goal := Vector2(to.x, to.z)

	for _i in MAX_DETOURS:
		var blocking := first_blocking(start, goal, obstacles, agent_radius)
		if blocking.is_empty():
			path.append(Vector3(goal.x, 0.0, goal.y))
			return path

		var center := Vector2(float(blocking["x"]), float(blocking["z"]))
		var detour: Array[Vector2] = []
		if String(blocking.get("shape", "circle")) == "box":
			var half := Vector2(float(blocking["size_x"]), float(blocking["size_z"])) * 0.5
			detour = _around_box(start, goal, center, half + Vector2(agent_radius + CLEARANCE, agent_radius + CLEARANCE))
		else:
			var r := float(blocking["radius"]) + agent_radius + CLEARANCE
			detour = _around(start, goal, center, r)
		if detour.is_empty():
			# 접선을 구할 수 없는 배치(출발/목표가 원 안 등) — 목표로 직진해
			# 이동 자체를 포기하지 않는다. 밀림 처리(push_out)가 받아 준다.
			path.append(Vector3(goal.x, 0.0, goal.y))
			return path
		for wp: Vector2 in detour:
			path.append(Vector3(wp.x, 0.0, wp.y))
		start = detour[detour.size() - 1]

	# 상한에 걸렸으면 목표를 그대로 붙인다 — 완벽한 경로를 못 찾았어도 이동
	# 자체를 포기하면 플레이어는 "탭이 먹지 않는다"고 느낀다.
	path.append(Vector3(goal.x, 0.0, goal.y))
	return path

## 선분을 막는 장애물 중 **출발점에서 가장 가까운** 것. 없으면 빈 Dictionary.
## 반환값에는 회피 계산에 필요한 정보(모양·중심·크기)를 담는다.
static func first_blocking(start: Vector2, goal: Vector2, obstacles: Array, agent_radius: float) -> Dictionary:
	var best_t := INF
	var found := {}
	var seg := goal - start
	var seg_len := seg.length()
	if seg_len <= 0.0001:
		return found
	var dir := seg / seg_len

	for o: Variant in obstacles:
		if typeof(o) != TYPE_DICTIONARY:
			continue
		var obs := o as Dictionary
		var center := Vector2(float(obs.get("x", 0.0)), float(obs.get("z", 0.0)))
		var is_box := String(obs.get("shape", "circle")) == "box"
		# 박스는 반지름 대신 바깥 반지름(대각선 절반)으로 선분 접근을 1차 판정한 뒤
		# 정확한 판정을 한다. 원은 그대로.
		var half := Vector2.ZERO
		var radius := 0.0
		if is_box:
			half = Vector2(float(obs.get("size_x", 1.0)), float(obs.get("size_z", 1.0))) * 0.5
			radius = half.length()
		else:
			radius = float(obs.get("radius", 1.0))

		var t := clampf((center - start).dot(dir), 0.0, seg_len)
		var closest := start + dir * t
		var blocks := false
		if is_box:
			blocks = _segment_hits_box(start, goal, center, half + Vector2(agent_radius, agent_radius))
		else:
			blocks = closest.distance_to(center) <= radius + agent_radius

		if not blocks:
			continue
		# 출발점이 이미 장애물 안이면(밀려 들어간 경우) 막는 것으로 보지 않는다 —
		# 그러면 안에서 영원히 우회 경로만 만들게 된다.
		if is_box:
			if _inside_box(start, center, half + Vector2(agent_radius, agent_radius)):
				continue
		elif start.distance_to(center) <= radius + agent_radius:
			continue

		if t < best_t:
			best_t = t
			if is_box:
				found = {"shape": "box", "x": center.x, "z": center.y,
					"size_x": half.x * 2.0, "size_z": half.y * 2.0}
			else:
				found = {"shape": "circle", "x": center.x, "z": center.y, "radius": radius}
	return found

static func _inside_box(p: Vector2, center: Vector2, half: Vector2) -> bool:
	return absf(p.x - center.x) <= half.x and absf(p.y - center.y) <= half.y

## 축 정렬 박스 위의 최근접점.
static func _closest_on_box(p: Vector2, center: Vector2, half: Vector2) -> Vector2:
	return Vector2(
		clampf(p.x, center.x - half.x, center.x + half.x),
		clampf(p.y, center.y - half.y, center.y + half.y)
	)

## 선분이 박스와 겹치는지. 표본이 아니라 분리축(SAT)으로 정확히 판정한다 —
## 표본 방식은 얇고 긴 벽을 통과하는 선분을 놓친다.
static func _segment_hits_box(a: Vector2, b: Vector2, center: Vector2, half: Vector2) -> bool:
	var mid := (a + b) * 0.5 - center
	var dir := (b - a) * 0.5
	var abs_dir := Vector2(absf(dir.x), absf(dir.y))
	if absf(mid.x) > half.x + abs_dir.x:
		return false
	if absf(mid.y) > half.y + abs_dir.y:
		return false
	# 선분 방향의 수직축 투영 검사(2D에서는 이 한 축만 남는다).
	if absf(mid.x * dir.y - mid.y * dir.x) > half.x * abs_dir.y + half.y * abs_dir.x:
		return false
	return true

## 원(center, r)을 돌아가는 경유지들. **좌우 두 방향을 모두 계산해 총 이동거리가
## 짧은 쪽**을 고른다(사용자 요구사항: "거리가 짧은 방향으로 돌아서 간다").
static func _around(start: Vector2, goal: Vector2, center: Vector2, r: float) -> Array[Vector2]:
	var empty: Array[Vector2] = []
	var ds := start.distance_to(center)
	var dg := goal.distance_to(center)
	# 접선은 원 밖의 점에서만 구할 수 있다.
	if ds <= r or dg <= r:
		return empty

	var best_cost := INF
	var best: Array[Vector2] = []
	for side: int in [1, -1]:
		var a_start := _tangent_angle(start, center, r, side)
		var a_goal := _tangent_angle(goal, center, r, -side)
		var arc := _arc_points(center, r, a_start, a_goal, side)
		if arc.is_empty():
			continue
		var cost := start.distance_to(arc[0])
		for i in range(1, arc.size()):
			cost += arc[i - 1].distance_to(arc[i])
		cost += arc[arc.size() - 1].distance_to(goal)
		if cost < best_cost:
			best_cost = cost
			best = arc
	return best

## 박스를 돌아가는 경유지들. 확장된 박스의 **네 모서리 중 어느 쪽으로 도는지**를
## 좌우로 나눠 계산하고, 총 이동거리가 짧은 쪽을 고른다(원과 같은 원칙).
static func _around_box(start: Vector2, goal: Vector2, center: Vector2, half: Vector2) -> Array[Vector2]:
	# 경유지는 확장된 박스 **표면 위**의 모서리라, 그 점을 지나는 선분은 박스와
	# 경계에서 닿는다. 판정용 박스를 살짝 줄이지 않으면 모든 후보가 "막혔다"로
	# 버려져 우회 경로가 아예 만들어지지 않는다(실측: 빈 배열 반환).
	var test_half := half - Vector2(CORNER_EPS, CORNER_EPS)
	var corners: Array[Vector2] = [
		center + Vector2(-half.x, -half.y),
		center + Vector2(half.x, -half.y),
		center + Vector2(half.x, half.y),
		center + Vector2(-half.x, half.y),
	]
	var best_cost := INF
	var best: Array[Vector2] = []
	# 네 모서리에서 시작해 시계/반시계로 돌아가는 경로를 모두 만들어 본다.
	# 모서리 수가 4개뿐이라 전수 탐색이 가장 단순하고 확실하다.
	for start_index in 4:
		for step: int in [1, 3]:   # 1=시계, 3=반시계(=-1 mod 4)
			var route: Array[Vector2] = []
			var index := start_index
			for _hop in 3:          # 최대 3개 모서리를 거치면 어느 쪽으로든 돌 수 있다
				route.append(corners[index])
				# 남은 구간이 더 이상 박스를 지나지 않으면 그만 돈다.
				if not _segment_hits_box(corners[index], goal, center, test_half):
					break
				index = (index + step) % 4
			if _segment_hits_box(route[route.size() - 1], goal, center, test_half):
				continue
			if _segment_hits_box(start, route[0], center, test_half):
				continue
			var cost := start.distance_to(route[0])
			for i in range(1, route.size()):
				cost += route[i - 1].distance_to(route[i])
			cost += route[route.size() - 1].distance_to(goal)
			if cost < best_cost:
				best_cost = cost
				best = route
	return best

## 점 p에서 원(center, r)에 그은 접선의 접점 각도. side로 두 접점 중 하나를 고른다.
static func _tangent_angle(p: Vector2, center: Vector2, r: float, side: int) -> float:
	var to_p := p - center
	var d := to_p.length()
	# acos 인자는 부동소수 오차로 1을 살짝 넘길 수 있어 클램프한다.
	var alpha := acos(clampf(r / d, -1.0, 1.0))
	return to_p.angle() + float(side) * alpha

## 두 접점 사이의 호를 따라가는 점들. 호를 한 번에 직선으로 잇지 않고 쪼개는
## 이유: 긴 호를 직선(현)으로 자르면 그 현이 원 안을 파고든다. 40° 이하로
## 쪼개면 현까지의 거리가 r·cos20° ≈ 0.94r로 남아 CLEARANCE 안에서 안전하다.
static func _arc_points(center: Vector2, r: float, from_angle: float, to_angle: float, side: int) -> Array[Vector2]:
	var span := to_angle - from_angle
	# side 방향으로 도는 호가 되도록 각도를 정규화한다.
	while span > 0.0 and side < 0:
		span -= TAU
	while span < 0.0 and side > 0:
		span += TAU
	var steps := clampi(int(ceil(absf(span) / deg_to_rad(40.0))), 1, ARC_MAX_POINTS - 1)
	var points: Array[Vector2] = []
	for i in range(steps + 1):
		var a := from_angle + span * (float(i) / float(steps))
		points.append(center + Vector2(cos(a), sin(a)) * r)
	return points

## 다른 캐릭터와 겹치지 않게 밀어낸다.
##
## 바위(push_out)와 달리 **한 프레임에 밀리는 양을 제한**한다: 겹친 상태가
## 순간이동으로 풀리면 상대가 갑자기 튀어 보이고, 스폰이 겹칠 때(모두 같은
## 지점에서 시작한다) 여러 명이 한꺼번에 튕겨 나간다. 살짝 밀리는 느낌이 되게
## 초당 속도 상한을 둔다.
##
## 왜 서버가 아니라 각 클라이언트가 푸는가: 위치는 이미 클라이언트가 보내고
## 서버는 경계·속도만 검증한다(docs/protocol.md §3). 겹침은 결과가 걸린 판정이
## 아니라 보기의 문제라, 양쪽이 각자 자기 자신을 밀어내면 대칭적으로 떨어진다.
## 대신 조작된 클라이언트는 겹칠 수 있다 — 그 한계를 문서에 남긴다.
##
## others: 다른 캐릭터들의 위치(Vector3). radius_sum: 두 캐릭터 반지름의 합.
static func separate(pos: Vector3, others: Array, radius_sum: float, max_step: float) -> Vector3:
	var p := Vector2(pos.x, pos.z)
	var push := Vector2.ZERO
	for o: Variant in others:
		if typeof(o) != TYPE_VECTOR3:
			continue
		var other := o as Vector3
		var to_me := p - Vector2(other.x, other.z)
		var d := to_me.length()
		if d >= radius_sum:
			continue
		if d <= 0.0001:
			# 정확히 같은 자리(스폰 겹침 등) — 방향이 없으니 임의 방향으로 민다.
			push += Vector2(radius_sum, 0.0)
		else:
			push += to_me / d * (radius_sum - d)
	if push == Vector2.ZERO:
		return pos
	if push.length() > max_step:
		push = push.normalized() * max_step
	return Vector3(pos.x + push.x, pos.y, pos.z + push.y)

## 원 안으로 밀려 들어간 위치를 표면 밖으로 되돌린다(수동 이동 충돌 처리).
static func push_out(pos: Vector3, obstacles: Array, agent_radius: float) -> Vector3:
	var p := Vector2(pos.x, pos.z)
	for o: Variant in obstacles:
		if typeof(o) != TYPE_DICTIONARY:
			continue
		var obs := o as Dictionary
		var center := Vector2(float(obs.get("x", 0.0)), float(obs.get("z", 0.0)))
		if String(obs.get("shape", "circle")) == "box":
			var half := Vector2(float(obs.get("size_x", 1.0)), float(obs.get("size_z", 1.0))) * 0.5 \
				+ Vector2(agent_radius, agent_radius)
			if not _inside_box(p, center, half):
				continue
			# 침투가 가장 적은 축으로 밀어낸다 — 벽에 붙어 미끄러지는 느낌이 된다.
			var dx := half.x - absf(p.x - center.x)
			var dz := half.y - absf(p.y - center.y)
			if dx <= dz:
				p.x = center.x + (half.x if p.x >= center.x else -half.x)
			else:
				p.y = center.y + (half.y if p.y >= center.y else -half.y)
			continue
		var r := float(obs.get("radius", 1.0)) + agent_radius
		var to_p := p - center
		var d := to_p.length()
		if d >= r:
			continue
		if d <= 0.0001:
			# 정확히 중심에 있으면 방향이 없다 — 임의 방향으로 밀어낸다.
			p = center + Vector2(r, 0.0)
		else:
			p = center + to_p / d * r
	return Vector3(p.x, pos.y, p.y)
