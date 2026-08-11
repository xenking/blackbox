import AVFoundation
import Foundation

// MARK: - Data Models

nonisolated struct RecordingMetadata: Codable, Sendable {
  var title: String
  var createdAt: Date
  var appName: String
  var speakers: [String: String]
  var perAppBundleID: String?
  var perAppName: String?
  var trackCount: Int?
  /// Role of each audio track, by index. Written since the 3-track format
  /// (`mixed`, `mic`, `system`). Absent on recordings made before it, which are
  /// resolved positionally by `RecordingTrackMap`.
  var tracks: [RecordingTrackRole]?

  static let fileName = "metadata.json"

  static func load(in directory: URL) -> RecordingMetadata? {
    let url = directory.appendingPathComponent(fileName)
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(RecordingMetadata.self, from: data)
  }

  func save(in directory: URL) throws {
    let url = directory.appendingPathComponent(Self.fileName)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(self)
    try data.write(to: url, options: .atomic)
  }
}

// MARK: - Track Roles

/// What a given audio track inside `audio.m4a` carries.
///
/// Track order is a *documented file-format* concern, not an internal detail:
/// tools that take a single audio stream (`ffmpeg` without `-map`, most
/// players' default track pick) read track 0, so track 0 must be the full mix.
nonisolated enum RecordingTrackRole: String, Codable, Sendable {
  /// Mic and system audio summed - the track a single-stream consumer gets.
  case mixed
  /// The local user's microphone alone.
  case mic
  /// Everything except the local user - the far end of the call.
  case system
  /// Legacy (pre-v0.7.0) per-app capture track.
  case perApp
}

/// Resolves track index -> role for any recording this app has ever written.
///
/// Recordings carry their layout in `metadata.tracks`. Older ones do not, so
/// they fall back to the positional layout that shipped with them. Every
/// consumer (AEC reference selection, transcription, the player's track picker)
/// must go through this rather than hard-coding indices, because the layouts
/// disagree about what index 0 and the last index mean.
nonisolated struct RecordingTrackMap: Sendable {
  let roles: [RecordingTrackRole]

  static func resolve(metadata: RecordingMetadata?, trackCount: Int) -> RecordingTrackMap {
    if let declared = metadata?.tracks, declared.count == trackCount {
      return RecordingTrackMap(roles: declared)
    }
    return RecordingTrackMap(roles: legacyRoles(trackCount: trackCount))
  }

  /// Layouts that shipped before `metadata.tracks` existed.
  private static func legacyRoles(trackCount: Int) -> [RecordingTrackRole] {
    switch trackCount {
    // v0.7.0+ dual-track: system first, mic last.
    case 2: return [.system, .mic]
    // pre-v0.7.0 triple-track: display-wide, per-app, mic.
    case 3: return [.system, .perApp, .mic]
    case ..<1: return []
    // Single track, or something unrecognised: treat the first as system and
    // any surplus as mic so callers still find a plausible pair.
    default: return [.system] + Array(repeating: .mic, count: trackCount - 1)
    }
  }

  func index(of role: RecordingTrackRole) -> Int? {
    roles.firstIndex(of: role)
  }

  var micIndex: Int? { index(of: .mic) }

  /// Track carrying only the far end - the AEC far-end reference, and the
  /// track to diarize when transcribing per-track. Prefers a dedicated per-app
  /// capture when one exists (legacy 3-track), else the system mix.
  var farEndIndex: Int? { index(of: .perApp) ?? index(of: .system) }

  /// Track a single-stream consumer should read. Only present once a recording
  /// has been rendered to the 3-track layout.
  var mixedIndex: Int? { index(of: .mixed) }
}

nonisolated struct ExportedSegment: Codable, Sendable {
  var speaker: String
  var time: String
  var text: String
}

nonisolated struct TranscriptDocument: Codable, Sendable {
  var segments: [TranscriptSegment]
  var language: String?
  var createdAt: Date

  nonisolated static func sidecarURL(for recordingURL: URL) -> URL {
    recordingURL.appendingPathComponent("transcript.json")
  }

  nonisolated static func load(for recordingURL: URL) -> TranscriptDocument? {
    let url = sidecarURL(for: recordingURL)
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(TranscriptDocument.self, from: data)
  }

  func save(for recordingURL: URL) throws {
    let url = Self.sidecarURL(for: recordingURL)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(self)
    try data.write(to: url, options: .atomic)
  }
}

