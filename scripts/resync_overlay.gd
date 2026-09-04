extends CanvasLayer
class_name ResyncOverlay

## 창 복귀 후 **서버 상태와 맞을 때까지** 화면을 살짝 흐리고 진행 표시를 띄운다.
##
## 왜 필요한가: 다른 탭·앱에 갔다 오면 브라우저가 프레임을 멈춘다. 돌아온 순간
## 내 캐릭터는 옛 위치에 있고, 남들은 멈춰 있고, 주워간 물건이 아직 남아 있다.
## 그 상태로 조작하면 "분명히 저기 있었는데" 하는 어긋남이 생긴다(사용자 요청).
##
## 블러: 웹에서는 캔버스에 CSS `filter: blur()`를 걸어 **실제로** 흐리게 한다.
## Godot에서 전체화면 블러를 하려면 셰이더와 화면 텍스처가 필요한데, 웹에서는
## 한 줄로 되는 방법이 있어 그걸 쓴다. 웹이 아니면 반투명 판으로 대체한다.

## 블러 세기(px). 너무 세면 무슨 일이 났는지 알 수 없다 — "살짝"이 요구사항.
const BLUR_PX := 3.0
## 이 시간이 지나면 서버 응답이 없어도 오버레이를 걷는다 — 화면이 영구히 잠기면
## 아무 것도 못 하게 된다(연결이 끊긴 경우 등).
const TIMEOUT_SEC := 6.0

var _dim: ColorRect
var _label: Label
var _bar: ProgressBar
var _active := false
var _timeout_left := 0.0
var _is_web := false

func _ready() -> void:
	layer = 100   # HUD·시트보다 위
	_is_web = OS.has_feature("web") and JavaScriptBridge.get_interface("document") != null

	_dim = ColorRect.new()
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	# 웹에서는 캔버스를 실제로 블러 처리하므로 판은 아주 옅게만 깐다.
	_dim.color = Palette.color("ui", "resync_dim_web") if _is_web else Palette.color("ui", "resync_dim")
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP   # 동기화 중 조작을 막는다
	add_child(_dim)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.add_theme_constant_override("separation", 10)
	add_child(box)

	_label = Label.new()
	_label.text = "돌아왔어요 — 위치를 맞추는 중"
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_color_override("font_color", Palette.color("ui", "hud_text"))
	_label.add_theme_color_override("font_outline_color", Palette.color("ui", "hud_outline"))
	_label.add_theme_constant_override("outline_size", 5)
	box.add_child(_label)

	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(UiScale.panel_width(260.0, 80.0), 16)
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.value = 0.0
	_bar.show_percentage = false
	box.add_child(_bar)

	visible = false

func is_active() -> bool:
	return _active

## 동기화 시작. progress는 0~1로 갱신한다.
func begin() -> void:
	_active = true
	_timeout_left = TIMEOUT_SEC
	visible = true
	set_progress(0.1)
	_set_canvas_blur(BLUR_PX)

func set_progress(value: float) -> void:
	if _bar != null:
		_bar.value = clampf(value, 0.0, 1.0)

## 서버 상태와 맞았을 때(또는 시간이 지났을 때) 정상 플레이로 돌아간다.
func finish(reason: String = "") -> void:
	if not _active:
		return
	_active = false
	visible = false
	_set_canvas_blur(0.0)
	if not reason.is_empty():
		push_warning("재동기화 종료: %s" % reason)

func _process(delta: float) -> void:
	if not _active:
		return
	_timeout_left -= delta
	# 진행 표시가 멈춰 보이지 않게 남은 시간에 따라 조금씩 채운다.
	set_progress(maxf(_bar.value, 1.0 - _timeout_left / TIMEOUT_SEC))
	if _timeout_left <= 0.0:
		finish("시간 초과 — 서버 응답을 받지 못했다")

## 웹에서는 캔버스 자체에 CSS 블러를 건다. 0이면 해제.
func _set_canvas_blur(px: float) -> void:
	if not _is_web:
		return
	JavaScriptBridge.eval("""
		(function(){
			var c = document.querySelector('canvas');
			if (!c) return;
			c.style.filter = %s;
			c.style.transition = 'filter 120ms ease-out';
		})();
	""" % ("''" if px <= 0.0 else "'blur(%.1fpx)'" % px), true)
