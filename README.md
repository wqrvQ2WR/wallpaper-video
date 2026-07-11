# Wallpaper Video — 멀티 플레이리스트 지원 🎬

macOS 메뉴바에 상주하면서 선택한 동영상이나 HTML 파일을 데스크탑 배경화면으로 재생해주는 가벼운 유틸리티입니다.

## 기능

- **플레이리스트** — 여러 동영상/HTML을 추가해서 순차/셔플 재생
- **HTML 배경화면** — `.html` 파일을 WKWebView로 렌더링 (JS 애니메이션, 같은 폴더의 CSS/이미지 상대경로 지원)
- **자동 전환** — 1분/5분/15분/30분/1시간 간격으로 자동 넘김
- **셔플** — 랜덤 순서로 재생
- **메뉴바에서 곡 선택** — 플레이리스트에서 바로 원하는 곡 선택 가능
- webm 파일은 자동으로 ffmpeg를 통해 mp4로 변환 후 캐싱 (`~/Library/Caches/WallpaperVideo/Transcoded`)
- 재생 / 일시정지 토글
- 로그인 시 자동 실행 설정
- 플레이리스트 자동 저장 (재실행 시 복원)

## 요구 사항

- macOS 13 (Ventura) 이상
- Swift 5.9 이상 (Xcode Command Line Tools)
- webm 변환 기능을 쓰려면 [ffmpeg](https://ffmpeg.org) 설치 필요 (`brew install ffmpeg`)

## 빌드 및 실행

```bash
./build_app.sh      # WallpaperVideo.app 빌드 (ad-hoc 서명 포함)
open WallpaperVideo.app
```

`/Applications`에 설치되어 있는 버전을 최신 소스로 다시 빌드해 교체하고 재실행하려면:

```bash
./update_app.sh
```

## 사용법

1. 메뉴바의 앱 아이콘 클릭
2. **플레이리스트 편집 → 비디오 추가...** 에서 영상 파일 선택 (여러개 선택 가능)
3. **전환 간격** 에서 자동 넘김 시간 설정
4. **셔플** 토글 가능
5. 플레이리스트에서 직접 곡 선택하거나 **다음 곡** 으로 바로 넘기기
6. 현재 곡 삭제 / 전체 삭제 가능

## 참고

- 현재 기본 화면(`NSScreen.main`) 한 대만 지원합니다.
- Mac App Store 배포용이 아닌 개인/로컬 사용을 위한 ad-hoc 서명 빌드입니다.
