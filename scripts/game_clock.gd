extends RefCounted
class_name GameClock

## 게임 시간. 동물의 숲 원칙대로 "현실 시간 = 게임 시간"이다(docs/design.md §1).
##
## **여기는 HUD 표시용 로컬 시계다.** 보상·판정이 걸린 시각은 이미 서버가 소유한다
## (낚시·벌레의 시간·월 조건, 하루 1개 부탁의 날짜, 벨 정산). 그래서 기기 시간을
## 바꿔도 재화를 앞당길 수는 없다. 앞당기면 화면의 계절·시각 표시와 클라이언트의
## 오랜만 인사 토스트(`_greet_returning_player`)가 같이 도는데, 둘 다 서버 상태를
## 바꾸지 않는다
## (2026-09-16 Codex 문서 감사에서 옛 주석을 정정).

const SEASONS := ["봄", "여름", "가을", "겨울"]

static func now() -> Dictionary:
	return Time.get_datetime_dict_from_system()

## 3~5 봄, 6~8 여름, 9~11 가을, 12~2 겨울 (북반구 기준).
## 예전 구현은 (a) float에 `%`를 써서 컴파일 자체가 실패했고(GDScript의 `%`는
## 정수 전용 — fmod()가 필요), (b) 나머지를 3으로 나눠 3월을 "여름"으로
## 반환했다. 3월이 인덱스 0(봄)이 되도록 -3 시프트한 뒤 계산한다.
## (2026-09-04 표준 Godot 4.7.1로 실제 기동해서 발견 — mono 빌드로는 헤드리스
## 실행이 막혀 있어 그때까지 드러나지 않았다.)
static func season_of(month: int) -> String:
	var shifted := ((month - 3) % 12 + 12) % 12
	return SEASONS[shifted / 3]

static func label() -> String:
	var t := now()
	return "%04d-%02d-%02d %02d:%02d (%s)" % [t.year, t.month, t.day, t.hour, t.minute, season_of(int(t.month))]

## 좁은 화면(폰)용 짧은 표기 — 연도는 화면 폭을 먹는 만큼의 정보가 없다.
static func short_label() -> String:
	var t := now()
	return "%02d-%02d %02d:%02d (%s)" % [t.month, t.day, t.hour, t.minute, season_of(int(t.month))]

## 마지막 접속 이후 **24시간 블록이 몇 번 지났는지**(`floor(경과/86400)`) — 달력 날짜가
## 아니다. 월 23시 → 수 22시면 달력상 이틀이 지났어도 1을 준다. 일일 이벤트처럼
## "날짜가 바뀌었나"를 물어야 하는 기능은 이 함수를 그대로 쓰면 안 된다.
## **지금 쓰는 곳은 오랜만 인사 토스트 하나뿐이다**
## (`world.gd::_greet_returning_player`). 채집물 재생은 서버가 소유하고, 일일 이벤트는
## 미구현이다.
static func days_since(last_unix: int) -> int:
	if last_unix <= 0:
		return 0
	var elapsed := int(Time.get_unix_time_from_system()) - last_unix
	return int(floor(float(elapsed) / 86400.0))
