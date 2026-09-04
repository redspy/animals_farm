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

## 테스트에서 파일을 바꿔 가며 확인할 때 쓴다.
static func clear_cache() -> void:
	_cache.clear()
