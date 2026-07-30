import GRDB

// Versioned, idempotent schema migration for the Privy SQLite store. The full
// PLAN.md §5 schema is created in migration `v1_create_schema` so later milestones do
// not need a destructive bootstrap migration. M1 only writes to `chunks`, `vad_events`,
// and `health`; `utterances`, `sessions`, `costs`, and the `utterances_fts` external-content
// table are created now so M2+ can populate them without a schema change.
//
// Re-running `migrator.migrate(_:)` is safe: GRDB records applied migrations in
// `grdb_migrations` and skips them, which is what makes `prepareDatabase` idempotent.
//
// Enum columns intentionally have NO CHECK constraint: the frozen `ChunkState`/
// `ChunkKind`/`VADEventKind` values are the exact SQL values, and the plan requires that
// all listed (including future) enum values be accepted without a schema change. State
// transitions are guarded in code (`PrivyStore`) rather than at the column level.
enum PrivyDatabaseMigrations {

    /// Builds the migrator that establishes the M1 schema. Pure: registering a migration
    /// does not touch the database.
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // We intentionally do NOT set `eraseDatabaseOnSchemaChange`: production audio and
        // health history must never be wiped by a migration edit. Tests use fresh temp
        // databases, so they do not rely on erase-on-change either.
        migrator.registerMigration("v1_create_schema") { db in
            try createSchema(in: db)
        }
        return migrator
    }

    // MARK: - Schema

    /// Creates every §5 table, the FTS5 external-content table over
    /// `utterances.transcript`, its sync triggers, and the required indexes. Kept
    /// self-contained so a future migration can reuse the helpers.
    static func createSchema(in db: Database) throws {
        // Foreign-key dependency order: sessions → chunks → vad_events/utterances.
        try db.create(table: "sessions") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("started_at_utc", .text)
            t.column("ended_at_utc", .text)
            t.column("title", .text)
        }

        try db.create(table: "chunks") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("kind", .text).notNull()
            t.column("started_at_utc", .text).notNull()
            t.column("started_mono", .double).notNull()
            t.column("duration_s", .double).notNull().defaults(sql: "0")
            t.column("audio_path", .text).notNull()
            t.column("size_bytes", .integer).notNull().defaults(sql: "0")
            t.column("checksum", .text)
            t.column("state", .text).notNull().defaults(sql: "'recording'")
            t.column("session_id", .integer).references("sessions", onDelete: .setNull)
        }

        try db.create(table: "vad_events") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("chunk_id", .integer).notNull().references("chunks", onDelete: .cascade)
            t.column("t_mono", .double).notNull()
            t.column("kind", .text).notNull()
            t.column("score", .double)
        }

        try db.create(table: "utterances") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("chunk_id", .integer).notNull().references("chunks", onDelete: .cascade)
            t.column("start_s", .double).notNull()
            t.column("end_s", .double).notNull()
            t.column("started_at_utc", .text)
            t.column("transcript", .text)
            t.column("asr_provider", .text)
            // Raw ASR/diarization payloads are JSON stored as TEXT (SQLite has no JSON type);
            // M2+ reads/writes them as opaque JSON strings.
            t.column("asr_raw", .text)
            t.column("speaker", .text)
            t.column("diar_raw", .text)
        }

        try db.create(table: "health") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("at_utc", .text).notNull()
            t.column("kind", .text).notNull()
            // One HealthEnvelope JSON object: {"severity":..., "detail":{...}}.
            t.column("detail", .text).notNull()
        }

        try db.create(table: "costs") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("date", .text).notNull()
            t.column("provider", .text).notNull()
            t.column("minutes", .double).notNull()
            t.column("usd", .double).notNull()
        }

        // FTS5 external-content table over utterances.transcript, kept in sync by
        // triggers. M1 does not insert utterances; the table exists so M2 search needs no
        // schema change. Built with raw SQL so the external-content + content_rowid +
        // trigger trio is explicit and unambiguous.
        try db.execute(sql: """
            CREATE VIRTUAL TABLE utterances_fts USING fts5(
                transcript,
                content='utterances',
                content_rowid='id'
            );
            """)
        try db.execute(sql: """
            CREATE TRIGGER utterances_ai AFTER INSERT ON utterances BEGIN
                INSERT INTO utterances_fts(rowid, transcript)
                VALUES (new.id, new.transcript);
            END;
            CREATE TRIGGER utterances_ad AFTER DELETE ON utterances BEGIN
                INSERT INTO utterances_fts(utterances_fts, rowid, transcript)
                VALUES ('delete', old.id, old.transcript);
            END;
            CREATE TRIGGER utterances_au AFTER UPDATE ON utterances BEGIN
                INSERT INTO utterances_fts(utterances_fts, rowid, transcript)
                VALUES ('delete', old.id, old.transcript);
                INSERT INTO utterances_fts(rowid, transcript)
                VALUES (new.id, new.transcript);
            END;
            """)

        // Required indexes (plan §"Store"): chunk state/start, VAD chunk/time, health time.
        try db.create(index: "chunks_state_started_idx", on: "chunks", columns: ["state", "started_at_utc"])
        try db.create(index: "vad_events_chunk_t_idx", on: "vad_events", columns: ["chunk_id", "t_mono"])
        try db.create(index: "health_at_idx", on: "health", columns: ["at_utc"])
        // A size/started index is cheap and directly serves `bytesRecordedToday` and audits.
        try db.create(index: "chunks_started_utc_idx", on: "chunks", columns: ["started_at_utc"])
    }
}
