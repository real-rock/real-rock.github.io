#!/bin/bash
# wt 유틸리티 빌드용 소스 tarball(wiredtiger-src.tar.gz)을 만든다. 네트워크를 쓰지 않는다.
#   - 소스 코드: mongo 저장소 r8.0.32의 src/third_party/wiredtiger (mongod 8.0.32와 같은 WiredTiger)
#   - mongo 사본에서 빠진 빌드 파일(CMakeLists.txt 등): WiredTiger 저장소 mongodb-8.0 브랜치에서 가져온다
# 사용법: make-wt-src.sh <mongo 저장소> <wiredtiger 저장소>
set -euo pipefail
MONGO=$1 WT=$2 TAG=r8.0.32 WT_REF=origin/mongodb-8.0
cd "$(dirname "$0")"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; work=$tmp/wiredtiger; mkdir "$work"
git -C "$MONGO" archive "$TAG":src/third_party/wiredtiger | tar x -C "$work"
comm -13 <(git -C "$MONGO" ls-tree -r --name-only "$TAG":src/third_party/wiredtiger | sort) \
         <(git -C "$WT" ls-tree -r --name-only "$WT_REF" | sort) > "$tmp/added-files"
git -C "$WT" archive "$WT_REF" $(cat "$tmp/added-files") | tar x -C "$work"
echo "mongo $TAG ($(git -C "$MONGO" rev-parse --short "$TAG^{commit}")) + $(wc -l < "$tmp/added-files" | tr -d ' ') files from wiredtiger $WT_REF ($(git -C "$WT" rev-parse --short "$WT_REF"))"
tar czf wiredtiger-src.tar.gz -C "$tmp" wiredtiger
