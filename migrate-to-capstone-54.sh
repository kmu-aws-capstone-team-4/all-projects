#!/usr/bin/env bash
# migrate-to-capstone-54.sh
#
# 006-capstone-modules 의 서브 레포지터리 12개를 단일 레포 (2026-capstone-54) 로
# 히스토리(저자/시각/메시지) 보존하며 마이그레이션한다.
#
# 정책:
#   - 각 sub repo 의 `main` 브랜치를 target 의 main 에 직접 머지
#   - 비-main 브랜치는 `<repo>/<branch>` 로컬 브랜치로 별도 보존 (1-B)
#   - 멱등성: 재실행 시 deterministic SHA + merge-base 체크로 새 커밋만 추가
#
# 사용:
#   ./migrate-to-capstone-54.sh                  # dry-run (계획만 출력)
#   ./migrate-to-capstone-54.sh --apply          # 실제 실행 (모든 모듈)
#   ./migrate-to-capstone-54.sh --apply backend  # 특정 모듈만
#   ./migrate-to-capstone-54.sh --apply --skip frontend backend  # 제외
#
# 환경 변수 (선택):
#   SOURCE_DIR    기본: 스크립트 위치 (006-capstone-modules)
#   TARGET_DIR    기본: $SOURCE_DIR/../2026-capstone-54
#   WORK_DIR      기본: /tmp/mefit-migrate (재실행 시 모듈 단위로 갱신)
#   TARGET_BRANCH 기본: main

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
SOURCE_DIR="${SOURCE_DIR:-$SCRIPT_DIR}"
TARGET_DIR="${TARGET_DIR:-$(cd -- "$SOURCE_DIR/.." &>/dev/null && pwd)/2026-capstone-54}"
WORK_DIR="${WORK_DIR:-/tmp/mefit-migrate}"
TARGET_BRANCH="${TARGET_BRANCH:-main}"

APPLY=0
declare -a ONLY=()
declare -a SKIP=()
MODE="only"
for arg in "$@"; do
  case "$arg" in
    --apply|-y) APPLY=1 ;;
    --skip)     MODE="skip" ;;
    -h|--help)  sed -n '2,28p' "$0"; exit 0 ;;
    -*)         echo "unknown option: $arg" >&2; exit 1 ;;
    *)
      if [ "$MODE" = "skip" ]; then SKIP+=("$arg"); else ONLY+=("$arg"); fi
      ;;
  esac
done

ALL_MODULES=(
  backend frontend infra interview-analysis-report
  analysis-resume scraping voice-api mefit-tools
  face-analyzer analysis-video mefit-diagrams analysis-stt
)

