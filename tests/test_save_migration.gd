extends SceneTree

## 세이브 마이그레이션 회귀 테스트. docs/design.md §4와 roles.md §4가 요구하는
## "구버전 세이브 로드 회귀 테스트"의 실체다 — 문서가 절차를 규정하는데 테스트가
## 없던 문제를 해결한다(2026-09-03 Codex 감사 지적).
##
## 실행:
##   <표준 Godot> --headless --path . --script tests/test_save_migration.gd
## (scripts/verify-project.sh가 이 명령을 포함해 돌린다)

var _failures := 0

func _initialize() -> void:
	_test_v0_fills_all_schema_fields()
	_test_v0_preserves_existing_values()
	_test_future_version_is_read_only()
	_test_corrupt_json_falls_back_to_default()
	_test_default_save_has_schema_fields()

	if _failures > 0:
		printerr("❌ 세이브 마이그레이션 테스트 실패 %d건" % _failures)
		quit(1)
	else:
		print("✅ 세이브 마이그레이션 테스트 전부 통과")
		quit(0)

func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok  — %s" % what)
	else:
		_failures += 1
		printerr("  FAIL — %s" % what)

func _load_fixture(name: String) -> Dictionary:
	var f := FileAccess.open("res://tests/fixtures/%s" % name, FileAccess.READ)
	if f == null:
		_failures += 1
		printerr("  FAIL — 픽스처 없음: %s" % name)
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed as Dictionary if typeof(parsed) == TYPE_DICTIONARY else {}

## v0(버전 필드 없음) 세이브를 올리면 문서 스키마의 모든 필드가 채워져야 한다.
func _test_v0_fills_all_schema_fields() -> void:
	print("[test] v0 → v1: 스키마 필드 전부 채움")
	var migrated := SaveManager.migrate(_load_fixture("save_v0.json"))
	for key: String in ["version", "bells", "inventory", "first_played_unix", "last_played_unix"]:
		_check(migrated.has(key), "필드 존재: %s" % key)
	_check(int(migrated.get("version", 0)) == SaveManager.CURRENT_VERSION, "version이 현재 버전")
	_check(int(migrated.get("first_played_unix", 0)) > 0, "first_played_unix가 채워짐")
	_check(int(migrated.get("last_played_unix", 0)) > 0, "last_played_unix가 채워짐")

## 마이그레이션은 기존 진행도를 잃지 않아야 한다(손실 없음이 v0→v1의 계약).
func _test_v0_preserves_existing_values() -> void:
	print("[test] v0 → v1: 기존 값 보존")
	var migrated := SaveManager.migrate(_load_fixture("save_v0.json"))
	_check(int(migrated.get("bells", -1)) == 1200, "벨 보존(1200)")
	var inv: Dictionary = migrated.get("inventory", {})
	_check(int(inv.get("wood", 0)) == 3, "가방 wood 3개 보존")
	_check(int(inv.get("shell", 0)) == 1, "가방 shell 1개 보존")

## 미래 버전 세이브는 마이그레이션하지 않고 읽기 전용으로 잠근다 —
## 신버전이 만든 데이터를 구버전이 덮어써 잃는 사고를 막기 위함.
func _test_future_version_is_read_only() -> void:
	print("[test] 미래 버전 세이브: 읽기 전용")
	var migrated := SaveManager.migrate(_load_fixture("save_future.json"))
	_check(bool(migrated.get("_read_only", false)), "_read_only 플래그 설정")
	_check(int(migrated.get("version", 0)) == 99, "version을 강제로 내리지 않음")
	_check(SaveManager.save(migrated) == false, "읽기 전용이면 save()가 거부")

## 손상된 JSON은 조용히 덮어쓰지 않고 기본 세이브로 시작해야 한다.
func _test_corrupt_json_falls_back_to_default() -> void:
	print("[test] 손상된 세이브: 기본값 폴백 + .corrupt 백업")
	var f := FileAccess.open(SaveManager.SAVE_PATH, FileAccess.WRITE)
	_check(f != null, "테스트용 손상 세이브 쓰기 가능")
	if f != null:
		f.store_string("{ this is not json ")
		f.close()
	var loaded := SaveManager.load_save()
	_check(int(loaded.get("version", 0)) == SaveManager.CURRENT_VERSION, "기본 세이브로 시작")
	_check(int(loaded.get("bells", -1)) == 0, "벨 0으로 초기화")
	_check(FileAccess.file_exists(SaveManager.SAVE_PATH + ".corrupt"), "손상 원본이 .corrupt로 백업됨")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SaveManager.SAVE_PATH))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SaveManager.SAVE_PATH + ".corrupt"))

func _test_default_save_has_schema_fields() -> void:
	print("[test] 기본 세이브: 스키마 필드")
	var d := SaveManager.default_save()
	for key: String in ["version", "bells", "inventory", "first_played_unix", "last_played_unix"]:
		_check(d.has(key), "필드 존재: %s" % key)
