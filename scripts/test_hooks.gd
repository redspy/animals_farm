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

var _controls: Dictionary = {}   # key -> Control
var _extra: Dictionary = {}      # key -> Vector2 (컨트롤이 아닌 지점)
var _timer := 0.0

func _ready() -> void:
	if not OS.has_feature("web"):
		# 웹이 아니면 할 일이 없다 — 프레임마다 도는 것도 낭비다.
		set_process(false)

## 이름으로 컨트롤을 등록한다. 같은 이름을 다시 등록하면 덮어쓴다(화면 전환).
func track(key: String, control: Control) -> void:
	_controls[key] = control

## 컨트롤이 아닌 지점(예: 조이스틱 영역 중앙)을 등록한다.
func track_point(key: String, point: Vector2) -> void:
	_extra[key] = point

func clear() -> void:
	_controls.clear()
	_extra.clear()

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
	var json := '{"vw":%.1f,"vh":%.1f,"points":{%s}}' % [size.x, size.y, ", ".join(parts)]
	JavaScriptBridge.eval("window.%s = %s;" % [GLOBAL_NAME, json], true)