nonisolated struct TranscriptSegment: Codable, Identifiable, Sendable {
  var id: UUID
  var speaker: Int
  var time: Double
  var text: String
  var endTime: Double?

  init(speaker: Int, time: Double, text: String, endTime: Double? = nil) {
    self.id = UUID()
    self.speaker = speaker
    self.time = time
    self.text = text
    self.endTime = endTime
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
    self.speaker = try container.decode(Int.self, forKey: .speaker)
    self.time = try container.decode(Double.self, forKey: .time)
    self.text = try container.decode(String.self, forKey: .text)
    self.endTime = try? container.decode(Double.self, forKey: .endTime)
  }
}

nonisolated struct SonioxTranscriptToken: Sendable, Equatable {
  var text: String
  var startMilliseconds: Double
  var endMilliseconds: Double
  var speaker: Int
  var language: String?
  var translationStatus: String?

  init(
    text: String,
    startMilliseconds: Double,
    endMilliseconds: Double,
    speaker: Int,
    language: String? = nil,
    translationStatus: String? = nil
  ) {
    self.text = text
    self.startMilliseconds = startMilliseconds
    self.endMilliseconds = endMilliseconds
    self.speaker = speaker
    self.language = language
    self.translationStatus = translationStatus
  }
}

nonisolated enum TranscriptionStatus: Equatable, Sendable {
  case idle
  case uploading
  case queued
  case transcribing
  case completed
  case error(String)
}

nonisolated enum TranscriptionError: Error, LocalizedError, Sendable {
  case uploadFailed(String)
  case transcriptionFailed(String)
  case pollTimeout
  /// Soniox reported terminal `status: error` for a job. Distinct from
  /// `transcriptionFailed` (which also covers transient HTTP failures) because
  /// only this one means the job produced nothing and its id is worthless.
  case jobFailed(String)

  var errorDescription: String? {
    switch self {
    case .uploadFailed(let msg): "Upload failed: \(msg)"
    case .transcriptionFailed(let msg): "Transcription failed: \(msg)"
    case .pollTimeout: "Transcription timed out"
    case .jobFailed(let msg): "Transcription failed: \(msg)"
    }
  }
}

// MARK: - Paid Job Ledger

/// Which side of the call a Soniox job covers.
nonisolated enum TranscriptionJobRole: String, Codable, Sendable {
  case mic
  case farEnd
  /// One job over the whole recording (mixed track, or a file with nothing to split).
  case single
}

/// The Soniox jobs a recording has already been billed for.
///
/// The async API bills input audio when a transcription is *created*, not when
/// its transcript is fetched, so a job id is money already spent. Persisting it
/// next to the recording is what makes a paid job survive switching recordings,
/// quitting the app, or a crash: the next attempt resumes that id instead of
/// uploading and paying again. Nothing here may be deleted remotely until its
/// transcript has actually been fetched.
nonisolated struct TranscriptionJobLedger: Codable, Sendable {
  nonisolated struct Job: Codable, Sendable {
    var role: TranscriptionJobRole
    /// Uploaded file. Storage only - uploading is not what gets billed.
    var fileId: String?
    /// Created transcription. Once set, this recording has been charged.
    var transcriptionId: String?
  }

  var jobs: [Job]
  var languageHints: [String]
  var separateTracks: Bool
  var createdAt: Date

  static let fileName = "transcription-job.json"

  static func load(in directory: URL) -> TranscriptionJobLedger? {
    let url = directory.appendingPathComponent(fileName)
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(TranscriptionJobLedger.self, from: data)
  }

  func save(in directory: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(
      to: directory.appendingPathComponent(Self.fileName), options: .atomic)
  }

  static func remove(in directory: URL) throws {
    let url = directory.appendingPathComponent(fileName)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }

  /// Ids worth resuming: a job that already has a transcription id.
  var hasPaidWork: Bool { jobs.contains { $0.transcriptionId != nil } }
}

