# 할 일 노트 (3티어)

PC와 휴대폰에서 같이 쓰는 할 일 노트. Docker Compose 하나로 세 티어를 띄운다.

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
| POST | `/api/todos` | 추가 `{text, priority?: high\|mid\|low, due?: "YYYY-MM-DD"}` |
| PATCH | `/api/todos/{id}` | 수정 (보낸 필드만) `{text?, done?, priority?, due?}` |
| DELETE | `/api/todos/{id}` | 삭제 |
| DELETE | `/api/todos` | 완료 항목 일괄 삭제 |

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
