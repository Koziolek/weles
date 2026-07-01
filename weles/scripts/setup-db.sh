#!/usr/bin/env bash
#
# setup-db.sh
#
# Pomocniczy skrypt do ręcznego założenia schematu claude_archive w już
# istniejącym kontenerze Postgres (gdy docker-entrypoint-initdb.d nie zadziała,
# bo wolumen bazy był już zainicjalizowany wcześniej).
#
# Użycie:
#   PGHOST=127.0.0.1 PGPORT=5432 PGDATABASE=claude_archive PGUSER=... PGPASSWORD=... ./setup-db.sh
#
# albo wczyta dane z ~/.env, jeśli zmienne nie są ustawione w środowisku.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_FILE="$SCRIPT_DIR/../sql/init-claude-archive.sql"

ENV_FILE="${CLAUDE_ARCHIVE_ENV_FILE:-$HOME/.env}"
if [[ -f "$ENV_FILE" ]]; then
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        if [[ -z "${!key:-}" ]]; then
            export "$key=$value"
        fi
    done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE")
fi

: "${PGHOST:=127.0.0.1}"
: "${PGPORT:=5432}"
: "${PGDATABASE:?Ustaw PGDATABASE (nazwa bazy, np. claude_archive)}"
: "${PGUSER:?Ustaw PGUSER}"
: "${PGPASSWORD:?Ustaw PGPASSWORD}"

if [[ ! -f "$SQL_FILE" ]]; then
    echo "Nie znaleziono pliku SQL: $SQL_FILE" >&2
    exit 1
fi

echo "Łączę z $PGHOST:$PGPORT/$PGDATABASE jako $PGUSER..."

PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
    -v ON_ERROR_STOP=1 -f "$SQL_FILE"

echo "Schemat claude_archive utworzony/zaktualizowany pomyślnie."
