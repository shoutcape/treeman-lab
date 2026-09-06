#!/usr/bin/env bash
# Run the rerunnable setup lifecycle against the lab project.

set -euo pipefail

PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TREEMAN_BIN=${TREEMAN_BIN:-treeman}
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)-$$
BRANCH=${TREEMAN_SETUP_E2E_BRANCH:-setup-e2e/$RUN_ID}
WORKTREE_PATH="$PROJECT_ROOT/.worktrees/${BRANCH//\//-}"
RESULT_DIR="$PROJECT_ROOT/.treeman-lab/setup-e2e/$RUN_ID"
CONFIG_PATH="$PROJECT_ROOT/.treeman.toml"
ROOT_ENV_PATH="$PROJECT_ROOT/.env"
CONFIG_BACKUP="$RESULT_DIR/treeman.toml.original"
ROOT_ENV_BACKUP="$RESULT_DIR/.env.original"
SOURCE_EXTRA_ENV="$PROJECT_ROOT/.env.setup-e2e-$RUN_ID"
SOURCE_EXTRA_NAME=".env.setup-e2e-$RUN_ID"
CREATE_LOG="$RESULT_DIR/create.log"
SETUP_LOG="$RESULT_DIR/setup.log"
REFRESH_DRIFT_LOG="$RESULT_DIR/refresh-drift.log"
REFRESH_LOG="$RESULT_DIR/refresh.log"
FAILURE_LOG="$RESULT_DIR/failure-continuation.log"
HOOK_DENIED_LOG="$RESULT_DIR/hooks-denied.log"
HOOK_TRUSTED_LOG="$RESULT_DIR/hooks-trusted.log"
HOOK_NOT_SAVED_LOG="$RESULT_DIR/hooks-not-saved.log"
LOCK_FIRST_LOG="$RESULT_DIR/lock-first.log"
LOCK_SECOND_LOG="$RESULT_DIR/lock-second.log"
LOCK_RELEASED_LOG="$RESULT_DIR/lock-released.log"
STDOUT_LOG="$RESULT_DIR/setup.stdout"
STDERR_LOG="$RESULT_DIR/setup.stderr"
WORKTREE_BEFORE="$RESULT_DIR/worktrees.before"
WORKTREE_AFTER="$RESULT_DIR/worktrees.after"
BRANCHES_BEFORE="$RESULT_DIR/branches.before"
BRANCHES_AFTER="$RESULT_DIR/branches.after"
LOCK_MARKER="$RESULT_DIR/hook-started"
DATABASE_NAME=""
POSTGRES_STOPPED=false
FIRST_PID=""

