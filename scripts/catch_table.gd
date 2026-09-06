extends RefCounted
class_name CatchTable

## 낚시·벌레의 확률 테이블(`data/gatherables.json`의 `catch_tables`)을 읽는다.
##
## **여기서 아이템을 고르지 않는다.** 무엇이 잡히는지는 서버가 자기 시계로
## 추첨한다(docs/design.md §6-C) — 클라이언트가 고르면 기기 시계를 겨울 밤으로
## 맞춰 실러캔스만 반복해서 잡을 수 있다. 이 클래스가 하는 일은 두 가지다:
##
## 1. **어떤 kind가 테이블 구동인지** 알려준다. 서버는 `catch_tables`의 키를
##    단일 출처로 쓰는데, 클라이언트가 ["fishing","bug"]를 하드코딩하면 세 번째
##    종류를 추가하는 순간 서버는 아이템을 비우고 클라는 "wood"를 넣어 갈린다.
## 2. **지금 무엇이든 잡히는지** 알려준다(표시용). 조건 밖이면 벌레 메시를
##    감춰서, 걸어가서 거절당하고 이유를 모르는 상황을 막는다.

const PATH := "res://data/gatherables.json"

static var _tables: Dictionary = {}
static var _loaded := false

static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	var cfg := DataFiles.load_dict(PATH)
	var raw: Variant = cfg.get("catch_tables", {})
	if typeof(raw) != TYPE_DICTIONARY:
		return
	for kind: Variant in (raw as Dictionary).keys():
		var rows: Variant = (raw as Dictionary)[kind]
		if typeof(rows) != TYPE_ARRAY:
			continue
		var entries: Array = []
		for r: Variant in rows as Array:
			if typeof(r) != TYPE_DICTIONARY:
				continue
			var row := r as Dictionary
			entries.append({
				"item": String(row.get("item", "")),
				"hours": row.get("hours", null),
				"months": row.get("months", null),
			})
		_tables[String(kind)] = entries

## 이 종류가 확률 테이블로 아이템을 정하는지(= spawn에 item이 없는지).
static func is_table_kind(kind: String) -> bool:
	_load()
	return _tables.has(kind)

## 지금(로컬 시계) 조건에 맞는 항목이 하나라도 있는지 — **표시용**이다.
## 실제 판정은 서버가 하므로, 여기서 맞다고 해서 반드시 잡히는 것은 아니다
## (기기 시계가 서버와 다르면 갈린다 — 그때는 서버가 이긴다).
static func any_available(kind: String, now: Dictionary = {}) -> bool:
	_load()
	if not _tables.has(kind):
		return true
	var t: Dictionary = now if not now.is_empty() else GameClock.now()
	var hour := int(t.get("hour", 12))
	var month := int(t.get("month", 1))
	for e: Variant in _tables[kind] as Array:
		if _matches(e as Dictionary, hour, month):
			return true
	return false

static func _matches(entry: Dictionary, hour: int, month: int) -> bool:
	var months: Variant = entry.get("months", null)
	if months != null and typeof(months) == TYPE_ARRAY:
		var found := false
		for m: Variant in months as Array:
			if int(m) == month:
				found = true
				break
		if not found:
			return false
	var hours: Variant = entry.get("hours", null)
	if hours == null or typeof(hours) != TYPE_ARRAY or (hours as Array).size() != 2:
		return true
	var from := int((hours as Array)[0])
	var to := int((hours as Array)[1])
	# 시작 > 끝이면 자정을 넘는 구간(예: 19~6시).
	return (hour >= from and hour < to) if from <= to else (hour >= from or hour < to)
