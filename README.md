# 할 일 노트 (3티어)

PC와 휴대폰에서 같이 쓰는 할 일 노트. Docker Compose 하나로 세 티어를 띄우고,
바탕화면 반투명 달력 위젯(`widget/`)도 같은 API를 써서 웹·휴대폰·바탕화면이 같은 데이터를 본다.

```
[브라우저 / 휴대폰]
        │  :8080
        ▼
┌──────────────┐   frontend 네트워크   ┌──────────────┐   backend 네트워크(internal)   ┌──────────────┐
│ web (nginx)  │ ───────────────────▶ │ api (FastAPI)│ ─────────────────────────────▶ │ db (Postgres)│
│ 정적 화면     │   /api/* 프록시       │ REST API     │                                │ 볼륨 db-data │
└──────────────┘                       └──────────────┘                                └──────────────┘
 프레젠테이션 티어                       애플리케이션 티어                                 데이터 티어
```

- **web/**: nginx가 `public/`(HTML·CSS·JS)을 서빙하고 `/api/*`를 api 컨테이너로 프록시
- **api/**: FastAPI + psycopg. 시작할 때 `todos` 테이블을 자동 생성
- **db**: PostgreSQL 16. 데이터는 `db-data` 볼륨에 저장되어 컨테이너를 지워도 남음
- web은 db에 직접 접근할 수 없고(네트워크 분리), db 포트는 호스트에 열리지 않음

## PC 설치판 (Docker 없이)

`desktop/` — API·웹 화면·위젯을 exe 하나로 묶은 Windows 설치 파일. DB는 PostgreSQL 대신 **SQLite 파일 하나**.

```
TodoNote.exe (트레이 상주)
 ├─ API + 웹 화면  http://127.0.0.1:8080   ← 위젯 기본 주소와 같아 위젯 설정 변경 불필요
 ├─ 데이터         %APPDATA%\TodoNote\todos.db   (백업 = 이 파일 복사, 프로그램을 지워도 남음)
 └─ 달력 위젯      실행 시 자동으로 띄움
```

**빌드** (Python 3.13, 설치 파일까지 만들려면 Inno Setup 6: `winget install JRSoftware.InnoSetup`)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File desktop\build.ps1
```

- `desktop\dist\TodoNote-Setup-<버전>.exe` — 설치 파일 (관리자 권한 불필요, 바탕화면 바로가기·로그인 시 자동 실행 선택)
- `desktop\dist\TodoNote\TodoNote.exe` — 설치 없이 바로 실행

**사용**

- 바탕화면 아이콘 → 주소창 없는 앱 창(Edge/Chrome `--app`)으로 열림. 이미 실행 중이면 창만 새로 열림
- 트레이 아이콘 우클릭: 열기 / 달력 위젯 켜기 / **휴대폰 접속 허용** / 데이터 폴더 열기 / 종료
- 휴대폰 접속 허용을 켜면 같은 와이파이에서 메뉴에 표시된 `http://<PC IP>:8080` 으로 접속 (PC가 켜져 있어야 함, 처음 켤 때 Windows 방화벽 허용 필요).
  ⚠ 로그인 기능이 없어 같은 네트워크의 누구나 접근 가능 — 집 와이파이에서만 켜기
- 설정: `%APPDATA%\TodoNote\desktop.json` (`port`, `lan`, `widget`), 로그: 같은 폴더 `desktop.log`
- Docker 판과 둘 다 8080 을 쓰므로 동시에 켜지 않기 (설치판이 알려 주고 종료함)

**Docker 판 데이터 옮기기** — Docker 스택이 켜진 상태에서 한 번 실행 (id 그대로 복사, 여러 번 해도 중복 없음):

```powershell
& "$env:LOCALAPPDATA\Programs\TodoNote\TodoNote.exe" --import-from http://localhost:8080/api
```

개발 중 실행·테스트 (패키지: `pip install -r desktop/requirements.txt`):

```bash
python desktop/todo_desktop.py --no-tray --port 8090          # 서버만
TODO_API_URL=http://127.0.0.1:8090/api python -m pytest api/tests
```

## 실행 (Docker 판)

```bash
cp .env.example .env          # POSTGRES_PASSWORD 를 긴 임의 문자열로 변경
docker compose up -d --build
```

브라우저에서 http://localhost:8080 접속. 상태 확인:

```bash
docker compose ps                         # 세 서비스 모두 healthy 인지
curl http://localhost:8080/api/health     # {"status":"ok","db":"ok"}
```

API 문서(Swagger): http://localhost:8080/api/docs

## API

| 메서드 | 경로 | 설명 |
|---|---|---|
| GET | `/api/health` | API·DB 상태 |
| GET | `/api/todos` | 목록 |
| POST | `/api/todos` | 추가 `{text, priority?: high\|mid\|low, start?, due?, color?: 0~4}` |
| PATCH | `/api/todos/{id}` | 수정 (보낸 필드만) `{text?, done?, priority?, start?, due?, color?}` |
| DELETE | `/api/todos/{id}` | 삭제 |
| DELETE | `/api/todos` | 완료 항목 일괄 삭제 |

- 날짜는 `YYYY-MM-DD`. `start ~ due` 가 기간 일정이고, `start` 없이 `due` 만 있으면 하루 일정
- `start` 는 `due` 가 있을 때만, `due` 보다 늦을 수 없음 (어기면 422)
- `color` 는 달력 위젯의 형광펜 색 번호. 없으면 위젯이 우선순위로 색을 고름

## 바탕화면 달력 위젯 (Windows)

`widget/widget.ps1` — Windows PowerShell 5.1 + WPF, 바탕화면 쪽에 붙는 달력.

```bat
widget\start-widget.cmd
```

- **월간 / 일일 보기**: 헤더의 `일일`·`월간` 버튼. 월간 달력에서 날짜 숫자를 누르면 그 날의 일일 보기로 이동
  - 일일 보기: 그 날 걸쳐 있는 일정 목록, 체크 상자로 바로 완료 표시, `‹ ›` 로 하루씩 이동
  - 제목(월/날짜)을 누르면 오늘로
- **라이트 / 다크 모드**: 헤더의 `다크`·`라이트` 버튼 (우클릭 메뉴에도 있음)
- 보기와 테마는 `settings.json` 에 저장되어 다음 실행에도 유지
- API에서 30초마다 다시 읽어 웹·휴대폰에서 바꾼 내용을 반영 (우클릭 → **지금 동기화**)
- 서버에 닿지 않으면 마지막으로 받은 목록(`todos-cache.json`)을 보여주고 제목에 **오프라인** 표시. 이때는 저장 불가
- 마감일 없는 할 일은 놓을 날짜가 없어 달력에 표시하지 않음
- API 주소 변경: `widget/settings.json` 의 `"api"` 또는 환경변수 `TODO_API_URL`
- 로그인 시 자동 실행: `Win+R` → `shell:startup` 폴더에 `start-widget.cmd` 바로가기 추가
- ⚠ `.ps1` 파일은 **UTF-8 BOM** 으로 저장해야 함. BOM이 없으면 PowerShell 5.1이 CP949로 읽어 한글 주석 뒤의 코드 줄이 사라질 수 있음

## 테스트

스택을 띄운 상태에서:

```bash
python -m pytest api/tests -v                                                   # API 통합 테스트
powershell -NoProfile -ExecutionPolicy Bypass -File widget/tests/sync-test.ps1   # 위젯 ↔ API 동기화 테스트
```

둘 다 테스트가 만든 항목만 지운다. 다른 서버를 검사하려면 `TODO_API_URL=http://<host>:8080/api`.

## 자주 쓰는 명령

```bash
docker compose logs -f api                 # API 로그
docker compose down                        # 중지 (데이터 유지)
docker compose down -v                     # 중지 + 데이터 삭제 (주의)
docker compose exec db pg_dump -U todo todo > backup.sql   # 백업
```

## VM에 올리기

1. VM에 Docker 설치 후 이 저장소를 clone
2. `.env` 작성 → `docker compose up -d --build`
3. 방화벽/보안 그룹에서 `WEB_PORT`(기본 8080) 허용

휴대폰에서 인터넷으로 쓰려면 추가로 권장:

- **HTTPS**: 도메인을 연결하고 Caddy / nginx + Let's Encrypt 를 앞단에 둠 (홈 화면 앱 설치에도 필요)
- **접근 제한**: 현재 로그인 기능이 없어 주소를 아는 누구나 접근 가능. 공개 배포 전 인증(예: 리버스 프록시 Basic Auth, VPN, Tailscale)을 반드시 추가

## 휴대폰 홈 화면에 추가

- iPhone(Safari): 공유 → 홈 화면에 추가
- Android(Chrome): ⋮ → 홈 화면에 추가