/// Serializes read-modify-write on the ledger file. The mic and far-end jobs run
/// concurrently and both record their ids, so unsynchronised writes would lose
/// one - and a lost id is a paid job that can never be resumed.
actor LedgerStore {
  private let directory: URL
  private var ledger: TranscriptionJobLedger

  init(directory: URL, desired: TranscriptionJobLedger) throws {
    self.directory = directory
    if let existing = TranscriptionJobLedger.load(in: directory), existing.hasPaidWork {
      ledger = existing
    } else {
      ledger = desired
      try desired.save(in: directory)
    }
  }

  func snapshot() -> TranscriptionJobLedger { ledger }

  func fileId(for role: TranscriptionJobRole) -> String? {
    ledger.jobs.first { $0.role == role }?.fileId
  }

  func transcriptionId(for role: TranscriptionJobRole) -> String? {
    ledger.jobs.first { $0.role == role }?.transcriptionId
  }

  func setFileId(_ id: String, for role: TranscriptionJobRole) throws {
    try mutate(role) { $0.fileId = id }
  }

  func setTranscriptionId(_ id: String, for role: TranscriptionJobRole) throws {
    try mutate(role) { $0.transcriptionId = id }
  }

  /// Forgets a job that failed terminally: its id bought nothing, so keeping it
  /// would make every retry re-poll a permanently failed transcription.
  func clear(role: TranscriptionJobRole) throws {
    try mutate(role) {
      $0.fileId = nil
      $0.transcriptionId = nil
    }
  }

  func remoteIds() -> (transcriptionIds: [String], fileIds: [String]) {
    (ledger.jobs.compactMap(\.transcriptionId), ledger.jobs.compactMap(\.fileId))
  }

  /// Called only after the transcript sidecar is atomically committed.
  func finish() throws {
    try TranscriptionJobLedger.remove(in: directory)
  }

  private func mutate(
    _ role: TranscriptionJobRole,
    _ change: (inout TranscriptionJobLedger.Job) -> Void
  ) throws {
    guard let index = ledger.jobs.firstIndex(where: { $0.role == role }) else {
      throw TranscriptionError.transcriptionFailed("ledger is missing \(role.rawValue) job")
    }
    change(&ledger.jobs[index])
    try ledger.save(in: directory)
  }
}

// MARK: - Soniox API Client

final class TranscriptionService {
  private let apiKey: String
  private static let baseURL = "https://api.soniox.com"

  init(apiKey: String) {
    self.apiKey = apiKey
  }

  /// Transcribes a recording, resuming any Soniox job it has already paid for.
  ///
  /// The async API bills input audio when a job is *created*, not when its
  /// transcript is fetched, so a job id on disk is money already spent. Two rules
  /// follow and both are load-bearing: a pending paid plan wins over the caller's
  /// current mode, and no remote object is deleted before its transcript is in hand.
  func transcribe(
    fileURL: URL,
    languageHints: [String],
    separateTracks: Bool,
    onStatus: @escaping @MainActor (TranscriptionStatus) -> Void
  ) async throws -> TranscriptDocument {
    let directory = fileURL.deletingLastPathComponent()
    let asset = AVURLAsset(url: fileURL)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let metadata = RecordingMetadata.load(in: directory)
    let map = RecordingTrackMap.resolve(metadata: metadata, trackCount: tracks.count)

    let desiredPlan = Self.planJobs(
      separateTracks: separateTracks, map: map, trackCount: tracks.count)
    let store = try LedgerStore(
      directory: directory,
      desired: TranscriptionJobLedger(
        jobs: desiredPlan.map { .init(role: $0.role, fileId: nil, transcriptionId: nil) },
        languageHints: languageHints,
        separateTracks: separateTracks,
        createdAt: .now))
    let ledger = await store.snapshot()
    let plan = try Self.planJobs(
      for: ledger.jobs.map(\.role), map: map, trackCount: tracks.count)

    if ledger.hasPaidWork {
      Log.info(
        Log.transcription, "transcription",
        "resuming \(ledger.jobs.count) already-billed job(s); current settings ignored for this run"
      )
    }

    var byRole: [TranscriptionJobRole: TranscriptDocument] = [:]
    try await withThrowingTaskGroup(of: (TranscriptionJobRole, TranscriptDocument).self) {
      group in
      for job in plan {
        group.addTask {
          let document = try await self.runJob(
            job, fileURL: fileURL, languageHints: ledger.languageHints, store: store,
            onStatus: onStatus)
          return (job.role, document)
        }
      }
      for try await (role, document) in group { byRole[role] = document }
    }
    let document = Self.combine(byRole)

    let ids = try await Self.commitCompletedTranscript(
      document, in: directory, store: store)
    fireAndForgetCleanup(transcriptionIds: ids.transcriptionIds, fileIds: ids.fileIds)
    onStatus(.completed)
    return document
  }

  /// Commits local output before releasing the paid remote job. Kept separate
  /// so the ordering is testable without contacting Soniox.
  static func commitCompletedTranscript(
    _ document: TranscriptDocument,
    in directory: URL,
    store: LedgerStore
  ) async throws -> (transcriptionIds: [String], fileIds: [String]) {
    try document.save(for: directory)
    let ids = await store.remoteIds()
    try await store.finish()
    return ids
  }

