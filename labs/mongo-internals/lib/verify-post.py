#!/usr/bin/env python3
"""인터널 연재 글의 console/mongosh/text 블록 출력 줄이 모두 실측 로그에 있는지 확인한다.

사용법: verify-post.py <글.md> <final-run.log> [로그2 ...]

글에서는 명령을 다시 적으므로 명령 줄은 검사하지 않고, 출력 줄만 로그와 대조한다.

명령 줄로 보는 것:
- 셸: "$ ", "> "(이어지는 줄)로 시작하는 줄
- mongosh: 프롬프트로 시작하는 줄. "test> ", "rs0 [direct: primary] test> ", "[direct: mongos] test> ",
  세션을 나눠 보여 줄 때 붙이는 "A test> ", "[세션 A] test> " 모양
허용하는 차이:
- 블록 안의 빈 줄과 "..."으로 시작하는 줄(생략 표시, 여러 줄 명령의 이어지는 줄)
- 줄 끝 공백
"""
import re
import sys

CHECKED = re.compile(r"^```(console|mongosh|text)\s*$")
COMMAND = re.compile(
    r"^(\$|>) "
    r"|^(\[세션 \S+\] |[A-Z] )?([A-Za-z0-9_-]+ )?(\[[^\]]+\] )?[A-Za-z0-9_.-]+> "
)


def main(post, logs):
    have = set()
    for path in logs:
        with open(path, encoding="utf-8") as f:
            for line in f:
                have.add(line.rstrip())

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
            elif s and not s.startswith("...") and not COMMAND.match(s) and s not in have:
                missing.append((n, s))

    for n, s in missing:
        print(f"{post}:{n}: not in log: {s}")
    print(f"{len(missing)} line(s) not found in log")
    return 1 if missing else 0


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2:]))
