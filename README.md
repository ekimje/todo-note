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

## 실행

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

`widget/widget.ps1` — Windows PowerShell 5.1 + WPF, 바탕화면 쪽에 붙는 반투명 달력.

```bat
widget\start-widget.cmd
```

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
