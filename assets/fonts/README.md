# 임베드 폰트

웹에는 시스템 폰트 폴백이 없어서, 화면에 쓰는 글자는 모두 프로젝트에 포함해야 한다.

| 파일 | 용도 | 라이선스 |
|---|---|---|
| `NotoSansKR-Regular.otf` | 한글·라틴 본문 (기본 테마 폰트) | SIL Open Font License 1.1 (`LICENSE.txt`) |
| `NotoEmoji-Regular.ttf` | 감정 표현 이모지 (기본 폰트의 **폴백**으로 등록) | SIL Open Font License 1.1 |

이모지는 **흑백(Noto Emoji)** 을 쓴다. 컬러 이모지(Noto Color Emoji)는 수십 MB라
첫 로딩 시간에 그대로 얹힌다(`docs/deploy.md`의 로딩 절 참고).

폴백 등록은 `scripts/fonts.gd`가 기본 테마 폰트에 이모지 폰트를 붙이는 방식이다 —
등록하지 않으면 이모지가 두부(□)로 보인다.
