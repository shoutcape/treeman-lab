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
