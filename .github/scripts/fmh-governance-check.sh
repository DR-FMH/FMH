#!/usr/bin/env bash
#
# FMH governance check.
#
# Usage:
#   fmh-governance-check.sh --base <commit> --head <commit>
#
# What it checks:
#   1. README.md contains the FMH Distribution Notice.
#   2. NOTICE-FMH.md exists with upstream attribution.
#   3. README.md keeps upstream attribution.
#   4. Full-tree scan for prohibited committed artifacts
#      (*.db, *.sqlite, *.sqlite3, *-wal, *-shm, *-journal,
#      *.bak, *.backup, real .env files).
#   5. Secret patterns in ADDED lines of base...head only.
#      No path is excluded: source, tests, docs, README, and
#      .env.example are all scanned. No keyword (EXAMPLE,
#      placeholder, your-, 123...) suppresses a match.
#   6. The no-automatic-approval disclaimer is present and no
#      doc claims automatic approval/admission as supported.
#
# Exit codes:
#   0  clean
#   1  governance finding
#   2  usage or internal error (unresolvable base/head, diff failure,
#      unparseable diff). Never prints PASS on error.
#
# Properties: read-only (no file modification), no network access.
# Secret values are never printed: findings show file, line, detector
# type, and a redacted prefix only.

set -euo pipefail

BASE=""
HEAD=""

