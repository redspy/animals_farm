extends SceneTree

## 경로 계산(PathPlanner) 테스트. 바위를 만나면 짧은 쪽으로 돌아가는지,
## 우회 경로가 실제로 바위를 비켜 가는지, 무한 루프에 빠지지 않는지 검증한다.
##
## 헤드리스로 도는 순수 계산 테스트라 브라우저나 서버가 필요 없다.
## 실행: <표준 Godot> --headless --path . --script tests/test_path.gd

const AGENT := 0.35

var _failures := 0

func _initialize() -> void:
	_test_clear_line_is_straight()
	_test_blocked_line_gets_detour()
	_test_picks_shorter_side()
	_test_detour_actually_clears_obstacle()
	_test_multiple_obstacles_terminate()
	_test_start_inside_obstacle_does_not_loop()
	_test_push_out()
	_test_separate()

	if _failures > 0:
		printerr("❌ 경로 계산 테스트 실패 %d건" % _failures)
		quit(1)
	else:
		print("✅ 경로 계산 테스트 전부 통과")
		quit(0)

func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok  — %s" % what)
	else:
		_failures += 1
		printerr("  FAIL — %s" % what)

func _rock(x: float, z: float, r: float) -> Dictionary:
	return {"x": x, "z": z, "radius": r}

## 경로 전체가 바위를 비켜 가는지 — 각 구간의 최근접 거리를 본다.
func _path_clears(from: Vector3, path: Array[Vector3], obstacles: Array) -> bool:
	var prev := Vector2(from.x, from.z)
	for p in path:
		var cur := Vector2(p.x, p.z)
		for o: Variant in obstacles:
			var obs := o as Dictionary
			var center := Vector2(float(obs["x"]), float(obs["z"]))
			var r := float(obs["radius"]) + AGENT
			var seg := cur - prev
			var seg_len := seg.length()
			var closest := prev
			if seg_len > 0.0001:
				var t := clampf((center - prev).dot(seg / seg_len), 0.0, seg_len)
				closest = prev + (seg / seg_len) * t
			# 0.01은 부동소수 여유 — 접선으로 지나가면 정확히 r이 된다.
			if closest.distance_to(center) < r - 0.01:
				return false
		prev = cur
	return true

func _test_clear_line_is_straight() -> void:
	print("[test] 막히지 않으면 직선")
	var path := PathPlanner.plan(Vector3.ZERO, Vector3(6, 0, 0), [_rock(0, 8, 1.0)], AGENT)
	_check(path.size() == 1, "경유지 없이 목표 하나")
	_check(path[0].is_equal_approx(Vector3(6, 0, 0)), "목표가 그대로 유지")

func _test_blocked_line_gets_detour() -> void:
	print("[test] 바위가 막으면 경유지가 생긴다")
	var rocks := [_rock(3, 0, 1.2)]
	var path := PathPlanner.plan(Vector3.ZERO, Vector3(6, 0, 0), rocks, AGENT)
	_check(path.size() >= 2, "경유지 %d개 + 목표" % (path.size() - 1))
	_check(path[path.size() - 1].is_equal_approx(Vector3(6, 0, 0)), "마지막은 목표")
	_check(_path_clears(Vector3.ZERO, path, rocks), "경로가 바위를 비켜 간다")

## 바위가 경로 중심에서 한쪽으로 치우쳐 있으면 **가까운 쪽**으로 돌아야 한다.
func _test_picks_shorter_side() -> void:
	print("[test] 짧은 쪽으로 돌아간다")
	# (3, 0.5)에 바위 → 선분(z=0)보다 +z쪽으로 치우쳐 있으므로 -z쪽이 짧다.
	var rocks := [_rock(3, 0.5, 1.2)]
	var path := PathPlanner.plan(Vector3.ZERO, Vector3(6, 0, 0), rocks, AGENT)
	_check(path.size() >= 2, "경유지 생성")
	if path.size() >= 2:
		_check(path[0].z < 0.0, "치우친 반대쪽(-z)으로 우회: z=%.2f" % path[0].z)

	# 반대로 치우치면 반대쪽을 골라야 한다.
	var rocks2 := [_rock(3, -0.5, 1.2)]
	var path2 := PathPlanner.plan(Vector3.ZERO, Vector3(6, 0, 0), rocks2, AGENT)
	if path2.size() >= 2:
		_check(path2[0].z > 0.0, "반대로 치우치면 +z로 우회: z=%.2f" % path2[0].z)

func _test_detour_actually_clears_obstacle() -> void:
	print("[test] 여러 방향에서도 경로가 바위를 비켜 간다")
	var rocks := [_rock(0, 0, 1.5)]
	for angle_deg in [0.0, 37.0, 90.0, 143.0, 200.0, 271.0, 330.0]:
		var rad := deg_to_rad(angle_deg)
		var from := Vector3(cos(rad) * 6.0, 0.0, sin(rad) * 6.0)
		var to := -from
		var path := PathPlanner.plan(from, to, rocks, AGENT)
		_check(_path_clears(from, path, rocks), "각도 %.0f°에서 우회 성공" % angle_deg)

