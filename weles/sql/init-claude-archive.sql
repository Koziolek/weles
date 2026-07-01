-- =============================================================================
-- init-claude-archive.sql
--
-- Schemat bazy danych do archiwizacji historii konwersacji Claude Code.
-- Plik przeznaczony do zamontowania w /docker-entrypoint-initdb.d/ kontenera
-- postgres:latest (uruchamia się automatycznie tylko przy PIERWSZEJ inicjalizacji
-- wolumenu danych - jeśli baza już istnieje, uruchom ten plik ręcznie przez psql).
--
-- Zakłada, że POSTGRES_DB z docker-compose już istnieje (tworzy go obraz
-- postgres przy starcie), więc tutaj tylko dodajemy schemat/tabele/indeksy.
-- =============================================================================

-- Osobny schemat, żeby nie zaśmiecać "public", jeśli baza jest współdzielona
-- z innymi projektami.
CREATE SCHEMA IF NOT EXISTS claude_archive;

SET search_path TO claude_archive, public;

-- -----------------------------------------------------------------------------
-- Tabela główna: jedna para (pytanie użytkownika / odpowiedź asystenta) na wiersz.
-- Hook Stop zapisuje tutaj po każdej zakończonej turze.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS claude_archive.conversation_turn (
    id              BIGSERIAL PRIMARY KEY,
    session_id      TEXT NOT NULL,
    project_dir     TEXT NOT NULL,             -- cwd sesji (do filtrowania per-projekt)
    turn_uuid       TEXT,                       -- uuid rekordu assistant z transkryptu, jeśli dostępny
    user_message    TEXT,
    assistant_message TEXT,
    occurred_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    archived_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    source          TEXT NOT NULL DEFAULT 'hook',  -- 'hook' | 'sync' (wstawione przez job synchronizujący z backupu)
    raw_meta        JSONB,                      -- dowolne dodatkowe metadane (np. nazwa hooka, wersja CLI)

    -- ochrona przed zdublowaniem tego samego wpisu (np. gdy hook Stop i job
    -- synchronizujący backup oba spróbują zapisać tę samą turę)
    CONSTRAINT uq_conversation_turn UNIQUE (session_id, turn_uuid)
);

CREATE INDEX IF NOT EXISTS idx_conversation_turn_session
    ON claude_archive.conversation_turn (session_id);

CREATE INDEX IF NOT EXISTS idx_conversation_turn_occurred_at
    ON claude_archive.conversation_turn (occurred_at);

CREATE INDEX IF NOT EXISTS idx_conversation_turn_project
    ON claude_archive.conversation_turn (project_dir);

-- Pełnotekstowe wyszukiwanie po treści (PL konfiguracja, jeśli dostępna w obrazie;
-- w razie braku słownika polskiego można zmienić na 'simple').
CREATE INDEX IF NOT EXISTS idx_conversation_turn_fts
    ON claude_archive.conversation_turn
    USING GIN (to_tsvector('simple', coalesce(user_message, '') || ' ' || coalesce(assistant_message, '')));

-- -----------------------------------------------------------------------------
-- Tabela sesji: metadane na poziomie całej sesji, aktualizowane przez SessionEnd.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS claude_archive.session (
    session_id      TEXT PRIMARY KEY,
    project_dir     TEXT NOT NULL,
    started_at      TIMESTAMPTZ,
    ended_at        TIMESTAMPTZ,
    end_reason      TEXT,                       -- clear | logout | prompt_input_exit | other
    turn_count      INTEGER NOT NULL DEFAULT 0,
    raw_meta        JSONB
);

CREATE INDEX IF NOT EXISTS idx_session_project
    ON claude_archive.session (project_dir);

-- -----------------------------------------------------------------------------
-- Tabela logów błędów archiwizacji - przydatna do diagnozowania, kiedy zapis
-- do bazy się nie powiódł i trzeba było polegać na backupie plikowym.
-- (Insert tu ma sens tylko jeśli baza akurat działa; przy realnej awarii bazy
-- błędy i tak lądują w pliku $ARCHIVE_DIR/db-errors.log, patrz hook).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS claude_archive.archive_error_log (
    id              BIGSERIAL PRIMARY KEY,
    occurred_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    session_id      TEXT,
    error_message   TEXT
);

-- -----------------------------------------------------------------------------
-- Uprawnienia: jeśli POSTGRES_USER z compose ma być jedynym właścicielem,
-- poniższe GRANT-y są no-op (już jest ownerem przez CREATE). Zostawione
-- na wypadek, gdyby do bazy podłączał się osobny, mniej uprzywilejowany user.
-- -----------------------------------------------------------------------------
GRANT USAGE ON SCHEMA claude_archive TO PUBLIC;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA claude_archive TO PUBLIC;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA claude_archive TO PUBLIC;
