extends RefCounted
class_name SaveManager

## 세이브 데이터 입출력. 웹(user://)에서는 브라우저 IndexedDB에 저장된다.
##
## AGENTS.md 세이브 규칙: 스키마에 버전 필드를 두고, 마이그레이션마다 역방향
## 손실 여부를 명시하며 구버전 로드 회귀 테스트를 남긴다(tests/test_save_migration.gd).
## 진행도 손실은 되돌릴 수 없으므로 이 파일의 변경은 3종 CLI 교차검증 대상이다.
##
## v2 스키마(2026-09-04, 캐릭터 슬롯 도입):
## {
##   "version": 2,
##   "slots": [ { "token", "preset", "name", "bells", "inventory", "pos": {"x","z"},
##                "created_unix", "last_played_unix" }, ... ],   # 최대 SLOT_COUNT개
##   "last_slot": 0,        # 마지막으로 고른 슬롯 인덱스(-1이면 없음)
##   "first_played_unix": 0
## }
##
## 토큰은 서버에서 캐릭터를 식별하는 유일한 열쇠다(docs/protocol.md §1) —
## 세이브를 지우면 그 캐릭터를 되찾을 수 없으므로 토큰을 함부로 재발급하지 않는다.

const SAVE_PATH := "user://save.json"
const CURRENT_VERSION := 2

## 기기별 슬롯 수. 늘리면 선택 화면도 함께 늘어난다(코드 상수 하나로 확장).
const SLOT_COUNT := 5
const NAME_MAX_LEN := 12

static func default_save() -> Dictionary:
	var now := int(Time.get_unix_time_from_system())
	return {
		"version": CURRENT_VERSION,
		"slots": [],
		"last_slot": -1,
		"first_played_unix": now,
		"last_played_unix": now,
	}

static func new_slot(preset_id: String, name: String, spawn: Vector2) -> Dictionary:
	var now := int(Time.get_unix_time_from_system())
	return {
		"token": _new_token(),
		"preset": preset_id,
		"name": sanitize_name(name),
		"bells": 0,
		"inventory": {},
		"pos": {"x": spawn.x, "z": spawn.y},
		"created_unix": now,
		"last_played_unix": now,
	}

## 이름 정리 — 서버도 같은 규칙을 강제한다(docs/protocol.md §3). 여기서 먼저
## 다듬어 두면 사용자가 서버 거절 메시지를 보기 전에 화면에서 바로 알 수 있다.
static func sanitize_name(raw: String) -> String:
	var cleaned := ""
	for c in raw.strip_edges():
		# 제어문자는 렌더를 깨뜨리므로 버린다.
		if c.unicode_at(0) >= 32:
			cleaned += c
	if cleaned.length() > NAME_MAX_LEN:
		cleaned = cleaned.substr(0, NAME_MAX_LEN)
	return cleaned

static func load_save() -> Dictionary:
	if not FileAccess.file_exists(SAVE_PATH):
		return default_save()
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		push_warning("세이브 열기 실패(%d) — 새 세이브로 시작" % FileAccess.get_open_error())
		return default_save()
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		# 손상된 세이브를 조용히 덮어쓰지 않는다 — 백업을 남기고 새로 시작한다.
		# 백업까지 실패하면 원본이 유일한 사본이므로 저장을 막는다(_read_only).
		var fresh := default_save()
		if _backup_corrupt(text):
			push_warning("세이브가 손상됨 — .corrupt 백업 후 새 세이브로 시작")
		else:
			push_error("세이브가 손상됐고 백업도 실패 — 원본 보존을 위해 저장을 막는다(읽기 전용)")
			fresh["_read_only"] = true
		return fresh
	return migrate(parsed as Dictionary)