  /// One Soniox job: which side of the call it covers, which track feeds it, and
  /// whether that side needs speaker splitting.
  struct PlannedJob: Sendable {
    let role: TranscriptionJobRole
    /// Track to upload. `nil` means "no single track carries this" - the upload is
    /// mixed on the fly instead.
    let trackIndex: Int?
    let diarization: Bool
  }

  static func planJobs(
    separateTracks: Bool, map: RecordingTrackMap, trackCount: Int
  ) -> [PlannedJob] {
    if separateTracks, let mic = map.micIndex, let farEnd = map.farEndIndex, mic != farEnd,
      (0..<trackCount).contains(mic), (0..<trackCount).contains(farEnd)
    {
      return [
        PlannedJob(role: .mic, trackIndex: mic, diarization: false),
        PlannedJob(role: .farEnd, trackIndex: farEnd, diarization: true),
      ]
    }
    // A rendered `mixed` track is already the full join, so it is uploaded as-is.
    return [PlannedJob(role: .single, trackIndex: map.mixedIndex, diarization: true)]
  }

  /// Reconstructs the plan from a paid ledger. The current settings cannot
  /// change which paid jobs are resumed.
  private static func planJobs(
    for roles: [TranscriptionJobRole], map: RecordingTrackMap, trackCount: Int
  ) throws -> [PlannedJob] {
    guard !roles.isEmpty, Set(roles).count == roles.count else {
      throw TranscriptionError.transcriptionFailed("invalid transcription job ledger")
    }
    return try roles.map { role in
      switch role {
      case .mic:
        guard let index = map.micIndex, (0..<trackCount).contains(index) else {
          throw TranscriptionError.transcriptionFailed("recording no longer has a microphone track")
        }
        return PlannedJob(role: .mic, trackIndex: index, diarization: false)
      case .farEnd:
        guard let index = map.farEndIndex, (0..<trackCount).contains(index) else {
          throw TranscriptionError.transcriptionFailed("recording no longer has a desktop track")
        }
        return PlannedJob(role: .farEnd, trackIndex: index, diarization: true)
      case .single:
        return PlannedJob(role: .single, trackIndex: map.mixedIndex, diarization: true)
      }
    }
  }

  private func runJob(
    _ job: PlannedJob,
    fileURL: URL,
    languageHints: [String],
    store: LedgerStore,
    onStatus: @escaping @MainActor (TranscriptionStatus) -> Void
  ) async throws -> TranscriptDocument {
    if let paid = await store.transcriptionId(for: job.role) {
      Log.info(
        Log.transcription, "transcription",
        "resuming paid job \(paid) (\(job.role.rawValue))")
      return try await pollAndFetch(
        transcriptionId: paid, role: job.role, store: store, onStatus: onStatus)
    }

    var fileId = await store.fileId(for: job.role)
    if fileId == nil {
      onStatus(.uploading)
      let uploadURL = try await Self.uploadURL(for: job, fileURL: fileURL)
      defer {
        if uploadURL != fileURL { try? FileManager.default.removeItem(at: uploadURL) }
      }
      let uploaded = try await uploadFile(uploadURL)
      try await store.setFileId(uploaded, for: job.role)
      fileId = uploaded
    }
    guard let fileId else { throw TranscriptionError.uploadFailed("missing file id") }

    onStatus(.queued)
    let transcriptionId = try await createTranscription(
      fileId: fileId, languageHints: languageHints, enableDiarization: job.diarization)
    do {
      try await store.setTranscriptionId(transcriptionId, for: job.role)
    } catch {
      // Billed but unrecordable. Put the id somewhere durable anyway so the work
      // can still be recovered by hand instead of silently paid for twice.
      Log.error(
        Log.transcription, "transcription",
        "PAID job \(transcriptionId) could not be recorded: \(error.localizedDescription)")
      throw error
    }

    return try await pollAndFetch(
      transcriptionId: transcriptionId, role: job.role, store: store, onStatus: onStatus)
  }

  private static func uploadURL(for job: PlannedJob, fileURL: URL) async throws -> URL {
    if let index = job.trackIndex {
      return try await extractTrack(from: fileURL, at: index)
    }
    return try await mixTracks(from: fileURL)
  }

