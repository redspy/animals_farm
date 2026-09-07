extends SceneTree

## 캐릭터·동물 스프라이트를 **확대 시트**로 뽑는 도구.
##
## 왜 필요한가: 도트 캐릭터는 게임 화면에서 40~60px로 보이므로 코드만 읽고는
## "얼굴이 보이는지"를 알 수 없다. 실제로 첫 구현은 머리카락이 얼굴을 통째로
## 덮고 있었는데(눈이 그려진 뒤 지워졌다) 그 사실을 **시트를 뽑아 보고서야**
## 알았다(docs/design.md §5 도트 캐릭터 규칙).
##
## 실행:
##   npm run sprites          # 세 장을 build/에 저장
##   <표준 Godot> --headless --path . --script tools/sprite_sheet.gd -- npc
##
## 인자(선택): presets | activities | npc  (없으면 전부)

const ZOOM := 6
## 잔디색 배경 — 실제 화면과 비슷한 조건에서 봐야 외곽선 판단이 맞다.
const BG := Color(0.35, 0.55, 0.32)

func _initialize() -> void:
	var want := _wanted()
	if want.has("presets"):
		await _presets_sheet()
	if want.has("activities"):
		await _activities_sheet()
	if want.has("npc"):
		await _npc_sheet()
	quit()

func _wanted() -> Array:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		return ["presets", "activities", "npc"]
	var out: Array = []
	for a: String in args:
		out.append(a.strip_edges())
	return out

## 프리셋별 idle 4방향 + 걷기 한 장.
func _presets_sheet() -> void:
	var presets: Array = DataFiles.load_dict("res://data/characters.json").get("presets", [])
	if presets.is_empty():
		push_error("data/characters.json에 프리셋이 없어 프리셋 시트를 만들 수 없습니다")
		return
	var sprites: Array = []
	for p: Variant in presets:
		var s := PlayerSprite.new()
		s.setup(p as Dictionary)
		get_root().add_child(s)
		sprites.append(s)
	await process_frame
	var rows: Array = []
	for s: PlayerSprite in sprites:
		var row: Array = []
		for anim: String in ["idle_down", "idle_right", "idle_up", "walk_down"]:
			row.append(_frame_image(s, anim, 0 if anim.begins_with("idle") else 2))
		rows.append(row)
	_save(rows, "build/sprite-sheet.png")
	for s: PlayerSprite in sprites:
		s.queue_free()

## 활동(장비 오버레이)별 정면·측면.
func _activities_sheet() -> void:
	var acts := [["", ""], ["jumprope", "double"], ["soccer", ""], ["bike", ""],
		["inline", ""], ["kickboard", ""], ["fishing", ""], ["swing", ""], ["carousel", ""]]
	var presets: Array = DataFiles.load_dict("res://data/characters.json").get("presets", [])
	if presets.is_empty():
		push_error("data/characters.json에 프리셋이 없어 활동 시트를 만들 수 없습니다")
		return
	var s := PlayerSprite.new()
	s.setup(presets[mini(3, presets.size() - 1)] as Dictionary)
	get_root().add_child(s)
	await process_frame
	var rows: Array = []
	for pair: Array in acts:
		s.set_activity(String(pair[0]), String(pair[1]))
		await process_frame
		rows.append([
			_frame_image(s, "idle_down", 0), _frame_image(s, "walk_down", 2),
			_frame_image(s, "idle_right", 0), _frame_image(s, "walk_right", 2),
		])
	_save(rows, "build/sprite-activities.png")
	s.queue_free()

## 이웃 동물 종별 정면·측면.
func _npc_sheet() -> void:
	var npcs: Array = DataFiles.load_dict("res://data/npcs.json").get("npcs", [])
	var sprites: Array = []
	for n: Variant in npcs:
		var s := NpcSprite.new()
		s.setup(String((n as Dictionary).get("species", "cat")))
		get_root().add_child(s)
		sprites.append(s)
	await process_frame
	var rows: Array = []
	for s: NpcSprite in sprites:
		s.face(Vector2(0, 1))
		var front: Image = s.texture.get_image()
		s.face(Vector2(1, 0))
		rows.append([front, s.texture.get_image()])
	_save(rows, "build/sprite-npc.png")
	for s: NpcSprite in sprites:
		s.queue_free()

func _frame_image(s: PlayerSprite, anim: String, index: int) -> Image:
	var count := s.sprite_frames.get_frame_count(anim)
	var tex: Texture2D = s.sprite_frames.get_frame_texture(anim, mini(index, maxi(count - 1, 0)))
	return tex.get_image()

func _save(rows: Array, path: String) -> void:
	if rows.is_empty():
		return
	var cols: int = (rows[0] as Array).size()
	var cw := 0
	var ch := 0
	for row: Array in rows:
		for img: Image in row:
			cw = maxi(cw, img.get_width())
			ch = maxi(ch, img.get_height())
	var sheet := Image.create_empty(cw * cols * ZOOM, ch * rows.size() * ZOOM, false, Image.FORMAT_RGBA8)
	sheet.fill(BG)
	for r in rows.size():
		var row: Array = rows[r]
		for c in row.size():
			var big := (row[c] as Image).duplicate() as Image
			big.resize(big.get_width() * ZOOM, big.get_height() * ZOOM, Image.INTERPOLATE_NEAREST)
			sheet.blend_rect(big, Rect2i(0, 0, big.get_width(), big.get_height()),
				Vector2i(c * cw * ZOOM, r * ch * ZOOM))
	# **저장 실패를 성공으로 보고하지 않는다** — 눈으로 확인하려고 만든 도구가
	# 실패를 숨기면 목적이 무너진다.
	var err := sheet.save_png(path)
	if err != OK:
		push_error("시트 저장 실패(%s): %s" % [path, error_string(err)])
		return
	print("시트 저장: %s (셀 %dx%d, 확대 %d)" % [path, cw, ch, ZOOM])
