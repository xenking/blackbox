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
}
