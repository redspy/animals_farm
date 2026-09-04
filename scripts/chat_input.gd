extends Node
class_name ChatInput

## 채팅 입력 경로를 한 곳으로 모은 노드.
##
## 웹에서는 캔버스 위에 **실제 DOM `<input>`을 얹는다**. Godot 웹의
## `experimental_virtual_keyboard`를 쓰지 않는 이유는 회의 결과에 있다
## (docs/meetings/2026-09-04-1150-폰-터치-조작-설계.md §9-나):
## 모바일 브라우저에서 한글 IME 조합이 풀리거나 글자가 중복 입력되는 사례가
## 보고돼 있고, 이 게임은 한국어 채팅이 기능의 핵심이다. DOM 입력은 브라우저
## 네이티브라 OS 키보드·IME와 그대로 연동된다.
##
## 웹이 아닌 환경(에디터/데스크톱/헤드리스 테스트)에서는 DOM이 없으므로
## Godot `LineEdit`으로 갈라진다. 바깥 코드는 어느 쪽인지 몰라도 되게
## `open()` / `close()` / `submitted` 만 본다.

signal submitted(text: String)
signal closed
## 소프트 키보드가 화면 아래를 덮은 비율(0~0.8). 폰에서 키보드가 올라오면
## 캐릭터가 가려진 영역에 들어가 보이지 않으므로, world가 카메라를 그만큼 올린다.
signal keyboard_cover_changed(ratio: float)

const MAX_LEN := 200
## DOM 입력을 만들 때 쓰는 요소 id. 재접속/재생성 시 중복 생성을 막는 열쇠다.
const DOM_ID := "af-chat-input"
## 키보드 높이를 폴링하는 간격(초). 키보드가 올라오는 애니메이션 때문에 즉시
## 값을 읽으면 0이 나온다.
const COVER_POLL_INTERVAL := 0.25
## 이 비율 이상 가려졌을 때만 카메라를 보정한다(작은 변화에 화면이 흔들리지 않게).
const COVER_MIN := 0.08

var _is_web := false
var _open := false
var _line_edit: LineEdit = null
var _js_submit_cb: JavaScriptObject = null
var _js_cancel_cb: JavaScriptObject = null
var _cover_timer := 0.0
var _cover_ratio := 0.0

func _ready() -> void:
	_is_web = OS.has_feature("web") and JavaScriptBridge.get_interface("document") != null
	if _is_web:
		_setup_dom()
	else:
		_setup_line_edit()

func is_open() -> bool:
	return _open

func open() -> void:
	if _open:
		return
	_open = true
	if _is_web:
		# 포커스는 사용자 제스처(버튼 탭/키 입력) 안에서 걸어야 모바일
		# 브라우저가 키보드를 띄운다 — 지연 호출하면 무시된다.
		JavaScriptBridge.eval("""
			(function(){
				var el = document.getElementById('%s');
				if (!el) return;
				el.style.display = 'block';
				el.value = '';
				el.focus();
			})();
		""" % DOM_ID, true)
	elif _line_edit != null:
		_line_edit.visible = true
		_line_edit.text = ""
		_line_edit.grab_focus()

func _process(delta: float) -> void:
	if not _is_web:
		return
	# 열려 있는 동안에만 폴링한다 — 닫혀 있을 때 매 프레임 JS를 호출할 이유가 없다.
	if not _open:
		if _cover_ratio != 0.0:
			_cover_ratio = 0.0
			keyboard_cover_changed.emit(0.0)
		return
	_cover_timer += delta
	if _cover_timer < COVER_POLL_INTERVAL:
		return
	_cover_timer = 0.0
	var ratio := _read_keyboard_cover()
	_reposition_for_keyboard()
	if absf(ratio - _cover_ratio) > 0.02:
		_cover_ratio = ratio
		keyboard_cover_changed.emit(ratio)

## 소프트 키보드가 **화면 아래를 덮은 비율**을 구한다.
##
## 왜 이렇게 복잡한가: 브라우저마다 키보드가 뷰포트를 다르게 바꾼다.
## - iOS Safari: 레이아웃 뷰포트는 그대로, `visualViewport.height`만 줄어든다.
## - Chrome Android: 설정(interactive-widget)에 따라 **레이아웃까지 줄어든다** —
##   그러면 `window.innerHeight`도 함께 줄어 "1 - vv.height/innerHeight"가 0이
##   되고, 실제로는 가려졌는데 0으로 계산된다(폰에서 보정이 안 먹은 원인).
##
## 그래서 기준을 `documentElement.clientHeight`(레이아웃 뷰포트)로 잡고,
## 스크롤된 만큼(`offsetTop`)까지 함께 고려한다. 두 값이 같이 줄어드는
## 브라우저에서는 캔버스 자체가 작아지므로 보정이 필요 없고, 그 경우는
## world.gd가 뷰포트 축소분을 빼서 이중 보정을 막는다.
##
## `window.afForceKeyboardCover`가 있으면 그 값을 쓴다 — E2E가 키보드를 띄울
## 수 없어서(에뮬레이션 불가) 이 경로로 검증한다.
func _read_keyboard_cover() -> float:
	var raw: Variant = JavaScriptBridge.eval("""
		(function(){
			if (typeof window.afForceKeyboardCover === 'number') {
				return window.afForceKeyboardCover;
			}
			var vv = window.visualViewport;
			if (!vv) return 0;
			var layout = (document.documentElement && document.documentElement.clientHeight)
				|| window.innerHeight || 0;
			if (!layout) return 0;
			var hidden = layout - (vv.height + vv.offsetTop);
			var ratio = hidden / layout;
			return ratio > 0 ? ratio : 0;
		})();
	""", true)
	if raw == null:
		return 0.0
	var ratio := float(raw)
	if ratio < COVER_MIN:
		return 0.0
	return clampf(ratio, 0.0, 0.8)

