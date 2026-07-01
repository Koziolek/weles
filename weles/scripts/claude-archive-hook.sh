#!/usr/bin/env bash
#
# claude-archive-hook.sh
#
# Jednoplikowy hook Claude Code archiwizujący historię konwersacji:
#   - zdarzenie "Stop"       -> archiwizuje ostatnią parę (user, assistant)
#   - zdarzenie "SessionEnd" -> zamyka rekord sesji (czas zakończenia, powód)
#
# Kolejność operacji per-tura (gwarancja "backup zawsze pierwszy"):
#   1) zapis do lokalnego pliku JSONL (źródło prawdy, zawsze się udaje)
#   2) próba zapisu do PostgreSQL (jeśli baza padnie, nic nie tracimy)
#
# Wymagane narzędzia w PATH: bash, jq, psql.
#
# == Konfiguracja ==
#
# Gdy używasz pluginu (zalecane): ustaw parametry przez
#   /plugin configure weles
# Plugin zapyta o host, port, bazę, użytkownika i hasło.
# Wartości trafiają do env jako CLAUDE_PLUGIN_OPTION_PG_*.
# Hasło jest przechowywane w keychain systemu (sensitive: true w userConfig).
#
# Gdy używasz standalone (bez pluginu): ustaw zmienne środowiskowe
# PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD — np. przez sekcję "env"
# w ~/.claude/settings.json albo przez plik ~/.env (fallback).
# Skrypt szuka konfiguracji w kolejności priorytetów:
#   1. CLAUDE_PLUGIN_OPTION_PG_* (plugin userConfig — najwyższy priorytet)
#   2. PGHOST / PGPORT / PGDATABASE / PGUSER / PGPASSWORD (zmienne systemowe)
#   3. Plik ~/.env (opcjonalny fallback — czytany tylko gdy brak obu powyżej)
#
set -uo pipefail
# UWAGA: celowo BEZ "set -e" — hook nigdy nie może przerwać Claude Code
# wyjściem != 0 z powodu np. niedostępnej bazy. Błędy obsługujemy sami.

# -----------------------------------------------------------------------------
# Konfiguracja — wartości domyślne, nadpisywane przez resolve_pg_config()
# -----------------------------------------------------------------------------

ARCHIVE_DIR="${CLAUDE_ARCHIVE_DIR:-${CLAUDE_PLUGIN_DATA:-$HOME/.claude/archive}}"
ERROR_LOG="$ARCHIVE_DIR/db-errors.log"

# Zmienne połączenia — wypełniane przez resolve_pg_config(), nie edytuj tutaj.
_PG_HOST=""
_PG_PORT=""
_PG_DATABASE=""
_PG_USER=""
_PG_PASSWORD=""

# -----------------------------------------------------------------------------
# Funkcje pomocnicze
# -----------------------------------------------------------------------------

log_error() {
    mkdir -p "$ARCHIVE_DIR"
    printf '%s | %s\n' "$(date -Iseconds)" "$1" >> "$ERROR_LOG"
}

