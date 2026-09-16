extends Node
class_name TestHooks

## E2E 테스트가 UI를 정확히 탭할 수 있도록 **화면상의 UI 위치를 브라우저에
## 공개**하는 seam.
##
## 왜 필요한가: 캔버스 게임은 DOM 셀렉터가 없어서 테스트가 좌표를 추측해야
## 한다. 데스크톱(960×540)에 맞춰 놓은 좌표가 폰 세로(412×839)에서는 전부
## 어긋나 슬롯 선택부터 실패했다(2026-09-04 실측). 비율로 짐작하는 방식은
## 레이아웃을 조금 바꿀 때마다 깨진다.
##
## 좌표는 **Godot 뷰포트 좌표 + 뷰포트 크기**로 넘기고, CSS 픽셀 변환은
## 테스트가 캔버스의 getBoundingClientRect로 한다(tests/godot-tap.mjs) —
## 스트레치/DPR 배율을 테스트가 알아야 할 필요가 없어진다.
##
## 게시 방식: 컨트롤을 등록해 두고 **주기적으로** 위치를 다시 읽어 내보낸다.
## 처음에는 Control의 `resized` 시그널에 걸었는데 실측에서 한 번도 발동하지
## 않아 `window.afTest`가 null이었다. 화면 회전·시트 열림으로 위치가 바뀌는
## 것도 주기 게시가 자연스럽게 따라간다.
##
## 프로덕션 영향: `window.afTest` 객체 하나가 생기는 것뿐이고 게임 동작에는
## 관여하지 않는다. 웹이 아닌 빌드에서는 노드가 스스로 비활성화된다.

const GLOBAL_NAME := "afTest"
const PUBLISH_INTERVAL := 0.4

## 인스턴스가 여러 개 있어도 되게 만든 이유: 선택 화면·터치 UI·월드가 각자
## 알려줄 지점을 갖는다. 처음에는 각 인스턴스가 window.afTest를 통째로
## 덮어써서 뒤에 게시한 쪽만 남고 조이스틱 지점이 사라졌다(2026-09-04 실측).
## 그래서 인스턴스별로 **자기 키만 지우고 병합**한다.
static var _next_id := 0

var _controls: Dictionary = {}   # key -> Control
var _extra: Dictionary = {}      # key -> Vector2 (컨트롤이 아닌 고정 지점)
var _dynamic: Dictionary = {}    # key -> Callable() -> Vector2 (매번 계산)
## 좌표가 아닌 게임 상태(벨·가방 개수 등). 판매처럼 **본인에게만 오는 결과**는
## 옵저버(WS)로 볼 수 없어서, E2E가 확인할 방법이 이것뿐이다.
var _state: Dictionary = {}
var _timer := 0.0
var _instance_id := ""

func _ready() -> void:
	_instance_id = "h%d" % _next_id
	_next_id += 1
	if not OS.has_feature("web"):
		# 웹이 아니면 할 일이 없다 — 프레임마다 도는 것도 낭비다.
		set_process(false)

## 이름으로 컨트롤을 등록한다. 같은 이름을 다시 등록하면 덮어쓴다(화면 전환).
func track(key: String, control: Control) -> void:
	_controls[key] = control

## 컨트롤이 아닌 지점(예: 조이스틱 영역 중앙)을 등록한다.
func track_point(key: String, point: Vector2) -> void:
	_extra[key] = point

## 매 게시 때 계산해야 하는 지점(예: 카메라가 움직이는 3D 대상의 화면 좌표).
func track_dynamic(key: String, fn: Callable) -> void:
	_dynamic[key] = fn

## 숫자/문자열 상태를 공개한다. 값이 바뀔 때만 호출하면 된다.
func set_state(key: String, value: Variant) -> void:
	_state[key] = value

## 등록을 하나만 취소한다(목록이 줄어드는 UI: 접속자 바 등).
func untrack(key: String) -> void:
	_controls.erase(key)
	_extra.erase(key)
	_dynamic.erase(key)

func clear() -> void:
	_controls.clear()
	_extra.clear()
	_dynamic.clear()

