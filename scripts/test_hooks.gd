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

## 등록을 하나만 취소한다(목록이 줄어드는 UI: 접속자 바 등).
func untrack(key: String) -> void:
	_controls.erase(key)
	_extra.erase(key)
	_dynamic.erase(key)

func clear() -> void:
	_controls.clear()
	_extra.clear()
	_dynamic.clear()

func _process(delta: float) -> void:
	_timer += delta
	if _timer < PUBLISH_INTERVAL:
		return
	_timer = 0.0
	publish_now()

func publish_now() -> void:
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
	var keys: Array[String] = []
	for key: String in _controls.keys():
		keys.append('"%s"' % key)
	for key: String in _extra.keys():
		keys.append('"%s"' % key)
	for key: String in _dynamic.keys():
		keys.append('"%s"' % key)
	JavaScriptBridge.eval("""
		(function(){
			var t = window.%s = window.%s || { points: {}, owners: {} };
			var mine = t.owners['%s'] || [];
			mine.forEach(function(k){ delete t.points[k]; });
			t.owners['%s'] = [%s];
			var next = %s;
			for (var k in next) t.points[k] = next[k];
			t.vw = %.1f; t.vh = %.1f;
		})();
	""" % [GLOBAL_NAME, GLOBAL_NAME, _instance_id, _instance_id, ", ".join(keys), json, size.x, size.y], true)
