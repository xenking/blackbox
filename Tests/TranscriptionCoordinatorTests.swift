import Foundation
import Testing

@testable import Blackbox

// MARK: - Test Doubles

/// Scriptable stand-in for the Soniox client. An actor so the counters a test
/// asserts on cannot race the coordinator's job runner.
/// Most tests are about the coordinator's state machine, not about how many
/// Soniox jobs a recording needs, so they speak in terms of one job. These are
/// views onto the first part; tests that care about parts use `parts` directly.
extension TranscriptionJob {
  init(
    fileId: String?, transcriptionId: String? = nil, isAutomatic: Bool = false,
    lastError: String? = nil, awaitingRemoteDelete: Bool = false
  ) {
    self.init(
      parts: [.init(role: .single, fileId: fileId, transcriptionId: transcriptionId)],
      isAutomatic: isAutomatic, lastError: lastError,
      awaitingRemoteDelete: awaitingRemoteDelete)
  }

  var fileId: String? {
    get { parts.first?.fileId }
    set {
      if parts.isEmpty { parts = [.init(role: .single)] }
      parts[0].fileId = newValue
    }
  }

  var transcriptionId: String? {
    get { parts.first?.transcriptionId }
    set {
      if parts.isEmpty { parts = [.init(role: .single)] }
      parts[0].transcriptionId = newValue
    }
  }
}

actor FakeTranscriptionService: TranscriptionServicing {
  private(set) var uploadCount = 0
  private(set) var createCount = 0
  private(set) var completionCount = 0
  private(set) var fetchCount = 0
  private(set) var deletedTranscriptionIds: [String] = []
  private(set) var deletedFileIds: [String] = []
  private(set) var references: [String] = []

  private var uploadError: Error?
  /// Consumed one per `awaitCompletion` call, so a test can fail then succeed.
  private var completionErrors: [Error] = []
  private var holdsCompletion = false
  private let document = TranscriptDocument(
    segments: [TranscriptSegment(speaker: 1, time: 0, text: "hello")],
    language: "en",
    createdAt: Date(timeIntervalSince1970: 1_700_000_000)
  )

  /// Runs just before `upload` returns, so a test can model the user changing
  /// something during the longest await in the job.
  private var afterUpload: (@Sendable () async -> Void)?

  func setUploadError(_ error: Error?) { uploadError = error }
  func setCompletionErrors(_ errors: [Error]) { completionErrors = errors }
  func setHoldsCompletion(_ holds: Bool) { holdsCompletion = holds }
  func setAfterUpload(_ handler: (@Sendable () async -> Void)?) { afterUpload = handler }
  private var afterCreate: (@Sendable () async -> Void)?
  func setAfterCreate(_ handler: (@Sendable () async -> Void)?) { afterCreate = handler }

  private var holdsUpload = false
  private(set) var uploadsInFlight = 0
  private(set) var maxConcurrentUploads = 0

  func setHoldsUpload(_ holds: Bool) { holdsUpload = holds }

  /// Keeps the job parked even after it is cancelled, so a test can observe
  /// what happens to a cancelled-but-still-running job. Real uploads behave
  /// this way: cancellation is only noticed at a suspension point, and
  /// `URLSession` does not abandon a transmit mid-flight.
  private var holdIgnoresCancellation = false
  func setHoldIgnoresCancellation(_ ignores: Bool) { holdIgnoresCancellation = ignores }

  /// Kept so a test can fire a progress report at a moment of its choosing.
  /// The scripted reports below all land before the hold, and the hold loop
  /// throws on cancellation, so there is otherwise no way to model a report
  /// arriving *after* the user pressed Cancel - which is the case that matters.
  private var progressHandler: (@Sendable (TranscriptionUploadPhase) -> Void)?
  func emitProgress(_ phase: TranscriptionUploadPhase) { progressHandler?(phase) }

  /// What `plan` answers. One job by default, which is what every test that is
  /// not about per-track transcription wants.
  private var plannedRoles: [TranscriptionJobRole] = [.single]
  private(set) var planCount = 0
  private(set) var uploadedRoles: [TranscriptionJobRole] = []
  private(set) var createdRoles: [TranscriptionJobRole] = []
  private(set) var configs: [TranscriptionConfig] = []
  /// Transcription ids whose transcript is empty, as a muted mic's would be.
  private var silentTranscriptionIds: Set<String> = []
  /// Fails the Nth `createTranscription` call (1-based) once, then recovers.
  private var failCreateAt: Int?
  private var documentsByTranscriptionId: [String: TranscriptDocument] = [:]

  func setPlannedRoles(_ roles: [TranscriptionJobRole]) { plannedRoles = roles }
  func setSilent(_ transcriptionId: String) { silentTranscriptionIds.insert(transcriptionId) }
  func setFailCreate(at call: Int?) { failCreateAt = call }
  func setDocument(_ document: TranscriptDocument, for transcriptionId: String) {
    documentsByTranscriptionId[transcriptionId] = document
  }

  func plan(fileURL: URL, separateTracks: Bool) async throws -> [TranscriptionJobRole] {
    planCount += 1
    return plannedRoles
  }

  func upload(
    fileURL: URL,
    role: TranscriptionJobRole,
    onProgress: @escaping @Sendable (TranscriptionUploadPhase) -> Void
  ) async throws -> String {
    progressHandler = onProgress
    uploadCount += 1
    uploadedRoles.append(role)
    if let uploadError { throw uploadError }
    uploadsInFlight += 1
    maxConcurrentUploads = max(maxConcurrentUploads, uploadsInFlight)
    defer { uploadsInFlight -= 1 }
    // Reported so a test can observe the coordinator's stage transitions
    // rather than only its terminal states.
    onProgress(.mixing(1))
    onProgress(.uploading(0.5))
    // Held so a test can pin jobs inside the stage the upload gate bounds.
    while holdsUpload {
      try? await Task.sleep(for: .milliseconds(2))
      if !holdIgnoresCancellation { try Task.checkCancellation() }
    }
    await afterUpload?()
    onProgress(.uploading(1))
    return "file-\(uploadCount)"
  }

  func createTranscription(
    fileId: String, reference: String, role: TranscriptionJobRole, config: TranscriptionConfig
  ) async throws -> String {
    createCount += 1
    if createCount == failCreateAt {
      failCreateAt = nil
      throw URLError(.timedOut)
    }
    references.append(reference)
    createdRoles.append(role)
    configs.append(config)
    await afterCreate?()
    return "transcription-\(createCount)"
  }

  func awaitCompletion(transcriptionId: String) async throws {
    completionCount += 1
    if !completionErrors.isEmpty { throw completionErrors.removeFirst() }
    if holdsCompletion {
      // Released only by cancellation, which surfaces as a thrown CancellationError.
      try await Task.sleep(for: .seconds(60))
    }
  }

  func fetchTranscript(transcriptionId: String) async throws -> TranscriptDocument {
    fetchCount += 1
    if silentTranscriptionIds.contains(transcriptionId) {
      throw TranscriptionError.noSpeechDetected
    }
    return documentsByTranscriptionId[transcriptionId] ?? document
  }

  /// Settable so a test can hold the coordinator in the state a failed cleanup
  /// leaves it in: the record kept, the ids still naming what is on Soniox.
  var deleteSucceeds = true

  func deleteRemote(transcriptionIds: [String], fileIds: [String]) async -> Bool {
    deletedTranscriptionIds.append(contentsOf: transcriptionIds)
    deletedFileIds.append(contentsOf: fileIds)
    return deleteSucceeds
  }

  func setDeleteSucceeds(_ value: Bool) { deleteSucceeds = value }
}

@MainActor
final class TranscriptionHarness {
  let root: URL
  /// Where the cleanup ledger lives: deliberately NOT under `root`, like production, where
  /// the save folder can be moved or replaced without taking the ledger with it.
  let cleanup: URL
  let service = FakeTranscriptionService()

