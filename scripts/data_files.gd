extends RefCounted
class_name DataFiles

## data/*.json 로더. 여러 스크립트가 각자 FileAccess+JSON 파싱을 반복하고 있어
## (world.gd, gatherable.gd, main.gd) 실패 처리도 조금씩 달랐다 — 한 곳으로 모은다.
##
## 읽은 결과를 캐시한다: 웹에서 같은 파일을 여러 노드가 각각 읽으면 불필요한
## I/O와 파싱이 반복된다. 데이터는 런타임에 바뀌지 않으므로 캐시가 안전하다.

static var _cache: Dictionary = {}

static func load_dict(path: String) -> Dictionary:
	if _cache.has(path):
		return _cache[path]
	var result := {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("데이터 파일 없음: %s" % path)
	else:
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(parsed) == TYPE_DICTIONARY:
			result = parsed as Dictionary
		else:
			push_error("데이터 파일 파싱 실패: %s" % path)
	_cache[path] = result
	return result

## 읽어 온 값의 형태를 확인해서 넘긴다. 타입이 다른 값을 **타입 있는 변수**에
## 대입하면(또는 배열 아닌 값을 for로 돌면) 런타임 에러가 나고 그 함수가 그 자리에서
## 멈춘다 — `_ready`에서 터지면 뒤따르는 월드 조립·접속까지 날아가 빈 화면이 된다.
##
## 이 규칙이 로더 옆에 있는 이유: 부팅 최상단(main.gd)에서 죽으면 월드 쪽 가드는
## 도달조차 못 한다(리뷰 지적 — characters.json이 그 경로였다).
##
## `what`에는 "items.json의 items"처럼 **파일까지 포함한 라벨**을 넘긴다. 문구에
## 파일명을 박아 두면 다른 파일에 재사용할 때 경고가 거짓말이 된다.
static func dict_or_empty(v: Variant, what: String) -> Dictionary:
	if typeof(v) != TYPE_DICTIONARY:
		push_warning("%s가 딕셔너리가 아니라 무시: %s" % [what, str(v)])
		return {}
	return v as Dictionary

static func array_or_empty(v: Variant, what: String) -> Array:
	if typeof(v) != TYPE_ARRAY:
		push_warning("%s가 배열이 아니라 무시: %s" % [what, str(v)])
		return []
	return v as Array

## 숫자로 쓸 값. **컨테이너만 막으면 leaf에서 같은 이유로 죽는다** — 딕셔너리인 것을
## 확인해 받은 뒤 `float(d.get("ui_zoom"))`을 부르는데 그 값이 배열이면 캐스트가
## 런타임 에러를 낸다(리뷰 지적). 발생 조건은 세이브 손상처럼 좁지만, "형태를
## 확인해서 받는다"는 규칙을 한 단계 덜 지킨 상태였다.
static func float_or(v: Variant, fallback: float, what: String) -> float:
	match typeof(v):
		TYPE_FLOAT, TYPE_INT:
			return float(v)
		TYPE_STRING:
			# 데이터에 "1.0"처럼 문자열로 적힌 경우는 받아 준다(JSON 편집 실수).
			var t := String(v)
			if t.is_valid_float():
				push_warning("%s가 문자열이라 숫자로 읽음: %s" % [what, t])
				return t.to_float()
	push_warning("%s가 숫자가 아니라 기본값(%s) 사용: %s" % [what, str(fallback), str(v)])
	return fallback

## 테스트에서 파일을 바꿔 가며 확인할 때 쓴다.
static func clear_cache() -> void:
	_cache.clear()