## 입력창이 키보드에 가리지 않게 위로 올린다. position:fixed + bottom만으로는
## iOS에서 키보드 뒤에 남는다.
func _reposition_for_keyboard() -> void:
	JavaScriptBridge.eval("""
		(function(){
			var el = document.getElementById('%s');
			var vv = window.visualViewport;
			if (!el || !vv) return;
			var layout = (document.documentElement && document.documentElement.clientHeight)
				|| window.innerHeight || 0;
			var hidden = Math.max(0, layout - (vv.height + vv.offsetTop));
			el.style.bottom = (hidden + 12) + 'px';
		})();
	""" % DOM_ID, true)

func close() -> void:
	if not _open:
		return
	_open = false
	if _is_web:
		JavaScriptBridge.eval("""
			(function(){
				var el = document.getElementById('%s');
				if (!el) return;
				el.blur();
				el.style.display = 'none';
			})();
		""" % DOM_ID, true)
	elif _line_edit != null:
		_line_edit.visible = false
		_line_edit.release_focus()
	closed.emit()

# ---------------------------------------------------------------------------
# 웹: DOM <input> 오버레이
# ---------------------------------------------------------------------------

func _setup_dom() -> void:
	# 콜백을 멤버로 들고 있어야 GC되지 않는다(해제되면 Enter가 먹지 않는다).
	_js_submit_cb = JavaScriptBridge.create_callback(_on_dom_submit)
	_js_cancel_cb = JavaScriptBridge.create_callback(_on_dom_cancel)
	var window := JavaScriptBridge.get_interface("window")
	window.afChatSubmit = _js_submit_cb
	window.afChatCancel = _js_cancel_cb

	# 캔버스 위에 고정 배치. 폰에서 키보드가 올라오면 브라우저가 뷰포트를
	# 줄이므로 bottom 기준으로 붙여야 입력창이 키보드에 가리지 않는다.
	JavaScriptBridge.eval("""
		(function(){
			if (document.getElementById('%s')) return;
			var el = document.createElement('input');
			el.id = '%s';
			el.type = 'text';
			el.maxLength = %d;
			el.placeholder = '메시지 입력 후 Enter';
			el.autocomplete = 'off';
			el.style.cssText = [
				'display:none', 'position:fixed', 'left:3%%', 'bottom:12px', 'width:70%%',
				'max-width:600px', 'padding:12px 14px', 'font-size:17px',
				'border:2px solid rgba(255,255,255,0.6)', 'border-radius:10px',
				'background:rgba(18,38,31,0.92)', 'color:#fff', 'z-index:2147483647',
				'outline:none', '-webkit-user-select:text', 'user-select:text'
			].join(';');
			el.addEventListener('keydown', function(ev){
				if (ev.key === 'Enter') {
					// IME 조합 중의 Enter는 조합 확정이므로 전송하지 않는다 —
					// 이걸 빼면 한글 입력 중 첫 Enter에 조합이 잘린 채 전송된다.
					if (ev.isComposing) return;
					ev.preventDefault();
					window.afChatSubmit(el.value);
				} else if (ev.key === 'Escape') {
					ev.preventDefault();
					window.afChatCancel();
				}
				// 게임이 키를 같이 먹지 않도록 캔버스로 전파하지 않는다.
				ev.stopPropagation();
			});
			el.addEventListener('keyup', function(ev){ ev.stopPropagation(); });
			el.addEventListener('keypress', function(ev){ ev.stopPropagation(); });
			document.body.appendChild(el);
		})();
	""" % [DOM_ID, DOM_ID, MAX_LEN], true)

func _on_dom_submit(args: Array) -> void:
	var text := String(args[0]) if args.size() > 0 else ""
	close()
	var clean := text.strip_edges()
	if not clean.is_empty():
		submitted.emit(clean.substr(0, MAX_LEN))

func _on_dom_cancel(_args: Array) -> void:
	close()

# ---------------------------------------------------------------------------
# 비웹: Godot LineEdit
# ---------------------------------------------------------------------------

func _setup_line_edit() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_line_edit = LineEdit.new()
	_line_edit.max_length = MAX_LEN
	_line_edit.placeholder_text = "메시지 입력 후 Enter (Esc 취소)"
	_line_edit.visible = false
	# 앵커로 붙여 좁은 화면에서도 잘리지 않게 한다.
	_line_edit.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_line_edit.offset_left = 16
	_line_edit.offset_right = -16
	_line_edit.offset_top = -52
	_line_edit.offset_bottom = -16
	_line_edit.text_submitted.connect(func(text: String) -> void:
		close()
		var clean := text.strip_edges()
		if not clean.is_empty():
			submitted.emit(clean)
	)
	layer.add_child(_line_edit)

func _unhandled_input(event: InputEvent) -> void:
	if _is_web or not _open:
		return
	if event is InputEventKey and event.pressed and (event as InputEventKey).keycode == KEY_ESCAPE:
		close()
