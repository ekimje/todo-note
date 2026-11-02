# 배포 실습 보고서 (할 일 노트)

같은 3티어 앱(web: Nginx / api: FastAPI / db: PostgreSQL)을 세 가지 방법으로 배포하고, 단계마다 과정을 캡처해 정리했습니다.

| 단계 | 방법 | 확인 결과 | 보고서 |
|---|---|---|---|
| 2 | VM에 직접 설치 (apt + systemd + Nginx) | `curl localhost/api/todos` ✅ · 재부팅 후 자동 복구 ✅ | [step2-vm-deploy/REPORT.md](step2-vm-deploy/REPORT.md) |
| 3 | Docker Compose | `docker compose up -d` 한 줄 실행 ✅ · down/up 후 데이터 유지 ✅ | [step3-compose/REPORT.md](step3-compose/REPORT.md) |
| 4 | Kubernetes (kind) | Ingress로 `curl localhost/api/todos`·브라우저 ✅ · DB 파드 재생성 후 데이터 유지 ✅ | [step4-k8s/REPORT.md](step4-k8s/REPORT.md) |

배포 파일 위치
- 2단계: [deploy/](../deploy/) (`todo-api.service`, `nginx-todo-note.conf`)
- 3단계: [compose.yaml](../compose.yaml), [api/Dockerfile](../api/Dockerfile), [web/Dockerfile](../web/Dockerfile), `.env`(Git 제외, `.env.example` 복사)
- 4단계: [k8s/](../k8s/) (Secret은 명령으로 생성)

캡처 만드는 법: [tools/cap.sh](tools/cap.sh)가 명령을 실행하면서 출력을 `logs/*.txt`로 남기고, 터미널 모양 PNG(`img/*.png`)로 그립니다. 브라우저 화면은 [tools/shot.py](tools/shot.py)(헤드리스 Chromium)로 캡처했습니다. 비밀번호는 모든 캡처에서 `********`로 가렸습니다.