  private func pollAndFetch(
    transcriptionId: String,
    role: TranscriptionJobRole,
    store: LedgerStore,
    onStatus: @escaping @MainActor (TranscriptionStatus) -> Void
  ) async throws -> TranscriptDocument {
    do {
      try await pollUntilComplete(transcriptionId: transcriptionId, onStatus: onStatus)
    } catch let error as TranscriptionError {
      // Only a terminal API failure means the id bought nothing. Cancellation,
      // network drops and HTTP errors all keep it for the next attempt.
      if case .jobFailed = error {
        try await store.clear(role: role)
        fireAndForgetCleanup(transcriptionIds: [transcriptionId], fileIds: [])
      }
      throw error
    }
    return try await fetchTranscript(transcriptionId: transcriptionId)
  }

  /// Folds per-role transcripts into one document on a shared timeline.
  private static func combine(
    _ byRole: [TranscriptionJobRole: TranscriptDocument]
  ) -> TranscriptDocument {
    if let single = byRole[.single] { return single }
    let local = byRole[.mic].map { document in
      var adjusted = document
      adjusted.segments = document.segments.map {
        var segment = $0
        segment.speaker = -1
        return segment
      }
      return adjusted
    }
    let remote = byRole[.farEnd].map { document in
      var adjusted = document
      adjusted.segments = document.segments.map {
        var segment = $0
        segment.speaker = max(0, segment.speaker)
        return segment
      }
      return adjusted
    }
    return mergeDocuments([local, remote].compactMap { $0 })
  }

  // MARK: - Audio Mixing & Export

  /// Mixes the mic and far-end tracks into a single-track M4A for export.
  static func mixTracks(from fileURL: URL) async throws -> URL {
    let asset = AVURLAsset(url: fileURL)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    guard tracks.count >= 2 else { return fileURL }

    let metadata = RecordingMetadata.load(in: fileURL.deletingLastPathComponent())
    let trackMap = RecordingTrackMap.resolve(metadata: metadata, trackCount: tracks.count)
    let tracksToMix: [AVAssetTrack]
    if let micTrackIndex = trackMap.micIndex,
      let farEndTrackIndex = trackMap.farEndIndex,
      micTrackIndex != farEndTrackIndex,
      tracks.indices.contains(micTrackIndex),
      tracks.indices.contains(farEndTrackIndex)
    {
      tracksToMix = [tracks[micTrackIndex], tracks[farEndTrackIndex]]
    } else {
      tracksToMix = tracks.enumerated().compactMap { index, track in
        trackMap.roles[index] == .mixed ? nil : track
      }
    }
    guard !tracksToMix.isEmpty else {
      throw TranscriptionError.transcriptionFailed("no audio tracks available for mixing")
    }

    let duration = try await asset.load(.duration)
    let mixedURL = try await exportTracks(
      tracksToMix,
      duration: duration,
      temporaryNamePrefix: "blackbox-mixed"
    )
    Log.info(
      Log.transcription, "transcription",
      "mixed \(tracksToMix.count) tracks into single file")
    return mixedURL
  }

  /// Exports a single-track M4A copy. Mixes tracks first if multi-track.
  static func exportM4A(from fileURL: URL, to outputURL: URL) async throws {
    let asset = AVURLAsset(url: fileURL)
    let tracks = try await asset.loadTracks(withMediaType: .audio)

    if tracks.count >= 2 {
      let mixed = try await mixTracks(from: fileURL)
      defer {
        if mixed != fileURL {
          try? FileManager.default.removeItem(at: mixed)
        }
      }
      try FileManager.default.copyItem(at: mixed, to: outputURL)
    } else {
      try FileManager.default.copyItem(at: fileURL, to: outputURL)
    }
  }

  /// Internal rather than private so tests can prove the per-track split without
  /// a live API key: this is the step that decides what audio Soniox actually hears.
  static func extractTrack(from fileURL: URL, at index: Int) async throws -> URL {
    let asset = AVURLAsset(url: fileURL)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    guard tracks.indices.contains(index) else {
      throw TranscriptionError.transcriptionFailed("audio track \(index) is unavailable")
    }
    let duration = try await asset.load(.duration)
    return try await exportTracks(
      [tracks[index]],
      duration: duration,
      temporaryNamePrefix: "blackbox-track"
    )
  }

