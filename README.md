# TreeMan Lab

Local project for manual TreeMan development. It exercises environment copying,
dependency installation, PostgreSQL branch databases, post-create hooks, and
database cleanup.

## Bootstrap

```bash
cd /home/shoutcape/github/treeman-lab
make up
npm install
make check
```

PostgreSQL runs in `treeman-lab-postgres` on port `55432`. The local base
database is `treeman_lab`.

## What This Tests

| TreeMan behavior | Lab fixture | How to verify |
| --- | --- | --- |
| Default-branch fetch | Local bare `origin` with `main` | Run `treeman create <branch>` from the main worktree. |
| Worktree paths | `.worktrees/` is ignored | Confirm the new path uses `.worktrees/<branch-slug>`. |
| Environment copying | Ignored `.env` and tracked `.env.example` | Confirm both files exist in the new worktree. |
| Database creation | `.treeman.toml` uses `DATABASE_URL` | Confirm `.env` points to the branch database. |
| Database cleanup | Docker PostgreSQL on port `55432` | Delete the worktree and query `pg_database`. |
| npm detection | `package-lock.json` | Confirm TreeMan runs `npm install` and creates `node_modules/`. |
| Post-create hooks | `npm run post-create` | Confirm `.treeman-lab/post-create.log` contains the branch database. |
| Optional setup skips | `--skip-env`, `--skip-database`, `--skip-deps`, and `--skip-hooks` | Confirm the setup summary reports the requested skip. |
| Setup failure handling | Stop PostgreSQL or temporarily use a failing hook | Confirm the worktree remains available and TreeMan prints a warning. |
| Remote branch workflows | Local bare `origin` | Push a branch, remove its local ref, then run `treeman branch <branch>`. |
| Repository diagnostics | Valid Git, Docker, and TreeMan config | Run `treeman doctor`. |
| List and direct switching | Multiple linked worktrees | Run `treeman list --json` and `treeman switch <branch>`. |
| Clean merged worktrees | A locally merged test branch | Run `treeman clean --dry-run`, then `treeman clean --yes`. |
| Safe deletion | Unmerged test branches | Confirm delete needs `--force` until the branch is merged. |
| Fixture paths and modes | `test/fixtures/` contains nested, hidden, spaced, and executable files | Run `npm test` and create a worktree to confirm the files and modes are preserved. |
| Dependency installation breadth | `pg` plus `vitest` and its transitive packages | Run `npm install` or create a worktree without `--skip-deps`. |

The tracked `test/fixtures/` directory is intentionally deterministic test data.
It includes branch names with slash, dot, underscore, and hyphen characters, as
well as paths that commonly expose worktree copy or cleanup bugs.

Run the fixture checks with:

```bash
npm test
```

## Test Current TreeMan

Build TreeMan from the source worktree.

```bash
cd /home/shoutcape/github/TreeMan/.worktrees/feature-faster-database-setup-cleanup
make build
```

Create a lab worktree with the built binary.

```bash
cd /home/shoutcape/github/treeman-lab
/home/shoutcape/github/TreeMan/.worktrees/feature-faster-database-setup-cleanup/bin/treeman create feature/test-db
```

Expected results in `.worktrees/feature-test-db`:

- `.env` contains `treeman_lab__feature_test_db`.
- `node_modules/` exists after `npm install`.
- `.treeman-lab/post-create.log` contains `treeman_lab__feature_test_db`.
- `npm run check:db` connects to the branch database.

Delete the worktree and database from the main worktree.

```bash
cd /home/shoutcape/github/treeman-lab
/home/shoutcape/github/TreeMan/.worktrees/feature-faster-database-setup-cleanup/bin/treeman delete \
  --path .worktrees/feature-test-db \
  --branch feature/test-db \
  --yes \
  --force
```

Confirm deletion.

```bash
docker exec treeman-lab-postgres psql -U postgres -d postgres -tAc \
  "select datname from pg_database where datname = 'treeman_lab__feature_test_db'"
```

## Test Setup Stages

Use a new branch name for each command. TreeMan does not create a branch that
already exists.

### Skip Environment Copy

```bash
treeman create feature/no-env --skip-env --skip-database
test ! -e .worktrees/feature-no-env/.env
```