require_tools() {
    local missing=()
    for tool in jq psql; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if (( ${#missing[@]} > 0 )); then
        log_error "Brak wymaganych narzędzi: ${missing[*]}. Pomijam archiwizację tej tury."
        return 1
    fi
    return 0
}

# Wczytuje konfigurację połączenia wg priorytetów:
#   1. CLAUDE_PLUGIN_OPTION_PG_* (plugin userConfig)
#   2. Klasyczne PG* (zmienne środowiskowe)
#   3. Plik ~/.env (fallback standalone)
# Zwraca 1 jeśli brak wystarczającej konfiguracji (user lub password puste).
resolve_pg_config() {
    # Priorytet 1: plugin userConfig — eksportowane przez Claude Code jako
    # CLAUDE_PLUGIN_OPTION_<UPPER_KEY>.
    if [[ -n "${CLAUDE_PLUGIN_OPTION_PG_USER:-}" ]]; then
        _PG_HOST="${CLAUDE_PLUGIN_OPTION_PG_HOST:-127.0.0.1}"
        _PG_PORT="${CLAUDE_PLUGIN_OPTION_PG_PORT:-5432}"
        _PG_DATABASE="${CLAUDE_PLUGIN_OPTION_PG_DATABASE:-}"
        _PG_USER="${CLAUDE_PLUGIN_OPTION_PG_USER}"
        _PG_PASSWORD="${CLAUDE_PLUGIN_OPTION_PG_PASSWORD:-}"
        return 0
    fi

    # Priorytet 2: klasyczne zmienne PG* z środowiska.
    if [[ -n "${PGUSER:-}" ]]; then
        _PG_HOST="${PGHOST:-127.0.0.1}"
        _PG_PORT="${PGPORT:-5432}"
        _PG_DATABASE="${PGDATABASE:-}"
        _PG_USER="${PGUSER}"
        _PG_PASSWORD="${PGPASSWORD:-}"
        return 0
    fi

    # Priorytet 3: fallback — plik ~/.env (standalone bez pluginu).
    local env_file="${CLAUDE_ARCHIVE_ENV_FILE:-$HOME/.env}"
    if [[ -f "$env_file" ]]; then
        local key value
        while IFS='=' read -r key value; do
            [[ -z "$key" || "$key" == \#* ]] && continue
            # shellcheck disable=SC2086
            case "$key" in
                PGHOST)     _PG_HOST="$value" ;;
                PGPORT)     _PG_PORT="$value" ;;
                PGDATABASE) _PG_DATABASE="$value" ;;
                PGUSER)     _PG_USER="$value" ;;
                PGPASSWORD) _PG_PASSWORD="$value" ;;
            esac
        done < <(grep -E '^(PGHOST|PGPORT|PGDATABASE|PGUSER|PGPASSWORD)=' "$env_file")

        : "${_PG_HOST:=127.0.0.1}"
        : "${_PG_PORT:=5432}"

        if [[ -n "$_PG_USER" ]]; then
            return 0
        fi
    fi

    log_error "Brak konfiguracji połączenia z bazą. Ustaw parametry przez '/plugin configure weles' lub zmienne środowiskowe PGUSER/PGPASSWORD."
    return 1
}

# Bezpieczne escapowanie wartości tekstowej do literału SQL (podwaja apostrofy).
# Pusta wartość / "null" -> SQL NULL.
sql_literal() {
    local value="$1"
    if [[ -z "$value" || "$value" == "null" ]]; then
        printf 'NULL'
        return
    fi
    printf "'%s'" "${value//\'/\'\'}"
}

run_psql() {
    local sql="$1"
    PGHOST="$_PG_HOST" \
    PGPORT="$_PG_PORT" \
    PGDATABASE="$_PG_DATABASE" \
    PGUSER="$_PG_USER" \
    PGPASSWORD="$_PG_PASSWORD" \
    psql -v ON_ERROR_STOP=1 -X -q -t -c "$sql" 2>&1
}

