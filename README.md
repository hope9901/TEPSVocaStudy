# TEPS Voca

TEPS 어휘 학습 iOS 앱. 간격 반복(SRS)과 TEPS 문맥 문제(빈칸 → 영단어)로 공부한다.

- 단어 **2,000개** — 강의 단어집(기출단어집, 빈출단어 1700, 327점 상위 8% 등)
- 예문 **2,000개**, 한글 번역 **2,000개** (전 단어 100%)
- 학습 진도는 기기의 앱 Documents 폴더에 있고, 앱을 다시 설치해도 유지된다

---

## 매주 해야 하는 일 — 앱 되살리기

무료 Apple 계정으로 서명한 앱은 **7일이면 열리지 않는다.** 되살리는 방법은 두 단계다.

### 1. 터미널에서 준비 스크립트 실행

```bash
cd ~/TEPSVocaStudy
./Scripts/refresh_app.sh --prep
```

### 2. Xcode 에서 빌드

Xcode 를 열고 → 상단에서 **연결된 아이폰 선택** → `⌘R`

끝이다.

> ### ⚠️ 앱을 삭제하지 말 것
> 학습 진도는 앱의 Documents 폴더 안에 있다. 덮어 설치하면 그대로 남고,
> 삭제하면 사라진다. 항상 기존 앱 위에 설치한다.

### 1단계를 왜 건너뛰면 안 되는가

Xcode 는 예전에 받아둔 프로비저닝 프로파일을 **만료 전까지 그대로 재사용한다.**
수명이 2일 남은 프로파일로 빌드하면 앱도 이틀 뒤에 죽는다. 실제로 "빌드한 지
일주일도 안 됐는데 앱이 안 열린다"가 이것 때문에 일어났다.

`--prep` 이 캐시된 프로파일을 지우므로, Xcode 가 **새 7일짜리**를 발급받는다.
스크립트 없이 하려면 이 한 줄과 같다:

```bash
rm -rf ~/Library/MobileDevice/Provisioning\ Profiles/*
```

### 만료일 확인

```bash
./Scripts/refresh_app.sh --status
```

현재 프로파일의 발급일·만료일과 서명 인증서 목록을 보여준다. 아무것도 바꾸지 않는다.

**여기 찍힌 날짜보다 훨씬 일찍 앱이 죽는다면** 프로파일 문제가 아니라 Apple 계정
쪽 제재다 (`0xE8008024 The provisioning profile is banned`). 그때는 사이드로딩
전용 Apple ID 를 새로 만들거나 유료 개발자 계정($99/년, 프로파일 1년)으로 가야 한다.

### 한 번에 끝내기 (선택)

Xcode 를 열지 않고 빌드·설치까지 스크립트가 처리하게 할 수도 있다.

```bash
./Scripts/refresh_app.sh              # 기기 자동 탐색
UDID=00008110-0001... ./Scripts/refresh_app.sh
```

---

## 앱 내용(단어·예문)을 바꿨을 때

DB 를 수정한 뒤에는 위와 같은 방법으로 설치하면 된다. 앱이 실행되면서 번들 DB 의
내용을 기기 DB 로 동기화하는데, **학습 진도(familiar, 복습 날짜)는 건드리지 않는다.**

동기화 여부는 콘텐츠 버전과 콘텐츠 지문(stamp) 두 가지로 판단한다. 지문은 번들 DB
에서 직접 읽으므로, `bundledContentVersion` 을 올리는 걸 깜빡해도 내용이 바뀌었으면
동기화된다.

설치 후 확인: **문맥 모드로 한 세션** 돌렸을 때 뜻 문제가 섞이지 않고 모든 단어에
예문과 한글 번역이 보이면 정상이다.

---

## 스크립트

| 파일 | 용도 |
|---|---|
| `refresh_app.sh` | 주간 재서명 (`--prep` / `--status` / 인자 없이 전체) |
| `make_ipa.sh` | 사이드로딩용 **서명 없는** IPA 패키징 |
| `rebuild_corpus.py` | 번들 DB 의 단어 목록을 단어집으로 교체 (행 id 유지 → 진도 보존) |
| `load_sentences.py` | 예문 JSON 적재. 앱이 빈칸을 못 만드는 문장은 거부 |
| `load_translations.py` | 한글 예문 번역 JSON 적재 |
| `export_sentences.py` | 예문을 단어 기준 JSON 으로 백업 (DB 재생성에도 살아남음) |
| `verify_blanker.py` | `context_blanker.py` 가 `ContextBlanker.swift` 와 어긋났는지 검사 |
| `context_blanker.py` | `Services/ContextBlanker.swift` 의 파이썬 포팅 (적재 검증용) |
| `generate_sentences_lmstudio.py` | 로컬 LM Studio 로 예문 생성 |

예문을 손보고 나면 적재 도구가 **앱과 같은 규칙으로** 검증한다. 빈칸을 만들 수 없는
문장은 저장되지 않으므로, 커버리지 숫자만 오르고 문맥 모드는 안 도는 일이 없다.

```bash
python3 Scripts/verify_blanker.py      # 예문 2000개 중 빈칸 생성 가능 2000개 (100.0%)
```

---

## 빌드

[XcodeGen](https://github.com/yonaskolb/XcodeGen) 기반이다. `project.yml` 을 고쳤으면:

```bash
xcodegen generate
```

GitHub Actions 의 **Build unsigned iOS IPA** 워크플로를 수동 실행하면 서명 없는
IPA 를 아티팩트로 받을 수 있다 (사이드로더로 설치할 때 사용).

## 데이터 백업

진도를 따로 보관하려면 파일 앱에서 꺼낸다 (`UIFileSharingEnabled` 가 켜져 있다).

> 파일 → 나의 iPhone → **TEPS Voca** → `v85_20260312T133124Z.db`

이 파일 하나가 학습 진도 전부다. 오래된 백업을 되돌려 넣어도, 앱이 실행되면서
진도는 유지한 채 최신 단어·예문 내용을 채워 넣는다.
