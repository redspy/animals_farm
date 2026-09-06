class_name Npc
extends Node3D

## 이웃 동물 한 마리. 위치·대사는 `data/npcs.json`이 단일 출처이고, **부탁 상태와
## 정산은 서버가 소유한다**(docs/protocol.md의 `npc_deliver`).
##
## 배회를 **시간 함수**로 만든 이유: 서버가 NPC 위치를 소유하면 3마리 × 10Hz
## 브로드캐스트가 늘어나는데, 얻는 것은 "모두가 똑같은 자리에서 본다"뿐이다.
## 그네와 같은 결정(docs/design.md §6-B)으로, 각 클라이언트가 자기 시계로 같은
## 함수를 그린다 — 기기 시계가 몇 초 달라도 "그 근처를 어슬렁거린다"는 사실은
## 같고, 상호작용 판정은 **기준 좌표에서의 거리**로 서버가 한다.

## 대화할 수 있는 거리(월드 단위). 서버도 같은 뜻의 검사를 하되 배회 반경을
## 더해 여유를 둔다 — 클라이언트마다 보이는 위치가 조금씩 다르다.
const TALK_DISTANCE := 2.2

## 배회 주기(초). 두 축의 주기를 다르게 두면 원을 돌지 않고 리사주 곡선처럼
## 불규칙하게 보인다 — 같은 주기면 기계적인 원운동이 된다.
const WANDER_PERIOD_X := 23.0
const WANDER_PERIOD_Z := 31.0

var id := ""
var label := ""
var species := "cat"
var base_position := Vector3.ZERO
var wander_radius := 3.0

var _sprite: NpcSprite
var _extras: AvatarExtras
var _mark: Label3D
var _phase := 0.0
var _last_pos := Vector3.ZERO
var _greet: Array = []
var _greet_index := 0
var _dialogue: Dictionary = {}

func setup(data: Dictionary) -> void:
	id = String(data.get("id", ""))
	label = String(data.get("label", id))
	species = String(data.get("species", "cat"))
	base_position = Vector3(float(data.get("x", 0.0)), 0.0, float(data.get("z", 0.0)))
	# 유효범위의 단일 출처는 데이터의 limits다(AGENTS.md 밸런스 규칙) — 여기에
	# 상한을 박으면 데이터에서 바꿔도 클라이언트만 안 따라간다.
	var limits: Dictionary = DataFiles.load_dict("res://data/npcs.json").get("limits", {})
	wander_radius = Balance.clamp_value(
		float(data.get("wander_radius", 3.0)),
		limits.get("wander_radius", null),
		"npcs.%s.wander_radius" % id, "wander_radius")
	_dialogue = data.get("dialogue", {}) as Dictionary
	_greet = _dialogue.get("greet", []) as Array
	# 위상은 id에서 뽑는다 — 세 마리가 같은 리듬으로 움직이면 한 몸처럼 보인다.
	_phase = float(hash(id) % 1000) / 1000.0 * TAU
	position = base_position
	_last_pos = base_position

func _ready() -> void:
	_sprite = NpcSprite.new()
	_sprite.setup(species)
	add_child(_sprite)

	# 이름표·말풍선은 플레이어와 같은 노드를 재사용한다 — 대사를 말풍선으로
	# 띄우는 연출이 공짜로 따라온다.
	_extras = AvatarExtras.new()
	add_child(_extras)
	_extras.set_name_text(label)

	# 부탁이 있으면 머리 위에 표시한다. 화면에 알림을 띄우지 않는 이유: 섬을
	# 돌아다니다 **눈으로 발견하는** 편이 이 게임의 리듬에 맞다.
	_mark = Label3D.new()
	_mark.text = "!"
	_mark.font_size = 96
	_mark.outline_size = 12
	_mark.modulate = Palette.color("npc", "mark")
	_mark.outline_modulate = Palette.color("ui", "hud_outline")
	_mark.pixel_size = 0.012
	_mark.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	_mark.no_depth_test = true
	_mark.render_priority = 2
	_mark.position = Vector3(0, 2.6, 0)
	_mark.visible = false
	add_child(_mark)

func _process(_delta: float) -> void:
	# 시간 함수 배회. 기기 시계를 쓰므로 클라이언트마다 몇 초 어긋날 수 있고,
	# 그건 감수한다(NPC는 장식이고 판정은 기준 좌표로 한다).
	var t := Time.get_unix_time_from_system()
	var offset := Vector3(
		sin(t / WANDER_PERIOD_X * TAU + _phase) * wander_radius * 0.7,
		0.0,
		cos(t / WANDER_PERIOD_Z * TAU + _phase * 1.7) * wander_radius * 0.7
	)
	position = base_position + offset
	if _sprite != null:
		var moved := position - _last_pos
		if moved.length() > 0.0005:
			_sprite.face(Vector2(moved.x, moved.z).normalized())
	_last_pos = position

## 부탁이 남아 있는지 표시한다(느낌표).
func set_has_request(on: bool) -> void:
	if _mark != null:
		_mark.visible = on

## 말풍선으로 한 마디. 인사는 순서대로 돌려 쓴다 — 무작위면 같은 말이 연속으로
## 나와서 대사가 하나뿐인 것처럼 보인다.
func next_greeting() -> String:
	if _greet.is_empty():
		return "…"
	var line := String(_greet[_greet_index % _greet.size()])
	_greet_index += 1
	return line

func say(text: String) -> void:
	if _extras != null:
		# 채팅과 같은 말풍선을 쓴다 — 표시 시간·배경 규격이 한 곳에서 정해진다.
		_extras.show_chat(text)

func dialogue(key: String, fallback: String = "") -> String:
	return String(_dialogue.get(key, fallback))

## 대화할 수 있는 거리인지(보이는 위치 기준).
func can_talk(from: Vector3) -> bool:
	return Vector2(from.x - position.x, from.z - position.z).length() <= TALK_DISTANCE

## 다가갈 목표 지점 — 발밑이 아니라 조금 앞에 선다.
func approach_point(from: Vector3) -> Vector3:
	var here := Vector2(position.x, position.z)
	var me := Vector2(from.x, from.z)
	var dir := (me - here)
	if dir.length() < 0.001:
		dir = Vector2(0, 1)
	dir = dir.normalized() * (TALK_DISTANCE * 0.7)
	return Vector3(here.x + dir.x, 0.0, here.y + dir.y)