if [[ "$TREEMAN_BIN" == */* ]]; then
  [[ -x "$TREEMAN_BIN" ]] || {
    printf 'SETUP E2E FAIL: TREEMAN_BIN is not executable: %s\n' "$TREEMAN_BIN" >&2
    exit 1
  }
  TREEMAN_BIN=$(CDPATH='' cd -- "$(dirname -- "$TREEMAN_BIN")" && pwd)/$(basename -- "$TREEMAN_BIN")
else
  TREEMAN_BIN=$(command -v "$TREEMAN_BIN") || {
    printf 'SETUP E2E FAIL: treeman binary not found: %s\n' "$TREEMAN_BIN" >&2
    exit 1
  }
fi

mkdir -p "$RESULT_DIR"
cp -p "$CONFIG_PATH" "$CONFIG_BACKUP"
cp -p "$ROOT_ENV_PATH" "$ROOT_ENV_BACKUP"

fail() {
  printf 'SETUP E2E FAIL: %s\n' "$1" >&2
  exit 1
}

assert_file_contains() {
  local file=$1
  local text=$2
  grep -F -- "$text" "$file" >/dev/null || fail "$file does not contain: $text"
}

assert_file_not_contains() {
  local file=$1
  local text=$2
  if grep -F -- "$text" "$file" >/dev/null; then
    fail "$file unexpectedly contains: $text"
  fi
}

assert_value() {
  local description=$1
  local expected=$2
  local actual=$3
  [[ "$expected" == "$actual" ]] || fail "$description: expected $expected, got $actual"
}

database_count() {
  docker exec treeman-lab-postgres \
    psql -U postgres -d postgres -tAc \
    "select count(*) from pg_database where datname = '$DATABASE_NAME'"
}

database_query() {
  local database=$1
  local query=$2
  docker exec treeman-lab-postgres \
    psql -v ON_ERROR_STOP=1 -U postgres -d "$database" -tAc "$query"
}

worktree_env_value() {
  local key=$1
  local file=$2
  while IFS= read -r line; do
    case "$line" in
      "$key"=*) printf '%s' "${line#*=}"; return 0 ;;
    esac
  done < "$file"
  return 1
}

hook_line_count() {
  if [[ -f "$WORKTREE_PATH/.treeman-lab/post-create.log" ]]; then
    wc -l < "$WORKTREE_PATH/.treeman-lab/post-create.log"
  else
    printf '0\n'
  fi
}

run_setup() {
  local log=$1
  shift
  "$TREEMAN_BIN" setup "$BRANCH" "$@" > "$log" 2>&1
}

reject_setup() {
  local log=$1
  shift
  set +e
  "$TREEMAN_BIN" setup "$BRANCH" "$@" > "$log" 2>&1
  local result=$?
  set -e
  [[ "$result" -ne 0 ]] || fail "setup unexpectedly accepted: $*"
}

restore_inputs() {
  if [[ -f "$CONFIG_BACKUP" ]]; then
    cp -p "$CONFIG_BACKUP" "$CONFIG_PATH"
  fi
  if [[ -f "$ROOT_ENV_BACKUP" ]]; then
    cp -p "$ROOT_ENV_BACKUP" "$ROOT_ENV_PATH"
  fi
  rm -f "$SOURCE_EXTRA_ENV"
}

cleanup() {
  local status=$?
  set +e

  if [[ -n "$FIRST_PID" ]]; then
    kill "$FIRST_PID" 2>/dev/null
    wait "$FIRST_PID" 2>/dev/null
    FIRST_PID=""
  fi

  restore_inputs

  if [[ "$POSTGRES_STOPPED" == true ]]; then
    docker compose up -d --wait postgres >/dev/null 2>&1
    POSTGRES_STOPPED=false
  fi

  if [[ -e "$WORKTREE_PATH" ]]; then
    printf 'SETUP E2E cleanup: deleting %s\n' "$BRANCH" >&2
    "$TREEMAN_BIN" delete --path "$WORKTREE_PATH" --branch "$BRANCH" --yes --force \
      > "$RESULT_DIR/delete.log" 2>&1
  fi

  if [[ "$status" -eq 0 && -e "$WORKTREE_PATH" ]]; then
    status=1
    printf 'SETUP E2E FAIL: worktree remains after cleanup: %s\n' "$WORKTREE_PATH" >&2
  fi
  if [[ "$status" -eq 0 ]]; then
    git worktree list --porcelain > "$WORKTREE_AFTER"
    git for-each-ref --format='%(refname) %(objectname)' refs/heads > "$BRANCHES_AFTER"
    if ! cmp -s "$WORKTREE_BEFORE" "$WORKTREE_AFTER"; then
      status=1
      printf 'SETUP E2E FAIL: Git worktree registrations changed\n' >&2
    fi
    if ! cmp -s "$BRANCHES_BEFORE" "$BRANCHES_AFTER"; then
      status=1
      printf 'SETUP E2E FAIL: local branch refs changed\n' >&2
    fi
  fi
  if [[ "$status" -eq 0 && -n "$DATABASE_NAME" ]]; then
    if [[ "$(database_count 2>/dev/null)" != "0" ]]; then
      status=1
      printf 'SETUP E2E FAIL: database remains after cleanup: %s\n' "$DATABASE_NAME" >&2
    fi
  fi

  if [[ "$status" -eq 0 ]]; then
    printf 'SETUP E2E PASS: branch=%s\n' "$BRANCH" >&2
  else
    printf 'SETUP E2E logs: %s\n' "$RESULT_DIR" >&2
  fi
  exit "$status"
}
trap cleanup EXIT

[[ ! -e "$WORKTREE_PATH" ]] || fail "worktree path already exists: $WORKTREE_PATH"
git worktree list --porcelain > "$WORKTREE_BEFORE"
git for-each-ref --format='%(refname) %(objectname)' refs/heads > "$BRANCHES_BEFORE"

# Add a run-specific hook command so this test cannot accidentally use an
# approval saved by an earlier manual run of the lab. The second hook is also
# the lock-test delay, so it works in a worktree created from committed HEAD.
printf '%s\n' \
  '[database]' \
  'env_key = "DATABASE_URL"' \
  '' \
  '[hooks]' \
  "post_create = [\"npm run post-create\", 'test -z \"\$TREEMAN_LAB_HOOK_START\" || (printf started > \"\$TREEMAN_LAB_HOOK_START\"; sleep \"\$TREEMAN_LAB_HOOK_DELAY_SECONDS\") # setup-e2e-$RUN_ID']" \
  > "$CONFIG_PATH"

printf 'SETUP E2E create: %s\n' "$BRANCH" >&2
"$TREEMAN_BIN" create "$BRANCH" --trust-hooks > "$CREATE_LOG" 2>&1

[[ -d "$WORKTREE_PATH" ]] || fail "worktree missing after create"
[[ -d "$WORKTREE_PATH/node_modules" ]] || fail "dependencies missing after create"
[[ -f "$WORKTREE_PATH/.treeman-lab/post-create.log" ]] || fail "creation hook did not run"

DATABASE_URL=$(worktree_env_value DATABASE_URL "$WORKTREE_PATH/.env") || fail "DATABASE_URL missing after create"
DATABASE_NAME=${DATABASE_URL##*/}
[[ "$DATABASE_NAME" != "$DATABASE_URL" && "$DATABASE_NAME" != "" ]] || fail "could not determine branch database"
assert_value "created database count" "1" "$(database_count)"

database_query "$DATABASE_NAME" \
  "create table treeman_setup_e2e_sentinel (value text); insert into treeman_setup_e2e_sentinel values ('survives-rerun');" \
  >/dev/null

printf 'SOURCE_ONLY=from-source\n' > "$SOURCE_EXTRA_ENV"
printf 'WORKTREE_EDIT=preserve-me\n' >> "$WORKTREE_PATH/.env"
rm -rf "$WORKTREE_PATH/node_modules"
mkdir -p "$WORKTREE_PATH/test/setup-e2e/nested"

printf 'SETUP E2E rerun from nested directory\n' >&2
(
  cd "$WORKTREE_PATH/test/setup-e2e/nested"
  "$TREEMAN_BIN" setup
) > "$SETUP_LOG" 2>&1
assert_file_contains "$SETUP_LOG" "Preserved existing .env"
assert_file_contains "$SETUP_LOG" "Copied .env.setup-e2e-$RUN_ID"
assert_file_contains "$SETUP_LOG" "completed: reused $DATABASE_NAME"
assert_file_contains "$WORKTREE_PATH/.env" "WORKTREE_EDIT=preserve-me"
assert_file_contains "$WORKTREE_PATH/$SOURCE_EXTRA_NAME" "SOURCE_ONLY=from-source"
[[ -d "$WORKTREE_PATH/node_modules" ]] || fail "dependency repair did not recreate node_modules"
assert_value "sentinel after normal rerun" "survives-rerun" \
  "$(database_query "$DATABASE_NAME" "select value from treeman_setup_e2e_sentinel")"

HOOK_LINES_BEFORE=$(hook_line_count)

printf 'SOURCE_ONLY=from-refresh\n' > "$SOURCE_EXTRA_ENV"
printf 'WORKTREE_ONLY=must-be-replaced\n' > "$WORKTREE_PATH/$SOURCE_EXTRA_NAME"
printf 'DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55433/treeman_lab\n' > "$ROOT_ENV_PATH"
docker compose stop postgres >/dev/null
POSTGRES_STOPPED=true

printf 'SETUP E2E refresh guard with a changed source target\n' >&2
run_setup "$REFRESH_DRIFT_LOG" --refresh-env --skip-database --skip-deps --skip-hooks
assert_file_contains "$REFRESH_DRIFT_LOG" "skipping .env"
assert_file_contains "$REFRESH_DRIFT_LOG" "Skipped .env."
assert_file_contains "$WORKTREE_PATH/.env" "WORKTREE_EDIT=preserve-me"
assert_file_not_contains "$WORKTREE_PATH/.env" "55433"
assert_file_contains "$WORKTREE_PATH/$SOURCE_EXTRA_NAME" "SOURCE_ONLY=from-refresh"
assert_file_not_contains "$WORKTREE_PATH/$SOURCE_EXTRA_NAME" "WORKTREE_ONLY"

cp -p "$ROOT_ENV_BACKUP" "$ROOT_ENV_PATH"
printf 'SETUP E2E refresh guard while database setup is skipped\n' >&2
run_setup "$REFRESH_LOG" --refresh-env --skip-database --skip-deps --skip-hooks
assert_file_contains "$REFRESH_LOG" "Kept database $DATABASE_NAME"
assert_file_contains "$WORKTREE_PATH/.env" "/$DATABASE_NAME"

docker compose up -d --wait postgres >/dev/null
POSTGRES_STOPPED=false
assert_value "sentinel after refresh" "survives-rerun" \
  "$(database_query "$DATABASE_NAME" "select value from treeman_setup_e2e_sentinel")"

rm -rf "$WORKTREE_PATH/node_modules"
docker compose stop postgres >/dev/null
POSTGRES_STOPPED=true

printf 'SETUP E2E best-effort continuation with database unavailable\n' >&2
run_setup "$FAILURE_LOG" --skip-hooks
assert_file_contains "$FAILURE_LOG" "database setup failed"
assert_file_contains "$FAILURE_LOG" "Completed npm install"
[[ -d "$WORKTREE_PATH/node_modules" ]] || fail "dependency installation did not continue after database failure"

docker compose up -d --wait postgres >/dev/null
POSTGRES_STOPPED=false
assert_value "sentinel after database failure" "survives-rerun" \
  "$(database_query "$DATABASE_NAME" "select value from treeman_setup_e2e_sentinel")"

printf 'SETUP E2E hook authorization\n' >&2
set +e
run_setup "$HOOK_DENIED_LOG" --rerun-hooks --skip-env --skip-database --skip-deps
HOOK_STATUS=$?
set -e
[[ "$HOOK_STATUS" -ne 0 ]] || fail "unapproved hooks unexpectedly ran"
assert_file_contains "$HOOK_DENIED_LOG" "--trust-hooks"
assert_file_contains "$HOOK_DENIED_LOG" "--skip-hooks"
assert_value "hook log after denied run" "$HOOK_LINES_BEFORE" "$(hook_line_count)"

TREEMAN_LAB_HOOK_START= TREEMAN_LAB_HOOK_DELAY_SECONDS= \
  run_setup "$HOOK_TRUSTED_LOG" --rerun-hooks --trust-hooks --skip-env --skip-database --skip-deps
assert_file_contains "$HOOK_TRUSTED_LOG" "Ran: npm run post-create"
assert_value "hook log after trusted run" "$((HOOK_LINES_BEFORE + 1))" "$(hook_line_count)"

set +e
run_setup "$HOOK_NOT_SAVED_LOG" --rerun-hooks --skip-env --skip-database --skip-deps
HOOK_STATUS=$?
set -e
[[ "$HOOK_STATUS" -ne 0 ]] || fail "--trust-hooks persisted approval"
assert_file_contains "$HOOK_NOT_SAVED_LOG" "hook approval required"

printf 'SETUP E2E flag validation and stderr output\n' >&2
reject_setup "$RESULT_DIR/flag-refresh-skip-env.log" --refresh-env --skip-env
reject_setup "$RESULT_DIR/flag-rerun-skip-hooks.log" --rerun-hooks --skip-hooks
reject_setup "$RESULT_DIR/flag-trust-skip-hooks.log" --trust-hooks --skip-hooks
reject_setup "$RESULT_DIR/flag-trust-without-rerun.log" --trust-hooks

printf 'SETUP E2E non-blocking setup lock\n' >&2
rm -f "$LOCK_MARKER"
TREEMAN_LAB_HOOK_START="$LOCK_MARKER" TREEMAN_LAB_HOOK_DELAY_SECONDS=4 \
  "$TREEMAN_BIN" setup "$BRANCH" --rerun-hooks --trust-hooks --skip-env --skip-database --skip-deps \
  > "$LOCK_FIRST_LOG" 2>&1 &
FIRST_PID=$!

for _ in {1..40}; do
  [[ -s "$LOCK_MARKER" ]] && break
  sleep 0.25
done
[[ -s "$LOCK_MARKER" ]] || fail "delayed hook did not start"

set +e
"$TREEMAN_BIN" setup "$BRANCH" --skip-env --skip-database --skip-deps --skip-hooks \
  > "$LOCK_SECOND_LOG" 2>&1
LOCK_STATUS=$?
set -e
[[ "$LOCK_STATUS" -ne 0 ]] || fail "second setup unexpectedly waited or succeeded"
assert_file_contains "$LOCK_SECOND_LOG" "another treeman setup is already running"

set +e
wait "$FIRST_PID"
FIRST_STATUS=$?
set -e
FIRST_PID=""
[[ "$FIRST_STATUS" -eq 0 ]] || fail "first delayed setup failed; see $LOCK_FIRST_LOG"

"$TREEMAN_BIN" setup "$BRANCH" --skip-env --skip-database --skip-deps --skip-hooks \
  > "$STDOUT_LOG" 2> "$STDERR_LOG"
assert_file_contains "$STDERR_LOG" "SETUP"
[[ ! -s "$STDOUT_LOG" ]] || fail "setup wrote destination output to stdout"
assert_value "hook log after lock run" "$((HOOK_LINES_BEFORE + 2))" "$(hook_line_count)"

printf 'SETUP E2E assertions passed\n' >&2
