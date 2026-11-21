#!/usr/bin/env bash
#
# End-to-end smoke test for the running URL shortener.
#
# It builds the app, creates a throwaway Postgres database, starts the real server on a spare
# port, drives it with curl (create, redirect, lookup, delete, caching, hit counting, concurrency,
# restart, graceful shutdown, code-space exhaustion, BASE_URL) and prints PASS/FAIL per check.
# Your development database is never touched; the throwaway one is dropped on exit.
#
# Usage:   scripts/smoke-test.sh
# Options: PORT=18080   port for the test server (default 18080)
#          KEEP_DB=1    keep the throwaway database for inspection (its name is printed)
#
# Needs: swift, curl, psql, createdb, dropdb, and a local Postgres that accepts your OS user.

set -u

PORT="${PORT:-18080}"
DB="urlshortener_smoke_$$"
BASE="localhost:${PORT}"
JSON='Content-Type: application/json'
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
LOG="$TMP/server.log"
SERVER_PID=""
PASS=0
FAIL=0

# ───────────────────────── output helpers ─────────────────────────

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()      { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()     { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m  %s\n        %s\n' "$1" "$2"; }

expect_eq() {      # description expected actual
    if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1" "expected: [$2]   actual: [$3]"; fi
}
expect_ne() {      # description unexpected actual
    if [[ "$3" != "$2" ]]; then ok "$1"; else bad "$1" "did not expect: [$2]"; fi
}
expect_match() {   # description regex actual
    if [[ "$3" =~ $2 ]]; then ok "$1"; else bad "$1" "expected to match /$2/   actual: [$3]"; fi
}

# ───────────────────────── infrastructure ─────────────────────────

cleanup() {
    stop_server
    if [[ "${KEEP_DB:-0}" == "1" ]]; then
        echo "Kept database: $DB   (drop it with: dropdb $DB)"
    else
        dropdb --if-exists "$DB" >/dev/null 2>&1
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT
trap 'echo; echo "Interrupted."; exit 130' INT TERM

die() { echo "ERROR: $1" >&2; exit 2; }

dbq() { psql -d "$DB" -Atc "$1" 2>&1; }

start_server() {   # [VAR=value ...] extra environment for this run
    stop_server
    : > "$LOG"
    env DATABASE_URL="postgres://$(whoami)@localhost:5432/$DB" PORT="$PORT" \
        HIT_FLUSH_INTERVAL_SECONDS="${FLUSH_INTERVAL:-300}" NEGATIVE_CACHE_TTL_SECONDS=3 \
        "$@" "$BIN" serve >> "$LOG" 2>&1 &
    SERVER_PID=$!
    local i
    for i in $(seq 1 100); do
        if curl -s -o /dev/null "$BASE/health"; then return 0; fi
        kill -0 "$SERVER_PID" 2>/dev/null || break
        sleep 0.2
    done
    echo "Server failed to start. Log:"; cat "$LOG"; exit 2
}

stop_server() {    # graceful: SIGINT, like Ctrl-C, so the hit counter flushes on shutdown
    [[ -n "$SERVER_PID" ]] || return 0
    kill -INT "$SERVER_PID" 2>/dev/null
    local i
    for i in $(seq 1 100); do
        kill -0 "$SERVER_PID" 2>/dev/null || break
        sleep 0.1
    done
    kill -KILL "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
    SERVER_PID=""
}

# ───────────────────────── HTTP helpers ─────────────────────────

STATUS=""; BODY=""

shorten() {        # url  → sets STATUS and BODY
    local out
    out=$(curl -s -w '\n%{http_code}' -X POST "$BASE/api/shorten" -H "$JSON" -d "{\"url\":\"$1\"}")
    STATUS="${out##*$'\n'}"
    BODY="${out%$'\n'*}"
}
code_of()     { sed -n 's/.*"shortCode":"\([^"]*\)".*/\1/p' <<<"$BODY"; }
short_url_of(){ sed -n 's/.*"shortURL":"\([^"]*\)".*/\1/p' <<<"$BODY" | tr -d '\\'; }
status_of()   { curl -s -o /dev/null -w '%{http_code}' -X "${2:-GET}" "$BASE/$1"; }
headers_of()  { curl -s -D - -o /dev/null -X "${2:-GET}" "$BASE/$1" | tr -d '\r'; }
api_hits()    { curl -s "$BASE/api/url/$1" | sed -n 's/.*"hitCount":\([0-9]*\).*/\1/p'; }
db_hits()     { dbq "select \"hitCount\" from url_records where \"shortCode\"='$1'"; }
header_value(){ grep -i "^$2:" <<<"$1" | head -1 | cut -d: -f2- | sed 's/^ *//'; }

wait_until() {     # description expected timeout_seconds command...
    local desc="$1" expected="$2" timeout="$3"; shift 3
    local deadline=$((SECONDS + timeout)) actual=""
    while (( SECONDS < deadline )); do
        actual="$("$@")"
        [[ "$actual" == "$expected" ]] && { ok "$desc"; return; }
        sleep 0.25
    done
    actual="$("$@")"
    expect_eq "$desc" "$expected" "$actual"
}

# ───────────────────────── prerequisites ─────────────────────────

for tool in swift curl psql createdb dropdb xargs; do
    command -v "$tool" >/dev/null || die "'$tool' is required but was not found"
done
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    die "port $PORT is already in use; run with PORT=<free port> $0"
fi

section "Setup"
cd "$ROOT" || die "cannot cd to $ROOT"
echo "  building..."
swift build >"$TMP/build.log" 2>&1 || { cat "$TMP/build.log"; die "swift build failed"; }
BIN="$(swift build --show-bin-path)/URLShortener"
[[ -x "$BIN" ]] || die "binary not found at $BIN"
createdb "$DB" || die "could not create database $DB"
echo "  database: $DB   port: $PORT"

# ═════════════════════ Phase A: functional checks (hit flush timer effectively off) ═════════════════════

FLUSH_INTERVAL=300 start_server

section "Health"
expect_eq "GET /health returns 200" "200" "$(status_of health)"
expect_eq "GET /health body is ok" "ok" "$(curl -s "$BASE/health")"

section "Create"
shorten "https://example.com"
EXAMPLE_CODE="$(code_of)"
expect_eq "create returns 200" "200" "$STATUS"
expect_eq "first code is 0000000 (counter starts at 0, 7 chars zero-padded)" "0000000" "$EXAMPLE_CODE"
expect_match "response has a shortURL on this port" "^http://localhost:${PORT}/0000000$" "$(short_url_of)"
for variant in "https://EXAMPLE.com/" "https://example.com:443/#frag" "  https://example.com  "; do
    shorten "$variant"
    expect_eq "same URL as [$variant] returns the same code" "$EXAMPLE_CODE" "$(code_of)"
done
shorten "https://apple.com/a?x=1"
APPLE_CODE="$(code_of)"
expect_eq "a different URL gets the next code" "0000001" "$APPLE_CODE"

section "Rejected input"
LONG_URL="https://x.com/$(printf 'a%.0s' {1..2100})"
for bad_url in "ftp://x.com" "not a url" "https://user:pw@x.com" "" "$LONG_URL"; do
    shorten "$bad_url"
    expect_eq "400 for [${bad_url:0:40}]" "400" "$STATUS"
done
expect_match "missing url field is a 4xx" "^4" "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/shorten" -H "$JSON" -d '{}')"

section "Redirect"
HDR="$(headers_of "$EXAMPLE_CODE")"
expect_match "redirect is a 307" "^HTTP/[0-9.]+ 307" "$(head -1 <<<"$HDR")"
expect_eq "Location is the normalized URL" "https://example.com/" "$(header_value "$HDR" location)"
expect_eq "redirect is Cache-Control: no-store" "no-store" "$(header_value "$HDR" cache-control)"
expect_eq "following the redirect lands on the target" "https://example.com/" \
    "$(curl -s -o /dev/null -L --max-redirs 0 -w '%{redirect_url}' "$BASE/$EXAMPLE_CODE")"
HDR="$(headers_of 0009999)"
expect_match "unknown code is a 404" "^HTTP/[0-9.]+ 404" "$(head -1 <<<"$HDR")"
expect_eq "404 is also no-store" "no-store" "$(header_value "$HDR" cache-control)"
expect_eq "malformed code is a 404" "404" "$(status_of abc)"

section "Metadata lookup"
INFO="$(curl -s -D "$TMP/lookup.h" "$BASE/api/url/$EXAMPLE_CODE")"
expect_match "lookup returns the long URL" '"longURL":"https:\\/\\/example.com\\/"' "$INFO"
expect_match "lookup returns the short code" "\"shortCode\":\"$EXAMPLE_CODE\"" "$INFO"
expect_match "lookup is no-store" "no-store" "$(tr -d '\r' < "$TMP/lookup.h" | grep -i '^cache-control')"
expect_eq "lookup of an unknown code is a 404" "404" "$(status_of api/url/0009999)"

section "Hit counting (batched, kept in memory until flushed)"
shorten "https://hits.test/"
HITS_CODE="$(code_of)"
for _ in $(seq 1 20); do curl -s -o /dev/null "$BASE/$HITS_CODE"; done
expect_eq "database is not written by redirects yet" "0" "$(db_hits "$HITS_CODE")"
expect_eq "API already reports the exact count (stored + unflushed)" "20" "$(api_hits "$HITS_CODE")"
status_of 0009999 >/dev/null
expect_eq "redirects for unknown codes are not counted anywhere" "0" "$(dbq "select count(*) from url_records where \"shortCode\"='0009999'")"

section "Delete"
shorten "https://delete.test/"
DEL_CODE="$(code_of)"
expect_eq "link redirects before delete (and is now cached)" "307" "$(status_of "$DEL_CODE")"
expect_eq "DELETE returns 204" "204" "$(status_of "api/url/$DEL_CODE" DELETE)"
expect_eq "redirect is 404 immediately (cache invalidated)" "404" "$(status_of "$DEL_CODE")"
expect_eq "lookup is 404" "404" "$(status_of "api/url/$DEL_CODE")"
expect_eq "second DELETE is 404" "404" "$(status_of "api/url/$DEL_CODE" DELETE)"
shorten "https://delete.test/"
expect_ne "re-creating a deleted URL issues a new code" "$DEL_CODE" "$(code_of)"

section "Cache behaviour"
expect_eq "unknown code is 404" "404" "$(status_of 0008888)"
dbq "insert into url_records (\"shortCode\",\"urlHash\",\"longURL\") values ('0008888', decode(repeat('ab',32),'hex'), 'https://late.test/')" >/dev/null
expect_eq "row added behind the app's back is still 404 (negative cache)" "404" "$(status_of 0008888)"
sleep 4   # NEGATIVE_CACHE_TTL_SECONDS=3 for this run
expect_eq "…and found once the negative entry has expired" "307" "$(status_of 0008888)"
expect_eq "cached link redirects before its row is removed" "307" "$(status_of "$EXAMPLE_CODE")"
dbq "delete from url_records where \"shortCode\"='$EXAMPLE_CODE'" >/dev/null
expect_eq "[by design] still redirects from cache after an out-of-band delete" "307" "$(status_of "$EXAMPLE_CODE")"

section "Concurrency"
seq 1 300 | xargs -P 50 -I{} curl -s -w '\n%{http_code}\n' -X POST "$BASE/api/shorten" -H "$JSON" \
    -d '{"url":"https://load.test/{}"}' > "$TMP/distinct.txt"
expect_eq "300 parallel creates of distinct URLs all succeed" "300" "$(grep -c '^200$' "$TMP/distinct.txt")"
expect_eq "…with 300 distinct codes" "300" "$(grep -o '"shortCode":"[^"]*"' "$TMP/distinct.txt" | sort -u | wc -l | tr -d ' ')"
seq 1 100 | xargs -P 50 -I{} curl -s -X POST "$BASE/api/shorten" -H "$JSON" -d '{"url":"https://same.test/"}' > "$TMP/same.txt"
expect_eq "100 parallel creates of one URL return a single code" "1" "$(grep -o '"shortCode":"[^"]*"' "$TMP/same.txt" | sort -u | wc -l | tr -d ' ')"
expect_eq "…and store a single row" "1" "$(dbq "select count(*) from url_records where \"longURL\"='https://same.test/'")"
OUT="$(seq 1 1000 | xargs -P 100 -I{} curl -s -o /dev/null -w '%{http_code}\n' "$BASE/$HITS_CODE" | sort | uniq -c | sed 's/^ *//')"
expect_eq "1,000 parallel redirects all return 307" "1000 307" "$OUT"
expect_eq "…and are counted exactly (20 + 1000)" "1020" "$(api_hits "$HITS_CODE")"
for _ in $(seq 1 7); do curl -s -o /dev/null "$BASE/$HITS_CODE"; done
expect_eq "7 more hits before shutdown" "1027" "$(api_hits "$HITS_CODE")"

section "Graceful shutdown flushes pending hits"
expect_eq "database still holds nothing for them" "0" "$(db_hits "$HITS_CODE")"
stop_server
expect_eq "after SIGINT the database holds all 1,027 hits" "1027" "$(db_hits "$HITS_CODE")"

# ═════════════════════ Phase B: restart, persistence, flush timer ═════════════════════

FLUSH_INTERVAL=2 start_server

section "Restart and persistence"
expect_eq "existing link still redirects after a restart" "307" "$(status_of "$HITS_CODE")"
expect_eq "its hit count survived the restart (+1 for the redirect above, still unflushed)" "1028" "$(api_hits "$HITS_CODE")"
RESERVED="$(dbq "select value from counters where name='short_code'")"
expect_eq "counter value is a whole reserved block (multiple of 1000)" "0" "$(( RESERVED % 1000 ))"
shorten "https://after-restart.test/"
AFTER_CODE="$(code_of)"
expect_eq "creating after a restart works" "200" "$STATUS"
expect_ne "…and issues a code that was never used before" "$HITS_CODE" "$AFTER_CODE"
expect_eq "idempotency survives a restart" "$APPLE_CODE" "$( shorten 'https://apple.com/a?x=1'; code_of )"

section "Hit counts flush on the timer"
BEFORE="$(db_hits "$HITS_CODE")"
for _ in $(seq 1 5); do curl -s -o /dev/null "$BASE/$HITS_CODE"; done
wait_until "database catches up within the flush interval" "$((BEFORE + 1 + 5))" 12 db_hits "$HITS_CODE"

# ═════════════════════ Phase C: code-space exhaustion and BASE_URL ═════════════════════

section "Code space exhausted"
stop_server
dbq "update counters set value = 3521614606208 where name='short_code'" >/dev/null   # 62^7
FLUSH_INTERVAL=300 start_server BASE_URL=https://sho.rt/
shorten "https://brand-new.test/"
expect_eq "creating a new link returns 503" "503" "$STATUS"
shorten "https://apple.com/a?x=1"
expect_eq "an existing URL is still returned (no counter needed)" "200" "$STATUS"
expect_eq "…with its original code" "$APPLE_CODE" "$(code_of)"
expect_eq "existing links still redirect" "307" "$(status_of "$APPLE_CODE")"

section "BASE_URL"
stop_server
dbq "update counters set value = 900000 where name='short_code'" >/dev/null
FLUSH_INTERVAL=300 start_server BASE_URL=https://sho.rt/
shorten "https://base-url.test/"
expect_eq "create works again after the counter was reset" "200" "$STATUS"
expect_match "shortURL uses BASE_URL (trailing slash trimmed)" "^https://sho\.rt/[0-9A-Za-z]{7}$" "$(short_url_of)"

# ───────────────────────── summary ─────────────────────────

if grep -qiE "fatal|crash" "$LOG"; then
    bad "server log contains no fatal errors" "$(grep -iE 'fatal|crash' "$LOG" | head -3)"
fi

printf '\n\033[1mResult: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
