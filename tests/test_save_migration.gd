extends SceneTree

## 세이브 마이그레이션 회귀 테스트. docs/design.md §4와 roles.md §4가 요구하는
## "구버전 세이브 로드 회귀 테스트"의 실체다.
##
## v2(캐릭터 슬롯 도입) 기준으로 갱신됨 — v0/v1의 단일 캐릭터 진행도가 슬롯
## 배열로 손실 없이 옮겨지는지가 이 테스트의 핵심이다. 진행도 손실은 되돌릴
## 수 없으므로 스키마를 바꿀 때마다 이 파일을 함께 고쳐야 한다.
##
## 실행:
##   <표준 Godot> --headless --path . --script tests/test_save_migration.gd

var _failures := 0

func _initialize() -> void:
	_test_default_save_shape()
	_test_v0_to_v2_moves_progress_into_slot()
	_test_v1_to_v2_moves_progress_into_slot()
	_test_empty_v1_makes_no_slot()
	_test_future_version_is_read_only()
	_test_corrupt_json_falls_back_to_default()
	_test_slot_helpers()
	_test_name_sanitize()
	_test_token_format()

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

func _test_default_save_shape() -> void:
	print("[test] 기본 세이브 구조")
	var d := SaveManager.default_save()
	for key: String in ["version", "slots", "last_slot", "first_played_unix", "last_played_unix"]:
		_check(d.has(key), "필드 존재: %s" % key)
	_check(int(d["version"]) == SaveManager.CURRENT_VERSION, "version이 현재 버전(%d)" % SaveManager.CURRENT_VERSION)
	_check(int(d["last_slot"]) == -1, "처음에는 고른 슬롯이 없다(-1)")
	_check((d["slots"] as Array).is_empty(), "슬롯 배열이 비어 있다")

## v0(버전 필드 없음) → v2: 진행도가 슬롯 0으로 손실 없이 옮겨져야 한다.
func _test_v0_to_v2_moves_progress_into_slot() -> void:
	print("[test] v0 → v2: 진행도가 슬롯으로 이동")
	var m := SaveManager.migrate(_load_fixture("save_v0.json"))
	_check(int(m.get("version", 0)) == 2, "version 2")
	_check(not m.has("bells"), "최상위 bells는 제거됨")
	_check(not m.has("inventory"), "최상위 inventory는 제거됨")
	var slots: Array = m.get("slots", [])
	_check(slots.size() == 1, "슬롯 1개 생성")
	if slots.is_empty():
		return
	var slot: Dictionary = slots[0]
	_check(int(slot.get("bells", -1)) == 1200, "벨 1200 보존")
	var inv: Dictionary = slot.get("inventory", {})
	_check(int(inv.get("wood", 0)) == 3, "가방 wood 3개 보존")
	_check(int(inv.get("shell", 0)) == 1, "가방 shell 1개 보존")
	_check(not String(slot.get("token", "")).is_empty(), "토큰 발급됨")
	_check(String(slot.get("name", "x")).is_empty(), "이름은 비어 있음(선택 화면에서 붙인다)")
	_check(int(m.get("last_slot", -1)) == 0, "마지막 슬롯이 0으로 지정됨")

func _test_v1_to_v2_moves_progress_into_slot() -> void:
	print("[test] v1 → v2: 진행도가 슬롯으로 이동")
	var m := SaveManager.migrate(_load_fixture("save_v1.json"))
	var slots: Array = m.get("slots", [])
	_check(slots.size() == 1, "슬롯 1개 생성")
	if slots.is_empty():
		return
	_check(int((slots[0] as Dictionary).get("bells", -1)) == 840, "벨 840 보존")
	_check(int(((slots[0] as Dictionary).get("inventory", {}) as Dictionary).get("fruit", 0)) == 2, "가방 fruit 2개 보존")
	# 진행도의 시작 시각은 v1 값을 이어받아야 한다(새로 시작한 것처럼 보이면 안 됨).
	_check(int((slots[0] as Dictionary).get("created_unix", 0)) == 1756000000, "created_unix가 v1의 first_played_unix를 이어받음")