  private static func exportTracks(
    _ sourceTracks: [AVAssetTrack],
    duration: CMTime,
    temporaryNamePrefix: String
  ) async throws -> URL {
    let composition = AVMutableComposition()
    for sourceTrack in sourceTracks {
      guard
        let compositionTrack = composition.addMutableTrack(
          withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
      else {
        throw TranscriptionError.transcriptionFailed("could not create composition audio track")
      }
      try compositionTrack.insertTimeRange(
        CMTimeRange(start: .zero, duration: duration),
        of: sourceTrack,
        at: .zero
      )
    }

    let tempURL =
      FileManager.default.temporaryDirectory
      .appendingPathComponent("\(temporaryNamePrefix)-\(UUID().uuidString).m4a")
    var didExport = false
    defer {
      if !didExport {
        try? FileManager.default.removeItem(at: tempURL)
      }
    }
    guard
      let exporter = AVAssetExportSession(
        asset: composition, presetName: AVAssetExportPresetAppleM4A)
    else {
      throw TranscriptionError.transcriptionFailed("could not create export session")
    }

    do {
      try await exporter.export(to: tempURL, as: .m4a)
    } catch {
      throw TranscriptionError.transcriptionFailed(
        "audio export failed: \(error.localizedDescription)")
    }
    didExport = true
    return tempURL
  }

  // MARK: - Upload

  private func uploadFile(_ fileURL: URL) async throws -> String {
    let boundary = UUID().uuidString
    let filename = fileURL.lastPathComponent

    // Build multipart body as a temp file to avoid loading entire audio into memory
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString + ".multipart")
    FileManager.default.createFile(atPath: tempURL.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: tempURL) }

    guard let output = OutputStream(url: tempURL, append: false) else {
      throw TranscriptionError.uploadFailed("failed to create temp file for upload")
    }
    output.open()

    let header = Data(
      "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: audio/mp4\r\n\r\n"
        .utf8)
    header.withUnsafeBytes { buf in
      _ = output.write(buf.bindMemory(to: UInt8.self).baseAddress!, maxLength: header.count)
    }

    // Stream file content in 64KB chunks
    guard let input = InputStream(url: fileURL) else {
      output.close()
      throw TranscriptionError.uploadFailed("failed to open audio file for reading")
    }
    input.open()
    let bufferSize = 65536
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while input.hasBytesAvailable {
      let bytesRead = input.read(buffer, maxLength: bufferSize)
      if bytesRead > 0 {
        _ = output.write(buffer, maxLength: bytesRead)
      } else {
        break
      }
    }
    input.close()

    let footer = Data("\r\n--\(boundary)--\r\n".utf8)
    footer.withUnsafeBytes { buf in
      _ = output.write(buf.bindMemory(to: UInt8.self).baseAddress!, maxLength: footer.count)
    }
    output.close()