usage() {
  echo "usage: fmh-governance-check.sh --base <commit> --head <commit>" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      [ $# -ge 2 ] || { usage; exit 2; }
      BASE="$2"
      shift 2
      ;;
    --head)
      [ $# -ge 2 ] || { usage; exit 2; }
      HEAD="$2"
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[ -n "$BASE" ] && [ -n "$HEAD" ] || { usage; exit 2; }

if ! git cat-file -e "${BASE}^{commit}" 2>/dev/null; then
  echo "error: base commit is not resolvable: $BASE" >&2
  exit 2
fi
if ! git cat-file -e "${HEAD}^{commit}" 2>/dev/null; then
  echo "error: head commit is not resolvable: $HEAD" >&2
  exit 2
fi

FINDINGS=0

fail() {
  FINDINGS=$((FINDINGS + 1))
  echo "::error::$1" >&2
}

echo "=== 1. FMH distribution notice ==="
if [ -f README.md ] && grep -q "FMH Distribution Notice" README.md; then
  echo "ok: README.md contains FMH Distribution Notice"
else
  fail "README.md is missing 'FMH Distribution Notice'"
fi

echo "=== 2. NOTICE-FMH.md with upstream attribution ==="
if [ -f NOTICE-FMH.md ] && grep -q "https://github.com/anomalyco/opencode" NOTICE-FMH.md; then
  echo "ok: NOTICE-FMH.md exists with upstream attribution"
else
  fail "NOTICE-FMH.md is missing or lacks upstream attribution"
fi

echo "=== 3. README keeps upstream attribution ==="
if [ -f README.md ] && grep -q "anomalyco/opencode" README.md; then
  echo "ok: README.md keeps upstream attribution"
else
  fail "README.md is missing upstream attribution (anomalyco/opencode)"
fi

echo "=== 4. prohibited artifacts (full tree, no exclusions) ==="
ARTIFACTS=$(git ls-files | grep -E '\.(db|sqlite|sqlite3)$|-(wal|shm|journal)$|\.(bak|backup)$' || true)
# Only the conventional placeholder template is not a real env file.
ENV_FILES=$(git ls-files | grep -E '(^|/)\.env(\.|$)' | grep -v -E '(^|/)\.env\.example$' || true)
if [ -n "$ARTIFACTS" ] || [ -n "$ENV_FILES" ]; then
  [ -n "$ARTIFACTS" ] && echo "$ARTIFACTS" >&2
  [ -n "$ENV_FILES" ] && echo "$ENV_FILES" >&2
  fail "committed database/backup artifacts or real .env files detected above"
else
  echo "ok: no committed database, backup, or real .env artifacts"
fi

echo "=== 5. secret patterns in added lines (no path exclusions) ==="
DIFF=""
if ! DIFF=$(git diff --no-color --no-ext-diff --unified=0 "${BASE}...${HEAD}" --); then
  echo "error: git diff failed for range ${BASE}...${HEAD}" >&2
  exit 2
fi

check_added_line() {
  local file="$1" line="$2" content="$3"
  local detector="" token=""
  if [[ $content =~ (sk-ant-[A-Za-z0-9_=-]{10,}) ]]; then
    detector="anthropic-key"; token="${BASH_REMATCH[1]}"
  elif [[ $content =~ (sk-proj-[A-Za-z0-9_=-]{10,}) ]]; then
    detector="openai-project-key"; token="${BASH_REMATCH[1]}"
  elif [[ $content =~ (ghp_[A-Za-z0-9]{30,}|gho_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}) ]]; then
    detector="github-token"; token="${BASH_REMATCH[1]}"
  elif [[ $content =~ (AKIA[0-9A-Z]{16}) ]]; then
    detector="aws-access-key"; token="${BASH_REMATCH[1]}"
  elif [[ $content =~ (xox[baprs]-[A-Za-z0-9-]{10,}) ]]; then
    detector="slack-token"; token="${BASH_REMATCH[1]}"
  elif [[ $content =~ (AIza[0-9A-Za-z_-]{30,}) ]]; then
    detector="google-api-key"; token="${BASH_REMATCH[1]}"
  elif [[ $content =~ (-----BEGIN\ [A-Z0-9\ ]*PRIVATE\ KEY-----) ]]; then
    detector="private-key-block"; token="${BASH_REMATCH[1]}"
  fi
  if [ -n "$detector" ]; then
    fail "secret-pattern:${detector} at ${file}:${line} (${token:0:4}***[${#token} chars redacted])"
  fi
}

if [ -z "$DIFF" ]; then
  echo "warning: empty diff for range ${BASE}...${HEAD}; added-line scan is vacuous, artifact and content checks still enforced" >&2
else
  CURRENT_FILE=""
  NEW_LINE=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '+++'*)
        CURRENT_FILE="${line#'+++ '}"
        CURRENT_FILE="${CURRENT_FILE#'b/'}"
        ;;
      '@@ '*)
        if [[ $line =~ ^@@\ -[0-9]+(,[0-9]+)?\ \+([0-9]+)(,[0-9]+)?\ @@ ]]; then
          NEW_LINE="${BASH_REMATCH[2]}"
        else
          echo "error: unparseable hunk header: $line" >&2
          exit 2
        fi
        ;;
      '+'*)
        check_added_line "$CURRENT_FILE" "$NEW_LINE" "${line#'+'}"
        NEW_LINE=$((NEW_LINE + 1))
        ;;
      '-'* | '\'* | 'diff --git '* | 'old mode'* | 'new mode'* | \
      'new file mode'* | 'deleted file mode'* | 'similarity index'* | \
      'dissimilarity index'* | 'rename from'* | 'rename to'* | \
      'index '* | 'Binary files '* | 'GIT binary patch'* | 'literal '*)
        : ;;
      *)
        echo "error: unexpected diff line: $line" >&2
        exit 2
        ;;
    esac
  done <<< "$DIFF"
  echo "ok: added-line secret scan complete"
fi

echo "=== 6. automatic approval/admission claims ==="
if [ -f README.md ] && [ -f NOTICE-FMH.md ] && grep -qi "does not provide automatic approval" README.md NOTICE-FMH.md; then
  echo "ok: disclaimer present (no automatic approval)"
else
  fail "FMH disclaimer about automatic approval is missing"
fi
TARGETS=()
for t in README.md NOTICE-FMH.md docs; do
  [ -e "$t" ] && TARGETS+=("$t")
done
if [ "${#TARGETS[@]}" -gt 0 ] && grep -rni -E 'automatic(ally)? +[^.]{0,60}(approv|admit)[^.]{0,40}(enabled|supported|available|granted|allowed by default)' "${TARGETS[@]}" 2>/dev/null; then
  fail "docs claim automatic approval/admission as supported"
else
  echo "ok: no unsupported automatic-approval claims"
fi

if [ "$FINDINGS" -ne 0 ]; then
  echo "FMH governance FAILED with ${FINDINGS} finding(s)" >&2
  exit 1
fi
echo "FMH_GOVERNANCE_CLEAN"
