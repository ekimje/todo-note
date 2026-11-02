#!/usr/bin/env bash
# 재부팅 뒤 확인 — 캡처 10(터미널)·11(브라우저)을 남긴다
#   사용: bash docs/step2-vm-deploy/tools/after-reboot.sh   (저장소 루트에서)
T=$(dirname "$(readlink -f "$0")")
cd /home/lab/todo-note
"$T/cap.sh" 10-after-reboot \
  "uptime -s; cat /proc/sys/kernel/random/boot_id" \
  "systemctl is-active postgresql todo-api nginx" \
  "systemctl status todo-api --no-pager | sed -n '1,4p'" \
  "curl -s localhost/api/health; echo" \
  "curl -s localhost/api/todos | python3 -m json.tool --no-ensure-ascii | grep '\"text\"'"
PW=$HOME/.local/share/pw-venv/bin/python
[ -x "$PW" ] && "$PW" "$T/shot.py" http://localhost/ docs/step2-vm-deploy/img/11-browser-after-reboot.png \
  || echo "(브라우저 캡처 생략: playwright 가상환경 없음 — PORTS 탭 화면을 직접 캡처해 img/11-browser-after-reboot.png 로 저장)"