  var apiKey: String? = "test-key"
  var autoEnabled = true
  /// Long enough to clear the automatic-transcription duration floor. Tests that
  /// care about the floor set it explicitly.
  var duration: Double? = 600
  /// Backoff and gate waits are no-ops by default so retries resolve instantly.
  /// Captured by value in `makeCoordinator`, unlike every other knob here, so
  /// set it BEFORE calling `makeCoordinator()` - a later assignment is ignored.
  var sleepHandler: @Sendable (Duration) async -> Void = { _ in }
  /// Runs where the real temp-file sweep runs, inside `resumePendingJobs` and
  /// before its scan. Lets a test act on a recording in that window.
  var sweepHandler: (@Sendable () async -> Void)?
  /// Captured by value in `makeCoordinator`, like `sleepHandler` - set it
  /// before building the coordinator.
  var uploadConcurrency = 2
  /// Read when a job is first planned; a job that has already paid ignores it.
  var languageHints = ["ru"]
  var model: String?

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("blackbox-transcription-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    cleanup = FileManager.default.temporaryDirectory
      .appendingPathComponent("blackbox-cleanup-\(UUID().uuidString)")
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: cleanup)
  }

  /// Creates a recording directory holding a placeholder `audio.m4a`. The fake
  /// never reads it; only its existence matters to the coordinator.
  @discardableResult
  func makeRecording(_ name: String) throws -> URL {
    let directory = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data([0]).write(to: directory.appendingPathComponent("audio.m4a"))
    return directory
  }

  func makeCoordinator() -> TranscriptionCoordinator {
    let coordinator = TranscriptionCoordinator(
      dependencies: TranscriptionCoordinator.Dependencies(
        makeService: { [service] _ in service },
        apiKey: { [weak self] in self?.apiKey ?? nil },
        isAutoEnabled: { [weak self] in self?.autoEnabled ?? false },
        transcriptionOptions: { [weak self] in
          TranscriptionConfig(languageHints: self?.languageHints ?? ["ru"], model: self?.model)
        },
        saveDirectory: { [root] in root },
        cleanupDirectory: { [cleanup] in cleanup },
        sleep: { [sleepHandler] duration in await sleepHandler(duration) },
        durationSeconds: { [weak self] _ in await self?.duration },
        sweepTemporaryFiles: { [weak self] in await self?.sweepHandler?() },
        uploadConcurrency: uploadConcurrency
      ))
    return coordinator
  }

  /// Polls until `condition` holds. The coordinator hops between the main actor
  /// and the service actor, so yielding a fixed number of times is not enough.
  func wait(
    upTo timeout: TimeInterval = 15,
    for condition: @MainActor () async -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return }
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(2))
    }
  }
}

// MARK: - Tests

@MainActor
@Suite("Transcription Coordinator")
struct TranscriptionCoordinatorTests {

  // MARK: Trigger decision

  @Test("auto-transcribes a finished recording when the setting and key are present")
  func autoTranscribesWhenEnabled() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.recordingFinished(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }
    // Cleanup is deliberately fire-and-forget so cancellation cannot kill it,
    // which means it lands after `.completed` rather than before.
    await harness.wait { await harness.service.deletedFileIds == ["file-1"] }

