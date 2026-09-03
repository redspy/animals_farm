extends RefCounted
class_name Balance

## 밸런스 데이터의 유효범위 적용 규칙 한 곳. 예전에는 main.gd와 gatherable.gd가
## 각자 다른 방식으로 클램프해서(한쪽은 범위가 없으면 경고 없이 통과, 다른 쪽은
## 경고만 하고 클램프 안 함, 양쪽 다 lo > hi 같은 잘못된 범위를 검증 안 함)
## "항상 클램프하고 항상 경고한다"는 문서 규칙과 어긋났다(2026-09-03 Codex 감사 지적).
##
## 데이터가 단일 출처라는 원칙은 유지한다 — 아래 폴백 범위는 "출처"가 아니라
## 데이터가 깨졌을 때의 마지막 안전장치이며, 발동하면 반드시 경고를 남긴다.

const FALLBACK := {
	"price": [0.0, 1000000.0],
	"duration_sec": [1.0, 86400.0],
}

## 범위 배열이 쓸 수 있는 형태인지 검증한다([lo, hi] 숫자 2개, lo <= hi).
static func valid_range(range_raw: Variant) -> bool:
	if typeof(range_raw) != TYPE_ARRAY:
		return false
	var arr := range_raw as Array
	if arr.size() != 2:
		return false
	for v: Variant in arr:
		if typeof(v) != TYPE_INT and typeof(v) != TYPE_FLOAT:
			return false
	return float(arr[0]) <= float(arr[1])

## 항상 클램프하고, 범위를 벗어났거나 범위 자체가 잘못됐으면 항상 경고한다.
static func clamp_value(value: float, range_raw: Variant, what: String, fallback_key: String) -> float:
	var range_arr: Array = []
	if valid_range(range_raw):
		range_arr = range_raw as Array
	else:
		push_warning("%s: 유효범위가 없거나 잘못됨(%s) — 폴백 범위 %s 적용, 데이터를 고칠 것"
			% [what, str(range_raw), str(FALLBACK[fallback_key])])
		range_arr = FALLBACK[fallback_key]
	var lo := float(range_arr[0])
	var hi := float(range_arr[1])
	if value < lo or value > hi:
		push_warning("%s 값 %s이 유효범위 [%s, %s] 밖 — 클램프" % [what, str(value), str(lo), str(hi)])
	return clampf(value, lo, hi)
