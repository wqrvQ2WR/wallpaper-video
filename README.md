# Wallpaper Video

macOS 메뉴바에 상주하면서 선택한 동영상을 데스크탑 배경화면으로 무한 반복 재생해주는 가벼운 유틸리티입니다.

## 기능

- 메뉴바 아이콘에서 동영상 파일 선택 (mp4, mov, webm)
- 선택한 영상을 데스크탑 레벨 창에서 음소거 반복 재생
- webm 파일은 자동으로 ffmpeg를 통해 mp4로 변환 후 캐싱 (`~/Library/Caches/WallpaperVideo/Transcoded`)
- 재생 / 일시정지 토글
- 로그인 시 자동 실행 설정
- 마지막으로 선택한 영상 경로를 기억했다가 재실행 시 자동 로드

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

1. 메뉴바의 앱 아이콘 클릭 → "비디오 선택..."
2. 배경으로 쓸 동영상 파일 선택
3. 메뉴에서 "일시정지" / "재생"으로 토글, "로그인 시 자동 실행"으로 부팅 시 자동 시작 설정 가능

## 참고

- 현재 기본 화면(`NSScreen.main`) 한 대만 지원합니다.
- Mac App Store 배포용이 아닌 개인/로컬 사용을 위한 ad-hoc 서명 빌드입니다.
