extends RefCounted
class_name UiScale

## 화면 크기에 맞춰 UI 배율과 글자 크기를 정한다.
##
## 왜 필요한가 (2026-09-05 폰 실측, 사용자 보고 "폰에서 글씨가 너무 작아"):
## 폰 브라우저의 캔버스는 CSS 픽셀이 아니라 **기기 픽셀**로 잡힌다(DPR 2.6짜리
## 폰에서 폭 411 CSS px → 캔버스 1080px). 그런데 캔버스 스트레치는 기준
## 해상도(960x540)에 대한 비율로 배율을 정하므로 배율이 1.12밖에 안 되고,
## 그 결과가 다시 DPR로 나눠져 눈에는 **글자 14가 CSS 6px**로 보였다.
## 데스크톱은 DPR이 1이고 배율이 2.0이라 같은 값이 28px로 보였다 — 그래서
## PC에서는 드러나지 않았다.
##
## 해결은 두 단계다.
##  1) `content_scale_factor`로 DPR을 되돌려 **1 UI 단위 = 1 CSS 픽셀**이 되게
##     한다. 터치 버튼 크기(72/56/48)와 여백은 원래 CSS 픽셀 기준으로 잡은
##     값이라(touch_controls.gd의 "44는 접근성 하한" 주석) 이때 의도대로 맞는다.
##     데스크톱은 손대지 않는다(DPR 1이면 배율이 이미 1 이상 → csf=1).
##  2) 그래도 좁은 화면에서는 **글자만 더 키운다**. 논리 폭이 411px인 폰에서
##     데스크톱과 같은 글자 크기는 화면 대비 훨씬 작게 느껴진다. 배율 전체를
##     키우면 버튼과 여백까지 커져서 좁은 화면을 다 먹는다 — 글자만 키운다.

## 이 아래면 "좁은 화면"(폰). CSS 픽셀 기준이며, 세로/가로 어느 쪽이든
## 짧은 변이 이 값보다 작으면 폰으로 본다(가로로 돌린 폰도 높이가 411px이다).
## 480인 이유: 기본 창이 960x540이라 520으로 두면 데스크톱 창을 조금만 줄이거나
## 브라우저 툴바가 두꺼운 것만으로 화면 전체가 폰 모드로 넘어간다(여유 20px).
const NARROW_MIN_SIDE := 480.0
## 좁은 화면에서 글자에 곱하는 값. 1.35면 기본 16 → 21px(모바일 본문 크기),
## HUD 14 → 18px가 된다. 1.5 이상은 긴 안내문이 화면 폭을 넘쳤다.
const NARROW_FONT_SCALE := 1.35
## 테마 기본 글자 크기. Label/Button이 따로 지정하지 않으면 이 값을 쓴다.
const BASE_FONT_SIZE := 16

## 사용자가 화면 크기를 직접 조절하는 배율(+/− 버튼). 화면과 눈이 사람마다
## 다르므로 자동 보정만으로는 부족하다는 요청이었다.
## 1.0이 "1 UI 단위 = 1 CSS 픽셀"이고, 0.7이면 더 많은 월드가 보이는 대신
## 글자가 작아진다. 상·하한은 실용 범위로 자른다 — 0.5는 폰에서 못 읽고,
## 2.0을 넘으면 버튼 몇 개가 화면을 다 덮는다.
const ZOOM_MIN := 0.7
const ZOOM_MAX := 1.8
const ZOOM_STEP := 0.1
static var _zoom := 1.0

## 캐시. `is_narrow()`/`font()`/`dim()`은 HUD 갱신·접속자 바 재구성 때 수십 번
## 불리는데, DPR을 매번 재려면 JS eval + getBoundingClientRect(브라우저 레이아웃
## 강제 플러시)가 따라온다 — 같은 파일의 다른 코드가 "HUD 문자열을 매 프레임
## 새로 만들지 말라"고 스로틀을 거는 것과 방향이 어긋난다. apply()에서만 갱신한다.
static var _ratio_cache := 0.0

## 창 픽셀 크기 ÷ DPR = 사용자가 실제로 체감하는 화면 크기(CSS 픽셀).
static func css_size() -> Vector2:
	var win := _window()
	if win == null:
		return Vector2(960, 540)
	return Vector2(win.size) / maxf(pixel_ratio(), 0.001)

static func is_narrow() -> bool:
	var css := css_size()
	return minf(css.x, css.y) < NARROW_MIN_SIDE

## 좁은 화면에서 키운 글자 크기.
static func font(base: int) -> int:
	if not is_narrow():
		return base
	return int(round(float(base) * NARROW_FONT_SCALE))

## 글자와 함께 커져야 하는 길이(글자를 담는 버튼 폭 등). 버튼만 그대로 두면
## 키운 글자가 잘린다.
static func dim(base: float) -> float:
	return base * NARROW_FONT_SCALE if is_narrow() else base

