import Foundation
import Testing

@testable import Blackbox

@Suite("Transcription job ledger")
struct TranscriptionLedgerTests {
  @Test("a paid ledger wins over changed transcription settings")
  func paidLedgerWins() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let paid = TranscriptionJobLedger(
      jobs: [.init(role: .single, fileId: "file-paid", transcriptionId: "job-paid")],
      languageHints: ["ru"],
      separateTracks: false,
      createdAt: .now)
    try paid.save(in: directory)

    let desired = TranscriptionJobLedger(
      jobs: [
        .init(role: .mic, fileId: nil, transcriptionId: nil),
        .init(role: .farEnd, fileId: nil, transcriptionId: nil),
      ],
      languageHints: ["en"],
      separateTracks: true,
      createdAt: .now)
    let store = try LedgerStore(directory: directory, desired: desired)
    let restored = await store.snapshot()

    #expect(restored.jobs.map(\.role) == [.single])
    #expect(restored.jobs.first?.fileId == "file-paid")
    #expect(restored.jobs.first?.transcriptionId == "job-paid")
    #expect(restored.languageHints == ["ru"])
    #expect(restored.separateTracks == false)
  }

  @Test("completion commits transcript before forgetting recovery ids")
  func completionCommitOrdering() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let paid = TranscriptionJobLedger(
      jobs: [.init(role: .single, fileId: "file-paid", transcriptionId: "job-paid")],
      languageHints: ["ru"],
      separateTracks: false,
      createdAt: .now)
    let store = try LedgerStore(directory: directory, desired: paid)
    let document = TranscriptDocument(segments: [], language: "ru", createdAt: .now)

    let ids = try await TranscriptionService.commitCompletedTranscript(
      document, in: directory, store: store)

    #expect(ids.transcriptionIds == ["job-paid"])
    #expect(TranscriptDocument.load(for: directory) != nil)
    #expect(TranscriptionJobLedger.load(in: directory) == nil)
  }

  @Test("a transcript write failure retains paid recovery ids")
  func failedCommitRetainsLedger() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: TranscriptDocument.sidecarURL(for: directory), withIntermediateDirectories: true)

    let paid = TranscriptionJobLedger(
      jobs: [.init(role: .single, fileId: "file-paid", transcriptionId: "job-paid")],
      languageHints: ["ru"],
      separateTracks: false,
      createdAt: .now)
    let store = try LedgerStore(directory: directory, desired: paid)
    let document = TranscriptDocument(segments: [], language: "ru", createdAt: .now)

    await #expect(throws: (any Error).self) {
      try await TranscriptionService.commitCompletedTranscript(
        document, in: directory, store: store)
    }

    #expect(TranscriptionJobLedger.load(in: directory)?.jobs.first?.transcriptionId == "job-paid")
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("blackbox-ledger-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