### Skip Database Setup

```bash
treeman create feature/no-db --skip-database
grep DATABASE_URL .worktrees/feature-no-db/.env
```

The copied URL must still point to `treeman_lab`, not a branch database.

### Skip Dependency Installation

```bash
treeman create feature/no-deps --skip-deps
test ! -d .worktrees/feature-no-deps/node_modules
```

### Skip Hooks

```bash
treeman create feature/no-hooks --skip-hooks
test ! -e .worktrees/feature-no-hooks/.treeman-lab/post-create.log
```

### Test Database Failure Handling

Stop PostgreSQL, create a worktree, then restart it.

```bash
make down
treeman create feature/db-unavailable
make up
```

TreeMan must create the worktree and print a database setup warning. Its copied
`.env` remains unchanged because no branch database was created.

## Test Diagnostics, Listing, and Switching

Create at least one worktree, then run these commands from the main worktree.

```bash
treeman doctor
treeman list --json
treeman switch feature/test-db
```

`treeman switch` prints the selected worktree path. The shell wrapper changes
the current directory only when shell integration is active.

## Remote Branch Test

Create and push a branch, return to `main`, then remove the local branch.

```bash
git switch -c feature/remote-demo
git commit --allow-empty -m "remote demo"
git push -u origin feature/remote-demo
git switch main
git branch -D feature/remote-demo
```

Test `treeman branch feature/remote-demo`. Delete its worktree with TreeMan
when finished.

## Test Clean

Create a worktree and make a commit in it.

```bash
treeman create feature/clean-demo
git -C .worktrees/feature-clean-demo commit --allow-empty -m "clean demo"
git merge --no-ff feature/clean-demo -m "merge clean demo"
treeman clean --dry-run
treeman clean --yes
```

`treeman clean --dry-run` must list the linked worktree. `treeman clean --yes`
must remove its worktree, branch, and branch database.

## Automated E2E

Run the complete real-project lifecycle against a TreeMan binary.

```bash
cd /home/shoutcape/github/treeman-lab
make e2e TREEMAN_BIN=/home/shoutcape/github/TreeMan/.worktrees/feature-faster-database-setup-cleanup/bin/treeman
```

The E2E test starts PostgreSQL if needed, creates a unique `e2e/<timestamp>`
branch, and captures TreeMan output. It verifies the linked worktree, copied
environment, npm installation, branch database, post-create hook, database
connection, and `list --json` output. It then force-deletes only its own
`e2e/` worktree and verifies that both the branch and database no longer exist.

Each run writes logs, `list.json`, and `report.json` under
`.treeman-lab/e2e/<timestamp>/`. The report records create and delete duration
in milliseconds. Failed runs use the same cleanup path and preserve the logs.

Set `TREEMAN_E2E_BRANCH=e2e/<name>` to use a stable test branch name. Names
can use letters, digits, `.`, `_`, `/`, and `-`, and must produce a PostgreSQL
database name of 63 characters or fewer. Do not run concurrent E2E tests with
the same branch name.

## Not Covered

The local bare `origin` has no GitHub or GitLab API. Use TreeMan's smoke test
for review commands, forge detection, and `gh` or `glab` interactions. Shell
installation is global machine configuration, so test it with TreeMan's
installation tests rather than this lab.

## Test Deletion Guards

Create a worktree, add an untracked file, then test both deletion paths.

```bash
treeman create feature/delete-guard
touch .worktrees/feature-delete-guard/untracked.txt
treeman delete \
  --path .worktrees/feature-delete-guard \
  --branch feature/delete-guard \
  --yes
```

The first delete must fail because the worktree is dirty. Repeat with `--force`
to remove the worktree, branch, and branch database.

```bash
treeman delete \
  --path .worktrees/feature-delete-guard \
  --branch feature/delete-guard \
  --yes \
  --force
```

## Reset

Delete linked worktrees first with `treeman delete`. Then remove generated
state and recreate the base environment.

```bash
rm -rf .treeman-lab node_modules .env
make up
npm install
```

Use `make down` to stop PostgreSQL. Use `docker compose down -v` only when you
intend to permanently remove all lab databases.
