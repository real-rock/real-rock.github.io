#!/bin/bash
# 인터널 연재 실습 10개를 순서대로 새 컨테이너에서 실행한다. 각 디렉터리에 final-run.log가 남는다.
# 시간을 재는 실습이 있어서 동시에 돌리지 않는다.
cd "$(dirname "$0")"
for d in pg-*/; do
  d=${d%/}
  start=$(date +%s)
  bash "$d/lab.sh" > "$d/stdout.txt" 2>&1
  echo "$d exit=$? $(( $(date +%s) - start ))s"
done