## 진행도가 없는 v1 세이브(설치 후 아무것도 안 한 상태)는 빈 슬롯을 만들지 않는다.
func _test_empty_v1_makes_no_slot() -> void:
	print("[test] 진행도 없는 v1 → 슬롯 생성 안 함")
	var m := SaveManager.migrate({"version": 1, "bells": 0, "inventory": {}})
	_check((m.get("slots", []) as Array).is_empty(), "슬롯 없음")
	_check(int(m.get("last_slot", 0)) == -1, "last_slot -1")

## 미래 버전 세이브는 마이그레이션하지 않고 읽기 전용으로 잠근다 —
## 신버전이 만든 데이터를 구버전이 덮어써 잃는 사고를 막기 위함.
func _test_future_version_is_read_only() -> void:
	print("[test] 미래 버전 세이브: 읽기 전용")
	var m := SaveManager.migrate(_load_fixture("save_future.json"))
	_check(bool(m.get("_read_only", false)), "_read_only 플래그 설정")
	_check(int(m.get("version", 0)) == 99, "version을 강제로 내리지 않음")
	_check(SaveManager.save(m) == false, "읽기 전용이면 save()가 거부")

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
	_check((loaded.get("slots", []) as Array).is_empty(), "슬롯 비어 있음")
	_check(FileAccess.file_exists(SaveManager.SAVE_PATH + ".corrupt"), "손상 원본이 .corrupt로 백업됨")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SaveManager.SAVE_PATH))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SaveManager.SAVE_PATH + ".corrupt"))

func _test_slot_helpers() -> void:
	print("[test] 슬롯 읽기/쓰기/삭제")
	var save := SaveManager.default_save()
	_check(SaveManager.slots_view(save).size() == SaveManager.SLOT_COUNT,
		"slots_view는 항상 %d칸" % SaveManager.SLOT_COUNT)

	var slot := SaveManager.new_slot("f1", "미나", Vector2(1.5, -2.5))
	_check(SaveManager.put_slot(save, 2, slot), "슬롯 2에 쓰기 성공")
	_check(String((SaveManager.slots_view(save)[2] as Dictionary).get("name", "")) == "미나", "슬롯 2에서 읽힘")
	_check(float(((SaveManager.slots_view(save)[2] as Dictionary).get("pos", {}) as Dictionary).get("x", 0.0)) == 1.5,
		"스폰 위치 저장됨")

	# 범위를 벗어난 인덱스는 조용히 무시하지 않고 false를 돌려준다.
	_check(SaveManager.put_slot(save, SaveManager.SLOT_COUNT, slot) == false, "범위 밖 인덱스 거부")
	_check(SaveManager.put_slot(save, -1, slot) == false, "음수 인덱스 거부")

	# 이름 삭제 = 슬롯 비우기(= 캐릭터를 버리는 것). 토큰도 함께 사라진다.
	SaveManager.clear_slot(save, 2)
	_check((SaveManager.slots_view(save)[2] as Dictionary).is_empty(), "이름 삭제 후 슬롯이 비어 있음")

func _test_name_sanitize() -> void:
	print("[test] 이름 정리 규칙(서버와 동일해야 함)")
	_check(SaveManager.sanitize_name("  미나  ") == "미나", "앞뒤 공백 제거")
	_check(SaveManager.sanitize_name("미\n나") == "미나", "제어문자 제거")
	_check(SaveManager.sanitize_name("가나다라마바사아자차카타파하").length() == SaveManager.NAME_MAX_LEN,
		"%d자로 자름" % SaveManager.NAME_MAX_LEN)
	_check(SaveManager.sanitize_name("   ").is_empty(), "공백만 있으면 빈 이름")

## 토큰은 서버가 형식을 검사하므로(docs/protocol.md §1) UUIDv4 모양이어야 한다.
func _test_token_format() -> void:
	print("[test] 토큰 형식")
	var token := String(SaveManager.new_slot("f1", "가", Vector2.ZERO).get("token", ""))
	var re := RegEx.new()
	re.compile("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
	_check(re.search(token) != null, "UUIDv4 형식: %s" % token)
	var other := String(SaveManager.new_slot("f1", "가", Vector2.ZERO).get("token", ""))
	_check(token != other, "매번 다른 토큰")