func _test_multiple_obstacles_terminate() -> void:
	print("[test] 바위가 여러 개여도 종료한다")
	var rocks := [
		_rock(2, 0, 1.0), _rock(4, 0.8, 1.0), _rock(6, -0.8, 1.0),
		_rock(8, 0.4, 1.0), _rock(10, -0.4, 1.0),
	]
	var path := PathPlanner.plan(Vector3.ZERO, Vector3(12, 0, 0), rocks, AGENT)
	# 우회 한 번이 호를 여러 점으로 쪼개므로, 보장되는 상한은
	# MAX_DETOURS × ARC_MAX_POINTS + 1이다 = 무한 루프가 아니다.
	var limit := PathPlanner.MAX_DETOURS * PathPlanner.ARC_MAX_POINTS + 1
	_check(path.size() <= limit, "경로 길이 %d (상한 %d)" % [path.size(), limit])
	_check(path[path.size() - 1].is_equal_approx(Vector3(12, 0, 0)), "목표에 도달하는 경로")

## 밀려서 바위 안에 들어간 상태에서도 경로 계산이 끝나야 한다.
func _test_start_inside_obstacle_does_not_loop() -> void:
	print("[test] 출발점이 바위 안이어도 종료한다")
	var rocks := [_rock(0, 0, 2.0)]
	var path := PathPlanner.plan(Vector3(0.5, 0, 0.2), Vector3(8, 0, 0), rocks, AGENT)
	_check(path.size() >= 1 and path.size() <= PathPlanner.MAX_DETOURS * PathPlanner.ARC_MAX_POINTS + 1,
		"경로 길이 %d" % path.size())
	_check(path[path.size() - 1].is_equal_approx(Vector3(8, 0, 0)), "목표로 향한다")

## 캐릭터 겹침 분리 — 겹치면 떨어지고, 한 프레임 이동량은 제한된다.
func _test_separate() -> void:
	print("[test] 캐릭터끼리 겹치지 않게 밀어낸다")
	var sep := 0.8

	# 겹친 상태 → 멀어지는 방향으로 밀린다.
	var moved := PathPlanner.separate(Vector3(0.2, 0, 0), [Vector3.ZERO], sep, 10.0)
	_check(Vector2(moved.x, moved.z).length() >= sep - 0.01,
		"겹침이 풀려 최소 간격 확보(거리 %.2f)" % Vector2(moved.x, moved.z).length())
	_check(moved.x > 0.2, "겹친 상대의 반대 방향으로 밀린다")

	# 한 프레임 이동량 상한이 지켜진다(순간이동 방지).
	var capped := PathPlanner.separate(Vector3(0.05, 0, 0), [Vector3.ZERO], sep, 0.1)
	_check(Vector2(capped.x - 0.05, capped.z).length() <= 0.1001,
		"한 프레임 이동량이 상한(0.1) 이내: %.3f" % Vector2(capped.x - 0.05, capped.z).length())

	# 정확히 같은 자리여도 크래시 없이 밀려난다(모두 같은 지점에서 시작하는 경우).
	var exact := PathPlanner.separate(Vector3.ZERO, [Vector3.ZERO], sep, 10.0)
	_check(Vector2(exact.x, exact.z).length() > 0.0, "같은 자리에 겹쳐도 밀려남")

	# 충분히 떨어진 상대는 무시한다(가만히 있는 캐릭터가 끌려다니면 안 된다).
	var far := PathPlanner.separate(Vector3(5, 0, 5), [Vector3.ZERO], sep, 10.0)
	_check(far.is_equal_approx(Vector3(5, 0, 5)), "멀리 있는 상대는 영향 없음")

	# 여러 명에게 둘러싸여도 결과가 유한하다.
	var crowd := PathPlanner.separate(Vector3.ZERO, [
		Vector3(0.3, 0, 0), Vector3(-0.3, 0, 0), Vector3(0, 0, 0.3), Vector3(0, 0, -0.3),
	], sep, 1.0)
	_check(is_finite(crowd.x) and is_finite(crowd.z), "여러 명에 둘러싸여도 유한한 결과")

func _test_push_out() -> void:
	print("[test] 바위 안으로 들어간 위치를 표면 밖으로 되돌린다")
	var rocks := [_rock(0, 0, 1.5)]
	var fixed := PathPlanner.push_out(Vector3(0.4, 0, 0.3), rocks, AGENT)
	var d := Vector2(fixed.x, fixed.z).length()
	_check(absf(d - (1.5 + AGENT)) < 0.01, "표면 위로 밀려남(거리 %.2f)" % d)
	# 바위 밖의 위치는 건드리지 않는다.
	var outside := PathPlanner.push_out(Vector3(5, 0, 5), rocks, AGENT)
	_check(outside.is_equal_approx(Vector3(5, 0, 5)), "바위 밖 위치는 그대로")
	# 정확히 중심에 있어도 크래시 없이 밀려난다.
	var center := PathPlanner.push_out(Vector3.ZERO, rocks, AGENT)
	_check(Vector2(center.x, center.z).length() > 1.5, "중심에 있어도 밀려남")
