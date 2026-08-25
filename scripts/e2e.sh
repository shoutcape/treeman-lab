#!/usr/bin/env bash
# Run a real TreeMan create/delete lifecycle against the lab project.

set -euo pipefail

PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TREEMAN_BIN=${TREEMAN_BIN:-treeman}
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)-$$
BRANCH=${TREEMAN_E2E_BRANCH:-e2e/$RUN_ID}
WORKTREE_PATH="$PROJECT_ROOT/.worktrees/${BRANCH//\//-}"
DB_SLUG=${BRANCH//\//_}
DB_SLUG=${DB_SLUG//-/_}
DB_SLUG=${DB_SLUG//./_}
DATABASE_NAME="treeman_lab__$DB_SLUG"
RESULT_DIR="$PROJECT_ROOT/.treeman-lab/e2e/$RUN_ID"
CREATE_LOG="$RESULT_DIR/create.log"
DELETE_LOG="$RESULT_DIR/delete.log"
LIST_JSON="$RESULT_DIR/list.json"
REPORT="$RESULT_DIR/report.json"
CREATE_MS=0
DELETE_MS=0
CREATED=false
DELETED=false
RESULT=failed

if [[ "$TREEMAN_BIN" == */* ]]; then
  [[ -x "$TREEMAN_BIN" ]] || {
    printf 'E2E FAIL: TREEMAN_BIN is not executable: %s\n' "$TREEMAN_BIN" >&2
    exit 1
  }
else
  TREEMAN_BIN=$(command -v "$TREEMAN_BIN") || {
    printf 'E2E FAIL: treeman binary not found: %s\n' "$TREEMAN_BIN" >&2
    exit 1
  }
fi

mkdir -p "$RESULT_DIR"

elapsed_ms() {
  local started_ns=$1
  printf '%s' "$(( ($(date +%s%N) - started_ns) / 1000000 ))"
}

database_count() {
  docker exec treeman-lab-postgres \
    psql -U postgres -d postgres -tAc \
    "select count(*) from pg_database where datname = '$DATABASE_NAME'"
}

write_report() {
  local status=$1
  printf '{\n'
  printf '  "status": "%s",\n' "$status"
  printf '  "branch": "%s",\n' "$BRANCH"
  printf '  "worktree_path": "%s",\n' "$WORKTREE_PATH"
  printf '  "database": "%s",\n' "$DATABASE_NAME"
  printf '  "create_ms": %s,\n' "$CREATE_MS"
  printf '  "delete_ms": %s,\n' "$DELETE_MS"
  printf '  "worktree_created": %s,\n' "$CREATED"
  printf '  "worktree_deleted": %s\n' "$DELETED"
  printf '}\n'
}

cleanup() {
  local status=$?

  if [[ -e "$WORKTREE_PATH" ]]; then
    CREATED=true
  fi
  if [[ "$CREATED" == true && "$DELETED" == false && -e "$WORKTREE_PATH" ]]; then
    printf 'E2E cleanup: deleting %s\n' "$BRANCH" >&2
    local started_ns
    started_ns=$(date +%s%N)
    if "$TREEMAN_BIN" delete --path "$WORKTREE_PATH" --branch "$BRANCH" --yes --force 2>&1 | tee "$DELETE_LOG" >&2; then
      DELETE_MS=$(elapsed_ms "$started_ns")
      DELETED=true
    fi
  fi

  if [[ "$status" -eq 0 ]]; then
    RESULT=passed
  fi
  write_report "$RESULT" > "$REPORT"
  printf 'E2E report: %s\n' "$REPORT" >&2
  exit "$status"
}
trap cleanup EXIT

[[ "$BRANCH" =~ ^e2e/[A-Za-z0-9._/-]+$ ]] || {
  printf 'E2E FAIL: TREEMAN_E2E_BRANCH must use e2e/ plus letters, digits, ., _, /, or -: %s\n' "$BRANCH" >&2
  exit 1
}
[[ ${#DATABASE_NAME} -le 63 ]] || {
  printf 'E2E FAIL: TREEMAN_E2E_BRANCH produces a PostgreSQL name longer than 63 characters\n' >&2
  exit 1
}
[[ ! -e "$WORKTREE_PATH" ]] || {
  printf 'E2E FAIL: worktree path already exists: %s\n' "$WORKTREE_PATH" >&2
  exit 1
}
[[ "$(database_count)" == "0" ]] || {
  printf 'E2E FAIL: database already exists: %s\n' "$DATABASE_NAME" >&2
  exit 1
}

printf 'E2E create: %s\n' "$BRANCH" >&2
started_ns=$(date +%s%N)
"$TREEMAN_BIN" create "$BRANCH" 2>&1 | tee "$CREATE_LOG" >&2
CREATE_MS=$(elapsed_ms "$started_ns")
CREATED=true

[[ -d "$WORKTREE_PATH" ]] || {
  printf 'E2E FAIL: worktree missing after create\n' >&2
  exit 1
}
[[ -d "$WORKTREE_PATH/node_modules" ]] || {
  printf 'E2E FAIL: dependencies missing after create\n' >&2
  exit 1
}
grep -Fx "DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/$DATABASE_NAME" "$WORKTREE_PATH/.env" >/dev/null
grep -Fx "$DATABASE_NAME" "$WORKTREE_PATH/.treeman-lab/post-create.log" >/dev/null
[[ "$(database_count)" == "1" ]] || {
  printf 'E2E FAIL: branch database missing after create\n' >&2
  exit 1
}

(
  cd "$WORKTREE_PATH"
  npm run check:db
) >&2
"$TREEMAN_BIN" list --json > "$LIST_JSON"
grep -F "\"branch\":\"$BRANCH\"" "$LIST_JSON" >/dev/null

printf 'E2E delete: %s\n' "$BRANCH" >&2
started_ns=$(date +%s%N)
"$TREEMAN_BIN" delete --path "$WORKTREE_PATH" --branch "$BRANCH" --yes --force 2>&1 | tee "$DELETE_LOG" >&2
DELETE_MS=$(elapsed_ms "$started_ns")
DELETED=true

[[ ! -e "$WORKTREE_PATH" ]] || {
  printf 'E2E FAIL: worktree remains after delete\n' >&2
  exit 1
}
! git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"
[[ "$(database_count)" == "0" ]] || {
  printf 'E2E FAIL: branch database remains after delete\n' >&2
  exit 1
}

printf 'E2E PASS: create=%sms delete=%sms branch=%s\n' "$CREATE_MS" "$DELETE_MS" "$BRANCH"
