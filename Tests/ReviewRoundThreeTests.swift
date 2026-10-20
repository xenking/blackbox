import Foundation
import SQLite3
import Testing

@testable import Blackbox

@Suite("Review round three")
struct ReviewRoundThreeTests {
  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("round3-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  @Test("moving the library only picks up recording directories, not unrelated files")
  func recordingDirectoriesOnly() throws {
    let root = try makeRoot()
    let fileManager = FileManager.default
    let recording = root.appendingPathComponent("2610-20-zoom")
    try fileManager.createDirectory(at: recording, withIntermediateDirectories: true)
    try Data([0]).write(to: recording.appendingPathComponent("audio.m4a"))
    let onlyTranscript = root.appendingPathComponent("2610-21-meet")
    try fileManager.createDirectory(at: onlyTranscript, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: TranscriptDocument.sidecarURL(for: onlyTranscript))
    // Things a shared folder such as Documents holds.
    try fileManager.createDirectory(
      at: root.appendingPathComponent("Taxes"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: root.appendingPathComponent("notes.txt"))
    try Data("x".utf8).write(to: TranscriptIndex.databaseURL(in: root))

    #expect(
      Set(RecordingStore.recordingDirectories(in: root).map(\.lastPathComponent))
        == ["2610-20-zoom", "2610-21-meet"])
  }

  @Test("a rebuilt index keeps the request config recorded in the transcript")
  func backfillKeepsConfig() async throws {
    let root = try makeRoot()
    let directory = root.appendingPathComponent("a")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try RecordingMetadata(
      title: "T", createdAt: Date(timeIntervalSince1970: 1_700_000_000), appName: "Zoom",
      speakers: [:]
    ).save(in: directory)
    let config = TranscriptionConfig(
      languageHints: ["en"], context: SonioxContext(generalLines: "", terms: "Blackbox", text: ""))
    try TranscriptDocument(
      segments: [TranscriptSegment(speaker: 0, time: 0, text: "hello")],
      createdAt: Date(timeIntervalSince1970: 1_700_000_100), config: config
    ).save(for: directory)

    await TranscriptIndex.backfill(in: root)

    let json = try #require(
      Self.firstColumn(TranscriptIndex.databaseURL(in: root), "SELECT config_json FROM transcripts")
    )
    #expect(json.contains("\"Blackbox\"") && json.contains("\"en\""))
  }

  @Test("an old transcript without a config still decodes")
  func oldTranscriptDecodes() throws {
    let json = #"{"segments":[],"createdAt":"2026-01-01T00:00:00Z"}"#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let document = try decoder.decode(TranscriptDocument.self, from: Data(json.utf8))
    #expect(document.config == nil)
  }

  @Test("replacing an export keeps the old file when the copy fails, and swaps it when it works")
  func exportReplacementIsAtomic() throws {
    let root = try makeRoot()
    let destination = root.appendingPathComponent("out.m4a")
    let source = root.appendingPathComponent("new.m4a")
    try Data("old".utf8).write(to: destination)
    try Data("new".utf8).write(to: source)

    // A source that cannot be copied must leave the previous export untouched.
    #expect(throws: (any Error).self) {
      try TranscriptionService.replaceItem(
        at: destination, withCopyOf: root.appendingPathComponent("missing.m4a"))
    }
    #expect(try String(contentsOf: destination, encoding: .utf8) == "old")

    try TranscriptionService.replaceItem(at: destination, withCopyOf: source)
    #expect(try String(contentsOf: destination, encoding: .utf8) == "new")
    // No staging file left behind.
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        == ["new.m4a", "out.m4a"])
  }

  @Test("the scratch sweep leaves fresh files alone and removes only stale ones")
  func sweepOnlyRemovesStaleScratch() async throws {
    let root = try makeRoot()
    let fresh = root.appendingPathComponent("blackbox-mixed-fresh.m4a")
    let stale = root.appendingPathComponent("blackbox-upload-stale.part")
    let unrelated = root.appendingPathComponent("other.tmp")
    for url in [fresh, stale, unrelated] { try Data([0]).write(to: url) }
    let old = Date().addingTimeInterval(-TranscriptionService.staleScratchAge - 60)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: stale.path)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: unrelated.path)

    await TranscriptionService.sweepTemporaryFiles(in: root)

    let left = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    #expect(left == ["blackbox-mixed-fresh.m4a", "other.tmp"])
  }

  /// First column of the first row, read straight from the database like an external reader.
  private static func firstColumn(_ database: URL, _ sql: String) -> String? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      return nil
    }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
    return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
  }
}