if [ ${#ONLY[@]} -gt 0 ]; then
  MODULES=("${ONLY[@]}")
else
  MODULES=("${ALL_MODULES[@]}")
fi
# skip 적용
if [ ${#SKIP[@]} -gt 0 ]; then
  declare -a FILTERED=()
  for M in "${MODULES[@]}"; do
    SKIP_THIS=0
    for S in "${SKIP[@]}"; do [ "$M" = "$S" ] && SKIP_THIS=1 && break; done
    [ $SKIP_THIS -eq 0 ] && FILTERED+=("$M")
  done
  MODULES=("${FILTERED[@]}")
fi

C_INFO=$'\033[1;36m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'; C_OK=$'\033[1;32m'; C_OFF=$'\033[0m'
log()  { printf '%s[%s]%s %s\n' "$C_INFO" "$(date +%H:%M:%S)" "$C_OFF" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
err()  { printf '%s[X]%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

[ -d "$SOURCE_DIR/.git" ] || err "SOURCE_DIR 는 git 레포가 아닙니다: $SOURCE_DIR"
[ -d "$TARGET_DIR/.git" ] || err "TARGET_DIR 는 git 레포가 아닙니다: $TARGET_DIR"
[ -f "$SOURCE_DIR/.gitmodules" ] || err ".gitmodules 가 없습니다: $SOURCE_DIR"
mkdir -p "$WORK_DIR"

export GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat PAGER=cat GCM_INTERACTIVE=never
export GIT_EDITOR=: EDITOR=: GIT_MERGE_AUTOEDIT=no

log "SOURCE_DIR    = $SOURCE_DIR"
log "TARGET_DIR    = $TARGET_DIR"
log "WORK_DIR      = $WORK_DIR"
log "TARGET_BRANCH = $TARGET_BRANCH"
log "MODE          = $([ $APPLY -eq 1 ] && echo APPLY || echo dry-run)"
  log "MODULES       = ${MODULES[*]}"
echo

if [ $APPLY -eq 1 ]; then
  command -v git-filter-repo >/dev/null 2>&1 || {
    err "git-filter-repo 가 없습니다.
  설치:  brew install git-filter-repo
  또는:  pip3 install --user git-filter-repo"
  }

  if ! git -C "$TARGET_DIR" diff --quiet --exit-code \
     || ! git -C "$TARGET_DIR" diff --cached --quiet --exit-code; then
    warn "TARGET 에 uncommitted 변경 사항이 있습니다:"
    git -C "$TARGET_DIR" status --short
    err "변경 정리 (commit 또는 stash) 후 다시 실행하세요."
  fi

  if git -C "$TARGET_DIR" rev-parse --verify "$TARGET_BRANCH" >/dev/null 2>&1; then
    log "target $TARGET_BRANCH 브랜치 존재. checkout."
    git -C "$TARGET_DIR" checkout -q "$TARGET_BRANCH"
  elif git -C "$TARGET_DIR" rev-parse --verify master >/dev/null 2>&1; then
    log "master → $TARGET_BRANCH 로 rename"
    git -C "$TARGET_DIR" checkout -q master
    git -C "$TARGET_DIR" branch -m master "$TARGET_BRANCH"
  else
    err "target 에 master/$TARGET_BRANCH 브랜치가 없습니다."
  fi

  BACKUP="${TARGET_BRANCH}-backup-$(date +%Y%m%d-%H%M%S)"
  git -C "$TARGET_DIR" branch "$BACKUP" "$TARGET_BRANCH"
  ok "백업 브랜치 생성: $BACKUP"
  echo
fi

TOTAL_NEW_COMMITS=0
declare -a SUMMARY=()

for M in "${MODULES[@]}"; do
  echo
  log "============================================================"
  log "  MODULE: $M"
  log "============================================================"

  URL=$(git -C "$SOURCE_DIR" config -f .gitmodules "submodule.$M.url" 2>/dev/null || echo "")
  if [ -z "$URL" ]; then
    warn "$M: .gitmodules 에 url 없음. skip"
    SUMMARY+=("$M: SKIP (no url)")
    continue
  fi
  log "URL: $URL"

  if [ $APPLY -eq 0 ]; then
    if [ -d "$SOURCE_DIR/$M/.git" ] || [ -f "$SOURCE_DIR/$M/.git" ]; then
      COUNT=$(git -C "$SOURCE_DIR/$M" rev-list --all --count 2>/dev/null || echo "?")
      BRANCHES=$(git -C "$SOURCE_DIR/$M" branch -r 2>/dev/null | grep -v HEAD | wc -l | tr -d ' ')
      log "  commits=$COUNT  remote-branches=$BRANCHES"
    else
      warn "  submodule 이 init 되지 않음 (git submodule update --init 필요)"
    fi
    SUMMARY+=("$M: dry-run")
    continue
  fi

  BARE="$WORK_DIR/$M.bare"
  WORK="$WORK_DIR/$M"

  log "1) mirror clone: $URL → $BARE"
  rm -rf "$BARE" "$WORK"
  git clone --mirror --quiet "$URL" "$BARE"

  log "2) working clone: $BARE → $WORK"
  git clone --no-local --quiet "$BARE" "$WORK"

  (
    cd "$WORK"
    for B in $(git branch -r | grep -v HEAD | sed 's|origin/||'); do
      git branch --force "$B" "origin/$B" >/dev/null 2>&1 || true
    done
    git remote remove origin

    log "3) filter-repo --to-subdirectory-filter $M"
    git filter-repo --to-subdirectory-filter "$M" --force --quiet
  )

  REMOTE="migrate-$M"
  log "4) target 에 remote 추가 + fetch"
  git -C "$TARGET_DIR" remote remove "$REMOTE" >/dev/null 2>&1 || true
  git -C "$TARGET_DIR" remote add "$REMOTE" "$WORK"
  git -C "$TARGET_DIR" fetch --quiet "$REMOTE"

  SRC_MAIN="$REMOTE/main"
  if ! git -C "$TARGET_DIR" rev-parse --verify "$SRC_MAIN" >/dev/null 2>&1; then
    git -C "$TARGET_DIR" remote remove "$REMOTE"
    err "$M: refs/heads/main 이 없습니다. (default branch 가 main 이 아닐 수 있음)"
  fi

  SRC_MAIN_SHA=$(git -C "$TARGET_DIR" rev-parse "$SRC_MAIN")
  if git -C "$TARGET_DIR" merge-base --is-ancestor "$SRC_MAIN_SHA" HEAD 2>/dev/null; then
    ok "5) $M/main: 이미 흡수됨 (skip merge)"
    MERGED="skip"
    NEW_CNT=0
  else
    if git -C "$TARGET_DIR" merge-base HEAD "$SRC_MAIN" >/dev/null 2>&1; then
      NEW_CNT=$(git -C "$TARGET_DIR" rev-list --count "HEAD..$SRC_MAIN" 2>/dev/null || echo 0)
    else
      NEW_CNT=$(git -C "$TARGET_DIR" rev-list --count "$SRC_MAIN" 2>/dev/null || echo 0)
    fi

    log "5) merging $SRC_MAIN → $TARGET_BRANCH  ($NEW_CNT new commits)"
    git -C "$TARGET_DIR" merge --allow-unrelated-histories --no-ff --no-edit \
      -m "merge($M): import from kmu-aws-capstone-team-4/$M (main)" \
      "$SRC_MAIN"
    ok "    merged."
    MERGED="merged"
    TOTAL_NEW_COMMITS=$((TOTAL_NEW_COMMITS + NEW_CNT))
  fi

  log "6) preserve non-main branches"
  BR_CREATED=0; BR_FF=0; BR_DIV=0; BR_SKIP=0
  while IFS= read -r BR_REF; do
    [ -z "$BR_REF" ] && continue
    B="${BR_REF#$REMOTE/}"
    [ "$B" = "HEAD" ] && continue
    [ "$B" = "main" ] && continue
    LOCAL_BR="$M/$B"
    SRC_BR="$REMOTE/$B"

    if git -C "$TARGET_DIR" rev-parse --verify "$LOCAL_BR" >/dev/null 2>&1; then
      LOCAL_SHA=$(git -C "$TARGET_DIR" rev-parse "$LOCAL_BR")
      SRC_SHA=$(git -C "$TARGET_DIR" rev-parse "$SRC_BR")
      if [ "$LOCAL_SHA" = "$SRC_SHA" ]; then
        BR_SKIP=$((BR_SKIP + 1))
      elif git -C "$TARGET_DIR" merge-base --is-ancestor "$LOCAL_SHA" "$SRC_SHA" 2>/dev/null; then
        git -C "$TARGET_DIR" branch -f "$LOCAL_BR" "$SRC_BR" >/dev/null
        BR_FF=$((BR_FF + 1))
      else
        warn "    $LOCAL_BR: divergent (local 과 source 가 갈라짐, manual review 필요)"
        BR_DIV=$((BR_DIV + 1))
      fi
    else
      git -C "$TARGET_DIR" branch "$LOCAL_BR" "$SRC_BR"
      BR_CREATED=$((BR_CREATED + 1))
    fi
  done < <(git -C "$TARGET_DIR" branch -r --list "$REMOTE/*" | sed 's/^[* ]*//')
  ok "    branches: created=$BR_CREATED ff=$BR_FF unchanged=$BR_SKIP divergent=$BR_DIV"

  git -C "$TARGET_DIR" remote remove "$REMOTE"

  SUMMARY+=("$M: $MERGED (+$NEW_CNT commits)  branches: +$BR_CREATED ff=$BR_FF div=$BR_DIV")
done

echo
log "============================================================"
log "  SUMMARY"
log "============================================================"
for line in "${SUMMARY[@]}"; do
  echo "  - $line"
done
echo
if [ $APPLY -eq 1 ]; then
  ok "DONE. 새로 흡수된 main 커밋 합계: $TOTAL_NEW_COMMITS"
  echo
  log "검증 명령:"
  echo "  git -C $TARGET_DIR log --all --graph --oneline | head -50"
  echo "  git -C $TARGET_DIR branch -a"
  echo "  git -C $TARGET_DIR log --follow backend/manage.py | head -5"
  echo "  git -C $TARGET_DIR log --pretty=format:'%h %an %ad %s' --date=short backend/ | head -10"
  echo
  log "푸시 (검토 후 수동):"
  echo "  git -C $TARGET_DIR push -u origin $TARGET_BRANCH"
  echo "  git -C $TARGET_DIR push origin --all     # 모든 로컬 브랜치 푸시"
  echo
  log "백업 브랜치는 그대로 둡니다. 문제 시 복구:"
  echo "  git -C $TARGET_DIR reset --hard $BACKUP"
else
  log "dry-run 완료. 실제 적용: ./migrate-to-capstone-54.sh --apply"
fi
