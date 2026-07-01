# weles

Claude Code plugin that archives conversation history (user questions and
assistant answers — no permission prompts, no `thinking` blocks) to
PostgreSQL, with a local JSONL backup in case the database is unavailable.

This repo holds a single plugin. `.claude-plugin/marketplace.json` at the
root is just a wrapper required by the Claude Code install format — the
actual plugin code lives in the `weles/` subdirectory.

Mechanism: `Stop` (after every turn) and `SessionEnd` (session close) hooks.
Write order: JSONL file first (always succeeds), then a best-effort write to
Postgres (errors go to a log, never block the session).

## Install as a plugin (recommended)

### 1. Set up the database

Mount `weles/sql/init-claude-archive.sql` into
`docker-entrypoint-initdb.d/` of your Postgres container **before the first
run** of the volume, or — if the database already exists — run manually:

```bash
PGHOST=127.0.0.1 PGPORT=5432 PGDATABASE=claude_archive \
PGUSER=your_user PGPASSWORD=your_password \
  ./weles/scripts/setup-db.sh
```

### 2. Add the marketplace and install the plugin

From Claude Code (CLI):

```
/plugin marketplace add <path-or-url-to-this-repo>
/plugin install weles@weles
```

Examples of source for `marketplace add`:
- locally cloned repo: `/plugin marketplace add ~/repos/weles`
- GitHub: `/plugin marketplace add your-user/weles`

### 3. Configure database credentials

After installing the plugin, run:

```
/plugin configure weles
```

Claude Code will ask for host, port, database name, and user (stored in
`settings.json`), and will store the password securely in the **system
keychain** (`sensitive: true`). This is the only required configuration
step.

The file backup lands by default in `${CLAUDE_PLUGIN_DATA}` (i.e.
`~/.claude/plugins/data/weles/`) — this directory survives plugin
updates and reinstalls.

#### Alternative: environment variables (standalone / CI)

If you use the hook without the plugin, the script looks for configuration
in this order:

1. `CLAUDE_PLUGIN_OPTION_PG_*` — set automatically by the plugin
2. `PGHOST` / `PGPORT` / `PGDATABASE` / `PGUSER` / `PGPASSWORD` — classic environment variables
3. `~/.env` — fallback (any file with KEY=VALUE pairs)

### 4. Verify

```
/hooks
```

should show the `Stop` and `SessionEnd` hooks registered from the `weles`
plugin. After one conversation turn, check:

```bash
ls ~/.claude/plugins/data/weles/
psql -h 127.0.0.1 -p 5432 -U $PGUSER -d claude_archive -c \
  "SELECT session_id, left(user_message,40), left(assistant_message,40) FROM claude_archive.conversation_turn ORDER BY id DESC LIMIT 5;"
```

## Updating the plugin

```
/plugin marketplace update
/plugin update weles
```

## Install without the plugin (standalone, quick test)

If you don't want to package this as a plugin yet, you can just wire the
hooks directly in `~/.claude/settings.json`, copying
`weles/scripts/claude-archive-hook.sh` to `~/.claude/hooks/` and pointing to
it in the `hooks` section. The plugin is just a more convenient, versioned
form of distributing the same mechanism.

## Distributing further (e.g. to a team)

1. Push this repo to your company's GitHub/GitLab.
2. Others add it via `/plugin marketplace add org/weles`.
3. Each person sets up their own `~/.env` with their database credentials
   (or a shared one, if the archive should be centralized — in that case
   it's worth adding a `user_name` column and populating it from
   `$USER`/`whoami` to distinguish authors).

---

Polish version: [README.pl.md](README.pl.md)
