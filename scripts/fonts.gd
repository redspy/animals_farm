extends RefCounted
class_name Fonts

## 기본 테마 폰트에 **이모지 폰트를 폴백으로 붙인다.**
##
## 왜 필요한가: 임베드한 Noto Sans KR에는 이모지 글리프가 없어서 감정 표현
## 이모지(😀 등)가 전부 두부(□)로 보인다. 웹에는 시스템 폰트 폴백도 없다.
##
## project.godot의 `gui/theme/custom_font`는 폰트 파일 하나만 받으므로, 런타임에
## 그 폰트의 `fallbacks`에 이모지 폰트를 넣어 준다. main.gd가 시작할 때 한 번
## 호출한다.

const EMOJI_PATH := "res://assets/fonts/NotoEmoji-Regular.ttf"

static func install_emoji_fallback() -> void:
	var base: Variant = ThemeDB.get_default_theme().default_font
	if base == null:
		push_warning("기본 테마 폰트가 없어 이모지 폴백을 붙이지 못했다")
		return
	if not (base is FontFile or base is FontVariation):
		push_warning("기본 폰트 타입(%s)에 폴백을 붙일 수 없다" % base.get_class())
		return
	var emoji: Variant = load(EMOJI_PATH)
	if emoji == null:
		push_warning("이모지 폰트를 찾지 못했다: %s" % EMOJI_PATH)
		return
	var font := base as Font
	for existing: Variant in font.fallbacks:
		if existing != null and (existing as Resource).resource_path == EMOJI_PATH:
			return   # 이미 등록됨(중복 호출 방지)
	var fallbacks := font.fallbacks.duplicate()
	fallbacks.append(emoji)
	font.fallbacks = fallbacks