# Wyciąga z transkryptu JSONL ostatni tekst dla danego typu rekordu ("user"
# albo "assistant"), biorąc pod uwagę tylko bloki content o type=="text"
# (pomija "thinking", "tool_use", "tool_result").
extract_last_text_record() {
    local transcript_path="$1"
    local record_type="$2"

    [[ -f "$transcript_path" ]] || { echo '{}'; return; }

    tac "$transcript_path" 2>/dev/null | jq -c --arg t "$record_type" '
        select(.type == $t) |
        {
            uuid: (.uuid // null),
            text: (
                (.message.content // empty)
                | if type == "array" then
                    [ .[] | select(.type == "text") | .text ] | join("\n")
                  elif type == "string" then
                    .
                  else
                    ""
                  end
            )
        }
    ' 2>/dev/null | head -n 1
}

# -----------------------------------------------------------------------------
# Logika zdarzenia: Stop
# -----------------------------------------------------------------------------

handle_stop() {
    local input="$1"

    local session_id transcript_path cwd
    session_id=$(jq -r '.session_id // empty' <<<"$input")
    transcript_path=$(jq -r '.transcript_path // empty' <<<"$input")
    cwd=$(jq -r '.cwd // empty' <<<"$input")

    if [[ -z "$session_id" || -z "$transcript_path" ]]; then
        log_error "Stop hook: brak session_id lub transcript_path w wejściu."
        return 0
    fi

    local assistant_record user_record
    assistant_record=$(extract_last_text_record "$transcript_path" "assistant")
    user_record=$(extract_last_text_record "$transcript_path" "user")

    local assistant_text user_text turn_uuid
    assistant_text=$(jq -r '.text // ""' <<<"$assistant_record")
    user_text=$(jq -r '.text // ""' <<<"$user_record")
    turn_uuid=$(jq -r '.uuid // empty' <<<"$assistant_record")

    if [[ -z "$assistant_text" && -z "$user_text" ]]; then
        return 0
    fi

    mkdir -p "$ARCHIVE_DIR"
    local backup_file="$ARCHIVE_DIR/${session_id}.jsonl"
    local now
    now=$(date -Iseconds)

    # ---- KROK 1: backup plikowy (zawsze pierwszy, zawsze się wykonuje) --------
    local entry
    entry=$(jq -nc \
        --arg ts "$now" \
        --arg sid "$session_id" \
        --arg proj "$cwd" \
        --arg uuid "$turn_uuid" \
        --arg u "$user_text" \
        --arg a "$assistant_text" \
        '{timestamp: $ts, session_id: $sid, project_dir: $proj, turn_uuid: $uuid, user_message: $u, assistant_message: $a}')

    if ! printf '%s\n' "$entry" >> "$backup_file"; then
        log_error "KRYTYCZNE: nie udało się zapisać backupu plikowego do $backup_file"
    fi

    # ---- KROK 2: zapis do PostgreSQL (best-effort) ----------------------------
    require_tools || return 0
    resolve_pg_config || return 0

    local sql
    sql=$(cat <<SQL
INSERT INTO claude_archive.conversation_turn
    (session_id, project_dir, turn_uuid, user_message, assistant_message, occurred_at, source)
VALUES
    ($(sql_literal "$session_id"),
     $(sql_literal "$cwd"),
     $(sql_literal "$turn_uuid"),
     $(sql_literal "$user_text"),
     $(sql_literal "$assistant_text"),
     $(sql_literal "$now"),
     'hook')
ON CONFLICT (session_id, turn_uuid) DO NOTHING;
SQL
)

    local psql_output
    if ! psql_output=$(run_psql "$sql"); then
        log_error "Zapis do bazy nieudany dla session_id=$session_id: $psql_output"
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Logika zdarzenia: SessionEnd
# -----------------------------------------------------------------------------

handle_session_end() {
    local input="$1"

    local session_id cwd reason
    session_id=$(jq -r '.session_id // empty' <<<"$input")
    cwd=$(jq -r '.cwd // empty' <<<"$input")
    reason=$(jq -r '.reason // "other"' <<<"$input")

    [[ -z "$session_id" ]] && return 0

    require_tools || return 0
    resolve_pg_config || return 0

    local now
    now=$(date -Iseconds)

    local sql
    sql=$(cat <<SQL
INSERT INTO claude_archive.session (session_id, project_dir, ended_at, end_reason, turn_count)
VALUES
    ($(sql_literal "$session_id"),
     $(sql_literal "$cwd"),
     $(sql_literal "$now"),
     $(sql_literal "$reason"),
     (SELECT count(*) FROM claude_archive.conversation_turn WHERE session_id = $(sql_literal "$session_id")))
ON CONFLICT (session_id) DO UPDATE SET
    ended_at = EXCLUDED.ended_at,
    end_reason = EXCLUDED.end_reason,
    turn_count = EXCLUDED.turn_count;
SQL
)

    local psql_output
    if ! psql_output=$(run_psql "$sql"); then
        log_error "SessionEnd: zapis do bazy nieudany dla session_id=$session_id: $psql_output"
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Punkt wejścia
# -----------------------------------------------------------------------------

main() {
    local event="${1:-}"
    local input
    input=$(cat)

    case "$event" in
        stop)
            handle_stop "$input"
            ;;
        session_end)
            handle_session_end "$input"
            ;;
        *)
            local detected
            detected=$(jq -r '.hook_event_name // empty' <<<"$input")
            case "$detected" in
                Stop)       handle_stop "$input" ;;
                SessionEnd) handle_session_end "$input" ;;
                *)          log_error "Nieznane zdarzenie hooka: '$event' / '$detected'" ;;
            esac
            ;;
    esac

    # Hook zawsze kończy się sukcesem — archiwizacja nigdy nie blokuje sesji.
    exit 0
}

main "$@"
