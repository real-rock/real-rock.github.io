#!/bin/bash
# verify-post.py 테스트: 통과 픽스처는 exit 0, 캡처에 없는 줄이 있는 픽스처는 exit 1
cd "$(dirname "$0")"
V=../verify-post.py; F=fixtures; fail=0
python3 "$V" "$F/post-ok.md" "$F/capture.txt" >/dev/null \
  && echo "ok   post-ok passes" || { echo "FAIL post-ok should pass"; python3 "$V" "$F/post-ok.md" "$F/capture.txt"; fail=1; }
out=$(python3 "$V" "$F/post-bad.md" "$F/capture.txt"); rc=$?
[ $rc -eq 1 ] && grep -q "post-bad.md:3: not in capture: overlay          59G   50G" <<<"$out" \
  && echo "ok   post-bad fails on line 3" || { echo "FAIL post-bad: rc=$rc out=$out"; fail=1; }
exit $fail
