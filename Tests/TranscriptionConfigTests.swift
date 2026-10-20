import Foundation
import SQLite3
import Testing

@testable import Blackbox

@Suite("Transcription config")
struct TranscriptionConfigTests {
  private func body(role: TranscriptionJobRole, _ config: TranscriptionConfig) -> [String: Any] {
    TranscriptionService.transcriptionConfiguration(
      model: "m", fileId: "f", role: role, config: config)
  }

  @Test("context is sent in Soniox's shape, and omitted when empty")
  func contextShape() throws {
    let context = SonioxContext(
      generalLines: "topic: sprint planning\nnot a pair\nteam : Core",
      terms: "Blackbox, Soniox\nDTLN",
      text: "  Weekly sync.  ")
    let sent = body(role: .farEnd, TranscriptionConfig(languageHints: ["ru"], context: context))

    let object = try #require(sent["context"] as? [String: Any])
    let general = try #require(object["general"] as? [[String: String]])
    #expect(
      general == [["key": "topic", "value": "sprint planning"], ["key": "team", "value": "Core"]])
    #expect(object["terms"] as? [String] == ["Blackbox", "Soniox", "DTLN"])
    #expect(object["text"] as? String == "Weekly sync.")

    #expect(body(role: .farEnd, TranscriptionConfig(languageHints: ["ru"]))["context"] == nil)
  }

  @Test("diarization follows the role unless the config overrides it")
  func diarizationOverride() {
    func diarized(_ role: TranscriptionJobRole, _ override: Bool?) -> Bool? {
      body(role: role, TranscriptionConfig(languageHints: ["ru"], diarization: override))[
        "enable_speaker_diarization"] as? Bool
    }
    #expect(diarized(.mic, nil) == false)
    #expect(diarized(.farEnd, nil) == true)
    #expect(diarized(.single, nil) == true)
    #expect(diarized(.mic, true) == true)
    #expect(diarized(.farEnd, false) == false)
  }

  @Test("strict hints and language identification reach the request")
  func languageFlags() {
    let strict = body(
      role: .single,
      TranscriptionConfig(
        languageHints: ["ru", "en"], languageHintsStrict: true, languageIdentification: false))
    #expect(strict["language_hints_strict"] as? Bool == true)
    #expect(strict["enable_language_identification"] as? Bool == false)
    #expect(strict["language_hints"] as? [String] == ["ru", "en"])

    #expect(
      body(role: .single, TranscriptionConfig(languageHints: ["ru"]))["language_hints_strict"]
        == nil)
  }

  @Test("settings become a config, with the documented defaults on a fresh install")
  func fromDefaults() throws {
    let suite = "TranscriptionConfigTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(
      TranscriptionConfig.fromDefaults(defaults)
        == TranscriptionConfig(languageHints: ["ru"], model: TranscriptionService.defaultModel))

    defaults.set("en, de", forKey: SettingsKeys.transcriptionLanguages)
    defaults.set("off", forKey: SettingsKeys.transcriptionDiarization)
    defaults.set("Blackbox", forKey: SettingsKeys.transcriptionContextTerms)
    let config = TranscriptionConfig.fromDefaults(defaults)
    #expect(config.languageHints == ["en", "de"])
    #expect(config.diarization == false)
    #expect(config.context.terms == ["Blackbox"])
  }
}

@Suite("Transcript index")
struct TranscriptIndexTests {
  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("index-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func makeRecording(
    in root: URL, _ name: String, title: String = "Call"
  ) throws -> URL {
    let directory = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try RecordingMetadata(
      title: title, createdAt: Date(timeIntervalSince1970: 1_700_000_000), appName: "Zoom",
      speakers: ["1": "Anna"]
    ).save(in: directory)
    return directory
  }

  private func document(_ texts: [String]) -> TranscriptDocument {
    TranscriptDocument(
      segments: texts.enumerated().map {
        TranscriptSegment(
          speaker: $0.offset == 0 ? -1 : 1, time: Double($0.offset), text: $0.element,
          endTime: Double($0.offset) + 0.5)
      },
      language: "ru", createdAt: Date(timeIntervalSince1970: 1_700_000_100),
      provider: "soniox", model: "stt-async-v4")
  }

