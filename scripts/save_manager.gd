extends RefCounted
class_name SaveManager

## 세이브 데이터 입출력. 웹(user://)에서는 브라우저 IndexedDB에 저장된다.
##
## AGENTS.md 세이브 규칙: 스키마에 버전 필드를 두고, 마이그레이션마다 역방향
## 손실 여부를 명시하며 구버전 로드 회귀 테스트를 남긴다. 진행도 손실은
## 되돌릴 수 없으므로 이 파일의 변경은 3종 CLI 교차검증 대상이다.

const SAVE_PATH := "user://save.json"
const CURRENT_VERSION := 1

static func default_save() -> Dictionary:
	return {
		"version": CURRENT_VERSION,
		"bells": 0,
		"inventory": {},
		"first_played_unix": int(Time.get_unix_time_from_system()),
		"last_played_unix": int(Time.get_unix_time_from_system()),
	}

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
		_backup_corrupt(text)
		push_warning("세이브가 손상됨 — .corrupt 백업 후 새 세이브로 시작")
		return default_save()
	return migrate(parsed as Dictionary)

## 구버전 세이브를 현재 스키마로 올린다. 각 단계는 손실 여부를 주석에 명시할 것.
static func migrate(data: Dictionary) -> Dictionary:
	var version: int = int(data.get("version", 0))
	if version > CURRENT_VERSION:
		# 미래 버전 세이브(다운그레이드)는 손실 위험이 커서 건드리지 않는다.
		push_warning("세이브 버전 %d은 이 빌드(%d)보다 최신 — 읽기만 하고 저장은 막는다" % [version, CURRENT_VERSION])
		data["_read_only"] = true
		return data
	# v0(버전 필드 없음) → v1: 누락 필드를 기본값으로 채움, 기존 값 손실 없음.
	# first_played_unix가 없는 구세이브는 "언제 시작했는지" 정보를 복구할 수
	# 없으므로 현재 시각으로 채운다(그 사실을 경고로 남긴다) — 예전에는 이
	# 필드를 아예 채우지 않아 저장 후에도 계속 누락된 채 남았다(2026-09-03
	# pre-commit Codex 감사 지적).
	if version < 1:
		data["version"] = 1
		data["bells"] = int(data.get("bells", 0))
		if typeof(data.get("inventory")) != TYPE_DICTIONARY:
			data["inventory"] = {}
		var now := int(Time.get_unix_time_from_system())
		if int(data.get("last_played_unix", 0)) <= 0:
			data["last_played_unix"] = now
		if int(data.get("first_played_unix", 0)) <= 0:
			push_warning("구세이브에 first_played_unix가 없어 현재 시각으로 채움(원래 시작 시각은 복구 불가)")
			data["first_played_unix"] = now
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

static func _backup_corrupt(text: String) -> void:
	var f := FileAccess.open(SAVE_PATH + ".corrupt", FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
