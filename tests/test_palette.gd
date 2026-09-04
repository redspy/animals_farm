extends SceneTree

## 팔레트 정합성 테스트.
##
## 색을 data/palette.json으로 모아도, 코드가 참조하는 키가 데이터에 없으면
## 화면이 조용히 마젠타로 그려진다. 그걸 커밋 전에 잡는 것이 이 테스트다.
## 키 목록을 여기에 다시 적으면 그 자체가 또 하나의 중복 출처가 되므로,
## **scripts/*.gd 를 스캔해 실제 호출된 `Palette.color("group", "key")`를
## 추출**해서 데이터와 대조한다.
##
## 실행: <표준 Godot> --headless --path . --script tests/test_palette.gd
## (scripts/verify-project.sh가 포함해 돌린다. 소스가 있는 개발 환경 전용 —
##  export된 빌드에는 .gd 원문이 없다.)

const SCRIPT_DIR := "res://scripts"
const CALL_PATTERN := "Palette\\.color\\(\\s*\"([a-zA-Z_]+)\"\\s*,\\s*\"([a-zA-Z_]+)\"\\s*\\)"

var _failures := 0

func _initialize() -> void:
	_test_palette_file_is_valid()
	_test_every_used_key_exists()
	_test_missing_key_returns_magenta()

	if _failures > 0:
		printerr("❌ 팔레트 테스트 실패 %d건" % _failures)
		quit(1)
	else:
		print("✅ 팔레트 테스트 전부 통과")
		quit(0)

func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok  — %s" % what)
	else:
		_failures += 1
		printerr("  FAIL — %s" % what)

## 파일이 파싱되고, 모든 값이 실제로 유효한 색 문자열인지.
func _test_palette_file_is_valid() -> void:
	print("[test] palette.json 형식")
	var f := FileAccess.open(Palette.PATH, FileAccess.READ)
	_check(f != null, "팔레트 파일 열기")
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	_check(typeof(parsed) == TYPE_DICTIONARY, "JSON 파싱")
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var data := parsed as Dictionary
	for group: String in ["world", "ui", "character"]:
		_check(typeof(data.get(group)) == TYPE_DICTIONARY, "그룹 존재: %s" % group)
	for group: String in data.keys():
		if group.begins_with("_") or typeof(data[group]) != TYPE_DICTIONARY:
			continue   # _comment, schema_version 등 메타 필드는 건너뛴다
		for key: String in (data[group] as Dictionary).keys():
			var value: Variant = (data[group] as Dictionary)[key]
			var ok := typeof(value) == TYPE_STRING and Color.html_is_valid(String(value))
			_check(ok, "색 문자열 유효: %s.%s = %s" % [group, key, str(value)])

## 코드가 실제로 호출하는 키가 모두 데이터에 있는지 — 없으면 화면이 마젠타가 된다.
func _test_every_used_key_exists() -> void:
	print("[test] 코드가 참조하는 팔레트 키가 데이터에 존재하는지")
	var re := RegEx.new()
	_check(re.compile(CALL_PATTERN) == OK, "정규식 컴파일")
	var dir := DirAccess.open(SCRIPT_DIR)
	if dir == null:
		_failures += 1
		printerr("  FAIL — %s 를 열 수 없음" % SCRIPT_DIR)
		return
	var used := 0
	for file: String in dir.get_files():
		if not file.ends_with(".gd"):
			continue
		var f := FileAccess.open("%s/%s" % [SCRIPT_DIR, file], FileAccess.READ)
		if f == null:
			continue
		var text := f.get_as_text()
		f.close()
		for m: RegExMatch in re.search_all(text):
			var group := m.get_string(1)
			var key := m.get_string(2)
			used += 1
			_check(
				Palette.color(group, key) != Palette.MISSING,
				"%s → %s.%s" % [file, group, key]
			)
	# 호출을 하나도 못 찾았다면 정규식이나 경로가 깨진 것이다(테스트가 조용히
	# 아무것도 검사하지 않는 상태를 통과로 오인하지 않게 한다).
	_check(used > 0, "코드에서 Palette.color 호출을 %d건 찾음" % used)

## 없는 키는 마젠타를 돌려준다는 계약 — 이게 깨지면 키 누락을 눈으로 못 잡는다.
func _test_missing_key_returns_magenta() -> void:
	print("[test] 없는 키는 마젠타 반환")
	_check(Palette.color("world", "__없는키__") == Palette.MISSING, "없는 키 → MISSING")
	_check(Palette.color("__없는그룹__", "sea") == Palette.MISSING, "없는 그룹 → MISSING")
