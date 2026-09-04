extends RefCounted
class_name PathPlanner

## 직선 경로가 바위에 막히면 **짧은 쪽으로 돌아가는** 경로를 만든다.
##
## 왜 내비메시가 아닌가: 이 월드의 장애물은 원(바위)뿐이고 수도 적다. 원 회피는
## 접선 계산으로 정확히 풀리므로 NavigationServer3D + 내비메시를 도입하는 비용이
## 아직 정당화되지 않는다. 다각형 장애물(건물·울타리)이 생기면 그때 교체한다
## (docs/roadmap.md의 "충돌·장애물을 넣는 시점의 내비게이션" 항목).
##
## 좌표는 XZ 평면만 쓴다(y는 항상 0).

## 우회를 몇 번까지 반복할지. 바위가 연달아 놓여 있으면 여러 번 필요하지만,
## 상한이 없으면 배치가 나쁠 때 무한 루프가 된다.
const MAX_DETOURS := 4
## 호 하나를 최대 몇 점으로 쪼갤지. 이 상한이 있어야 "경로 길이가 유한하다"는
## 보장이 생긴다(최대 MAX_DETOURS × ARC_MAX_POINTS + 1).
const ARC_MAX_POINTS := 10
## 바위 표면에서 이만큼 더 떨어져 지나간다 — 딱 접선으로 지나가면 부동소수
## 오차로 표면을 스치며 밀려난다.
const CLEARANCE := 0.25

## obstacles: [{ "x": float, "z": float, "radius": float }, ...]
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
		var r := float(blocking["radius"]) + agent_radius + CLEARANCE
		var detour := _around(start, goal, center, r)
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
static func first_blocking(start: Vector2, goal: Vector2, obstacles: Array, agent_radius: float) -> Dictionary:
	var best_t := INF
	var found := {}
	for o: Variant in obstacles:
		if typeof(o) != TYPE_DICTIONARY:
			continue
		var obs := o as Dictionary
		var center := Vector2(float(obs.get("x", 0.0)), float(obs.get("z", 0.0)))
		var r := float(obs.get("radius", 1.0)) + agent_radius
		var seg := goal - start
		var seg_len := seg.length()
		if seg_len <= 0.0001:
			continue
		var dir := seg / seg_len
		var t := clampf((center - start).dot(dir), 0.0, seg_len)
		var closest := start + dir * t
		if closest.distance_to(center) > r:
			continue
		# 출발점이 이미 원 안이면(밀려 들어간 경우) 그 원은 막는 것으로 보지
		# 않는다 — 그러면 원 안에서 영원히 우회 경로만 만들게 된다.
		if start.distance_to(center) <= r:
			continue
		if t < best_t:
			best_t = t
			found = {"x": center.x, "z": center.y, "radius": float(obs.get("radius", 1.0))}
	return found

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

## 원 안으로 밀려 들어간 위치를 표면 밖으로 되돌린다(수동 이동 충돌 처리).
static func push_out(pos: Vector3, obstacles: Array, agent_radius: float) -> Vector3:
	var p := Vector2(pos.x, pos.z)
	for o: Variant in obstacles:
		if typeof(o) != TYPE_DICTIONARY:
			continue
		var obs := o as Dictionary
		var center := Vector2(float(obs.get("x", 0.0)), float(obs.get("z", 0.0)))
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