    var request = try makeRequest(.post, "/v1/files")
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    let (data, response) = try await URLSession.shared.upload(for: request, fromFile: tempURL)
    try checkHTTPResponse(response, data: data, context: "upload")

    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let fileId = json?["id"] as? String else {
      throw TranscriptionError.uploadFailed("missing file id in response")
    }
    Log.info(Log.transcription, "transcription", "uploaded file: \(fileId)")
    return fileId
  }

  private func createTranscription(
    fileId: String,
    languageHints: [String],
    enableDiarization: Bool
  ) async throws -> String {
    let config = Self.transcriptionConfiguration(
      fileId: fileId,
      languageHints: languageHints,
      enableDiarization: enableDiarization
    )

    var request = try makeRequest(.post, "/v1/transcriptions")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: config)

    let (data, response) = try await URLSession.shared.data(for: request)
    try checkHTTPResponse(response, data: data, context: "create transcription")

    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let transcriptionId = json?["id"] as? String else {
      throw TranscriptionError.transcriptionFailed("missing transcription id")
    }
    Log.info(
      Log.transcription, "transcription", "created transcription: \(transcriptionId)")
    return transcriptionId
  }

  /// A transcription request deliberately carries no inferred context. Context
  /// is an accuracy bias, not a source of truth: Blackbox has no pre-recording
  /// agenda or participant data, and must not bias the desktop-only job toward
  /// the local speaker from a transcript it does not yet have.
  static func transcriptionConfiguration(
    fileId: String,
    languageHints: [String],
    enableDiarization: Bool
  ) -> [String: Any] {
    [
      "model": "stt-async-v5",
      "file_id": fileId,
      "language_hints": languageHints,
      "enable_speaker_diarization": enableDiarization,
      "enable_language_identification": true,
    ]
  }

  // MARK: - Poll

  private func pollUntilComplete(
    transcriptionId: String,
    onStatus: @escaping @MainActor (TranscriptionStatus) -> Void
  ) async throws {
    var didReportTranscribing = false

    // First minute at 2s, then 5s: 1,458 polls span two hours.
    for attempt in 0..<1_458 {
      try Task.checkCancellation()
      try await Task.sleep(for: attempt < 30 ? .seconds(2) : .seconds(5))

      let request = try makeRequest(.get, "/v1/transcriptions/\(transcriptionId)")
      let data: Data
      let response: URLResponse
      do {
        (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTPResponse(response, data: data, context: "poll status")
      } catch let error as URLError
        where [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(
          error.code)
      {
        Log.error(
          Log.transcription, "transcription",
          "poll network error, retrying: \(error.localizedDescription)")
        continue
      }

      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      let status = json?["status"] as? String

      switch status {
      case "queued":
        onStatus(.queued)
      case "processing" where !didReportTranscribing:
        didReportTranscribing = true
        onStatus(.transcribing)
      case "completed":
        Log.info(Log.transcription, "transcription", "completed: \(transcriptionId)")
        return
      case "error":
        let message =
          json?["error_message"] as? String
          ?? json?["error_type"] as? String
          ?? "unknown error"
        throw TranscriptionError.jobFailed(message)
      default:
        break
      }
    }
    throw TranscriptionError.pollTimeout
  }

  // MARK: - Fetch Transcript

  private func fetchTranscript(
    transcriptionId: String
  ) async throws -> TranscriptDocument {
    let request = try makeRequest(
      .get, "/v1/transcriptions/\(transcriptionId)/transcript")
    let (data, response) = try await URLSession.shared.data(for: request)
    try checkHTTPResponse(response, data: data, context: "fetch transcript")

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let rawTokens = json["tokens"] as? [[String: Any]], !rawTokens.isEmpty
    else {
      throw TranscriptionError.transcriptionFailed("empty or invalid transcript response")
    }

    return Self.groupTokensIntoDocument(Self.tokens(from: rawTokens))
  }

  // MARK: - Transcript Grouping

  nonisolated static func languageHints(from value: String) -> [String] {
    let hints =
      value
      .split(separator: ",")
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return hints.isEmpty ? ["ru"] : hints
  }

  nonisolated static func groupTokensIntoDocument(
    _ tokens: [SonioxTranscriptToken]
  ) -> TranscriptDocument {
    let transcriptTokens = tokens.filter { $0.translationStatus != "translation" }
    var segments: [TranscriptSegment] = []
    var currentSpeaker: Int?
    var currentText = ""
    var currentStart = 0.0
    var currentEnd = 0.0
    var previousToken: SonioxTranscriptToken?

    func appendCurrentSegment() {
      guard let currentSpeaker else { return }
      let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return }
      segments.append(
        TranscriptSegment(
          speaker: currentSpeaker,
          time: currentStart,
          text: text,
          endTime: currentEnd
        )
      )
    }

    for token in transcriptTokens {
      let start = token.startMilliseconds / 1_000
      let end = token.endMilliseconds / 1_000
      let shouldStartNewSegment: Bool
      if let currentSpeaker, let previousToken {
        let previousEnd = previousToken.endMilliseconds / 1_000
        let speakerChanged = token.speaker != currentSpeaker
        let hasGap = start - previousEnd > 0.8
        let shouldBreakLongSentence =
          Self.endsSentence(previousToken.text)
          && previousEnd - currentStart > 12
        shouldStartNewSegment = speakerChanged || hasGap || shouldBreakLongSentence
      } else {
        shouldStartNewSegment = true
      }

      if shouldStartNewSegment {
        appendCurrentSegment()
        currentSpeaker = token.speaker
        currentText = ""
        currentStart = start
      }
      currentText += token.text
      currentEnd = end
      previousToken = token
    }
    appendCurrentSegment()

    let language = transcriptTokens.first(where: { $0.language != nil })?.language
    return TranscriptDocument(segments: segments, language: language, createdAt: Date())
  }

  nonisolated static func mergeDocuments(
    _ documents: [TranscriptDocument]
  ) -> TranscriptDocument {
    let indexedSegments = documents.flatMap(\.segments).enumerated().map {
      (index: $0.offset, segment: $0.element)
    }
    let segments = indexedSegments.sorted {
      $0.segment.time == $1.segment.time
        ? $0.index < $1.index
        : $0.segment.time < $1.segment.time
    }
    let language = documents.compactMap(\.language).first
    let createdAt = documents.map(\.createdAt).min() ?? Date()
    return TranscriptDocument(
      segments: segments.map { $0.segment },
      language: language,
      createdAt: createdAt
    )
  }

  nonisolated private static func endsSentence(_ text: String) -> Bool {
    guard let finalCharacter = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
      return false
    }
    return ".!?…".contains(finalCharacter)
  }

  private static func tokens(from rawTokens: [[String: Any]]) -> [SonioxTranscriptToken] {
    let reservedSpeakerIDs = Set(
      rawTokens
        .compactMap { rawSpeakerIdentifier(in: $0) }
        .compactMap(Int.init)
        .filter { $0 >= 0 }
    )
    var opaqueSpeakerIDs: [String: Int] = [:]
    var nextSpeakerID = 0

    func speakerID(for rawToken: [String: Any]) -> Int {
      guard let identifier = rawSpeakerIdentifier(in: rawToken) else { return 0 }
      if let numericID = Int(identifier), numericID >= 0 {
        return numericID
      }
      if let existingID = opaqueSpeakerIDs[identifier] {
        return existingID
      }
      while reservedSpeakerIDs.contains(nextSpeakerID) {
        nextSpeakerID += 1
      }
      let assignedID = nextSpeakerID
      opaqueSpeakerIDs[identifier] = assignedID
      nextSpeakerID += 1
      return assignedID
    }

    return rawTokens.map { rawToken in
      token(from: rawToken, speaker: speakerID(for: rawToken))
    }
  }

  private static func rawSpeakerIdentifier(in rawToken: [String: Any]) -> String? {
    if let value = rawToken["speaker"] as? String, !value.isEmpty {
      return value
    }
    if let value = rawToken["speaker"] as? Int {
      return String(value)
    }
    if let value = rawToken["speaker"] as? NSNumber {
      return String(value.intValue)
    }
    return nil
  }

  private static func token(
    from rawToken: [String: Any],
    speaker: Int
  ) -> SonioxTranscriptToken {
    SonioxTranscriptToken(
      text: rawToken["text"] as? String ?? "",
      startMilliseconds: numericValue(rawToken["start_ms"]),
      endMilliseconds: numericValue(rawToken["end_ms"]),
      speaker: speaker,
      language: rawToken["language"] as? String,
      translationStatus: rawToken["translation_status"] as? String
    )
  }

  private static func numericValue(_ value: Any?) -> Double {
    if let value = value as? Double { return value }
    if let value = value as? Int { return Double(value) }
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String, let parsed = Double(value) { return parsed }
    return 0
  }

  // MARK: - Cleanup

  private func fireAndForgetCleanup(transcriptionIds: [String], fileIds: [String]) {
    let key = apiKey
    Task.detached {
      await TranscriptionService.cleanup(
        transcriptionIds: transcriptionIds, fileIds: fileIds, apiKey: key)
    }
  }

  nonisolated private static func cleanup(
    transcriptionIds: [String], fileIds: [String], apiKey: String
  ) async {
    let base = "https://api.soniox.com"
    for tId in transcriptionIds {
      guard let url = URL(string: "\(base)/v1/transcriptions/\(tId)") else { continue }
      var req = URLRequest(url: url)
      req.httpMethod = "DELETE"
      req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
      _ = try? await URLSession.shared.data(for: req)
    }
    for fId in fileIds {
      guard let url = URL(string: "\(base)/v1/files/\(fId)") else { continue }
      var req = URLRequest(url: url)
      req.httpMethod = "DELETE"
      req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
      _ = try? await URLSession.shared.data(for: req)
    }
  }

  // MARK: - Helpers

  private enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
  }

  private func makeRequest(_ method: HTTPMethod, _ path: String) throws -> URLRequest {
    guard let url = URL(string: "\(Self.baseURL)\(path)") else {
      throw TranscriptionError.transcriptionFailed("invalid URL: \(path)")
    }
    var request = URLRequest(url: url)
    request.httpMethod = method.rawValue
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    return request
  }

  private func checkHTTPResponse(
    _ response: URLResponse, data: Data, context: String
  ) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? "no body"
      Log.error(
        Log.transcription, "transcription",
        "\(context) failed (\(http.statusCode)): \(body)")

      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      let validationMessages =
        (json?["validation_errors"] as? [[String: Any]])?
        .compactMap { $0["message"] as? String }
        .filter { !$0.isEmpty } ?? []
      let message = json?["message"] as? String ?? json?["error"] as? String
      let apiMessage: String
      if !validationMessages.isEmpty {
        apiMessage = ([message].compactMap { $0 } + validationMessages)
          .joined(separator: ": ")
      } else {
        apiMessage = message ?? "HTTP \(http.statusCode)"
      }
      throw TranscriptionError.transcriptionFailed("\(context): \(apiMessage)")
    }
  }
}
