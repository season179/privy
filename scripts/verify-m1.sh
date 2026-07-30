#!/bin/zsh
# Read-only post-run audit for Privy's M1 recording invariants.
set -euo pipefail

export LC_ALL=C
SCRIPT_PATH=${0:A}

usage() {
    cat <<'EOF'
Usage:
  verify-m1.sh --db PATH --audio PATH (--since-hours HOURS | --since UTC [--until UTC])
  verify-m1.sh --self-test

UTC values must be ISO-8601 (for example 2026-07-30T00:00:00Z).
The audit never repairs, renames, or deletes production data.
EOF
}

SELF_TEST=0
DB=""
AUDIO=""
SINCE=""
UNTIL=""
SINCE_HOURS=""
SELF_TEST_ROOT=""

while (( $# > 0 )); do
    case "$1" in
        --self-test) SELF_TEST=1; shift ;;
        --db) DB=${2:?missing value for --db}; shift 2 ;;
        --audio) AUDIO=${2:?missing value for --audio}; shift 2 ;;
        --since-hours) SINCE_HOURS=${2:?missing value for --since-hours}; shift 2 ;;
        --since) SINCE=${2:?missing value for --since}; shift 2 ;;
        --until) UNTIL=${2:?missing value for --until}; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) print -u2 -- "error: unknown argument: $1"; usage >&2; exit 2 ;;
    esac
done

SQLITE=${SQLITE:-$(command -v sqlite3 || true)}
FFPROBE=${FFPROBE:-$(command -v ffprobe || true)}
[[ -n "$SQLITE" ]] || { print -u2 -- "error: sqlite3 is required"; exit 2; }
[[ -n "$FFPROBE" ]] || { print -u2 -- "error: ffprobe is required"; exit 2; }

sql_quote() {
    print -r -- "${1//\'/\'\'}"
}

memory_sql() {
    "$SQLITE" -batch -noheader ':memory:' "$1"
}

readonly_sql() {
    "$SQLITE" -readonly -batch -noheader -separator $'\t' "$DB" "$1"
}

fail_count=0
fail() {
    print -u2 -r -- "FAIL $1"
    (( fail_count += 1 ))
}