    #expect(coordinator.status(for: directory) == .completed)
    #expect(TranscriptDocument.load(for: directory)?.segments.count == 1)
    #expect(await harness.service.uploadCount == 1)
    // The job sidecar exists only while work is outstanding.
    #expect(TranscriptionJob.load(for: directory) == nil)
    #expect(await harness.service.deletedFileIds == ["file-1"])
    #expect(await harness.service.deletedTranscriptionIds == ["transcription-1"])
    // The remote job is tagged with the recording it belongs to.
    #expect(await harness.service.references == ["call-1"])
  }

  @Test("a 409 while fetching the transcript is retried, not treated as failure")
  func retriesNotReady() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setCompletionErrors([
      TranscriptionError.notReady("fetch transcript: still processing")
    ])
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(await harness.service.uploadCount == 1)
    #expect(TranscriptDocument.load(for: directory) != nil)
  }

  @Test("an exhausted balance fails terminally instead of retrying")
  func balanceExhaustedIsTerminal() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setUploadError(
      TranscriptionError.balanceExhausted("prepaid balance is zero"))
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait {
      if case .error = coordinator.status(for: directory) { return true }
      return false
    }

    // Retrying a dead balance just spends time; one attempt only.
    #expect(await harness.service.uploadCount == 1)
  }

  @Test("does not auto-transcribe when the setting is off")
  func skipsWhenSettingOff() async throws {
    let harness = try TranscriptionHarness()
    harness.autoEnabled = false
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.recordingFinished(recordingDirectory: directory)
    await harness.wait(upTo: 0.2) { await harness.service.uploadCount > 0 }

    #expect(await harness.service.uploadCount == 0)
    #expect(coordinator.status(for: directory) == .idle)
    #expect(TranscriptionJob.load(for: directory) == nil)
  }

  @Test("does not auto-transcribe when no API key is configured")
  func skipsWhenNoAPIKey() async throws {
    let harness = try TranscriptionHarness()
    harness.apiKey = nil
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.recordingFinished(recordingDirectory: directory)
    await harness.wait(upTo: 0.2) { await harness.service.uploadCount > 0 }

    #expect(await harness.service.uploadCount == 0)
    #expect(!coordinator.hasAPIKey)
    #expect(TranscriptionJob.load(for: directory) == nil)
  }

  /// The save directory holds every recording and, on an old install, stray
  /// loose audio next to them. Enqueueing it transcribes whichever stray file
  /// `RecordingStore.audioURL(in:)` finds and bills the user for it, so a
  /// directory that is not a child of the save directory is refused outright.
  @Test("refuses a directory that is not a recording directory")
  func refusesNonRecordingDirectory() async throws {
    let harness = try TranscriptionHarness()
    try harness.makeRecording("call-1")
    let strayAudio = harness.root.appendingPathComponent("audio.m4a")
    try Data([0]).write(to: strayAudio)
    let coordinator = harness.makeCoordinator()

    coordinator.recordingFinished(recordingDirectory: harness.root)
    await harness.wait(upTo: 0.2) { await harness.service.uploadCount > 0 }

    #expect(await harness.service.uploadCount == 0)
    #expect(coordinator.status(for: harness.root) == .idle)
    #expect(TranscriptionJob.load(for: harness.root) == nil)
  }

  @Test("manual transcription ignores the auto-transcribe setting")
  func manualIgnoresAutoSetting() async throws {
    let harness = try TranscriptionHarness()
    harness.autoEnabled = false
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(await harness.service.uploadCount == 1)
  }

  // MARK: Queueing

  @Test("enqueueing the same recording twice runs it once")
  func duplicateEnqueueRunsOnce() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }
    await harness.wait(upTo: 0.2) { await harness.service.uploadCount > 1 }

    #expect(await harness.service.uploadCount == 1)
  }

  /// The direct regression test for the reported bug: a recording finished at
  /// 17:52 did not start transcribing until 18:17, because it sat behind
  /// another job's poll loop.
  @Test("a second recording transcribes while the first is still polling")
  func jobsRunConcurrently() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setHoldsCompletion(true)
    let first = try harness.makeRecording("call-1")
    let second = try harness.makeRecording("call-2")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: first)
    // Wait until the first job is inside `awaitCompletion` before releasing the
    // hold - it is a single flag on the fake, read at call time, so the first
    // job stays parked while later ones sail past.
    await harness.wait { coordinator.status(for: first) == .transcribing }
    await harness.service.setHoldsCompletion(false)
    coordinator.transcribe(recordingDirectory: second)

    // The second job runs to completion while the first is still parked in
    // `awaitCompletion`, which is where a job spends most of its life.
    await harness.wait { coordinator.status(for: second) == .completed }
    #expect(coordinator.status(for: second) == .completed)
    #expect(await harness.service.uploadCount == 2)
    #expect(coordinator.status(for: first) == .transcribing)

    coordinator.cancel(recordingDirectory: first)
  }

  @Test("cancelling one job leaves the others running")
  func cancellingOneJobLeavesOthers() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setHoldsCompletion(true)
    let first = try harness.makeRecording("call-1")
    let second = try harness.makeRecording("call-2")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: first)
    await harness.wait { coordinator.status(for: first) == .transcribing }
    await harness.service.setHoldsCompletion(false)
    coordinator.transcribe(recordingDirectory: second)

    coordinator.cancel(recordingDirectory: first)
    await harness.wait { coordinator.status(for: second) == .completed }

    #expect(coordinator.status(for: second) == .completed)
    #expect(coordinator.status(for: first) == .idle)
    #expect(TranscriptDocument.load(for: second) != nil)
  }

  @Test("resume starts every pending job, not just the first")
  func resumeStartsEveryJob() async throws {
    let harness = try TranscriptionHarness()
    for name in ["call-1", "call-2", "call-3"] {
      let directory = try harness.makeRecording(name)
      TranscriptionJob(fileId: "f", transcriptionId: "t", isAutomatic: false)
        .save(for: directory)
    }
    let coordinator = harness.makeCoordinator()

    coordinator.resumePendingJobs()
    await harness.wait { await harness.service.completionCount == 3 }

    #expect(await harness.service.completionCount == 3)
  }

  @Test("at most the configured number of uploads run at once")
  func uploadConcurrencyIsBounded() async throws {
    let harness = try TranscriptionHarness()
    harness.uploadConcurrency = 2
    await harness.service.setHoldsUpload(true)
    let directories = try (1...5).map { try harness.makeRecording("call-\($0)") }
    let coordinator = harness.makeCoordinator()

    for directory in directories { coordinator.transcribe(recordingDirectory: directory) }
    await harness.wait { await harness.service.uploadsInFlight == 2 }
    #expect(await harness.service.uploadsInFlight == 2)

    await harness.service.setHoldsUpload(false)
    await harness.wait { coordinator.status(for: directories[4]) == .completed }

    #expect(await harness.service.maxConcurrentUploads <= 2)
    #expect(await harness.service.uploadCount == 5)
  }

  @Test("a job waiting for an upload slot is dropped when consent is withdrawn")
  func consentWithdrawnWhileWaitingForSlot() async throws {
    let harness = try TranscriptionHarness()
    harness.uploadConcurrency = 1
    await harness.service.setHoldsUpload(true)
    let first = try harness.makeRecording("call-1")
    let second = try harness.makeRecording("call-2")
    let coordinator = harness.makeCoordinator()

    coordinator.recordingFinished(recordingDirectory: first)
    await harness.wait { await harness.service.uploadsInFlight == 1 }
    coordinator.recordingFinished(recordingDirectory: second)

    // The second job is parked on the gate, which is a wait the user can act
    // during - so it has to be a consent re-check point like every other wait.
    harness.autoEnabled = false
    await harness.service.setHoldsUpload(false)
    await harness.wait { TranscriptionJob.load(for: second) == nil }

    #expect(coordinator.status(for: second) == .idle)
    #expect(await harness.service.uploadCount == 1)
  }

  @Test("two jobs finishing back to back each report their own completion")
  func finishCountsArePerRecording() async throws {
    let harness = try TranscriptionHarness()
    let first = try harness.makeRecording("call-1")
    let second = try harness.makeRecording("call-2")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: first)
    coordinator.transcribe(recordingDirectory: second)
    await harness.wait {
      coordinator.status(for: first) == .completed && coordinator.status(for: second) == .completed
    }

    // A single `lastFinishedPath` could only name one of these, so an open
    // detail view on the other never reloaded its transcript.
    #expect(coordinator.finishCount(for: first) == 1)
    #expect(coordinator.finishCount(for: second) == 1)
  }

  @Test("a recording reported at quit writes its sidecar without starting")
  func quitDefersInsteadOfUploading() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.suspendNewJobs()
    coordinator.recordingFinished(recordingDirectory: directory)
    await harness.wait(upTo: 0.2) { await harness.service.uploadCount > 0 }

    #expect(await harness.service.uploadCount == 0)
    #expect(TranscriptionJob.load(for: directory) != nil)

    // The next launch picks it up, which is the whole point of deferring rather
    // than starting an upload the process kill is about to interrupt.
    let next = harness.makeCoordinator()
    next.resumePendingJobs()
    await harness.wait { next.status(for: directory) == .completed }
    #expect(next.status(for: directory) == .completed)
  }

  @Test("a transient failure is retried without re-uploading")
  func retriesTransientFailure() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setCompletionErrors([TranscriptionError.serverError(503, "busy")])
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(await harness.service.completionCount == 2)
    #expect(await harness.service.uploadCount == 1)
    #expect(TranscriptDocument.load(for: directory) != nil)
  }

  @Test("a terminal failure surfaces the error and keeps the job for retry")
  func terminalFailureKeepsJob() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setUploadError(TranscriptionError.uploadFailed("invalid key"))
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait {
      if case .error = coordinator.status(for: directory) { return true }
      return false
    }

    #expect(coordinator.status(for: directory) == .error("Upload failed: invalid key"))
    #expect(TranscriptionJob.load(for: directory)?.lastError != nil)
    #expect(TranscriptDocument.load(for: directory) == nil)
    // One attempt only: an invalid key is not worth retrying.
    #expect(await harness.service.uploadCount == 1)
  }

  @Test("a terminal failure after upload drops the audio it left on the server")
  func terminalFailureDiscardsRemoteArtifacts() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setCompletionErrors([
      TranscriptionError.transcriptionFailed("unsupported audio")
    ])
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { await harness.service.deletedFileIds.contains("file-1") }

    #expect(await harness.service.deletedTranscriptionIds == ["transcription-1"])
    // The failure is kept for the UI, but the ids are gone: a retry starts clean.
    let job = try #require(TranscriptionJob.load(for: directory))
    #expect(job.lastError != nil)
    #expect(job.fileId == nil)
    #expect(job.transcriptionId == nil)
  }

  @Test("retrying a failed job clears the recorded error")
  func retryClearsRecordedError() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setUploadError(TranscriptionError.uploadFailed("invalid key"))
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait {
      if case .error = coordinator.status(for: directory) { return true }
      return false
    }

    await harness.service.setUploadError(nil)
    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(TranscriptDocument.load(for: directory) != nil)
    // The record is retired on the delete's confirmation, one hop after the
    // status lands.
    await harness.wait { TranscriptionJob.load(for: directory) == nil }
    #expect(TranscriptionJob.load(for: directory) == nil)
  }

  @Test("cancelling drops the job and the remote artifacts")
  func cancelDropsJobAndRemoteArtifacts() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setHoldsCompletion(true)
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { await harness.service.completionCount == 1 }

    coordinator.cancel(recordingDirectory: directory)
    await harness.wait { await harness.service.deletedFileIds.contains("file-1") }

    #expect(coordinator.status(for: directory) == .idle)
    #expect(TranscriptionJob.load(for: directory) == nil)
    #expect(await harness.service.deletedTranscriptionIds == ["transcription-1"])
  }

  @Test("cancelling a queued job drops the audio a previous session uploaded")
  func cancelQueuedJobDiscardsRemoteArtifacts() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setHoldsCompletion(true)
    let running = try harness.makeRecording("call-1")
    let queued = try harness.makeRecording("call-2")
    var job = TranscriptionJob()
    job.fileId = "file-from-previous-session"
    job.transcriptionId = "transcription-from-previous-session"
    job.save(for: queued)

    let coordinator = harness.makeCoordinator()
    coordinator.transcribe(recordingDirectory: running)
    await harness.wait { await harness.service.completionCount == 1 }
    coordinator.transcribe(recordingDirectory: queued)
    #expect(coordinator.status(for: queued) == .queued)

    coordinator.cancel(recordingDirectory: queued)
    await harness.wait {
      await harness.service.deletedFileIds.contains("file-from-previous-session")
    }

    #expect(TranscriptionJob.load(for: queued) == nil)
    #expect(coordinator.status(for: queued) == .idle)
  }

  // MARK: Resume

  @Test("a job interrupted mid-poll resumes without re-uploading")
  func resumesInterruptedJob() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    var job = TranscriptionJob()
    job.fileId = "file-from-previous-session"
    job.transcriptionId = "transcription-from-previous-session"
    job.save(for: directory)

    let coordinator = harness.makeCoordinator()
    coordinator.resumePendingJobs()
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(await harness.service.uploadCount == 0)
    #expect(await harness.service.createCount == 0)
    #expect(await harness.service.completionCount == 1)
    // Resume polls the id it already had and fetches once; it does not re-create.
    #expect(await harness.service.fetchCount == 1)
    #expect(TranscriptDocument.load(for: directory) != nil)
  }

  @Test("a job that already failed is surfaced, not retried, on launch")
  func doesNotAutoRetryFailedJobOnLaunch() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    var job = TranscriptionJob()
    job.lastError = "Upload failed: invalid key"
    job.save(for: directory)

    let coordinator = harness.makeCoordinator()
    coordinator.resumePendingJobs()
    await harness.wait {
      if case .error = coordinator.status(for: directory) { return true }
      return false
    }

    #expect(coordinator.status(for: directory) == .error("Upload failed: invalid key"))
    #expect(await harness.service.uploadCount == 0)
  }

  @Test("turning the setting off stops a pending auto job that never uploaded")
  func dropsPendingAutoJobWhenSettingTurnedOff() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    // What the quit path leaves behind: enqueued, nothing uploaded yet.
    TranscriptionJob(isAutomatic: true).save(for: directory)
    harness.autoEnabled = false

    let coordinator = harness.makeCoordinator()
    coordinator.resumePendingJobs()
    await harness.wait { TranscriptionJob.load(for: directory) == nil }

    #expect(await harness.service.uploadCount == 0)
    #expect(TranscriptionJob.load(for: directory) == nil)
  }

  @Test("an auto job that uploaded but was never billed is dropped with the setting off")
  func dropsUploadedButUnbilledAutoJobWhenSettingTurnedOff() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    var job = TranscriptionJob(isAutomatic: true)
    job.fileId = "file-from-previous-session"
    job.save(for: directory)
    harness.autoEnabled = false

    let coordinator = harness.makeCoordinator()
    coordinator.resumePendingJobs()
    await harness.wait {
      await harness.service.deletedFileIds.contains("file-from-previous-session")
    }

    // Consent was withdrawn before anything was charged, so the right move is to
    // delete the uploaded audio rather than bill for a transcription of it.
    #expect(await harness.service.createCount == 0)
    #expect(TranscriptionJob.load(for: directory) == nil)
    #expect(TranscriptDocument.load(for: directory) == nil)
  }

  @Test("an auto job that was already billed still finishes with the setting off")
  func finishesBilledAutoJobWhenSettingTurnedOff() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    var job = TranscriptionJob(isAutomatic: true)
    job.fileId = "file-from-previous-session"
    job.transcriptionId = "transcription-from-previous-session"
    job.save(for: directory)
    harness.autoEnabled = false

    let coordinator = harness.makeCoordinator()
    coordinator.resumePendingJobs()
    await harness.wait { coordinator.status(for: directory) == .completed }

    // The money is already spent; throwing the result away helps nobody.
    #expect(await harness.service.uploadCount == 0)
    #expect(TranscriptDocument.load(for: directory) != nil)
  }

  @Test("a manual job resumes regardless of the auto-transcribe setting")
  func resumesManualJobWithSettingOff() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    TranscriptionJob(isAutomatic: false).save(for: directory)
    harness.autoEnabled = false

    let coordinator = harness.makeCoordinator()
    coordinator.resumePendingJobs()
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(await harness.service.uploadCount == 1)
  }

  @Test("nothing resumes without an API key")
  func skipsResumeWithoutAPIKey() async throws {
    let harness = try TranscriptionHarness()
    harness.apiKey = nil
    let directory = try harness.makeRecording("call-1")
    TranscriptionJob().save(for: directory)

    let coordinator = harness.makeCoordinator()
    coordinator.resumePendingJobs()
    await harness.wait(upTo: 0.2) { await harness.service.uploadCount > 0 }

    #expect(await harness.service.uploadCount == 0)
    #expect(TranscriptionJob.load(for: directory) != nil)
  }

  @Test("a recording whose audio is gone drops its job instead of looping")
  func dropsJobWhenAudioMissing() async throws {
    let harness = try TranscriptionHarness()
    let directory = harness.root.appendingPathComponent("call-1")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    TranscriptionJob().save(for: directory)

    let coordinator = harness.makeCoordinator()
    coordinator.resumePendingJobs()
    await harness.wait { TranscriptionJob.load(for: directory) == nil }

    #expect(TranscriptionJob.load(for: directory) == nil)
    #expect(await harness.service.uploadCount == 0)
  }

  @Test("a job whose audio is gone deletes what it had already uploaded")
  func dropsJobWhenAudioMissingDiscardsRemoteArtifacts() async throws {
    let harness = try TranscriptionHarness()
    let directory = harness.root.appendingPathComponent("call-1")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var job = TranscriptionJob()
    job.fileId = "file-from-previous-session"
    job.transcriptionId = "transcription-from-previous-session"
    job.save(for: directory)

    let coordinator = harness.makeCoordinator()
    coordinator.resumePendingJobs()
    await harness.wait {
      await harness.service.deletedFileIds.contains("file-from-previous-session")
    }

    // Removing the sidecar without this would destroy the only record of what
    // is sitting on Soniox.
    #expect(
      await harness.service.deletedTranscriptionIds == ["transcription-from-previous-session"])
    #expect(TranscriptionJob.load(for: directory) == nil)
  }

  // MARK: Consent re-checks

  @Test("a queued auto job does not upload if the setting is turned off first")
  func dropsQueuedAutoJobWhenSettingTurnedOffBeforeItRuns() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.recordingFinished(recordingDirectory: directory)
    // No await between the enqueue and the flip, so the job's task cannot have
    // run yet - this is the window between queueing and first execution.
    #expect(coordinator.status(for: directory) == .queued)

    // The user changes their mind before the job gets going.
    harness.autoEnabled = false
    await harness.wait { TranscriptionJob.load(for: directory) == nil }

    #expect(await harness.service.uploadCount == 0)
    #expect(coordinator.status(for: directory) == .idle)
  }

  @Test("a manual request outranks the automatic flag an interrupted job left behind")
  func manualEnqueueDowngradesAutomaticFlag() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    // An automatic job is enqueued...
    coordinator.recordingFinished(recordingDirectory: directory)
    #expect(TranscriptionJob.load(for: directory)?.isAutomatic == true)

    // ...then, in the same main-actor turn and so before that job's task has
    // run, the user asks for the same recording explicitly and turns the
    // setting off. The downgrade must survive, or the job would be dropped as
    // a withdrawn automatic one.
    coordinator.transcribe(recordingDirectory: directory)
    #expect(TranscriptionJob.load(for: directory)?.isAutomatic == false)

    harness.autoEnabled = false
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(await harness.service.uploadCount == 1)
  }

  @Test("consent withdrawn during a retry wait stops the job before it bills")
  func dropsInFlightAutoJobWhenSettingTurnedOffDuringBackoff() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setUploadError(TranscriptionError.serverError(503, "busy"))
    // The user reaches Settings while the job is sleeping off a transient error.
    harness.sleepHandler = { [weak harness] _ in
      await MainActor.run { harness?.autoEnabled = false }
    }
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.recordingFinished(recordingDirectory: directory)
    await harness.wait { TranscriptionJob.load(for: directory) == nil }

    // The retry that would have followed the wait never runs.
    #expect(await harness.service.uploadCount == 1)
    #expect(await harness.service.createCount == 0)
    #expect(coordinator.status(for: directory) == .idle)
  }

  @Test("consent withdrawn during the upload stops the job before it bills")
  func dropsAutoJobWhenSettingTurnedOffDuringUpload() async throws {
    let harness = try TranscriptionHarness()
    // Uploading a long call re-encodes and transmits the whole recording, so
    // this window is minutes wide in practice.
    await harness.service.setAfterUpload { [weak harness] in
      await MainActor.run { harness?.autoEnabled = false }
    }
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.recordingFinished(recordingDirectory: directory)
    await harness.wait { TranscriptionJob.load(for: directory) == nil }

    #expect(await harness.service.uploadCount == 1)
    // The billing call never goes out, and the upload is deleted again.
    #expect(await harness.service.createCount == 0)
    #expect(await harness.service.deletedFileIds == ["file-1"])
  }

  // MARK: Sidecar format

  /// The job sidecar was hardened against this and these two were not, which is
  /// worse: the three rename paths rebuild metadata from
  /// `load(...) ?? RecordingMetadata(fresh)` and write it back, so one
  /// unreadable decode plus one rename permanently loses the title, the date and
  /// every speaker name.
  @Test("a metadata file written before a field existed still decodes")
  func metadataDecodesWithMissingKeys() throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let json = #"{"title":"Standup","appName":"Zoom"}"#
    try Data(json.utf8).write(to: directory.appendingPathComponent(RecordingMetadata.fileName))

    let loaded = try #require(RecordingMetadata.load(in: directory))
    #expect(loaded.title == "Standup")
    #expect(loaded.appName == "Zoom")
    #expect(loaded.speakers.isEmpty)
  }

  @Test("a transcript written before a field existed still decodes")
  func transcriptDecodesWithMissingKeys() throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let json = #"{"segments":[{"speaker":1,"time":0,"text":"hello"}]}"#
    try Data(json.utf8).write(to: TranscriptDocument.sidecarURL(for: directory))

    let loaded = try #require(TranscriptDocument.load(for: directory))
    #expect(loaded.segments.count == 1)
    #expect(loaded.segments.first?.text == "hello")
  }

  /// The cost of losing a transcript is a paid-for result vanishing and the user
  /// pressing Transcribe again, so one malformed segment must not take the other
  /// four hundred with it. `decodeIfPresent` only covers a *missing* key - a key
  /// present with the wrong type still throws, and that throw propagates out of
  /// the segment array and loses the whole document.
  @Test("one malformed segment does not lose the rest of the transcript")
  func transcriptSurvivesMalformedSegment() throws {
    let harness = try TranscriptionHarness()
    let shapes: [(String, String)] = [
      ("speaker as a string", #"{"speaker":"1","time":0,"text":"a"}"#),
      ("time as a string", #"{"speaker":1,"time":"0","text":"a"}"#),
      ("text as a number", #"{"speaker":1,"time":0,"text":7}"#),
      ("null values", #"{"speaker":null,"time":null,"text":null}"#),
      ("missing every key", #"{}"#),
    ]
    for (name, bad) in shapes {
      let directory = try harness.makeRecording("call-\(UUID().uuidString)")
      let json = #"{"segments":[\#(bad),{"speaker":2,"time":9,"text":"survivor"}]}"#
      try Data(json.utf8).write(to: TranscriptDocument.sidecarURL(for: directory))

      let loaded = try #require(TranscriptDocument.load(for: directory), "lost the file: \(name)")
      #expect(loaded.segments.count == 2, "lost a segment: \(name)")
      #expect(loaded.segments.last?.text == "survivor", "lost the good segment: \(name)")
    }
  }

  @Test("a job sidecar written before a field existed still decodes")
  func decodesSidecarMissingNewerFields() throws {
    // Exactly what an earlier build wrote. The synthesized decoder throws on a
    // missing key, and `load` swallows that with `try?`, so getting this wrong
    // orphans in-flight jobs and strands their audio on Soniox.
    let legacy = #"{"attempts":2,"fileId":"file-1","transcriptionId":"transcription-1"}"#
    let job = try #require(
      try? JSONDecoder().decode(TranscriptionJob.self, from: Data(legacy.utf8)))

    #expect(job.fileId == "file-1")
    #expect(job.transcriptionId == "transcription-1")
    #expect(job.attempts == 2)
    #expect(job.isAutomatic == false)
    #expect(job.lastError == nil)
    #expect(job.awaitingRemoteDelete == false)
  }

  @Test("an empty job sidecar decodes to a clean job rather than being dropped")
  func decodesEmptySidecar() throws {
    let job = try #require(try? JSONDecoder().decode(TranscriptionJob.self, from: Data("{}".utf8)))

    #expect(job.fileId == nil)
    #expect(job.attempts == 0)
    #expect(job.awaitingRemoteDelete == false)
  }

  // MARK: Cleanup that cannot run

  @Test("cleanup that cannot run without a key is kept and retried at next launch")
  func keepsDeleteOnlyRecordWhenKeyIsMissing() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setHoldsCompletion(true)
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { await harness.service.completionCount == 1 }

    // The user clears the key mid-job, then cancels the recording.
    harness.apiKey = nil
    coordinator.apiKeyChanged()
    coordinator.cancel(recordingDirectory: directory)
    await harness.wait { TranscriptionJob.load(for: directory)?.awaitingRemoteDelete == true }

    // Nothing could be deleted, so the ids are still on disk rather than lost.
    #expect(await harness.service.deletedFileIds.isEmpty)
    let kept = try #require(TranscriptionJob.load(for: directory))
    #expect(kept.fileId == "file-1")
    #expect(kept.transcriptionId == "transcription-1")

    // With the key back, the next launch finishes the cleanup and does not
    // re-run the job itself.
    harness.apiKey = "test-key"
    let relaunched = harness.makeCoordinator()
    relaunched.resumePendingJobs()
    await harness.wait { await harness.service.deletedFileIds.contains("file-1") }

    #expect(TranscriptionJob.load(for: directory) == nil)
    #expect(await harness.service.uploadCount == 1)
    #expect(await harness.service.createCount == 1)
  }

  @Test("a terminal failure that could not clean up keeps its ids and cleans up later")
  func terminalFailureWithoutKeyKeepsIdsAndCleansUpAtNextLaunch() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setCompletionErrors([
      TranscriptionError.transcriptionFailed("unsupported audio")
    ])
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()
    // The key goes away between the upload and the failure, so the cleanup the
    // failure would normally do cannot be dispatched. `apiKeyChanged` is what
    // Settings calls on the same edit; without it the coordinator keeps serving
    // the key it cached when the job started.
    await harness.service.setAfterUpload { [weak harness, weak coordinator] in
      await MainActor.run {
        harness?.apiKey = nil
        coordinator?.apiKeyChanged()
      }
    }

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { TranscriptionJob.load(for: directory)?.lastError != nil }

    // The ids survive: they are the only record of what is on Soniox.
    let failed = try #require(TranscriptionJob.load(for: directory))
    #expect(failed.fileId == "file-1")
    #expect(await harness.service.deletedFileIds.isEmpty)

    harness.apiKey = "test-key"
    let relaunched = harness.makeCoordinator()
    relaunched.resumePendingJobs()
    await harness.wait { await harness.service.deletedFileIds.contains("file-1") }

    // The failure is still on screen for the user to retry, but the artifacts
    // are gone and the record no longer names them.
    let cleaned = try #require(TranscriptionJob.load(for: directory))
    #expect(cleaned.lastError != nil)
    #expect(cleaned.fileId == nil)
    #expect(cleaned.transcriptionId == nil)
    #expect(await harness.service.uploadCount == 1)
  }

  @Test("transcribing a recording with leftover cleanup starts clean instead of reusing its ids")
  func manualTranscribeClearsDeleteOnlyRecord() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    // What a cancel with no key leaves behind.
    TranscriptionJob(
      fileId: "stale-file", transcriptionId: "stale-transcription", awaitingRemoteDelete: true
    ).save(for: directory)
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }

    // The leftovers are deleted, and the new job uploaded rather than polling
    // the transcription id it was in the middle of deleting.
    #expect(await harness.service.deletedFileIds.contains("stale-file"))
    #expect(await harness.service.uploadCount == 1)
    #expect(await harness.service.createCount == 1)
    #expect(TranscriptionJob.load(for: directory) == nil)
  }

  /// A control, not a regression test: it holds with the stale-snapshot version
  /// too. The window the fix closes is a single continuation hop inside the
  /// off-main scan, which no test can land in deterministically without a seam
  /// that would dictate the snapshot and make the test circular. What this does
  /// pin is that acting on a recording while resume is running leaves the
  /// user's job intact.
  @Test("resume leaves alone a job the user restarted while it was scanning")
  func resumeSkipsJobsAlreadyInFlight() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    // A failure from a previous session whose cleanup could not be dispatched,
    // so it still holds the ids naming what is on Soniox.
    TranscriptionJob(
      fileId: "file-from-previous-session",
      transcriptionId: "transcription-from-previous-session",
      lastError: "Soniox error 503: busy"
    ).save(for: directory)
    let coordinator = harness.makeCoordinator()
    // Retry lands inside the window between resume starting and its scan
    // reading the record - which is where the real sweep enumerates and
    // deletes recording-sized scratch files, so it is not a microsecond wide.
    harness.sweepHandler = { [weak coordinator] in
      await MainActor.run { coordinator?.transcribe(recordingDirectory: directory) }
    }

    coordinator.resumePendingJobs()
    await harness.wait { coordinator.status(for: directory) == .completed }

    // The user's retry ran to completion: resume neither cancelled it nor wrote
    // the old failed record back over it.
    #expect(TranscriptDocument.load(for: directory) != nil)
    await harness.wait { TranscriptionJob.load(for: directory) == nil }
    #expect(TranscriptionJob.load(for: directory) == nil)
    // It started clean rather than re-polling a transcription that had already
    // failed, and the leftovers from the previous session were deleted.
    #expect(await harness.service.uploadCount == 1)
    #expect(await harness.service.createCount == 1)
    #expect(
      await harness.service.deletedTranscriptionIds.contains(
        "transcription-from-previous-session"))
  }

  // MARK: Minimum duration

  @Test("an automatic job is dropped when the recording is too short to be a call")
  func dropsAutomaticJobBelowDurationFloor() async throws {
    let harness = try TranscriptionHarness()
    harness.duration = 1.5
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.recordingFinished(recordingDirectory: directory)
    await harness.wait { TranscriptionJob.load(for: directory) == nil }

    #expect(await harness.service.uploadCount == 0)
    #expect(coordinator.status(for: directory) == .idle)
  }

  @Test("an automatic job is dropped when the duration cannot be read at all")
  func dropsAutomaticJobWithUnreadableDuration() async throws {
    let harness = try TranscriptionHarness()
    // What a recorder that died on startup leaves behind: a container that will
    // not open. The floor has to fail closed here, not wave it through.
    harness.duration = nil
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.recordingFinished(recordingDirectory: directory)
    await harness.wait { TranscriptionJob.load(for: directory) == nil }

    #expect(await harness.service.uploadCount == 0)
    #expect(coordinator.status(for: directory) == .idle)
  }

  /// A control, not a regression test: it holds with the floor removed entirely,
  /// because it asserts the absence of a behaviour. It catches an inverted
  /// comparison, not a missing floor.
  @Test("a manual job is transcribed however short the recording is")
  func manualJobIgnoresDurationFloor() async throws {
    let harness = try TranscriptionHarness()
    harness.duration = 1.5
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(await harness.service.uploadCount == 1)
  }

  /// Also a control, for the same reason as the test above.
  @Test("an automatic job runs when the recording is long enough")
  func runsAutomaticJobAboveDurationFloor() async throws {
    let harness = try TranscriptionHarness()
    harness.duration = 42
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.recordingFinished(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(await harness.service.uploadCount == 1)
  }

  /// `transcribe` reset the sidecar and dispatched remote DELETEs before
  /// `enqueue`'s in-flight guard could reject the request, so asking again for a
  /// running job destroyed that job's remote artifacts and erased its ids.
  @Test("asking again for a running job does not delete its remote artifacts")
  func repeatRequestLeavesRunningJobAlone() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setHoldsCompletion(true)
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .transcribing }

    coordinator.transcribe(recordingDirectory: directory)

    #expect(await harness.service.deletedFileIds.isEmpty)
    #expect(await harness.service.deletedTranscriptionIds.isEmpty)
    let job = try #require(TranscriptionJob.load(for: directory))
    #expect(job.transcriptionId == "transcription-1")

    coordinator.cancel(recordingDirectory: directory)
  }

  /// `.cancelling` is `isActive`, so a progress report arriving after the user
  /// pressed Cancel overwrote it and re-enabled the button.
  @Test("a progress report does not undo a cancellation")
  func progressDoesNotOverwriteCancelling() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setHoldsUpload(true)
    await harness.service.setHoldIgnoresCancellation(true)
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .uploading(fraction: 0.5) }

    coordinator.cancel(recordingDirectory: directory)
    #expect(coordinator.status(for: directory) == .cancelling)

    // A mix reports every 0.5s and runs for minutes on a long call, so a report
    // landing after the click is the normal case, not a rare one.
    await harness.service.emitProgress(.uploading(0.9))
    try await Task.sleep(for: .milliseconds(50))
    #expect(coordinator.status(for: directory) == .cancelling)

    await harness.service.setHoldIgnoresCancellation(false)
    await harness.service.setHoldsUpload(false)
  }

  // Quit can land after enqueue but before the job reaches the upload gate.
  @Test("suspend before the gate keeps the sidecar and uploads nothing")
  func suspendedBeforeGateKeepsSidecar() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    coordinator.suspendNewJobs()

    await harness.wait(upTo: 0.5) { await harness.service.uploadCount > 0 }
    #expect(await harness.service.uploadCount == 0)
    #expect(TranscriptionJob.load(for: directory) != nil, "sidecar was destroyed")
    #expect(coordinator.status(for: directory) == .queued)
  }

  // A job parked on the upload gate when quit arrives keeps its sidecar, so
  // the next launch resumes it instead of re-uploading.
  @Test("a waiter drained at quit keeps its sidecar")
  func drainedWaiterKeepsSidecar() async throws {
    let harness = try TranscriptionHarness()
    harness.uploadConcurrency = 1
    await harness.service.setHoldsUpload(true)
    let first = try harness.makeRecording("call-1")
    let second = try harness.makeRecording("call-2")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: first)
    await harness.wait { await harness.service.uploadsInFlight == 1 }
    coordinator.transcribe(recordingDirectory: second)
    // Long enough that `second`'s task has certainly reached the gate. It is
    // parked there rather than inside `upload`, which `uploadCount == 1` proves
    // - so the only way it can be resumed is the drain in `releaseUploadSlot`.
    try await Task.sleep(for: .milliseconds(300))
    #expect(await harness.service.uploadCount == 1, "second was not parked on the gate")

    coordinator.suspendNewJobs()
    await harness.service.setHoldsUpload(false)
    await harness.wait { coordinator.status(for: first) == .completed }
    // Give the drained waiter a chance to do the wrong thing.
    try await Task.sleep(for: .milliseconds(200))

    #expect(await harness.service.uploadCount == 1, "the drained waiter uploaded anyway")
    #expect(TranscriptionJob.load(for: second) != nil, "drained waiter lost its sidecar")
  }

  // Cancelling is the one case that does drop the sidecar.
  @Test("a cancelled waiter drops its sidecar")
  func cancelledWaiterDrops() async throws {
    let harness = try TranscriptionHarness()
    harness.uploadConcurrency = 1
    await harness.service.setHoldsUpload(true)
    let first = try harness.makeRecording("call-1")
    let second = try harness.makeRecording("call-2")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: first)
    await harness.wait { await harness.service.uploadsInFlight == 1 }
    coordinator.transcribe(recordingDirectory: second)
    await harness.wait { coordinator.status(for: second) == .queued }

    coordinator.cancel(recordingDirectory: second)
    await harness.wait { TranscriptionJob.load(for: second) == nil }
    #expect(TranscriptionJob.load(for: second) == nil)

    await harness.service.setHoldsUpload(false)
    await harness.wait { coordinator.status(for: first) == .completed }
  }

  // The job is read before the trash moves the directory, so the remote
  // DELETE still goes out for a recording the user deleted.
  @Test("forgetDeletedRecording deletes remote artifacts from the passed job")
  func forgetDeletedDispatchesDelete() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    let job = TranscriptionJob(fileId: "file-9", transcriptionId: "transcription-9")
    job.save(for: directory)
    let captured = TranscriptionJob.load(for: directory)
    try FileManager.default.removeItem(at: directory)

    coordinator.forgetDeletedRecording(recordingDirectory: directory, job: captured)
    await harness.wait { await harness.service.deletedFileIds == ["file-9"] }
    #expect(await harness.service.deletedFileIds == ["file-9"])
    #expect(await harness.service.deletedTranscriptionIds == ["transcription-9"])
  }

  // A refused DELETE must not take the record with it: that record is the only
  // thing naming audio that is still sitting on Soniox.
  @Test("a cleanup the server refuses keeps its marker for the next launch")
  func refusedCleanupKeepsItsMarker() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setDeleteSucceeds(false)
    let directory = try harness.makeRecording("call-1")
    TranscriptionJob(
      fileId: "file-1", transcriptionId: "transcription-1", awaitingRemoteDelete: true
    ).save(for: directory)
    let coordinator = harness.makeCoordinator()

    coordinator.resumePendingJobs()
    await harness.wait { await harness.service.deletedFileIds == ["file-1"] }
    // Long enough for a retirement to have landed if one were coming.
    try await Task.sleep(for: .milliseconds(200))

    #expect(TranscriptionJob.load(for: directory)?.awaitingRemoteDelete == true)
    #expect(TranscriptionJob.load(for: directory)?.fileId == "file-1")
  }

  // MARK: - Per-track jobs

  private func segment(_ speaker: Int, _ time: Double, _ text: String) -> TranscriptDocument {
    TranscriptDocument(
      segments: [TranscriptSegment(speaker: speaker, time: time, text: text)],
      language: "ru", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
  }

  @Test("a per-track recording runs a mic job and a far-end job and merges them")
  func perTrackJobsMerge() async throws {
    let harness = try TranscriptionHarness()
    harness.languageHints = ["ru", "en"]
    await harness.service.setPlannedRoles([.mic, .farEnd])
    await harness.service.setDocument(segment(0, 5, "mic words"), for: "transcription-1")
    await harness.service.setDocument(segment(2, 1, "far words"), for: "transcription-2")
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(await harness.service.uploadedRoles == [.mic, .farEnd])
    #expect(await harness.service.createdRoles == [.mic, .farEnd])
    #expect(await harness.service.configs.map(\.languageHints) == [["ru", "en"], ["ru", "en"]])
    let transcript = try #require(TranscriptDocument.load(for: directory))
    // One shared timeline; the mic is the one known speaker, rendered as -1.
    #expect(transcript.segments.map(\.text) == ["far words", "mic words"])
    #expect(transcript.segments.map(\.speaker) == [2, -1])
    #expect(
      Set(await harness.service.deletedTranscriptionIds) == ["transcription-1", "transcription-2"])
  }

  @Test("silence on the mic is not a failure when the far end has speech")
  func silentMicIsNotAFailure() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setPlannedRoles([.mic, .farEnd])
    await harness.service.setSilent("transcription-1")
    await harness.service.setDocument(segment(1, 1, "far words"), for: "transcription-2")
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(TranscriptDocument.load(for: directory)?.segments.map(\.text) == ["far words"])
  }

  @Test("silence on both sides is reported as no speech")
  func silenceOnBothSides() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setPlannedRoles([.mic, .farEnd])
    await harness.service.setSilent("transcription-1")
    await harness.service.setSilent("transcription-2")
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait {
      if case .error = coordinator.status(for: directory) { return true }
      return false
    }

    #expect(
      coordinator.status(for: directory)
        == .error(TranscriptionError.noSpeechDetected.localizedDescription))
    #expect(TranscriptDocument.load(for: directory) == nil)
  }

  /// Creating a transcription is what bills, so an id that was obtained must
  /// survive a failure on the next create and be resumed, never created again.
  @Test("a failed second create keeps the first part's paid id")
  func failedSecondCreateKeepsPaidId() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setPlannedRoles([.mic, .farEnd])
    await harness.service.setFailCreate(at: 2)
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }

    // Three attempts at creating, one of them failed: the mic is created once.
    #expect(await harness.service.createdRoles == [.mic, .farEnd])
    #expect(await harness.service.createCount == 3)
    #expect(await harness.service.uploadedRoles == [.mic, .farEnd])
  }

  @Test("a resumed job only does the work its parts have not done")
  func resumeSkipsFinishedParts() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    TranscriptionJob(
      parts: [
        .init(role: .mic, fileId: "file-m", transcriptionId: "paid-mic"),
        .init(role: .farEnd, fileId: "file-f"),
      ],
      languageHints: ["ru"]
    ).save(for: directory)
    let coordinator = harness.makeCoordinator()

    coordinator.resumePendingJobs()
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(await harness.service.planCount == 0)
    #expect(await harness.service.uploadCount == 0)
    #expect(await harness.service.createdRoles == [.farEnd])
  }

  @Test("a plan that has already paid wins over a changed track setting")
  func paidPlanWinsOverSettings() async throws {
    let harness = try TranscriptionHarness()
    // The service would now plan two jobs; the paid record says one.
    await harness.service.setPlannedRoles([.mic, .farEnd])
    let directory = try harness.makeRecording("call-1")
    TranscriptionJob(
      parts: [.init(role: .single, fileId: "file-1", transcriptionId: "paid-single")],
      languageHints: ["ru"]
    ).save(for: directory)
    let coordinator = harness.makeCoordinator()

    coordinator.resumePendingJobs()
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(await harness.service.planCount == 0)
    #expect(await harness.service.createCount == 0)
    #expect(await harness.service.fetchCount == 1)
  }

  /// The per-track build kept its paid-job ledger in this same file under
  /// `jobs`; a job it left behind has to keep resuming.
  @Test("a ledger written by the per-track build still decodes")
  func legacyLedgerDecodes() throws {
    let json = """
      {"createdAt":"2026-07-01T10:00:00Z","languageHints":["ru"],"separateTracks":true,
       "jobs":[{"role":"mic","fileId":"f1","transcriptionId":"t1"},{"role":"farEnd","fileId":"f2"}]}
      """
    let job = try JSONDecoder().decode(TranscriptionJob.self, from: Data(json.utf8))

    #expect(job.parts.map(\.role) == [.mic, .farEnd])
    #expect(job.transcriptionIds == ["t1"])
    #expect(job.fileIds == ["f1", "f2"])
    #expect(job.languageHints == ["ru"])
  }

  // MARK: - Per-run config

  @Test("a per-run override replaces Settings, and is the config every part is created with")
  func overrideReplacesSettings() async throws {
    let harness = try TranscriptionHarness()
    harness.languageHints = ["ru"]
    await harness.service.setPlannedRoles([.mic, .farEnd])
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()
    let override = TranscriptionConfig(
      languageHints: ["en"], diarization: true,
      context: SonioxContext(generalLines: "topic: launch", terms: "Blackbox", text: ""))

    coordinator.transcribe(recordingDirectory: directory, configOverride: override)
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(await harness.service.configs == [override, override])
  }

  @Test("a job resumed after planning keeps the config it was planned with")
  func resumedJobKeepsPlannedConfig() async throws {
    let harness = try TranscriptionHarness()
    harness.languageHints = ["de"]  // Settings changed since planning
    let directory = try harness.makeRecording("call-1")
    let planned = TranscriptionConfig(
      languageHints: ["en"], languageHintsStrict: true,
      context: SonioxContext(generalLines: "", terms: "Soniox", text: ""))
    TranscriptionJob(
      parts: [.init(role: .single, fileId: "file-1")], config: planned
    ).save(for: directory)
    let coordinator = harness.makeCoordinator()

    coordinator.resumePendingJobs()
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(await harness.service.configs == [planned])
  }

  @Test("a job record from before configs existed still resumes with its language hints")
  func legacyJobResumesWithHints() throws {
    let json = #"{"languageHints":["en","fr"],"jobs":[{"role":"single","fileId":"f"}]}"#
    let job = try JSONDecoder().decode(TranscriptionJob.self, from: Data(json.utf8))

    #expect(job.config == nil)
    #expect(job.effectiveConfig.languageHints == ["en", "fr"])
    #expect(job.effectiveConfig.separateTracks)
  }

  // MARK: - Review fixes

  @Test("turning auto-transcription off between two uploads stops the second and deletes the first")
  func consentWithdrawnBetweenUploads() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setPlannedRoles([.mic, .farEnd])
    await harness.service.setAfterUpload { @MainActor [harness] in harness.autoEnabled = false }
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.recordingFinished(recordingDirectory: directory)
    await harness.wait { await harness.service.deletedFileIds == ["file-1"] }

    #expect(await harness.service.uploadedRoles == [.mic])
    #expect(await harness.service.createCount == 0)
  }

  @Test("turning auto-transcription off after the first part is billed does not bill the second")
  func consentWithdrawnBetweenCreates() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setPlannedRoles([.mic, .farEnd])
    await harness.service.setAfterCreate { @MainActor [harness] in harness.autoEnabled = false }
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.recordingFinished(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(await harness.service.createdRoles == [.mic])
    // The part that was billed still delivers; the unbilled upload is cleaned up.
    #expect(TranscriptDocument.load(for: directory) != nil)
    #expect(Set(await harness.service.deletedFileIds) == ["file-1", "file-2"])
  }

  /// The skipped part's uploaded file exists only on Soniox. If its delete fails,
  /// the sidecar must still name it, or nothing ever will.
  @Test("a skipped part's uploaded file stays named until its delete is confirmed")
  func skippedUploadSurvivesFailedDelete() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setPlannedRoles([.mic, .farEnd])
    await harness.service.setAfterCreate { @MainActor [harness] in harness.autoEnabled = false }
    await harness.service.setDeleteSucceeds(false)
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.recordingFinished(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }
    await harness.wait { TranscriptionJob.load(for: directory)?.awaitingRemoteDelete == true }

    let job = try #require(TranscriptionJob.load(for: directory))
    #expect(job.fileIds.contains("file-2"))
    #expect(job.fileIds.contains("file-1"))
  }

  @Test("a job record that cannot be written stops the job before it bills")
  func unwritableRecordStopsBeforeBilling() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()
    await harness.service.setAfterUpload {
      // The disk fills, or the folder turns read-only, mid-job.
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o555], ofItemAtPath: directory.path)
    }
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: directory.path)
    }

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait {
      if case .error = coordinator.status(for: directory) { return true }
      return false
    }

    #expect(await harness.service.createCount == 0)
    #expect(await harness.service.deletedFileIds == ["file-1"])
  }

  @Test("a transcript is stamped with the model its parts were created with")
  func modelFrozenWithPlan() async throws {
    let harness = try TranscriptionHarness()
    harness.model = "stt-old"
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(await harness.service.configs.map(\.model) == ["stt-old"])
    #expect(TranscriptDocument.load(for: directory)?.model == "stt-old")
  }

  @Test("a recording pending its mixdown has a job record but does not start or resume")
  func pendingRecordingIsReservedNotRun() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.recordingPending(recordingDirectory: directory)
    coordinator.resumePendingJobs()
    try await Task.sleep(for: .milliseconds(150))

    #expect(TranscriptionJob.load(for: directory)?.isAutomatic == true)
    #expect(await harness.service.uploadCount == 0)

    coordinator.recordingFinished(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }
    #expect(await harness.service.uploadCount == 1)
  }

  @Test("quit landing during the last upload does not start a create")
  func suspendedBeforeCreateDoesNotBill() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()
    await harness.service.setAfterUpload { @MainActor in coordinator.suspendNewJobs() }

    coordinator.transcribe(recordingDirectory: directory)
    try await Task.sleep(for: .milliseconds(200))

    #expect(await harness.service.createCount == 0)
    // Left for the next launch to resume, with the uploaded file still named.
    #expect(TranscriptionJob.load(for: directory)?.fileIds == ["file-1"])
  }

  @Test("cancel landing during the last upload does not start a create")
  func cancelledBeforeCreateDoesNotBill() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()
    await harness.service.setAfterUpload { @MainActor in
      coordinator.cancel(recordingDirectory: directory)
    }

    coordinator.transcribe(recordingDirectory: directory)
    try await Task.sleep(for: .milliseconds(200))

    #expect(await harness.service.createCount == 0)
  }

  @Test("a reservation does not outlive the setting being turned off")
  func reservationReleasedWhenConsentGone() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.recordingPending(recordingDirectory: directory)
    #expect(coordinator.hasActiveJobs)
    harness.autoEnabled = false
    coordinator.recordingFinished(recordingDirectory: directory)

    #expect(!coordinator.hasActiveJobs)
  }

  @Test("a running job blocks moving the library")
  func activeJobBlocksMove() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()
    #expect(!coordinator.hasActiveJobs)

    coordinator.transcribe(recordingDirectory: directory)
    #expect(coordinator.hasActiveJobs)
    await harness.wait { coordinator.status(for: directory) == .completed }
    await harness.wait { !coordinator.hasActiveJobs }
  }

  // MARK: - Third review round

  @Test("a deleted recording's Soniox ids survive a failed delete and are retried at launch")
  func deletedRecordingCleanupSurvivesFailedDelete() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setDeleteSucceeds(false)
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    // What the delete action does: capture the job, trash the directory, then forget it.
    let job = TranscriptionJob(fileId: "file-1", transcriptionId: "t-1")
    try FileManager.default.removeItem(at: directory)
    coordinator.forgetDeletedRecording(recordingDirectory: directory, job: job)
    await harness.wait { await harness.service.deletedFileIds == ["file-1"] }

    let pending = TranscriptionCoordinator.pendingCleanupEntries(in: harness.cleanup)
    #expect(pending.count == 1, "the failed delete leaves the ids where launch can find them")
    #expect(
      pending.first?.job.fileIds == ["file-1"] && pending.first?.job.transcriptionIds == ["t-1"])

    await harness.service.setDeleteSucceeds(true)
    harness.makeCoordinator().resumePendingJobs()
    await harness.wait {
      TranscriptionCoordinator.pendingCleanupEntries(in: harness.cleanup).isEmpty
    }
    #expect(await harness.service.deletedTranscriptionIds.contains("t-1"))
  }

  @Test("a confirmed delete of a deleted recording leaves no cleanup record")
  func confirmedDeleteRetiresTheRecord() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()
    try FileManager.default.removeItem(at: directory)

    coordinator.forgetDeletedRecording(
      recordingDirectory: directory, job: TranscriptionJob(fileId: "file-1"))
    await harness.wait {
      TranscriptionCoordinator.pendingCleanupEntries(in: harness.cleanup).isEmpty
    }

    #expect(await harness.service.deletedFileIds == ["file-1"])
  }

  @Test("the ledger survives the save folder being moved or replaced")
  func ledgerIsOutsideTheLibrary() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setDeleteSucceeds(false)
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()
    try FileManager.default.removeItem(at: directory)
    coordinator.forgetDeletedRecording(
      recordingDirectory: directory, job: TranscriptionJob(fileId: "file-1"))
    await harness.wait { await harness.service.deletedFileIds == ["file-1"] }

    // The user points Blackbox at a different folder; the old one is never scanned again.
    try FileManager.default.removeItem(at: harness.root)

    #expect(TranscriptionCoordinator.pendingCleanupEntries(in: harness.cleanup).count == 1)
  }

  @Test("retrying a failed job whose delete then fails keeps the old ids in the ledger")
  func retryKeepsOldIdsUntilDeleteConfirmed() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setDeleteSucceeds(false)
    let directory = try harness.makeRecording("call-1")
    TranscriptionJob(
      parts: [.init(role: .single, fileId: "old-file", transcriptionId: "old-t")],
      lastError: "boom"
    ).save(for: directory)
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { await harness.service.deletedTranscriptionIds.contains("old-t") }

    let pending = TranscriptionCoordinator.pendingCleanupEntries(in: harness.cleanup)
    #expect(pending.count == 1)
    #expect(
      pending.first?.job.transcriptionIds == ["old-t"] && pending.first?.job.fileIds == ["old-file"]
    )
    // The new run started from nothing rather than polling the ids being deleted.
    #expect(!(TranscriptionJob.load(for: directory)?.transcriptionIds.contains("old-t") ?? false))
  }
}
