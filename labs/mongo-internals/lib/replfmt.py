#!/usr/bin/env python3
"""mongosh REPL 출력을 "프롬프트> 명령" + 결과 형태로 되돌린다. labkit.sh의 msh가 쓴다.

사용법: replfmt.py <보낸 명령 파일> <mongosh 원본 출력 파일> [세션 이름]

mongosh를 표준입력으로 돌리면 결과가 프롬프트 뒤에 붙어 나와서 어느 명령의 결과인지 알기 어렵다.
그래서 labkit.sh는 프롬프트를 "@@PROMPT@@<프롬프트>@@" 마커 줄로 바꿔서 실행하고,
여기서 마커를 기준으로 출력을 잘라 n번째 조각을 n번째 명령과 짝짓는다.

- 명령은 들여쓰기 없이 시작하는 줄부터, 들여쓰기가 있거나 닫는 괄호/점으로 시작하는 줄까지가 하나다.
  둘째 줄부터는 "... "를 붙여 기록한다.
- 여러 줄 명령에서 mongosh가 결과 앞에 붙이는 이어쓰기 표시("| ")는 지운다.
- 한 줄 안의 CR은 터미널에 보이는 대로 처리한다. mongosh는 오류를 "Uncaught \rMongoServerError: ..."로
  찍는데, 터미널에서는 CR 뒤의 글자가 앞을 덮어써서 "MongoServerError: ..."만 보인다.
"""
import re
import sys

MARK = re.compile(r"^@@PROMPT@@(.*)@@$")
CONT = re.compile(r"^[\s})\].]")


def statements(lines):
    out = []
    for line in lines:
        if not line.strip():
            continue
        if out and CONT.match(line):
            out[-1].append(line)
        else:
            out.append([line])
    return out


def segments(raw):
    """마커 앞의 조각(첫 프롬프트 앞)은 버리고, (프롬프트, 그 뒤 출력 줄들)을 돌려준다."""
    segs = []
    for line in raw.split("\n"):
        line = line.rstrip("\r").rsplit("\r", 1)[-1]
        m = MARK.match(line)
        if m:
            segs.append((m.group(1), []))
        elif segs:
            segs[-1][1].append(line)
    return segs


def tidy(body, nlines):
    # 마커 줄 앞뒤로 넣은 개행 때문에 생긴 빈 줄을 떼어 낸다
    while body and body[0] == "":
        body.pop(0)
    while body and body[-1] == "":
        body.pop()
    if body and nlines > 1:
        body[0] = re.sub(r"^(\| )+", "", body[0])
    return body


def main(stmt_path, raw_path, label=""):
    with open(stmt_path, encoding="utf-8") as f:
        stmts = statements(f.read().split("\n"))
    with open(raw_path, encoding="utf-8", errors="replace", newline="") as f:
        segs = segments(f.read())
    prefix = f"[세션 {label}] " if label else ""
    for i, stmt in enumerate(stmts):
        if i >= len(segs):
            print(f"{prefix}(앞 명령이 아직 끝나지 않아 실행 전) {stmt[0]}")
            continue
        # i번째 프롬프트 뒤, 다음 프롬프트 전까지가 i번째 명령의 결과다
        prompt, body = segs[i]
        print(f"{prefix}{prompt} {stmt[0]}")
        for extra in stmt[1:]:
            print(f"... {extra}")
        for line in tidy(list(body), len(stmt)):
            print(line)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(*sys.argv[1:4])
