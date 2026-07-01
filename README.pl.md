# weles

English version: [README.md](README.md)

Plugin Claude Code archiwizujący historię konwersacji (pytania użytkownika i
odpowiedzi asystenta — bez permission promptów i bez bloków `thinking`) do
PostgreSQL, z lokalnym backupem JSONL na wypadek awarii bazy.

Repo zawiera jeden plugin. `.claude-plugin/marketplace.json` w korzeniu to
tylko wrapper wymagany przez format instalacji Claude Code — sam kod pluginu
leży w podkatalogu `weles/`.

Mechanizm: hooki `Stop` (po każdej turze) i `SessionEnd` (zamknięcie sesji).
Kolejność zapisu: najpierw plik JSONL (zawsze się udaje), potem próba zapisu
do Postgresa (best-effort, błędy lądują w logu, nigdy nie blokują sesji).

## Instalacja jako plugin (zalecane)

### 1. Załóż bazę danych

Zamontuj `weles/sql/init-claude-archive.sql` w
`docker-entrypoint-initdb.d/` swojego kontenera Postgres **przed pierwszym
uruchomieniem** wolumenu, albo — jeśli baza już istnieje — uruchom ręcznie:

```bash
PGHOST=127.0.0.1 PGPORT=5432 PGDATABASE=claude_archive \
PGUSER=twoj_user PGPASSWORD=twoje_haslo \
  ./weles/scripts/setup-db.sh
```

### 2. Dodaj marketplace i zainstaluj plugin

Z poziomu Claude Code (CLI):

```
/plugin marketplace add <ścieżka-lub-url-do-tego-repo>
/plugin install weles@weles
```

Przykłady źródła dla `marketplace add`:
- lokalnie sklonowane repo: `/plugin marketplace add ~/repos/weles`
- GitHub: `/plugin marketplace add twoj-user/weles`

### 3. Skonfiguruj dane dostępowe do bazy

Po instalacji pluginu uruchom:

```
/plugin configure weles
```

Claude Code zapyta o host, port, nazwę bazy i użytkownika (przechowywane
w `settings.json`), a hasło zapisze bezpiecznie w **keychain systemu**
(`sensitive: true`). To jedyny wymagany krok konfiguracyjny.

Backup plikowy domyślnie ląduje w `${CLAUDE_PLUGIN_DATA}` (czyli
`~/.claude/plugins/data/weles/`) — katalog ten przeżywa
aktualizacje i reinstalacje pluginu.

#### Alternatywa: zmienne środowiskowe (standalone / CI)

Jeśli używasz hooka bez pluginu, skrypt szuka konfiguracji w kolejności:

1. `CLAUDE_PLUGIN_OPTION_PG_*` — ustawiane automatycznie przez plugin
2. `PGHOST` / `PGPORT` / `PGDATABASE` / `PGUSER` / `PGPASSWORD` — klasyczne zmienne środowiskowe
3. `~/.env` — fallback (dowolny plik z parami KLUCZ=WARTOŚĆ)

### 4. Zweryfikuj

```
/hooks
```

powinno pokazać zarejestrowane hooki `Stop` i `SessionEnd` z pluginu
`weles`. Po jednej turze rozmowy sprawdź:

```bash
ls ~/.claude/plugins/data/weles/
psql -h 127.0.0.1 -p 5432 -U $PGUSER -d claude_archive -c \
  "SELECT session_id, left(user_message,40), left(assistant_message,40) FROM claude_archive.conversation_turn ORDER BY id DESC LIMIT 5;"
```

## Aktualizacja pluginu

```
/plugin marketplace update
/plugin update weles
```

## Instalacja bez pluginu (standalone, szybki test)

Jeśli nie chcesz na razie pakować tego jako plugin, możesz po prostu podpiąć
hooki bezpośrednio w `~/.claude/settings.json`, kopiując
`weles/scripts/claude-archive-hook.sh` do
`~/.claude/hooks/` i wskazując na niego w sekcji `hooks`. Plugin to po prostu
wygodniejsza, wersjonowana forma dystrybucji tego samego mechanizmu.

## Dystrybucja dalej (np. dla reszty zespołu)

1. Wypchnij to repo na firmowy GitHub/GitLab.
2. Inni dodają je przez `/plugin marketplace add org/weles`.
3. Każdy ustawia własne `~/.env` z danymi do swojej bazy (albo wspólnej,
   jeśli archiwum ma być scentralizowane — wtedy warto dodać kolumnę
   `user_name` i ją wypełniać z `$USER`/`whoami`, żeby rozróżniać autorów).