run_audit() {
    fail_count=0
    [[ -n "$DB" && -n "$AUDIO" ]] || {
        print -u2 -- "error: --db and --audio are required"
        return 2
    }
    [[ -f "$DB" ]] || { print -u2 -- "error: database not found: $DB"; return 2; }
    [[ -d "$AUDIO" ]] || { print -u2 -- "error: audio directory not found: $AUDIO"; return 2; }

    if [[ -n "$SINCE_HOURS" ]]; then
        [[ -z "$SINCE" && "$SINCE_HOURS" == <->(|.<->) ]] && (( SINCE_HOURS > 0 )) || {
            print -u2 -- "error: --since-hours must be a positive number and cannot accompany --since"
            return 2
        }
    elif [[ -z "$SINCE" ]]; then
        print -u2 -- "error: provide --since-hours or --since"
        return 2
    fi

    [[ -n "$UNTIL" ]] || UNTIL=$(memory_sql "SELECT strftime('%Y-%m-%dT%H:%M:%fZ','now');")
    local until_q=$(sql_quote "$UNTIL")
    [[ $(memory_sql "SELECT julianday('$until_q') IS NOT NULL;") == 1 ]] || {
        print -u2 -- "error: invalid --until time: $UNTIL"
        return 2
    }
    if [[ -n "$SINCE_HOURS" ]]; then
        SINCE=$(memory_sql "SELECT strftime('%Y-%m-%dT%H:%M:%fZ',julianday('$until_q')-($SINCE_HOURS/24.0));")
    fi
    local since_q=$(sql_quote "$SINCE")
    [[ $(memory_sql "SELECT julianday('$since_q') IS NOT NULL AND julianday('$since_q') < julianday('$until_q');") == 1 ]] || {
        print -u2 -- "error: invalid or empty audit window: $SINCE .. $UNTIL"
        return 2
    }

    DB=${DB:A}
    AUDIO=${AUDIO:A}
    print -- "Privy M1 read-only audit"
    print -- "  database: $DB"
    print -- "  audio:    $AUDIO"
    print -- "  window:   $SINCE .. $UNTIL"

    local migration
    if ! migration=$(readonly_sql "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='grdb_migrations';" 2>&1); then
        fail "database-open: $migration"
        return 1
    fi
    if [[ "$migration" != 1 ]] || [[ $(readonly_sql "SELECT COUNT(*) FROM grdb_migrations WHERE identifier='v1_create_schema';") != 1 ]]; then
        fail "migration: grdb_migrations lacks v1_create_schema"
        return 1
    fi
    local required_table
    for required_table in chunks health; do
        if [[ $(readonly_sql "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$required_table';") != 1 ]]; then
            fail "migration: required table '$required_table' is absent"
            return 1
        fi
    done

    local window="julianday(started_at_utc) >= julianday('$since_q') AND julianday(started_at_utc) <= julianday('$until_q')"
    local selected_count=$(readonly_sql "SELECT COUNT(*) FROM chunks WHERE $window;")
    print -- "INFO chunks-in-window: $selected_count"

    local row
    while IFS=$'\t' read -r id audio_path started; do
        [[ -n "$id" ]] || continue
        fail "stuck-recording: chunk_id=$id started_at=$started audio_path=$audio_path"
    done < <(readonly_sql "SELECT id,audio_path,started_at_utc FROM chunks WHERE state='recording' AND $window ORDER BY id;")

    while IFS=$'\t' read -r audio_path ids count; do
        [[ -n "$audio_path" ]] || continue
        fail "duplicate-audio-row: audio_path=$audio_path row_ids=$ids count=$count"
    done < <(readonly_sql "SELECT audio_path,group_concat(id),COUNT(*) FROM chunks WHERE $window GROUP BY audio_path HAVING COUNT(*)<>1;")

    typeset -A ROW_COUNT ROW_ID ROW_STATE ROW_SELECTED
    while IFS=$'\t' read -r id state audio_path selected; do
        [[ -n "$audio_path" ]] || continue
        ROW_COUNT[$audio_path]=$(( ${ROW_COUNT[$audio_path]:-0} + 1 ))
        ROW_ID[$audio_path]=$id
        ROW_STATE[$audio_path]=$state
        [[ "$selected" == 1 ]] && ROW_SELECTED[$audio_path]=1
    done < <(readonly_sql "SELECT id,state,audio_path,CASE WHEN $window THEN 1 ELSE 0 END FROM chunks;")

    while IFS=$'\t' read -r id audio_path state; do
        [[ -n "$id" ]] || continue
        if [[ "$audio_path" == /* || "$audio_path" == ../* || "$audio_path" == *'/../'* ]]; then
            fail "ready-missing-file: chunk_id=$id has unsafe audio_path=$audio_path"
        elif [[ ! -f "$AUDIO/$audio_path" ]]; then
            fail "ready-missing-file: chunk_id=$id audio_path=$audio_path"
        fi
    done < <(readonly_sql "SELECT id,audio_path,state FROM chunks WHERE state='ready' AND $window ORDER BY id;")

    local file rel row_path kind count selected state size probe audio_path
    while IFS= read -r -d $'\0' file; do
        rel=${file#$AUDIO/}
        case "$rel" in
            *.ogg.partial) row_path=${rel%.partial}; kind=partial ;;
            *.ogg) row_path=$rel; kind=final ;;
            *) continue ;;
        esac
        count=${ROW_COUNT[$row_path]:-0}
        selected=${ROW_SELECTED[$row_path]:-0}
        state=${ROW_STATE[$row_path]:-}

        if (( count == 0 )); then
            fail "orphan-$kind: file=$file expected_audio_path=$row_path"
            selected=1
        elif (( count > 1 )); then
            fail "duplicate-audio-row: file=$file audio_path=$row_path row_count=$count"
            selected=1
        fi
        if (( selected == 0 )); then
            continue
        fi

        size=$(stat -f '%z' "$file")
        if (( size == 0 )); then
            fail "zero-byte-file: file=$file"
            continue
        fi

        # Failed rows are intentionally preserved for inspection and may be undecodable.
        # Every other selected audio artifact must expose a positive decoded duration.
        if [[ "$state" != failed ]]; then
            if ! probe=$("$FFPROBE" -v error -show_entries format=duration \
                    -of default=noprint_wrappers=1:nokey=1 "$file" 2>&1); then
                fail "undecodable-file: file=$file ffprobe=${probe//$'\n'/ }"
            elif ! awk -v value="$probe" 'BEGIN { exit !(value + 0 > 0) }'; then
                fail "undecodable-file: file=$file duration=$probe"
            fi
        fi
    done < <(find "$AUDIO" -type f -print0)

    while IFS=$'\t' read -r id started duration; do
        [[ -n "$id" ]] || continue
        fail "chunk-ordering: chunk_id=$id invalid started_at=$started duration_s=$duration"
    done < <(readonly_sql "SELECT id,started_at_utc,duration_s FROM chunks WHERE $window AND (julianday(started_at_utc) IS NULL OR duration_s < 0) ORDER BY id;")

    local ordered_cte="WITH ordered AS (SELECT id,started_at_utc,duration_s,julianday(started_at_utc) AS start_jd,julianday(started_at_utc)+duration_s/86400.0 AS end_jd,LAG(id) OVER (ORDER BY julianday(started_at_utc),id) AS prev_id,LAG(julianday(started_at_utc)) OVER (ORDER BY julianday(started_at_utc),id) AS prev_start_jd,LAG(julianday(started_at_utc)+duration_s/86400.0) OVER (ORDER BY julianday(started_at_utc),id) AS prev_end_jd FROM chunks WHERE $window)"
    while IFS=$'\t' read -r prev_id id overlap; do
        [[ -n "$prev_id" ]] || continue
        fail "chunk-ordering: previous_chunk_id=$prev_id chunk_id=$id overlap_seconds=$overlap"
    done < <(readonly_sql "$ordered_cte SELECT prev_id,id,printf('%.3f',(prev_end_jd-start_jd)*86400.0) FROM ordered WHERE prev_id IS NOT NULL AND (start_jd <= prev_start_jd OR start_jd < prev_end_jd-0.0000005787);")

    local evidence="'sleep','wake','deviceChange','engineRestart','queueOverrun','gap','recovery','error','recordingStopped','clockDiscontinuity','writerError'"
    local gaps_sql="$ordered_cte, gaps AS (SELECT prev_id,id,prev_end_jd,start_jd,(start_jd-prev_end_jd)*86400.0 AS gap_s FROM ordered WHERE prev_id IS NOT NULL AND (start_jd-prev_end_jd)*86400.0 > 5.0) SELECT g.prev_id,g.id,printf('%.3f',g.gap_s),strftime('%Y-%m-%dT%H:%M:%fZ',g.prev_end_jd),strftime('%Y-%m-%dT%H:%M:%fZ',g.start_jd) FROM gaps g WHERE NOT EXISTS (SELECT 1 FROM health h WHERE h.kind IN ($evidence) AND (julianday(h.at_utc) BETWEEN g.prev_end_jd AND g.start_jd OR (json_valid(h.detail) AND julianday(json_extract(h.detail,'$.detail.gapStartedUTC')) <= g.start_jd AND julianday(json_extract(h.detail,'$.detail.gapEndedUTC')) >= g.prev_end_jd)));"
    while IFS=$'\t' read -r prev_id id gap_s gap_start gap_end; do
        [[ -n "$prev_id" ]] || continue
        fail "unexplained-gap: previous_chunk_id=$prev_id chunk_id=$id duration_seconds=$gap_s interval=$gap_start..$gap_end"
    done < <(readonly_sql "$gaps_sql")

    local overrun
    overrun=$(readonly_sql "SELECT COUNT(*),printf('%.6f',COALESCE(SUM(CASE WHEN json_valid(detail) THEN json_extract(detail,'$.detail.durationSeconds') END),0)) FROM health WHERE kind='queueOverrun' AND julianday(at_utc) BETWEEN julianday('$since_q') AND julianday('$until_q');")
    print -- "INFO queue-overrun: count=${overrun%%$'\t'*} duration_seconds=${overrun#*$'\t'}"
    print -- "INFO limitation: this audit checks inter-chunk gaps; persisted queue-overrun telemetry reports drops but cannot prove there are no holes inside Ogg files."

    if (( fail_count > 0 )); then
        print -u2 -- "AUDIT FAILED: $fail_count invariant violation(s); no data was modified."
        return 1
    fi
    print -- "AUDIT PASSED: no checked M1 invariant violations; no data was modified."
}

run_self_test() {
    local ffmpeg=${FFMPEG:-$(command -v ffmpeg || true)}
    [[ -n "$ffmpeg" ]] || { print -u2 -- "error: ffmpeg is required for --self-test"; return 2; }

    local root=$(mktemp -d "${TMPDIR:-/tmp}/privy-m1-self-test.XXXXXX")
    SELF_TEST_ROOT=$root
    trap '[[ -z "$SELF_TEST_ROOT" ]] || rm -rf -- "$SELF_TEST_ROOT"' EXIT INT TERM
    local script_path=$SCRIPT_PATH
    local since='2026-07-29T23:59:00Z'
    local until='2026-07-30T00:11:30Z'
    local case_db case_audio

    make_fixture() {
        local name=$1
        local dir="$root/$name"
        mkdir -p "$dir/Audio"
        case_db="$dir/privy.sqlite"
        case_audio="$dir/Audio"
        "$SQLITE" -batch "$case_db" <<'SQL'
CREATE TABLE grdb_migrations(identifier TEXT PRIMARY KEY NOT NULL);
INSERT INTO grdb_migrations VALUES('v1_create_schema');
CREATE TABLE chunks(
  id INTEGER PRIMARY KEY, kind TEXT NOT NULL, started_at_utc TEXT NOT NULL,
  started_mono REAL NOT NULL, duration_s REAL NOT NULL DEFAULT 0,
  audio_path TEXT NOT NULL, size_bytes INTEGER NOT NULL DEFAULT 0,
  checksum TEXT, state TEXT NOT NULL, session_id INTEGER
);
CREATE TABLE health(id INTEGER PRIMARY KEY, at_utc TEXT NOT NULL, kind TEXT NOT NULL, detail TEXT NOT NULL);
INSERT INTO chunks(id,kind,started_at_utc,started_mono,duration_s,audio_path,size_bytes,state)
VALUES
 (1,'shadow','2026-07-30T00:00:00.000000Z',0,1,'first.ogg',100,'ready'),
 (2,'shadow','2026-07-30T00:00:10.000000Z',10,1,'second.ogg',100,'ready');
INSERT INTO health(at_utc,kind,detail) VALUES
 ('2026-07-30T00:05:00.000000Z','gap','{"severity":"warning","detail":{"message":"fixture gap","gapStartedUTC":"2026-07-30T00:00:01.000000Z","gapEndedUTC":"2026-07-30T00:00:10.000000Z","durationSeconds":9}}'),
 ('2026-07-30T00:00:00.500000Z','queueOverrun','{"severity":"warning","detail":{"message":"fixture overrun","durationSeconds":0.25}}');
SQL
        "$ffmpeg" -nostdin -v error -f lavfi -i 'anullsrc=r=16000:cl=mono' \
            -t 1 -c:a libopus -b:a 24k "$case_audio/first.ogg"
        cp "$case_audio/first.ogg" "$case_audio/second.ogg"
    }

    audit_case() {
        "$script_path" --db "$case_db" --audio "$case_audio" \
            --since "$since" --until "$until"
    }

    local output
    make_fixture passing
    if ! output=$(audit_case 2>&1); then
        print -u2 -- "SELF-TEST FAIL passing fixture was rejected"
        print -u2 -r -- "$output"
        return 1
    fi
    [[ "$output" == *'AUDIT PASSED'* ]] || {
        print -u2 -- "SELF-TEST FAIL passing fixture lacked success marker"
        return 1
    }
    print -- "SELF-TEST PASS passing fixture"

    expect_failure() {
        local label=$1
        local marker=$2
        if output=$(audit_case 2>&1); then
            print -u2 -- "SELF-TEST FAIL $label fixture exited zero"
            return 1
        fi
        if [[ "$output" != *"$marker"* ]]; then
            print -u2 -- "SELF-TEST FAIL $label fixture did not report '$marker'"
            print -u2 -r -- "$output"
            return 1
        fi
        print -- "SELF-TEST PASS $label"
    }

    make_fixture missing-migration
    "$SQLITE" "$case_db" "DELETE FROM grdb_migrations;"
    expect_failure migration 'FAIL migration:'

    make_fixture stuck-recording
    "$SQLITE" "$case_db" "UPDATE chunks SET state='recording' WHERE id=1;"
    expect_failure stuck-recording 'FAIL stuck-recording:'

    make_fixture duplicate-audio-row
    "$SQLITE" "$case_db" "INSERT INTO chunks(id,kind,started_at_utc,started_mono,duration_s,audio_path,size_bytes,state) VALUES(3,'shadow','2026-07-30T00:00:20.000000Z',20,1,'first.ogg',100,'failed');"
    expect_failure duplicate-audio-row 'FAIL duplicate-audio-row:'

    make_fixture orphan-partial
    cp "$case_audio/first.ogg" "$case_audio/orphan.ogg.partial"
    expect_failure orphan-partial 'FAIL orphan-partial:'

    make_fixture orphan-final
    cp "$case_audio/first.ogg" "$case_audio/orphan.ogg"
    expect_failure orphan-final 'FAIL orphan-final:'

    make_fixture ready-missing-file
    rm "$case_audio/second.ogg"
    expect_failure ready-missing-file 'FAIL ready-missing-file:'

    make_fixture zero-byte
    : > "$case_audio/second.ogg"
    expect_failure zero-byte 'FAIL zero-byte-file:'

    make_fixture undecodable
    print -n -- 'not an ogg file' > "$case_audio/second.ogg"
    expect_failure undecodable 'FAIL undecodable-file:'

    make_fixture chunk-ordering
    "$SQLITE" "$case_db" "UPDATE chunks SET started_at_utc='2026-07-30T00:00:00.000000Z' WHERE id=2;"
    expect_failure chunk-ordering 'FAIL chunk-ordering:'

    make_fixture unexplained-gap
    "$SQLITE" "$case_db" "DELETE FROM health WHERE kind='gap';"
    expect_failure unexplained-gap 'FAIL unexplained-gap:'

    print -- "SELF-TEST PASSED: passing case and every required failing invariant were detected."
}

if (( SELF_TEST )); then
    run_self_test
else
    run_audit
fi