## 패널 폭을 화면 안으로 접는다. 데스크톱 기준으로 잡은 560px짜리 패널은
## 폰의 논리 폭(411px)을 넘어 잘린다.
static func panel_width(preferred: float, margin: float = 24.0) -> float:
	var vp := _viewport_size()
	return minf(preferred, maxf(vp.x - margin, 200.0))

## 캔버스 픽셀 ÷ CSS 픽셀. 웹에서는 실제 캔버스를 재서 구한다 —
## `devicePixelRatio`를 그대로 믿으면 hidpi 설정이 꺼진 빌드에서 두 번
## 보정하게 된다(캔버스가 CSS 픽셀과 1:1인 경우).
static func pixel_ratio() -> float:
	if _ratio_cache > 0.05:
		return _ratio_cache
	_ratio_cache = _measure_pixel_ratio()
	return _ratio_cache

static func _measure_pixel_ratio() -> float:
	if OS.has_feature("web"):
		var got: Variant = JavaScriptBridge.eval("""
			(function () {
				var c = document.querySelector('canvas');
				if (!c) return window.devicePixelRatio || 1;
				var r = c.getBoundingClientRect();
				if (!(r.width > 0)) return window.devicePixelRatio || 1;
				return c.width / r.width;
			})()
		""", true)
		var ratio := float(got) if got != null else 0.0
		if ratio > 0.05:
			return ratio
		return 1.0
	var scale := DisplayServer.screen_get_scale()
	return scale if scale > 0.05 else 1.0

static func zoom() -> float:
	return _zoom

## 사용자 배율을 바꾸고 즉시 적용한다. 실제로 적용된 값을 돌려준다(상·하한 클램프).
static func set_zoom(value: float) -> float:
	var next := clampf(snappedf(value, 0.01), ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(next, _zoom):
		return _zoom
	_zoom = next
	apply()
	return _zoom

## +/− 버튼용. 한 단계 올리고 내린다.
static func nudge_zoom(steps: float) -> float:
	return set_zoom(_zoom + ZOOM_STEP * steps)

## 화면에 보여줄 문자열("100%").
static func zoom_label() -> String:
	return "%d%%" % int(round(_zoom * 100.0))

## 창이 만들어진 뒤/크기가 바뀔 때마다 부른다. main.gd가 연결한다.
static func apply() -> void:
	var win := _window()
	if win == null:
		return
	# 화면이 바뀌었을 수 있으니 DPR을 다시 잰다(회전·창 크기 변경·확대/축소).
	_ratio_cache = _measure_pixel_ratio()
	var px := Vector2(win.size)
	var base := Vector2(
		float(ProjectSettings.get_setting("display/window/size/viewport_width", 960)),
		float(ProjectSettings.get_setting("display/window/size/viewport_height", 540))
	)
	if px.x < 1.0 or px.y < 1.0 or base.x < 1.0 or base.y < 1.0:
		return
	# 스트레치(canvas_items + expand)가 이미 적용하는 배율. 짧은 쪽이 기준이다.
	# 이 식은 expand/keep 계열 전제다 — aspect를 ignore로 바꾸면 조용히 틀어지므로
	# 설정을 확인해 알려준다(주석만 남기면 다음 사람이 못 본다).
	var aspect := String(ProjectSettings.get_setting("display/window/stretch/aspect", "expand"))
	if aspect == "ignore":
		push_warning("stretch/aspect=ignore에서는 UiScale의 배율 계산이 맞지 않는다")
	var stretch := minf(px.x / base.x, px.y / base.y)
	# 목표: stretch * csf == DPR (1 UI 단위 = 1 CSS 픽셀).
	# max(1.0)인 이유: 데스크톱을 지금보다 작게 만들지 않는다 — 현재 크기에는
	# 불만이 없었고, 줄이면 멀쩡한 화면이 망가진다.
	# 자동 보정(1 UI 단위 = 1 CSS 픽셀)에 사용자 배율을 곱한다. 사용자가 줄이면
	# 자동 보정보다 작아질 수 있어야 하므로 max는 자동 보정에만 적용한다.
	var target := maxf(1.0, pixel_ratio() / maxf(stretch, 0.001)) * _zoom
	var wanted_font := font(BASE_FONT_SIZE)
	# 이미 맞으면 손대지 않는다. content_scale_factor 대입은 값이 같아도 뷰포트를
	# 다시 계산해서 size_changed를 또 쏘고, 그러면 apply()가 재진입한다(수렴하긴
	# 하지만 리사이즈마다 계산이 두 배로 돈다).
	if is_equal_approx(win.content_scale_factor, target) \
			and ThemeDB.get_default_theme().default_font_size == wanted_font:
		return
	win.content_scale_factor = target
	# 따로 지정하지 않은 모든 Label/Button이 이 값을 쓴다 — 한 곳에서 좁은
	# 화면 보정을 걸 수 있는 유일한 지점이다.
	ThemeDB.get_default_theme().default_font_size = wanted_font

static func _window() -> Window:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root
	return null

static func _viewport_size() -> Vector2:
	var win := _window()
	if win == null:
		return Vector2(960, 540)
	return win.get_visible_rect().size
