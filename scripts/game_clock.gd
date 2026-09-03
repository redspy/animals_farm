extends RefCounted
class_name GameClock

## 게임 시간. 동물의 숲 원칙대로 "현실 시간 = 게임 시간"이다(docs/design.md §1).
## 서버 시간에 의존하지 않고 로컬 시계를 쓰므로 기기 시간을 바꾸면 앞당길 수
## 있다 — 온라인 재화가 붙는 시점에는 서버 검증이 필요하다(설계 미확정).

const SEASONS := ["봄", "여름", "가을", "겨울"]

static func now() -> Dictionary:
	return Time.get_datetime_dict_from_system()

static func season_of(month: int) -> String:
	# 3~5 봄, 6~8 여름, 9~11 가을, 12~2 겨울 (북반구 기준)
	var idx := int(floor((float(month) % 12.0) / 3.0))
	return SEASONS[clampi(idx, 0, 3)]

static func label() -> String:
	var t := now()
	return "%04d-%02d-%02d %02d:%02d (%s)" % [t.year, t.month, t.day, t.hour, t.minute, season_of(int(t.month))]

## 마지막 접속 이후 하루가 지났는지 — 채집물 전체 리스폰/일일 이벤트 트리거용.
static func days_since(last_unix: int) -> int:
	if last_unix <= 0:
		return 0
	var elapsed := int(Time.get_unix_time_from_system()) - last_unix
	return int(floor(float(elapsed) / 86400.0))
