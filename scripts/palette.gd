extends RefCounted
class_name Palette

## 화면 색의 단일 출처(data/palette.json)를 읽는 유틸.
##
## Balance(밸런스 수치)와 같은 원칙이다 — 값은 데이터가 소유하고, 코드는 읽어
## 쓰면서 잘못된 데이터를 조용히 넘기지 않는다. 키가 없으면 눈에 확 띄는
## 마젠타를 돌려주고 경고를 남긴다: 화면에 마젠타가 보이면 팔레트 키 누락이다.

const PATH := "res://data/palette.json"

## 키 누락을 화면에서 바로 알아채기 위한 색. 게임에 쓰지 않는 색이어야 한다.
const MISSING := Color(1, 0, 1)

static var _groups: Dictionary = {}
static var _loaded := false

static func _load() -> void:
	if _loaded:
		return
	_loaded = true   # 실패해도 매 프레임 재시도하지 않는다(웹에서 I/O 반복은 비싸다)
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		push_error("팔레트 파일 없음: %s — 모든 색이 마젠타로 그려진다" % PATH)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("팔레트 파싱 실패: %s" % PATH)
		return
	_groups = parsed as Dictionary

## group은 "world"|"ui"|"character", key는 그 그룹 안의 색 이름.
static func color(group: String, key: String) -> Color:
	_load()
	var g: Variant = _groups.get(group, null)
	if typeof(g) != TYPE_DICTIONARY:
		push_warning("팔레트 그룹 없음: %s" % group)
		return MISSING
	var raw: Variant = (g as Dictionary).get(key, null)
	if typeof(raw) != TYPE_STRING:
		push_warning("팔레트 키 없음: %s.%s" % [group, key])
		return MISSING
	var hex := String(raw)
	if not Color.html_is_valid(hex):
		push_warning("팔레트 값이 올바른 색 문자열이 아님: %s.%s = %s" % [group, key, hex])
		return MISSING
	return Color.html(hex)

## 테스트/디버그용 — 로드된 그룹 이름 목록.
static func groups() -> Array:
	_load()
	return _groups.keys()
