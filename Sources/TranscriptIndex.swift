import Foundation
import SQLite3

/// A shared SQLite copy of every transcript, living next to the recordings it
/// indexes (`<save folder>/transcripts.sqlite`). The per-recording
/// `transcript.json` stays the transcript of record; this is a derived index
/// that other tools - the planned MCP adapter - can search without walking
/// directories.
///
/// Rebuildable by design: every write is an upsert keyed by the recording's
/// directory *name* (not its path, so moving the save folder keeps the keys
/// valid), and `backfill` re-derives anything missing or stale from the
/// sidecars. WAL mode lets a reader and the app work concurrently.
///
/// Schema (`PRAGMA user_version = 1`):
/// - `transcripts`: one row per recording - title, app, times, language,
///   provider/model, the `TranscriptionConfig` it was run with, and the
///   speaker-name map.
/// - `segments`: one row per segment. `speaker` is Soniox's id; `-1` is the
///   local microphone ("Я"), names for the rest are in `transcripts.speakers_json`.
/// - `segments_fts`: FTS5 index over `segments.text`, kept in step by triggers.
nonisolated enum TranscriptIndex {
  static let fileName = "transcripts.sqlite"

  static func databaseURL(in saveDirectory: URL) -> URL {
    saveDirectory.appendingPathComponent(fileName)
  }

  private static let schema = """
    CREATE TABLE IF NOT EXISTS transcripts(
      recording TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      app_name TEXT,
      recorded_at REAL,
      transcribed_at REAL NOT NULL,
      language TEXT,
      provider TEXT,
      model TEXT,
      config_json TEXT,
      speakers_json TEXT,
      source_mtime REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS segments(
      id INTEGER PRIMARY KEY,
      recording TEXT NOT NULL REFERENCES transcripts(recording) ON DELETE CASCADE,
      idx INTEGER NOT NULL,
      speaker INTEGER NOT NULL,
      start REAL NOT NULL,
      end REAL,
      text TEXT NOT NULL,
      UNIQUE(recording, idx)
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS segments_fts USING fts5(
      text, content='segments', content_rowid='id',
      tokenize='unicode61 remove_diacritics 2'
    );
    CREATE TRIGGER IF NOT EXISTS segments_ai AFTER INSERT ON segments BEGIN
      INSERT INTO segments_fts(rowid, text) VALUES (new.id, new.text);
    END;
    CREATE TRIGGER IF NOT EXISTS segments_ad AFTER DELETE ON segments BEGIN
      INSERT INTO segments_fts(segments_fts, rowid, text) VALUES('delete', old.id, old.text);
    END;
    """

  // MARK: - Public API

  /// Replaces the recording's row and segments. Failures are logged, never
  /// thrown: the index must not fail a transcription that has already been
  /// paid for and saved.
  @concurrent
  static func upsert(
    recordingDirectory: URL, document: TranscriptDocument, config: TranscriptionConfig?
  ) async {
    perform(
      "index \(recordingDirectory.lastPathComponent)",
      in: recordingDirectory.deletingLastPathComponent()
    ) { db in
      try write(
        db, recordingDirectory: recordingDirectory, document: document, config: config,
        sourceMTime: Date().timeIntervalSince1970)
    }
  }

  /// Drops a recording that was deleted in the app, so an agent searching the
  /// index never surfaces text the user has removed.
  @concurrent
  static func remove(recordingDirectory: URL) async {
    perform(
      "unindex \(recordingDirectory.lastPathComponent)",
      in: recordingDirectory.deletingLastPathComponent()
    ) { db in
      try exec(
        db, "DELETE FROM transcripts WHERE recording = ?", [recordingDirectory.lastPathComponent])
    }
  }

  /// Re-reads title and speaker names after the user edits them.
  @concurrent
  static func refreshMetadata(recordingDirectory: URL) async {
    perform(
      "refresh \(recordingDirectory.lastPathComponent)",
      in: recordingDirectory.deletingLastPathComponent()
    ) { db in
      let metadata = RecordingMetadata.load(in: recordingDirectory)
      try exec(
        db, "UPDATE transcripts SET title = ?, app_name = ?, speakers_json = ? WHERE recording = ?",
        [
          metadata?.title ?? recordingDirectory.lastPathComponent, metadata?.appName,
          speakersJSON(metadata), recordingDirectory.lastPathComponent,
        ])
    }
  }

  /// Indexes every `transcript.json` the database does not have yet, or has an
  /// older copy of, and forgets rows whose recording is gone. Safe to run on
  /// every launch: a recording already indexed costs one dictionary lookup.
  @concurrent
  static func backfill(in saveDirectory: URL) async {
    let directories = RecordingStore.directories(in: saveDirectory)
    let sidecars: [(url: URL, mtime: Double)] = directories.compactMap { url in
      let sidecar = TranscriptDocument.sidecarURL(for: url)
      guard
        let date = try? sidecar.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate
      else { return nil }
      return (url, date.timeIntervalSince1970)
    }
    // Opening creates the file, and a fresh install has nothing to index.
    guard
      !sidecars.isEmpty
        || FileManager.default.fileExists(atPath: databaseURL(in: saveDirectory).path)
    else { return }
    perform("backfill", in: saveDirectory) { db in
      var known: [String: Double] = [:]
      try query(db, "SELECT recording, source_mtime FROM transcripts", []) { stmt in
        known[text(stmt, 0)] = sqlite3_column_double(stmt, 1)
      }
      var present = Set<String>()
      for (url, mtime) in sidecars {
        let name = url.lastPathComponent
        present.insert(name)
        // Stale only when the sidecar is *newer* than what was indexed: a
        // re-transcribe rewrites it, and the live path indexes at write time.
        if let indexed = known[name], indexed >= mtime { continue }
        guard let document = TranscriptDocument.load(for: url) else { continue }
        try write(db, recordingDirectory: url, document: document, config: nil, sourceMTime: mtime)
      }
      // An unreadable folder lists as empty; pruning on that would wipe the
      // index, so rows are only dropped when the listing found something.
      for name in known.keys where !directories.isEmpty && !present.contains(name) {
        try exec(db, "DELETE FROM transcripts WHERE recording = ?", [name])
      }
    }
  }

  // MARK: - Writing

  private static func write(
    _ db: OpaquePointer, recordingDirectory: URL, document: TranscriptDocument,
    config: TranscriptionConfig?, sourceMTime: Double
  ) throws {
    let name = recordingDirectory.lastPathComponent
    let metadata = RecordingMetadata.load(in: recordingDirectory)
    let configJSON = config.flatMap { try? JSONEncoder().encode($0) }
      .flatMap { String(data: $0, encoding: .utf8) }
    try exec(db, "BEGIN IMMEDIATE", [])
    do {
      // Delete-then-insert rather than REPLACE: the cascade and the FTS delete
      // trigger only fire on a real DELETE, and a stale tail of segments from a
      // longer previous transcript must not survive a re-transcribe.
      try exec(db, "DELETE FROM transcripts WHERE recording = ?", [name])
      try exec(
        db,
        """
        INSERT INTO transcripts(recording, title, app_name, recorded_at, transcribed_at, language,
          provider, model, config_json, speakers_json, source_mtime)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          name, metadata?.title ?? name, metadata?.appName,
          metadata?.createdAt.timeIntervalSince1970, document.createdAt.timeIntervalSince1970,
          document.language, document.provider, document.model, configJSON,
          speakersJSON(metadata), sourceMTime,
        ])
      for (index, segment) in document.segments.enumerated() {
        try exec(
          db,
          "INSERT INTO segments(recording, idx, speaker, start, end, text) VALUES (?, ?, ?, ?, ?, ?)",
          [name, index, segment.speaker, segment.time, segment.endTime, segment.text])
      }
      try exec(db, "COMMIT", [])
    } catch {
      try? exec(db, "ROLLBACK", [])
      throw error
    }
  }

  private static func speakersJSON(_ metadata: RecordingMetadata?) -> String? {
    guard let speakers = metadata?.speakers, !speakers.isEmpty,
      let data = try? JSONEncoder().encode(speakers)
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  // MARK: - SQLite plumbing

  private struct SQLiteError: Error, CustomStringConvertible {
    let description: String
  }

  /// Opens the database in `saveDirectory`, runs `body`, closes it.
  /// A connection per operation: writes are rare (a transcript finishing), and
  /// holding one open would pin the WAL for an external reader.
  private static func perform(
    _ label: String, in saveDirectory: URL, _ body: (OpaquePointer) throws -> Void
  ) {
    let url = databaseURL(in: saveDirectory)
    var db: OpaquePointer?
    guard
      sqlite3_open_v2(
        url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK, let db
    else {
      Log.error(Log.transcription, "index", "\(label): cannot open \(url.path)")
      sqlite3_close(db)
      return
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 5000)
    do {
      try exec(db, "PRAGMA journal_mode = WAL", [])
      try exec(db, "PRAGMA foreign_keys = ON", [])
      var error: UnsafeMutablePointer<CChar>?
      guard sqlite3_exec(db, schema, nil, nil, &error) == SQLITE_OK else {
        let message = error.map { String(cString: $0) } ?? "unknown"
        sqlite3_free(error)
        throw SQLiteError(description: message)
      }
      try exec(db, "PRAGMA user_version = 1", [])
      try body(db)
    } catch {
      Log.error(Log.transcription, "index", "\(label) failed: \(error)")
    }
  }

  private static func prepare(_ db: OpaquePointer, _ sql: String, _ args: [Any?]) throws
    -> OpaquePointer
  {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
      throw SQLiteError(description: String(cString: sqlite3_errmsg(db)))
    }
    // SQLITE_TRANSIENT: the bound Swift strings do not outlive the call.
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (offset, arg) in args.enumerated() {
      let position = Int32(offset + 1)
      switch arg {
      case let value as String: sqlite3_bind_text(stmt, position, value, -1, transient)
      case let value as Int: sqlite3_bind_int64(stmt, position, Int64(value))
      case let value as Double: sqlite3_bind_double(stmt, position, value)
      default: sqlite3_bind_null(stmt, position)
      }
    }
    return stmt
  }

  private static func exec(_ db: OpaquePointer, _ sql: String, _ args: [Any?]) throws {
    let stmt = try prepare(db, sql, args)
    defer { sqlite3_finalize(stmt) }
    let status = sqlite3_step(stmt)
    guard status == SQLITE_DONE || status == SQLITE_ROW else {
      throw SQLiteError(description: String(cString: sqlite3_errmsg(db)))
    }
  }

  private static func query(
    _ db: OpaquePointer, _ sql: String, _ args: [Any?], row: (OpaquePointer) -> Void
  ) throws {
    let stmt = try prepare(db, sql, args)
    defer { sqlite3_finalize(stmt) }
    while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
  }

  private static func text(_ stmt: OpaquePointer, _ column: Int32) -> String {
    sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
  }
}
