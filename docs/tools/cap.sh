#!/usr/bin/env bash
# 사용: CAP_DIR=docs/step3-compose cap.sh <이름> <명령1> [명령2 ...]
#   명령마다 프롬프트 줄 + 출력을 이어 붙여 $CAP_DIR/logs/<이름>.txt 와 $CAP_DIR/img/<이름>.png 로 저장
S=$(dirname "$(readlink -f "$0")")
OUT=$(readlink -f "${CAP_DIR:?CAP_DIR 를 지정하세요}")
mkdir -p "$OUT/logs" "$OUT/img"
name=$1; shift
log="$OUT/logs/$name.txt"; : > "$log"
for c in "$@"; do
  dir=$(pwd | sed "s|^$HOME|~|")
  echo "lab@s07:$dir\$ $c" >> "$log"
  bash -c "$c" >> "$log" 2>&1
done
cat "$log"
python3 "$S/term2png.py" "$log" "$OUT/img/$name.png" "lab@s07: $name"
