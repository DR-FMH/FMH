#!/usr/bin/env bash
#
# Regression tests for fmh-governance-check.sh.
#
# Synthetic token-shaped fixtures are built by concatenation at runtime,
# so this file itself contains no literal detector-matching string and
# stays clean under the governance scan.
#
#   T0  script + workflow files committed alone in a stub repo -> EXIT 0
#   T1  current repo range without injection               -> EXIT 0
#   T2  synthetic token in a normal source file             -> nonzero
#   T3  synthetic token under tests/                        -> nonzero
#   T4  synthetic token in docs (same line says example)    -> nonzero
#   T5  synthetic token in .env.example (same line says     -> nonzero
#       example/placeholder)
#   T6  unresolvable base SHA                               -> nonzero
#   T7  synthetic value in a file named redaction.ts        -> nonzero
#
# T1 base defaults to dr-fmh/dev; override with FMH_REGRESSION_BASE.
# Read-only for the real repo: negative tests use throwaway repos
# under $TMPDIR. No network. No real credentials anywhere.

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/fmh-governance-check.sh"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BASE_REF="${FMH_REGRESSION_BASE:-dr-fmh/dev}"

# Token-shape fragments. Concatenated below; no single literal below
# matches a detector on its own.
P_ANTH="sk-ant-"
P_GH="ghp_"
P_AWS="AKIA"
P_SL="xoxb-"
P_GG="AIza"

PASS=0
FAIL=0

report() {
  if [ "$1" = "0" ]; then
    PASS=$((PASS + 1))
    echo "PASS: $2"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $2"
  fi
}

# run_expect <name> <want:zero|nonzero> [want-output-substring] -- cmd...
run_expect() {
  local name="$1" want="$2" needle="$3"
  shift 3
  [ "$1" = "--" ] && shift
  local out rc
  out=$("$@" 2>&1) && rc=0 || rc=$?
  if [ "$want" = "zero" ] && [ "$rc" -eq 0 ]; then
    report 0 "$name (exit 0)"
  elif [ "$want" = "nonzero" ] && [ "$rc" -ne 0 ]; then
    if [ -n "$needle" ] && ! grep -q "$needle" <<< "$out"; then
      echo "$out" | tail -5
      report 1 "$name (nonzero but missing marker '$needle')"
    else
      report 0 "$name (exit $rc)"
    fi
  else
    echo "$out" | tail -8
    report 1 "$name (exit $rc, wanted $want)"
  fi
}

# new_stub_repo: throwaway repo satisfying the content checks.
new_stub_repo() {
  local d
  d=$(mktemp -d)
  (
    cd "$d"
    git init -q
    git config user.email "fmh-test@example.invalid"
    git config user.name "fmh-test"
    printf '# Stub\n\nFMH Distribution Notice: stub.\nUpstream: anomalyco/opencode.\nFMH does not provide automatic approval.\n' > README.md
    printf '# Stub notice\n\nhttps://github.com/anomalyco/opencode\n' > NOTICE-FMH.md
    mkdir -p docs
    printf '# Stub docs\n\nNothing here.\n' > docs/probe.md
    git add -A
    git commit -qm "stub base"
  )
  echo "$d"
}

echo "### T0: governance files committed alone scan clean"
T0=$(new_stub_repo)
mkdir -p "$T0/.github/scripts" "$T0/.github/workflows"
cp "$REPO/.github/scripts/fmh-governance-check.sh" "$T0/.github/scripts/"
cp "$REPO/.github/workflows/fmh-ci.yml" "$T0/.github/workflows/"
(
  cd "$T0"
  git add -A
  git commit -qm "governance files"
)
run_expect "T0 self-trip guard" zero "" -- bash -c "cd '$T0' && bash '$SCRIPT' --base HEAD^ --head HEAD"
rm -rf "$T0"

echo "### T1: clean baseline range in real repo"
run_expect "T1 clean baseline" zero "" -- bash -c "cd '$REPO' && bash '$SCRIPT' --base '$BASE_REF' --head HEAD"

echo "### T2: token in normal source file"
T2=$(new_stub_repo)
TOK_SRC="${P_ANTH}$(printf 't%.0s' 1 2 3 4)$(printf '0%.0s' 1 2 3 4 5 6 7 8)"
(
  cd "$T2"
  mkdir -p src
  cat > src/notes.ts <<EOF
export const note = "plain";
export const key = "${TOK_SRC}";
EOF
  git add -A
  git commit -qm "inject source token"
)
run_expect "T2 source token fails" nonzero "secret-pattern:" -- bash -c "cd '$T2' && bash '$SCRIPT' --base HEAD^ --head HEAD"
rm -rf "$T2"

echo "### T3: token under tests/"
T3=$(new_stub_repo)
TOK_T="${P_GH}$(printf 'A%.0s' {1..36})"
(
  cd "$T3"
  mkdir -p tests
  cat > tests/fixture-notes.test.ts <<EOF
const k = "${TOK_T}";
test("stub", () => {});
EOF
  git add -A
  git commit -qm "inject test token"
)
run_expect "T3 tests-dir token fails" nonzero "secret-pattern:" -- bash -c "cd '$T3' && bash '$SCRIPT' --base HEAD^ --head HEAD"
rm -rf "$T3"

echo "### T4: token in docs (same line carries example wording)"
T4=$(new_stub_repo)
TOK_D="${P_AWS}$(printf 'Z%.0s' {1..16})"
(
  cd "$T4"
  cat > docs/notes.md <<EOF
# Notes
Deploy key ${TOK_D} (example placeholder for docs).
EOF
  git add -A
  git commit -qm "inject docs token"
)
run_expect "T4 docs token fails despite example wording" nonzero "secret-pattern:" -- bash -c "cd '$T4' && bash '$SCRIPT' --base HEAD^ --head HEAD"
rm -rf "$T4"

echo "### T5: token in .env.example (same line carries wording)"
T5=$(new_stub_repo)
TOK_E="${P_SL}$(printf '1%.0s' 1 2 3)-$(printf '2%.0s' 1 2 3)-$(printf 'Z%.0s' 1 2 3 4 5 6)"
(
  cd "$T5"
  cat > .env.example <<EOF
# example placeholder values for local setup
SLACK_TOKEN=${TOK_E} # example placeholder
EOF
  git add -A
  git commit -qm "inject env example token"
)
run_expect "T5 env-example token fails despite wording" nonzero "secret-pattern:" -- bash -c "cd '$T5' && bash '$SCRIPT' --base HEAD^ --head HEAD"
rm -rf "$T5"

echo "### T6: unresolvable base SHA fails closed"
run_expect "T6 invalid base" nonzero "" -- bash -c "cd '$REPO' && bash '$SCRIPT' --base 0000000000000000000000000000000000000001 --head HEAD"

echo "### T7: value in detector-named source file still fails"
T7=$(new_stub_repo)
TOK_G="${P_GG}$(printf 'Z%.0s' {1..32})"
(
  cd "$T7"
  mkdir -p src
  cat > src/redaction.ts <<EOF
export const fixture = "${TOK_G}";
EOF
  git add -A
  git commit -qm "inject detector-file token"
)
run_expect "T7 detector-named file gets no exemption" nonzero "secret-pattern:" -- bash -c "cd '$T7' && bash '$SCRIPT' --base HEAD^ --head HEAD"
rm -rf "$T7"

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