## 구버전 세이브를 현재 스키마로 올린다. 각 단계는 손실 여부를 주석에 명시할 것.
static func migrate(data: Dictionary) -> Dictionary:
	var version: int = int(data.get("version", 0))
	if version > CURRENT_VERSION:
		# 미래 버전 세이브(다운그레이드)는 손실 위험이 커서 건드리지 않는다.
		push_warning("세이브 버전 %d은 이 빌드(%d)보다 최신 — 읽기만 하고 저장은 막는다" % [version, CURRENT_VERSION])
		data["_read_only"] = true
		return data

	var now := int(Time.get_unix_time_from_system())

	# v0(버전 필드 없음) → v1: 누락 필드를 기본값으로 채움, 기존 값 손실 없음.
	# first_played_unix가 없는 구세이브는 원래 시작 시각을 복구할 수 없어 현재
	# 시각으로 채운다(그 사실을 경고로 남긴다).
	if version < 1:
		data["version"] = 1
		data["bells"] = int(data.get("bells", 0))
		if typeof(data.get("inventory")) != TYPE_DICTIONARY:
			data["inventory"] = {}
		if int(data.get("last_played_unix", 0)) <= 0:
			data["last_played_unix"] = now
		if int(data.get("first_played_unix", 0)) <= 0:
			push_warning("구세이브에 first_played_unix가 없어 현재 시각으로 채움(원래 시작 시각은 복구 불가)")
			data["first_played_unix"] = now

	# v1 → v2: 단일 캐릭터를 슬롯 배열로 옮긴다.
	# 손실 없음 — v1의 bells/inventory를 첫 슬롯이 그대로 이어받는다. 다만 v1에는
	# 캐릭터 개념이 없었으므로 프리셋/이름은 알 수 없어 기본값을 넣고, 토큰은
	# 이 시점에 새로 발급한다(서버 기록이 없던 시절의 세이브이므로 안전하다).
	if int(data.get("version", 0)) < 2:
		var slots: Array = []
		var had_progress := int(data.get("bells", 0)) > 0 \
			or (typeof(data.get("inventory")) == TYPE_DICTIONARY and not (data["inventory"] as Dictionary).is_empty())
		if had_progress:
			slots.append({
				"token": _new_token(),
				"preset": "",         # 선택 화면에서 사용자가 고르게 한다
				"name": "",           # 이름 미지정 상태 = 빈 슬롯이 아니라 "이름 없는 기존 진행도"
				"bells": int(data.get("bells", 0)),
				"inventory": data.get("inventory", {}),
				"pos": {"x": 0.0, "z": 0.0},
				"created_unix": int(data.get("first_played_unix", now)),
				"last_played_unix": int(data.get("last_played_unix", now)),
			})
		data["slots"] = slots
		data["last_slot"] = 0 if had_progress else -1
		data.erase("bells")
		data.erase("inventory")
		data["version"] = 2
	return data

static func save(data: Dictionary) -> bool:
	if bool(data.get("_read_only", false)):
		push_warning("읽기 전용 세이브 — 저장 생략")
		return false
	data["version"] = CURRENT_VERSION
	data["last_played_unix"] = int(Time.get_unix_time_from_system())
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("세이브 쓰기 실패(%d)" % FileAccess.get_open_error())
		return false
	f.store_string(JSON.stringify(data))
	f.close()
	return true

## 슬롯 목록을 SLOT_COUNT 길이로 맞춰 돌려준다(빈 칸은 빈 Dictionary).
static func slots_view(data: Dictionary) -> Array:
	var raw: Variant = data.get("slots", [])
	var out: Array = []
	for i in SLOT_COUNT:
		if typeof(raw) == TYPE_ARRAY and i < (raw as Array).size() and typeof((raw as Array)[i]) == TYPE_DICTIONARY:
			out.append((raw as Array)[i])
		else:
			out.append({})
	return out

## 슬롯을 쓴다. index가 범위를 벗어나면 아무것도 하지 않고 false.
static func put_slot(data: Dictionary, index: int, slot: Dictionary) -> bool:
	if index < 0 or index >= SLOT_COUNT:
		push_warning("슬롯 인덱스 범위 밖: %d" % index)
		return false
	var slots: Array = data.get("slots", [])
	while slots.size() <= index:
		slots.append({})
	slots[index] = slot
	data["slots"] = slots
	return true

## 이름 삭제 = 슬롯 비우기. 컨셉상 "이름 삭제 전까지 이름을 기억"이므로,
## 이름을 지우는 것이 곧 그 캐릭터를 버리는 것이다 — 토큰도 함께 사라져
## 서버 기록과의 연결이 끊긴다는 점을 호출부에서 사용자에게 알려야 한다.
static func clear_slot(data: Dictionary, index: int) -> bool:
	return put_slot(data, index, {})

static func _new_token() -> String:
	# Godot 4의 crypto RNG로 UUIDv4 형태를 만든다(서버는 형식만 검사한다).
	var bytes := Crypto.new().generate_random_bytes(16)
	bytes[6] = (bytes[6] & 0x0f) | 0x40
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	var hex := bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [
		hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4), hex.substr(16, 4), hex.substr(20, 12)
	]

static func _backup_corrupt(text: String) -> bool:
	var f := FileAccess.open(SAVE_PATH + ".corrupt", FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	return FileAccess.file_exists(SAVE_PATH + ".corrupt")
