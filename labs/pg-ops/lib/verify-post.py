#!/usr/bin/env python3
"""운영 연재 글의 console/psql/text 블록 줄이 모두 실측 캡처에 있는지 확인한다.

사용법: verify-post.py <글.md> <캡처.txt> [캡처2.txt ...]

허용하는 차이:
- 블록 안의 빈 줄과 "..." 줄(생략 표시)
- 줄 끝 공백
- 캡처 쪽의 "psql:<stdin>:N: " 접두어 (하네스가 세션 psql을 표준입력으로 돌려서 생긴다)
"""
import re
import sys

CHECKED = re.compile(r"^```(console|psql|text)\s*$")
STDIN_PREFIX = re.compile(r"^psql:<stdin>:\d+: ")


def main(post, captures):
    have = set()
    for path in captures:
        with open(path, encoding="utf-8") as f:
            for line in f:
                have.add(STDIN_PREFIX.sub("", line.rstrip()))

    missing = []
    in_block = False
    with open(post, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            s = line.rstrip()
            if not in_block:
                in_block = bool(CHECKED.match(s))
                continue
            if s == "```":
                in_block = False
            elif s and s != "..." and s not in have:
                missing.append((n, s))

    for n, s in missing:
        print(f"{post}:{n}: not in capture: {s}")
    print(f"{len(missing)} line(s) not found in capture")
    return 1 if missing else 0


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2:]))