## 노드가 사라질 때 **자기 것을 치운다.**
##
## 없으면 닫힌 화면의 좌표·상태가 `window.afTest`에 영구히 남는다 — E2E가
## "가게가 다시 열렸다"를 그 훅의 존재로 판정하면 **클릭이 실패해도 통과**하고,
## 값 비교도 "언젠가 그 값을 그린 적 있다"가 된다(2026-09-16 리뷰가 실제로 그
## 상태를 잡았다). 모달이 여럿인 화면 전부가 같은 문제를 공유했다.
func _exit_tree() -> void:
	if not OS.has_feature("web"):
		return
	JavaScriptBridge.eval("""
		(function(){
			var t = window.%s; if (!t) return;
			var id = '%s';
			// **내가 아직 주인인 키만** 지운다 — 다른 인스턴스가 같은 이름으로 다시
			// 올렸으면 그쪽이 주인이므로 건드리지 않는다.
			for (var k in (t.owner || {}))
				if (t.owner[k] === id) { delete t.points[k]; delete t.owner[k]; }
			for (var k2 in (t.stateOwner || {}))
				if (t.stateOwner[k2] === id) { delete t.state[k2]; delete t.stateOwner[k2]; }
		})();
	""" % [GLOBAL_NAME, _instance_id], true)

func _process(delta: float) -> void:
	_timer += delta
	if _timer < PUBLISH_INTERVAL:
		return
	_timer = 0.0
	publish_now()

func publish_now() -> void:
	# 주기 게시와 겹치지 않게 타이머를 리셋한다 — 즉시 게시 직후 또 올리면
	# 같은 내용으로 eval을 두 번 돈다.
	_timer = 0.0
	if not OS.has_feature("web"):
		return
	var vp := get_viewport()
	if vp == null:
		return
	var size := vp.get_visible_rect().size
	var parts: Array[String] = []
	for key: String in _controls.keys():
		var c: Control = _controls[key]
		if c == null or not is_instance_valid(c) or not c.is_visible_in_tree():
			continue
		var center := c.get_global_rect().get_center()
		parts.append('"%s":[%.1f,%.1f]' % [key, center.x, center.y])
	for key: String in _extra.keys():
		var p: Vector2 = _extra[key]
		parts.append('"%s":[%.1f,%.1f]' % [key, p.x, p.y])
	for key: String in _dynamic.keys():
		var fn: Callable = _dynamic[key]
		var dp: Vector2 = fn.call()
		parts.append('"%s":[%.1f,%.1f]' % [key, dp.x, dp.y])
	var json := "{%s}" % ", ".join(parts)
	JavaScriptBridge.eval("""
		(function(){
			var t = window.%s = window.%s || {};
			t.points = t.points || {}; t.state = t.state || {};
			// **키마다 마지막으로 올린 인스턴스를 적어 둔다.** 인스턴스별 키 목록만
			// 두면, 죽는 쪽이 "내가 예전에 올린 키"를 지우면서 **그 사이 다른
			// 인스턴스가 새로 올린 값까지** 날린다(2026-09-16 리뷰 지적). 소유권이
			// 키 단위 최종 기록자여야 _exit_tree가 남의 값을 안 건드린다.
			t.owner = t.owner || {}; t.stateOwner = t.stateOwner || {};
			var id = '%s';
			var next = %s;
			var st = %s;
			// 내가 주인이던 좌표 중 이번에 안 올린 것은 지운다(목록이 줄어드는 UI).
			for (var k in t.owner)
				if (t.owner[k] === id && !(k in next)) { delete t.points[k]; delete t.owner[k]; }
			for (var k2 in next) { t.points[k2] = next[k2]; t.owner[k2] = id; }
			for (var k3 in st) { t.state[k3] = st[k3]; t.stateOwner[k3] = id; }
			t.vw = %.1f; t.vh = %.1f;
		})();
	""" % [GLOBAL_NAME, GLOBAL_NAME, _instance_id, json, _state_json(), size.x, size.y], true)

func _state_json() -> String:
	var parts: Array[String] = []
	for key: String in _state.keys():
		# **모든 값을 JSON으로 직렬화한다.** `str()`은 null을 `<null>`, INF를 `inf`,
		# Vector2를 `(1, 2)`로 내서 JSON이 깨지고, 그러면 eval이 통째로 실패해
		# **훅 게시가 영구히 멈춘다**(E2E가 전부 눈이 먼다 — 리뷰 지적).
		parts.append('"%s":%s' % [key, JSON.stringify(_state[key])])
	return "{%s}" % ", ".join(parts)
