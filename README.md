# DB 인터널 노트

Hugo + PaperMod 테마로 만든 GitHub Pages 블로그입니다.

## 처음 한 번만 하는 설정

1. GitHub에서 `<GitHub 사용자명>.github.io` 이름으로 Public 저장소를 만듭니다. (README 등은 추가하지 않고 빈 저장소로 생성)
2. 이 폴더에서 아래 명령을 실행합니다.

```bash
git init -b main
git submodule add https://github.com/adityatelange/hugo-PaperMod.git themes/PaperMod
git add .
git commit -m "블로그 초기 세팅"
git remote add origin https://github.com/<GitHub 사용자명>/<GitHub 사용자명>.github.io.git
git push -u origin main
```

3. 저장소의 Settings > Pages > Build and deployment > Source를 **GitHub Actions**로 바꿉니다.
4. Actions 탭에서 배포가 끝나면 `https://<GitHub 사용자명>.github.io` 에서 블로그를 확인할 수 있습니다.

## 글 쓰기

```bash
hugo new content posts/postgresql-process-architecture.md   # 템플릿으로 새 글 생성
hugo server -D                                              # http://localhost:1313 에서 미리보기 (초안 포함)
```

- 글은 `draft: true` 상태로 생성됩니다. 공개하려면 `draft: false`로 바꾸고 push 하세요.
- 시리즈는 `series: ["PostgreSQL 인터널"]`처럼 지정하면 시리즈 페이지에 자동으로 묶입니다.
- 시리즈 목차는 `content/series/<시리즈>/_index.md`의 `chapters`에서 관리합니다. n번째 항목은 `weight: n`인 글과 연결되고, 글이 공개되기 전에는 "준비 중"으로 표시됩니다.
- 다이어그램은 ` ```mermaid ` 코드 블록으로 작성하면 그림으로 표시됩니다.
- 이미지는 `static/images/` 에 넣고 `![설명](/images/파일명.png)` 로 사용합니다.
- 날짜가 미래인 글은 표시되지 않습니다.

## 수정하면 좋은 곳

- `hugo.toml`: 블로그 제목, 설명, 작성자
- `content/about.md`: 소개 페이지
- `content/posts/hello.md`: 첫 글 (지워도 됩니다)