  /// Reads straight through the C API, as the MCP adapter will.
  private func rows(_ root: URL, _ sql: String) throws -> [[String]] {
    var db: OpaquePointer?
    #expect(
      sqlite3_open_v2(TranscriptIndex.databaseURL(in: root).path, &db, SQLITE_OPEN_READONLY, nil)
        == SQLITE_OK)
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    #expect(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
    defer { sqlite3_finalize(stmt) }
    var result: [[String]] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      result.append(
        (0..<sqlite3_column_count(stmt)).map {
          sqlite3_column_text(stmt, $0).map { String(cString: $0) } ?? "NULL"
        })
    }
    return result
  }

  @Test("a transcript is searchable by what was said, with its metadata")
  func upsertAndSearch() async throws {
    let root = try makeRoot()
    let directory = try makeRecording(in: root, "2610-20-zoom", title: "Планёрка")
    await TranscriptIndex.upsert(
      recordingDirectory: directory, document: document(["привет всем", "обсудим релиз"]),
      config: TranscriptionConfig(languageHints: ["ru"]))

    let hits = try rows(
      root,
      """
      SELECT t.title, s.speaker, s.text FROM segments_fts f
      JOIN segments s ON s.id = f.rowid JOIN transcripts t ON t.recording = s.recording
      WHERE segments_fts MATCH 'релиз'
      """)
    #expect(hits == [["Планёрка", "1", "обсудим релиз"]])
    #expect(
      try rows(root, "SELECT provider, model, speakers_json FROM transcripts")
        == [["soniox", "stt-async-v4", #"{"1":"Anna"}"#]])
    #expect(try rows(root, "SELECT config_json FROM transcripts")[0][0].contains("\"ru\""))
  }

  @Test("re-transcribing replaces the old segments, including a longer tail")
  func reTranscribeReplaces() async throws {
    let root = try makeRoot()
    let directory = try makeRecording(in: root, "a")
    await TranscriptIndex.upsert(
      recordingDirectory: directory, document: document(["one", "two", "three"]), config: nil)
    await TranscriptIndex.upsert(
      recordingDirectory: directory, document: document(["fresh"]), config: nil)

    #expect(try rows(root, "SELECT text FROM segments") == [["fresh"]])
    // The FTS index must follow: a stale hit would surface deleted text.
    #expect(
      try rows(root, "SELECT count(*) FROM segments_fts WHERE segments_fts MATCH 'three'") == [
        ["0"]
      ])
    #expect(
      try rows(root, "SELECT count(*) FROM segments_fts WHERE segments_fts MATCH 'fresh'") == [
        ["1"]
      ])
  }

  @Test("removing a recording removes its text from search")
  func removeDeletesText() async throws {
    let root = try makeRoot()
    let directory = try makeRecording(in: root, "a")
    await TranscriptIndex.upsert(
      recordingDirectory: directory, document: document(["secret"]), config: nil)
    await TranscriptIndex.remove(recordingDirectory: directory)

    #expect(try rows(root, "SELECT count(*) FROM transcripts") == [["0"]])
    #expect(
      try rows(root, "SELECT count(*) FROM segments_fts WHERE segments_fts MATCH 'secret'") == [
        ["0"]
      ])
  }

  @Test("a renamed recording's title follows")
  func refreshTitle() async throws {
    let root = try makeRoot()
    let directory = try makeRecording(in: root, "a", title: "Old")
    await TranscriptIndex.upsert(
      recordingDirectory: directory, document: document(["x"]), config: nil)
    var metadata = try #require(RecordingMetadata.load(in: directory))
    metadata.title = "New"
    try metadata.save(in: directory)
    await TranscriptIndex.refreshMetadata(recordingDirectory: directory)

    #expect(try rows(root, "SELECT title FROM transcripts") == [["New"]])
  }

  @Test("backfill indexes existing sidecars once and forgets recordings that are gone")
  func backfill() async throws {
    let root = try makeRoot()
    let kept = try makeRecording(in: root, "kept")
    let gone = try makeRecording(in: root, "gone")
    try document(["kept text"]).save(for: kept)
    try document(["gone text"]).save(for: gone)
    await TranscriptIndex.backfill(in: root)
    #expect(
      try rows(root, "SELECT recording FROM transcripts ORDER BY recording") == [
        ["gone"], ["kept"],
      ])

    try FileManager.default.removeItem(at: gone)
    await TranscriptIndex.backfill(in: root)
    #expect(try rows(root, "SELECT recording FROM transcripts") == [["kept"]])
    #expect(try rows(root, "SELECT count(*) FROM segments") == [["1"]])
  }

  @Test("the database file is not mistaken for a recording")
  func databaseIsNotARecording() async throws {
    let root = try makeRoot()
    let directory = try makeRecording(in: root, "a")
    await TranscriptIndex.upsert(
      recordingDirectory: directory, document: document(["x"]), config: nil)

    #expect(RecordingStore.directories(in: root).map(\.lastPathComponent) == ["a"])
  }

  @Test("moving the library rebuilds the index in the new folder and retires the old one")
  func moveMigratesIndex() async throws {
    let old = try makeRoot()
    let new = try makeRoot()
    let directory = try makeRecording(in: old, "a")
    try document(["moved words"]).save(for: directory)
    await TranscriptIndex.backfill(in: old)
    #expect(FileManager.default.fileExists(atPath: TranscriptIndex.databaseURL(in: old).path))

    try FileManager.default.moveItem(at: directory, to: new.appendingPathComponent("a"))
    await TranscriptIndex.backfill(in: new)
    TranscriptIndex.removeDatabase(in: old)

    #expect(try rows(new, "SELECT text FROM segments") == [["moved words"]])
    #expect(!FileManager.default.fileExists(atPath: TranscriptIndex.databaseURL(in: old).path))
  }

  @Test("a partial move prunes the old index down to what stayed behind")
  func partialMovePrunesOldIndex() async throws {
    let old = try makeRoot()
    let new = try makeRoot()
    let stayed = try makeRecording(in: old, "stayed")
    let moved = try makeRecording(in: old, "moved")
    try document(["stay"]).save(for: stayed)
    try document(["go"]).save(for: moved)
    await TranscriptIndex.backfill(in: old)

    try FileManager.default.moveItem(at: moved, to: new.appendingPathComponent("moved"))
    await TranscriptIndex.backfill(in: old)

    #expect(try rows(old, "SELECT recording FROM transcripts") == [["stayed"]])
  }

  // MARK: - Meeting metadata and schema v2

  @Test("the app, the window or tab title and the bundle id are stored separately")
  func meetingMetadataIsStructured() async throws {
    let root = try makeRoot()
    let directory = root.appendingPathComponent("2610-20-meet")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try RecordingMetadata(
      title: "Standup", createdAt: Date(timeIntervalSince1970: 1_792_490_400),
      appName: RecordingNaming.compose(app: "Google Chrome", windowTitle: "Weekly — sync | Meet"),
      speakers: [:], perAppBundleID: "com.google.Chrome"
    ).save(in: directory)
    await TranscriptIndex.upsert(
      recordingDirectory: directory, document: document(["hi"]), config: nil)

    #expect(
      try rows(root, "SELECT app, window_title, bundle_id, recorded_at FROM transcripts")
        == [["Google Chrome", "Weekly — sync | Meet", "com.google.Chrome", "1792490400.0"]])
  }

  @Test("an app name with no window title has none, and the separator splits only once")
  func namingRoundTrip() {
    #expect(RecordingNaming.split("SonoBus").windowTitle == nil)
    #expect(RecordingNaming.split("SonoBus").app == "SonoBus")
    let composed = RecordingNaming.compose(app: "Arc", windowTitle: "A — B")
    let split = RecordingNaming.split(composed)
    #expect(split.app == "Arc" && split.windowTitle == "A — B")
    #expect(RecordingNaming.split("Arc — ").windowTitle == nil)
  }

  /// A database the previous build created (schema v1) must keep working: the new columns
  /// are added, every row is rewritten from its sidecar at the next backfill, and the
  /// config the old row held survives for a transcript that never stored one.
  @Test("a v1 index migrates to v2 and is repopulated from the transcripts")
  func migratesFromV1() async throws {
    let root = try makeRoot()
    let directory = try makeRecording(in: root, "a", title: "Call")
    try document(["old text"]).save(for: directory)

    var db: OpaquePointer?
    #expect(sqlite3_open(TranscriptIndex.databaseURL(in: root).path, &db) == SQLITE_OK)
    let v1 = """
      PRAGMA journal_mode = WAL;
      CREATE TABLE transcripts(recording TEXT PRIMARY KEY, title TEXT NOT NULL, app_name TEXT,
        recorded_at REAL, transcribed_at REAL NOT NULL, language TEXT, provider TEXT, model TEXT,
        config_json TEXT, speakers_json TEXT, source_mtime REAL NOT NULL);
      CREATE TABLE segments(id INTEGER PRIMARY KEY,
        recording TEXT NOT NULL REFERENCES transcripts(recording) ON DELETE CASCADE,
        idx INTEGER NOT NULL, speaker INTEGER NOT NULL, start REAL NOT NULL, end REAL,
        text TEXT NOT NULL, UNIQUE(recording, idx));
      CREATE VIRTUAL TABLE segments_fts USING fts5(text, content='segments', content_rowid='id',
        tokenize='unicode61 remove_diacritics 2');
      CREATE TRIGGER segments_ai AFTER INSERT ON segments BEGIN
        INSERT INTO segments_fts(rowid, text) VALUES (new.id, new.text); END;
      CREATE TRIGGER segments_ad AFTER DELETE ON segments BEGIN
        INSERT INTO segments_fts(segments_fts, rowid, text) VALUES('delete', old.id, old.text); END;
      INSERT INTO transcripts VALUES('a','Call','Zoom',1,2,'ru',NULL,NULL,'{"languageHints":["ru"]}',
        NULL, 4102444800);
      PRAGMA user_version = 1;
      """
    #expect(sqlite3_exec(db, v1, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)

    await TranscriptIndex.backfill(in: root)

    #expect(try rows(root, "PRAGMA user_version") == [["2"]])
    #expect(
      try rows(root, "SELECT app, config_json FROM transcripts") == [
        ["Zoom", #"{"languageHints":["ru"]}"#]
      ])
    #expect(try rows(root, "SELECT text FROM segments") == [["old text"]])
  }

  /// The invariant an agent relies on: whatever was transcribed is findable.
  @Test("every segment of every transcript is in the index and searchable")
  func indexIsComplete() async throws {
    let root = try makeRoot()
    var expectedSegments = 0
    for n in 0..<25 {
      let directory = try makeRecording(
        in: root, "rec-\(String(format: "%02d", n))", title: "Meeting \(n)")
      let texts = (0..<(3 + n % 7)).map { "unique\(n)x\($0) общая фраза" }
      expectedSegments += texts.count
      try document(texts).save(for: directory)
    }

    await TranscriptIndex.backfill(in: root)

    #expect(try rows(root, "SELECT count(*) FROM transcripts") == [["25"]])
    #expect(try rows(root, "SELECT count(*) FROM segments") == [["\(expectedSegments)"]])
    #expect(
      try rows(root, "SELECT count(*) FROM segments_fts WHERE segments_fts MATCH 'общая'") == [
        ["\(expectedSegments)"]
      ])
    // Every recording is reachable by a word only it contains.
    for n in 0..<25 {
      let hit = try rows(
        root,
        "SELECT s.recording FROM segments_fts f JOIN segments s ON s.id = f.rowid WHERE segments_fts MATCH 'unique\(n)x0'"
      )
      #expect(hit == [["rec-\(String(format: "%02d", n))"]])
    }
    // A second backfill changes nothing and costs no rewrites.
    await TranscriptIndex.backfill(in: root)
    #expect(try rows(root, "SELECT count(*) FROM segments") == [["\(expectedSegments)"]])
  }
}
