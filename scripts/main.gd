extends Node

## 진입점 라우터: 캐릭터 선택 화면 → 월드맵.
##
## 컨셉(docs/roadmap.md P1): 시작하면 기기별 캐릭터 슬롯을 보여주고, 하나를
## 골라 이름을 붙이면 그 캐릭터로 월드에 들어간다. 슬롯은 이름을 지울 때까지
## 이름·외형·위치·진행도를 기억한다.
##
## 월드 로직은 world.gd, 선택 UI는 character_select.gd가 갖는다 — main은 둘을
## 갈아 끼우는 일만 한다.

var _save: Dictionary = {}
var _presets: Array = []
var _world_cfg: Dictionary = {}
var _select: CharacterSelect = null
var _world: World = null

func _ready() -> void:
	_save = SaveManager.load_save()
	_presets = DataFiles.load_dict("res://data/characters.json").get("presets", [])
	_world_cfg = DataFiles.load_dict("res://data/world.json")
	if _presets.is_empty():
		push_error("data/characters.json에 프리셋이 없어 캐릭터를 만들 수 없다")
	_show_select()

func _show_select() -> void:
	var spawn: Dictionary = _world_cfg.get("spawn", {})
	_select = CharacterSelect.new()
	_select.setup(_save, _presets, Vector2(float(spawn.get("x", 0.0)), float(spawn.get("z", 0.0))))
	_select.slot_chosen.connect(_on_slot_chosen)
	add_child(_select)

func _on_slot_chosen(index: int, slot: Dictionary) -> void:
	if _select != null:
		_select.queue_free()
		_select = null
	_save["last_slot"] = index
	SaveManager.save(_save)

	_world = World.new()
	_world.setup(_save, index, _preset_by_id(String(slot.get("preset", ""))), _world_cfg)
	add_child(_world)

func _preset_by_id(preset_id: String) -> Dictionary:
	for p: Variant in _presets:
		if typeof(p) == TYPE_DICTIONARY and String((p as Dictionary).get("id", "")) == preset_id:
			return p as Dictionary
	# 프리셋이 사라졌거나(데이터에서 항목 삭제) 지정되지 않은 슬롯 —
	# 캐릭터를 못 만들어 게임이 멈추는 대신 첫 프리셋으로 대체하고 경고한다.
	if not _presets.is_empty():
		push_warning("프리셋 '%s'을 찾을 수 없어 첫 프리셋으로 대체" % preset_id)
		return _presets[0] as Dictionary
	return {}
