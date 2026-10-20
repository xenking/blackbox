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

  init(
    title: String, createdAt: Date, appName: String, speakers: [String: String],
    perAppBundleID: String? = nil, perAppName: String? = nil, trackCount: Int? = nil,
    tracks: [RecordingTrackRole]? = nil
  ) {
    self.title = title
    self.createdAt = createdAt
    self.appName = appName
    self.speakers = speakers
    self.perAppBundleID = perAppBundleID
    self.perAppName = perAppName
    self.trackCount = trackCount
    self.tracks = tracks
  }

  /// Hand-written for the same reason `TranscriptionJob`'s is: the synthesized
  /// decoder throws on a missing key rather than falling back to the property's
  /// default, and `load` swallows that with `try?`. Adding one non-optional
  /// field would therefore make every metadata file a previous build wrote
  /// undecodable at once - and the three rename paths rebuild a fresh record
  /// from `load(...) ?? RecordingMetadata(...)` and write it back, so a single
  /// unreadable decode plus one rename permanently loses the title, the date and
  /// every speaker name. Every key is optional here so the format stays
  /// additive.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    appName = try container.decodeIfPresent(String.self, forKey: .appName) ?? ""
    speakers = try container.decodeIfPresent([String: String].self, forKey: .speakers) ?? [:]
    perAppBundleID = try container.decodeIfPresent(String.self, forKey: .perAppBundleID)
    perAppName = try container.decodeIfPresent(String.self, forKey: .perAppName)
    trackCount = try container.decodeIfPresent(Int.self, forKey: .trackCount)
    tracks = try container.decodeIfPresent([RecordingTrackRole].self, forKey: .tracks)
  }

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

/// Where a recording's files live and how to find them. Centralised because
/// two rules here are easy to get subtly wrong in a copy: which of the two
/// audio files is the current one, and how to enumerate recording directories.
nonisolated enum RecordingStore {
  static let audioName = "audio.m4a"
  static let processedAudioName = "audio-processed.m4a"

  /// Echo cancellation writes here and moves the result into place only on
  /// success. The name lives with its two siblings rather than on
  /// `AECProcessor`, because the size scanners have to know about all three -
  /// an in-flight run is a recording-sized third file, and neither the
  /// recordings list nor the storage total could see it from over there.
  private static let partialProcessedPrefix = "audio-processed-partial-"

  /// Unique per run: two runs for one recording sharing a scratch path meant
  /// the second one's cleanup unlinked the first one's output mid-write.
  static func partialProcessedName() -> String {
    "\(partialProcessedPrefix)\(UUID().uuidString).m4a"
  }

  static func isPartialProcessedName(_ name: String) -> Bool {
    name.hasPrefix(partialProcessedPrefix)
  }

  /// The echo-cancelled output when the user has run AEC, otherwise the raw
  /// capture. Nil when the directory holds neither.
  static func audioURL(in recordingDirectory: URL) -> URL? {
    let processed = recordingDirectory.appendingPathComponent(processedAudioName)
    if isUsable(processed) { return processed }
    let raw = recordingDirectory.appendingPathComponent(audioName)
    return isUsable(raw) ? raw : nil
  }

  /// Exists *and* has bytes. A killed echo-cancellation run used to leave a
  /// zero-byte `audio-processed.m4a`, and because this method prefers the
  /// processed file, that empty file silently became the playback, export and
  /// transcription source - so a recording whose audio was perfectly intact
  /// reported "Could not load audio: Cannot Open".
  static func isUsable(_ url: URL) -> Bool {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
    return size > 0
  }

  /// Enumerates by name rather than with `contentsOfDirectory(at:)`, which
  /// resolves symlinks in its base and hands back a different spelling of the
  /// same path than the recorder produces. Transcription status is keyed by
  /// path, so the two spellings have to agree.
  /// Dotfiles are filtered here because the path-based enumeration has no
  /// equivalent of `.skipsHiddenFiles`, and without it every scan stats
  /// `.DS_Store` looking for a recording inside it.
  static func directories(in saveDirectory: URL) -> [URL] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: saveDirectory.path)
    else { return [] }
    return
      names
      .filter { !$0.hasPrefix(".") && !$0.hasPrefix(TranscriptIndex.fileName) }
      .map { saveDirectory.appendingPathComponent($0, isDirectory: true) }
  }
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
  /// Which service and model produced this. Optional so transcripts written
  /// before provenance existed still decode, and so a later provider picker has
  /// something to label them with.
  var provider: String?
  var model: String?

  init(
    segments: [TranscriptSegment], language: String? = nil, createdAt: Date,
    provider: String? = nil, model: String? = nil
  ) {
    self.segments = segments
    self.language = language
    self.createdAt = createdAt
    self.provider = provider
    self.model = model
  }

  /// Hand-written for the same reason as `RecordingMetadata`'s. Here the cost of
  /// an undecodable file is a paid-for transcript vanishing from the detail
  /// view, the user pressing Transcribe, and the intact file being overwritten
  /// by a re-billed one.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    segments = try container.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
    language = try container.decodeIfPresent(String.self, forKey: .language)
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    provider = try container.decodeIfPresent(String.self, forKey: .provider)
    model = try container.decodeIfPresent(String.self, forKey: .model)
  }

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
  /// When the segment's last token ends. Optional so transcripts written before
  /// segments carried it still decode.
  var endTime: Double?

  init(speaker: Int, time: Double, text: String, endTime: Double? = nil) {
    self.id = UUID()
    self.speaker = Self.clampSpeaker(speaker)
    self.time = Self.clampTime(time)
    self.text = text
    self.endTime = endTime.map(Self.clampTime)
  }

  /// Defaults rather than throws, for the same reason `TranscriptDocument`'s
  /// initialiser is hand-written: a throw here propagates out of the document's
  /// `decodeIfPresent([TranscriptSegment].self)` and takes the whole transcript
  /// with it, so one malformed segment loses a transcript the user has paid for
  /// and the retry re-bills.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
    // `try?`, not `decodeIfPresent`: the latter still throws when the key is
    // present with the wrong type - a speaker sent as a string, a time sent as
    // null - and a throw here propagates out of the document's segment array
    // and loses the entire transcript, which is the exact outcome this
    // initialiser exists to prevent. Measured: 4 of 6 malformed shapes still
    // took the whole file before this.
    self.speaker = Self.clampSpeaker((try? container.decode(Int.self, forKey: .speaker)) ?? 0)
    self.time = Self.clampTime((try? container.decode(Double.self, forKey: .time)) ?? 0)
    self.text = (try? container.decode(String.self, forKey: .text)) ?? ""
    self.endTime = (try? container.decode(Double.self, forKey: .endTime)).map(Self.clampTime)
  }

  /// Clamped at the parse boundary rather than in each formatter. `abs(Int.min)`
  /// and `speakerID + 1` both trap, and the transcript is written to disk before
  /// it is ever displayed, so an out-of-range value from a corrupt sidecar or a
  /// misbehaving response crashes the app on every attempt to open that
  /// recording, permanently.
  /// `Int.min` maps to 0, not to -1: -1 is the reserved id for the local
  /// speaker, so folding garbage onto it labels it "You".
  static func clampSpeaker(_ value: Int) -> Int {
    value == Int.min ? 0 : min(value, Int.max - 1)
  }

  /// `Int(time)` traps on a value outside `Int`'s range, and the display
  /// helpers convert before they clamp.
  static func clampTime(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(max(0, value), 24 * 60 * 60)
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

/// Which half of `upload` is running. The two are reported separately because
/// they fail and stall for different reasons, and because on a long call the
/// local re-encode is the longer of the two.
nonisolated enum TranscriptionUploadPhase: Sendable {
  case mixing(Double)
  case uploading(Double)
}

/// Reports bytes-sent for a single upload. `URLSession.shared` has no delegate
/// of its own, so this is attached per task rather than per session.
/// `@unchecked Sendable` because the callback is the only state and it is
/// immutable; libdispatch delivers the delegate calls on the session queue.
nonisolated final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  private let onFraction: @Sendable (Double) -> Void

  init(onFraction: @escaping @Sendable (Double) -> Void) {
    self.onFraction = onFraction
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
    totalBytesExpectedToSend: Int64
  ) {
    guard totalBytesExpectedToSend > 0 else { return }
    onFraction(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
  }
}

/// Every stage the user can be waiting through gets its own case. They used to
/// collapse into three, so a job held behind a recording, a job third in line,
/// and a job an hour into offline retries all read "Queued for transcription"
/// - which tells the user nothing about whether the wait is theirs to fix.
nonisolated enum TranscriptionStatus: Equatable, Sendable {
  case idle
  /// Enqueued and not yet started, waiting for an upload slot, or submitted to
  /// Soniox and waiting for it to begin.
  case queued
  /// Re-encoding the two tracks into one file. Local, slow on a long call, and
  /// entirely invisible before it had its own case.
  case mixing(fraction: Double)
  case uploading(fraction: Double)
  case transcribing
  /// Network is unreachable; retrying without spending an attempt.
  case offline
  /// A recoverable failure is being retried, with which attempt this is.
  case retrying(attempt: Int, of: Int)
  /// The user asked to stop and the job has not finished unwinding yet.
  case cancelling
  case completed
  case error(String)

  /// True while the job is doing or waiting on work - anything that should show
  /// progress rather than an action button.
  var isActive: Bool {
    switch self {
    case .idle, .completed, .error: false
    default: true
    }
  }

  /// Determinate progress for the stages that can report it, nil for the rest.
  var fraction: Double? {
    switch self {
    case .mixing(let f), .uploading(let f): f
    default: nil
    }
  }
}

nonisolated enum TranscriptionError: Error, LocalizedError, Sendable {
  case uploadFailed(String)
  case transcriptionFailed(String)
  case serverError(Int, String)
  /// 409 `transcription_invalid_state` - the transcript is not retrievable yet.
  /// Retryable: polling and fetching are separate calls, so a job that finishes
  /// between them answers 409 for a moment.
  case notReady(String)
  case balanceExhausted(String)
  case pollTimeout
  /// Soniox answered normally with no tokens: the audio held no speech. Not a
  /// failure of the pipeline, and retrying pays again for the same silence.
  case noSpeechDetected

  var errorDescription: String? {
    switch self {
    case .uploadFailed(let msg): "Upload failed: \(msg)"
    case .transcriptionFailed(let msg): "Transcription failed: \(msg)"
    case .serverError(let code, let msg): "Soniox error \(code): \(msg)"
    case .notReady(let msg): "Transcript not ready: \(msg)"
    case .balanceExhausted(let msg): "Soniox balance or budget exhausted: \(msg)"
    case .pollTimeout: "Transcription timed out"
    case .noSpeechDetected: "No speech found in this recording"
    }
  }

  /// Whether another pass is worth attempting. Lives with the error rather than
  /// with the caller so adding a case forces the decision here, where the
  /// status codes it came from are documented.
  var isRetryable: Bool {
    switch self {
    case .serverError, .pollTimeout, .notReady: true
    // Not retryable on purpose: the audio held no speech, so another pass pays
    // Soniox again for the same silence.
    case .uploadFailed, .transcriptionFailed, .balanceExhausted, .noSpeechDetected: false
    }
  }
}

// MARK: - Soniox Jobs

/// Which side of the call a Soniox job covers.
nonisolated enum TranscriptionJobRole: String, Codable, Sendable {
  case mic
  case farEnd
  /// One job over the whole recording (mixed track, or a file with nothing to split).
  case single
}

// MARK: - Soniox API Client

/// Stage-level transcription API. `TranscriptionCoordinator` drives the state
/// machine, so a job interrupted by quit or a network failure resumes from its
/// persisted stage instead of re-uploading.
///
/// Every requirement is `@concurrent`: under this target's `.defaultIsolation(MainActor.self)`,
/// a `nonisolated` conforming type is *not* enough to get async work off the main
/// thread - the annotation on the requirement is what moves it, for class and
/// actor witnesses alike. Without it, transcript JSON parsing and poll responses
/// are decoded on the main thread.
nonisolated protocol TranscriptionServicing: Sendable {
  /// Decides which Soniox jobs cover a recording: `[.mic, .farEnd]` when
  /// `separateTracks` is on and the file has distinct mic and far-end tracks,
  /// otherwise `[.single]`. Asked once per job and persisted, because the
  /// answer decides what gets billed and a later change of setting must not
  /// reinterpret a job that has already paid.
  @concurrent func plan(fileURL: URL, separateTracks: Bool) async throws -> [TranscriptionJobRole]
  /// Extracts (or mixes) the audio a role covers, uploads it, and returns the
  /// remote file id.
  @concurrent func upload(
    fileURL: URL,
    role: TranscriptionJobRole,
    onProgress: @escaping @Sendable (TranscriptionUploadPhase) -> Void
  ) async throws -> String
  /// Billing starts here: the returned id is money already spent.
  @concurrent func createTranscription(
    fileId: String, reference: String, role: TranscriptionJobRole, config: TranscriptionConfig
  ) async throws -> String
  @concurrent func awaitCompletion(transcriptionId: String) async throws
  @concurrent func fetchTranscript(transcriptionId: String) async throws -> TranscriptDocument
  /// True only when Soniox has confirmed every artifact is gone. The caller
  /// retires the record that names them on that answer, so "dispatched" is
  /// not good enough: a 401 from a half-typed key, or an offline machine,
  /// would otherwise erase the last trace of audio still sitting there.
  @concurrent func deleteRemote(transcriptionIds: [String], fileIds: [String]) async -> Bool
}

nonisolated final class TranscriptionService: TranscriptionServicing {
  static let defaultModel = "stt-async-v5"
  /// Offered in Settings. A free-text field meant a typo became a terminal
  /// failure per recording, discovered one recording at a time and only after
  /// an upload had already been paid for - while "Verify Key" happily reported
  /// success, because it checks the key and not the model.
  /// Only ids Soniox currently serves. `stt-async-preview` was offered here and
  /// is not one of them - it is not a model or an alias, and the nearest real
  /// name (`stt-async-preview-v1`) was retired in October 2025 - so picking it
  /// produced exactly the terminal per-recording failure, after a paid-for
  /// upload, that replacing the free-text field was meant to prevent.
  /// A model this list does not know still works if it is already in defaults:
  /// the picker surfaces the stored value, so a retirement does not need a
  /// release. See `docs/specification.md` D14.
  static let knownModels = [defaultModel]
  static let defaultBaseURL = "https://api.soniox.com"
  static let providerName = "soniox"

  private let apiKey: String
  private let model: String
  private let baseURL: String
  private static let mixPrefix = "blackbox-mixed-"
  /// Prefixed like its sibling. `temporaryDirectory` is the user's shared
  /// `$TMPDIR` for a non-sandboxed app, so sweeping a bare `.multipart` suffix
  /// reached files this app never wrote - and, because onboarding's relaunch
  /// overlaps two instances, the new one's launch sweep could unlink the old
  /// one's in-flight upload body.
  private static let uploadPrefix = "blackbox-upload-"
  private static let uploadSuffix = ".multipart"
  /// Soniox finalizes long calls slowly; 30 minutes abandoned some mid-flight.
  private static let pollCeiling = Duration.seconds(2 * 60 * 60)
  /// Soniox caps `client_reference_id` at 256 characters.
  private static let referenceLimit = 256
  private static let bodyLogLimit = 512

  /// Falls back to the default when the stored model is blank - the Settings
  /// field is free text, and an empty `model` is rejected by every request.
  static func resolvedModel(_ stored: String?) -> String {
    let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? defaultModel : trimmed
  }

  /// The one place that decides whether this process may talk to Soniox at all.
  ///
  /// Under `--ui-test-mode` the answer is never: the smoke suite records real
  /// audio on a developer's machine, so a live-host client there would send
  /// their call audio to a third party and bill them for it. Enforced here
  /// rather than at each call site because a call site is a thing to forget -
  /// every request in this feature is built by an instance of this type or by
  /// `verifyAPIKey`, and both funnel through this check.
  ///
  /// `precondition`, not `assert`: `make bundle` builds release, which is what
  /// the smoke suite launches, and `assert` is compiled out there. Crashing a
  /// test run is the correct failure - loud, immediate, impossible to mistake
  /// for a pass.
  /// The policy, split from the assertion so it can be tested: `isEnabled` is a
  /// launch-time constant, so a test process can never make the assertion fire.
  nonisolated static func egressAllowed(baseURL: String, underTestMode: Bool) -> Bool {
    !underTestMode || baseURL != defaultBaseURL
  }

  nonisolated private static func assertEgressAllowed(_ baseURL: String) {
    precondition(
      egressAllowed(baseURL: baseURL, underTestMode: BlackboxTestMode.isEnabled),
      "refusing to reach the live Soniox API under --ui-test-mode")
  }

  /// `baseURL` is injectable so the contract tests can point the client at a
  /// loopback stub that speaks the documented Soniox wire format.
  init(apiKey: String, model: String = defaultModel, baseURL: String = defaultBaseURL) {
    Self.assertEgressAllowed(baseURL)
    self.apiKey = apiKey
    self.model = model
    self.baseURL = baseURL
  }

  /// Checks a key without spending anything: the file list is the cheapest
  /// authenticated endpoint. Lets Settings tell the user the key is wrong now
  /// rather than through a recording that silently fails to transcribe later.
  @concurrent
  static func verifyAPIKey(_ apiKey: String, baseURL: String = defaultBaseURL) async -> (
    isValid: Bool, message: String?
  ) {
    // Static, so it never passes through `init` - it needs its own check.
    assertEgressAllowed(baseURL)
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return (false, "No API key entered.")
    }
    guard let url = URL(string: "\(baseURL)/v1/files") else { return (false, "Invalid URL.") }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 10
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else { return (false, "No HTTP response.") }
      if (200..<300).contains(http.statusCode) { return (true, nil) }
      let envelope = Self.errorEnvelope(from: data)
      return (false, envelope.message ?? "HTTP \(http.statusCode)")
    } catch {
      return (false, error.localizedDescription)
    }
  }

  /// Which jobs a recording needs. Reads the track layout from the file itself
  /// (through `RecordingTrackMap`, never positionally).
  @concurrent
  func plan(fileURL: URL, separateTracks: Bool) async throws -> [TranscriptionJobRole] {
    let tracks = try await AVURLAsset(url: fileURL).loadTracks(withMediaType: .audio)
    let map = Self.trackMap(for: fileURL, trackCount: tracks.count)
    return Self.planRoles(separateTracks: separateTracks, map: map, trackCount: tracks.count)
  }

  static func planRoles(
    separateTracks: Bool, map: RecordingTrackMap, trackCount: Int
  ) -> [TranscriptionJobRole] {
    if separateTracks, let mic = map.micIndex, let farEnd = map.farEndIndex, mic != farEnd,
      (0..<trackCount).contains(mic), (0..<trackCount).contains(farEnd)
    {
      return [.mic, .farEnd]
    }
    return [.single]
  }

  /// Soniox needs diarization on for anything that can hold more than one
  /// speaker. The mic track is one known speaker, and diarizing it would only
  /// invent a second one out of the user's own cough.
  static func diarizes(_ role: TranscriptionJobRole) -> Bool { role != .mic }

  private static func trackMap(for fileURL: URL, trackCount: Int) -> RecordingTrackMap {
    RecordingTrackMap.resolve(
      metadata: RecordingMetadata.load(in: fileURL.deletingLastPathComponent()),
      trackCount: trackCount)
  }

  /// Every Blackbox recording is multi-track, so audio is always re-encoded
  /// before a byte leaves the machine - and on a long call that is the slowest
  /// thing here. `onProgress` exists because that used to be minutes of a
  /// spinner captioned "Uploading audio...", which is both the wrong stage and
  /// no way to tell work from a stall.
  ///
  /// What gets uploaded depends on the role. `.mic` and `.farEnd` each send
  /// their own track, so the mic carries no cross-talk and the local speaker is
  /// attributed exactly instead of guessed from a mixed file. `.single` sends
  /// the rendered `mixed` track when there is one, else mixes on the fly.
  @concurrent
  func upload(
    fileURL: URL,
    role: TranscriptionJobRole,
    onProgress: @escaping @Sendable (TranscriptionUploadPhase) -> Void
  ) async throws -> String {
    let asset = AVURLAsset(url: fileURL)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let map = Self.trackMap(for: fileURL, trackCount: tracks.count)

    let uploadURL: URL
    switch role {
    case .mic:
      guard let index = map.micIndex, tracks.indices.contains(index) else {
        throw TranscriptionError.transcriptionFailed("recording no longer has a microphone track")
      }
      uploadURL = try await Self.extractTrack(
        asset: asset, tracks: tracks, at: index, onProgress: onProgress)
    case .farEnd:
      guard let index = map.farEndIndex, tracks.indices.contains(index) else {
        throw TranscriptionError.transcriptionFailed("recording no longer has a desktop track")
      }
      uploadURL = try await Self.extractTrack(
        asset: asset, tracks: tracks, at: index, onProgress: onProgress)
    case .single:
      if tracks.count < 2 {
        return try await uploadFile(fileURL, onProgress: onProgress)
      }
      // A rendered `mixed` track is already the full join, so it is uploaded as-is.
      if let index = map.mixedIndex, tracks.indices.contains(index) {
        uploadURL = try await Self.extractTrack(
          asset: asset, tracks: tracks, at: index, onProgress: onProgress)
      } else {
        Log.info(
          Log.transcription, "transcription",
          "multi-track file detected (\(tracks.count) tracks), mixing before transcription")
        uploadURL = try await Self.mix(
          asset: asset, tracks: tracks, map: map, onProgress: onProgress)
      }
    }
    defer { try? FileManager.default.removeItem(at: uploadURL) }
    return try await uploadFile(uploadURL, onProgress: onProgress)
  }

  // MARK: - Audio Mixing & Export

  /// Mixes the mic and far-end tracks, and never the rendered `mixed` track,
  /// which would double the call audio. Takes an already-loaded asset so
  /// callers that had to inspect the track count first do not parse the
  /// container a second time.
  @concurrent
  static func mix(
    asset: AVAsset,
    tracks: [AVAssetTrack],
    map: RecordingTrackMap,
    onProgress: (@Sendable (TranscriptionUploadPhase) -> Void)? = nil
  ) async throws -> URL {
    let tracksToMix: [AVAssetTrack]
    if let mic = map.micIndex, let farEnd = map.farEndIndex, mic != farEnd,
      tracks.indices.contains(mic), tracks.indices.contains(farEnd)
    {
      tracksToMix = [tracks[mic], tracks[farEnd]]
    } else {
      tracksToMix = tracks.enumerated().compactMap { index, track in
        map.roles.indices.contains(index) && map.roles[index] == .mixed ? nil : track
      }
    }
    guard !tracksToMix.isEmpty else {
      throw TranscriptionError.transcriptionFailed("no audio tracks available for mixing")
    }
    let url = try await exportTracks(
      tracksToMix, duration: try await asset.load(.duration), onProgress: onProgress)
    Log.info(
      Log.transcription, "transcription", "mixed \(tracksToMix.count) tracks into single file")
    return url
  }

  /// Internal rather than private so tests can prove the per-track split without
  /// a live API key: this is the step that decides what audio Soniox actually hears.
  static func extractTrack(from fileURL: URL, at index: Int) async throws -> URL {
    let asset = AVURLAsset(url: fileURL)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    return try await extractTrack(asset: asset, tracks: tracks, at: index, onProgress: nil)
  }

  @concurrent
  private static func extractTrack(
    asset: AVAsset,
    tracks: [AVAssetTrack],
    at index: Int,
    onProgress: (@Sendable (TranscriptionUploadPhase) -> Void)?
  ) async throws -> URL {
    guard tracks.indices.contains(index) else {
      throw TranscriptionError.transcriptionFailed("audio track \(index) is unavailable")
    }
    return try await exportTracks(
      [tracks[index]], duration: try await asset.load(.duration), onProgress: onProgress)
  }

  /// Renders `sourceTracks` into one single-track M4A in the temp directory.
  @concurrent
  private static func exportTracks(
    _ sourceTracks: [AVAssetTrack],
    duration: CMTime,
    onProgress: (@Sendable (TranscriptionUploadPhase) -> Void)?
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
      .appendingPathComponent("\(Self.mixPrefix)\(UUID().uuidString).m4a")

    guard
      let exporter = AVAssetExportSession(
        asset: composition, presetName: AVAssetExportPresetAppleM4A)
    else {
      throw TranscriptionError.transcriptionFailed("could not create export session")
    }

    var didExport = false
    defer { if !didExport { try? FileManager.default.removeItem(at: tempURL) } }
    do {
      if let onProgress {
        onProgress(.mixing(0))
        // `nonisolated(unsafe)` because `AVAssetExportSession` is not Sendable
        // and both the export and its progress sequence need the same
        // instance. Reading progress while an export runs is what the API is
        // for - `states(updateInterval:)` exists to be consumed concurrently
        // with `export(to:as:)`, and the sequence ends when the export does.
        nonisolated(unsafe) let session = exporter
        async let export: Void = session.export(to: tempURL, as: .m4a)
        for await state in session.states(updateInterval: 0.5) {
          if case .exporting(let progress) = state {
            onProgress(.mixing(progress.fractionCompleted))
          }
        }
        try await export
        onProgress(.mixing(1))
      } else {
        try await exporter.export(to: tempURL, as: .m4a)
      }
    } catch {
      throw TranscriptionError.transcriptionFailed(
        "audio export failed: \(error.localizedDescription)")
    }
    didExport = true
    return tempURL
  }

  /// Removes mix and upload scratch files stranded by a quit mid-job. Each is
  /// the full size of a recording, and resume-after-quit makes that a routine
  /// path rather than a crash-only one.
  @concurrent
  static func sweepTemporaryFiles() async {
    let temporaryDirectory = FileManager.default.temporaryDirectory
    guard
      let names = try? FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
    else { return }
    for name in names
    where name.hasPrefix(Self.mixPrefix) || name.hasPrefix(Self.uploadPrefix) {
      try? FileManager.default.removeItem(at: temporaryDirectory.appendingPathComponent(name))
    }
  }

  /// Exports a single-track M4A copy. Mixes tracks first if multi-track.
  @concurrent
  static func exportM4A(from fileURL: URL, to outputURL: URL) async throws {
    let asset = AVURLAsset(url: fileURL)
    let tracks = try await asset.loadTracks(withMediaType: .audio)

    // NSSavePanel's "Replace" confirmation does not remove the target, and
    // `copyItem` throws on an existing file - so agreeing to replace produced a
    // "file exists" error and left the old file untouched.
    guard tracks.count >= 2 else {
      try? FileManager.default.removeItem(at: outputURL)
      try FileManager.default.copyItem(at: fileURL, to: outputURL)
      return
    }
    // Reuses the already-loaded asset rather than re-parsing the container.
    let mixed = try await mix(
      asset: asset, tracks: tracks, map: trackMap(for: fileURL, trackCount: tracks.count))
    defer { try? FileManager.default.removeItem(at: mixed) }
    try? FileManager.default.removeItem(at: outputURL)
    try FileManager.default.copyItem(at: mixed, to: outputURL)
  }

  // MARK: - Upload

  @concurrent
  private func uploadFile(
    _ fileURL: URL,
    onProgress: @escaping @Sendable (TranscriptionUploadPhase) -> Void
  ) async throws -> String {
    let boundary = UUID().uuidString

    // Build multipart body as a temp file to avoid loading entire audio into memory
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(Self.uploadPrefix + UUID().uuidString + Self.uploadSuffix)
    defer { try? FileManager.default.removeItem(at: tempURL) }
    try Self.writeMultipartBody(audio: fileURL, boundary: boundary, to: tempURL)

    var request = try makeRequest(.post, "/v1/files")
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    onProgress(.uploading(0))
    let (data, response) = try await URLSession.shared.upload(
      for: request, fromFile: tempURL,
      delegate: UploadProgressDelegate { onProgress(.uploading($0)) })
    try checkHTTPResponse(response, data: data, context: "upload")

    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let fileId = json?["id"] as? String else {
      throw TranscriptionError.uploadFailed("missing file id in response")
    }
    Log.info(Log.transcription, "transcription", "uploaded file: \(fileId)")
    return fileId
  }

  /// Streams the audio into a multipart body on disk in 64KB chunks. Stream
  /// errors and short writes are surfaced: swallowing them uploads a truncated
  /// body that the transport reports as a success and Soniox rejects much later,
  /// pointing nowhere near the real cause.
  private static func writeMultipartBody(audio fileURL: URL, boundary: String, to tempURL: URL)
    throws
  {
    FileManager.default.createFile(atPath: tempURL.path, contents: nil)
    guard let output = OutputStream(url: tempURL, append: false) else {
      throw TranscriptionError.uploadFailed("failed to create temp file for upload")
    }
    output.open()
    defer { output.close() }

    func writeAll(_ bytes: UnsafePointer<UInt8>, count: Int) throws {
      var offset = 0
      while offset < count {
        let written = output.write(bytes + offset, maxLength: count - offset)
        guard written > 0 else {
          throw TranscriptionError.uploadFailed(
            "short write building upload body: "
              + (output.streamError?.localizedDescription ?? "stream closed"))
        }
        offset += written
      }
    }

    let header = Data(
      "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\nContent-Type: audio/mp4\r\n\r\n"
        .utf8)
    try header.withUnsafeBytes { buffer in
      try writeAll(buffer.bindMemory(to: UInt8.self).baseAddress!, count: header.count)
    }

    guard let input = InputStream(url: fileURL) else {
      throw TranscriptionError.uploadFailed("failed to open audio file for reading")
    }
    input.open()
    defer { input.close() }

    let bufferSize = 65536
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while input.hasBytesAvailable {
      let bytesRead = input.read(buffer, maxLength: bufferSize)
      if bytesRead > 0 {
        try writeAll(buffer, count: bytesRead)
      } else if bytesRead < 0 {
        throw TranscriptionError.uploadFailed(
          "failed reading audio for upload: "
            + (input.streamError?.localizedDescription ?? "unknown error"))
      } else {
        break
      }
    }

    let footer = Data("\r\n--\(boundary)--\r\n".utf8)
    try footer.withUnsafeBytes { buffer in
      try writeAll(buffer.bindMemory(to: UInt8.self).baseAddress!, count: footer.count)
    }
  }

  // MARK: - Create Transcription

  @concurrent
  func createTranscription(
    fileId: String, reference: String, role: TranscriptionJobRole, config: TranscriptionConfig
  ) async throws -> String {
    var body = Self.transcriptionConfiguration(
      model: model, fileId: fileId, role: role, config: config)
    // Ties the remote job back to a recording directory, so an artifact this
    // client loses track of is still identifiable in the Soniox console.
    body["client_reference_id"] = String(reference.prefix(Self.referenceLimit))

    var request = try makeRequest(.post, "/v1/transcriptions")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

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

  /// The request body. Context and every flag come from `config` - Settings or
  /// the per-run options - and never from the recording itself: Blackbox has no
  /// pre-recording agenda or participant data, and must not bias the
  /// desktop-only job toward the local speaker from a transcript it does not yet
  /// have.
  static func transcriptionConfiguration(
    model: String,
    fileId: String,
    role: TranscriptionJobRole,
    config: TranscriptionConfig
  ) -> [String: Any] {
    var body: [String: Any] = [
      "model": model,
      "file_id": fileId,
      "language_hints": config.languageHints,
      "enable_speaker_diarization": config.diarization ?? diarizes(role),
      "enable_language_identification": config.languageIdentification,
    ]
    if config.languageHintsStrict { body["language_hints_strict"] = true }
    if !config.context.isEmpty { body["context"] = config.context.requestObject }
    return body
  }

  // MARK: - Poll

  @concurrent
  func awaitCompletion(transcriptionId: String) async throws {
    // Measured on the clock, not by summing the sleeps: the round trips are not
    // free, so a ceiling built from sleep durations alone is a floor.
    let started = ContinuousClock.now
    var elapsed = Duration.zero

    while elapsed < Self.pollCeiling {
      try Task.checkCancellation()
      let interval = Self.pollInterval(after: elapsed)
      try await Task.sleep(for: interval)
      elapsed = ContinuousClock.now - started

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
        // A blip during a poll that can run for half an hour is not worth
        // spending one of the coordinator's persisted attempts on.
        Log.error(
          Log.transcription, "transcription",
          "poll network error, retrying: \(error.localizedDescription)")
        continue
      }

      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      switch json?["status"] as? String {
      case "completed":
        Log.info(Log.transcription, "transcription", "completed: \(transcriptionId)")
        return
      case "error":
        throw TranscriptionError.transcriptionFailed(
          json?["error_message"] as? String ?? "unknown error")
      default:
        break
      }
    }
    throw TranscriptionError.pollTimeout
  }

  /// Ramps the poll interval so a job that takes minutes does not cost hundreds
  /// of requests, while a short one is still noticed promptly.
  private static func pollInterval(after elapsed: Duration) -> Duration {
    switch elapsed {
    case ..<(.seconds(30)): .seconds(2)
    case ..<(.seconds(300)): .seconds(5)
    default: .seconds(15)
    }
  }

  // MARK: - Fetch Transcript

  @concurrent
  func fetchTranscript(
    transcriptionId: String
  ) async throws -> TranscriptDocument {
    let request = try makeRequest(
      .get, "/v1/transcriptions/\(transcriptionId)/transcript")
    let (data, response) = try await URLSession.shared.data(for: request)
    try checkHTTPResponse(response, data: data, context: "fetch transcript")

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tokens = json["tokens"] as? [[String: Any]]
    else {
      throw TranscriptionError.transcriptionFailed("could not read the transcript response")
    }
    // A well-formed response with no tokens is not a failure - it is a
    // recording with nothing audible in it. Reporting that as "Transcription
    // failed" sent the user looking for a bug in a call that was simply silent,
    // and offered a Retry that would upload and bill for the same silence.
    guard !tokens.isEmpty else {
      throw TranscriptionError.noSpeechDetected
    }

    var document = Self.groupTokensIntoDocument(Self.tokens(from: tokens))
    document.provider = Self.providerName
    document.model = model
    return document
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
      createdAt: createdAt,
      provider: documents.compactMap(\.provider).first,
      model: documents.compactMap(\.model).first
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

  /// Folds per-role transcripts into one document on a shared timeline. The mic
  /// is one known speaker, rendered as -1; far-end speakers keep Soniox's ids.
  nonisolated static func combine(
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

  // MARK: - Cleanup

  /// Best-effort removal of the remote file and transcription so the account
  /// does not accumulate artifacts. A failure here does not fail the job, but it
  /// is logged: this is the only thing standing between a finished job and the
  /// user's call audio living on Soniox indefinitely, so a silent miss is the
  /// one outcome that must not be invisible.
  @concurrent
  func deleteRemote(transcriptionIds: [String], fileIds: [String]) async -> Bool {
    var allGone = true
    for tId in transcriptionIds {
      allGone =
        await delete(path: "/v1/transcriptions/\(tId)", describing: "transcription \(tId)")
        && allGone
    }
    for fId in fileIds {
      allGone = await delete(path: "/v1/files/\(fId)", describing: "file \(fId)") && allGone
    }
    return allGone
  }

  @concurrent
  private func delete(path: String, describing what: String) async -> Bool {
    guard let url = URL(string: "\(baseURL)\(path)") else {
      Log.error(Log.transcription, "transcription", "cannot delete \(what): invalid URL \(path)")
      return false
    }
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        Log.error(
          Log.transcription, "transcription",
          "cannot confirm deletion of \(what): no HTTP response; it may remain on Soniox")
        return false
      }
      // 404 means it is already gone, which is the outcome we wanted.
      guard !(200..<300).contains(http.statusCode), http.statusCode != 404 else { return true }
      Log.error(
        Log.transcription, "transcription",
        "failed to delete \(what) (HTTP \(http.statusCode)); it may remain on Soniox: \(Self.bodyExcerpt(from: data))"
      )
      return false
    } catch {
      Log.error(
        Log.transcription, "transcription",
        "failed to delete \(what); it may remain on Soniox: \(error.localizedDescription)")
      return false
    }
  }

  // MARK: - Helpers

  private enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
  }

  private func makeRequest(_ method: HTTPMethod, _ path: String) throws -> URLRequest {
    guard let url = URL(string: "\(baseURL)\(path)") else {
      throw TranscriptionError.transcriptionFailed("invalid URL: \(path)")
    }
    var request = URLRequest(url: url)
    request.httpMethod = method.rawValue
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    // Without this each stalled request can sit for URLSession's 60s default,
    // and the poll loop issues up to 169 of them - so a ceiling described as
    // thirty minutes became hours before it reported a timeout.
    request.timeoutInterval = 30
    return request
  }

  /// Soniox errors carry `{status_code, error_type, message, request_id}`.
  /// `request_id` is what their support asks for, so it goes in the log even
  /// though the user never sees it.
  nonisolated private static func errorEnvelope(from data: Data) -> (
    message: String?, errorType: String?, requestId: String?
  ) {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return (nil, nil, nil)
    }
    return (
      json["message"] as? String, json["error_type"] as? String, json["request_id"] as? String
    )
  }

  /// A prefix of the raw body, for the failures that carry no Soniox envelope
  /// at all - a proxy's HTML error page, an empty 502, a truncated response.
  /// Without this the log says only "HTTP 502" and the cause is unrecoverable.
  nonisolated private static func bodyExcerpt(from data: Data) -> String {
    guard !data.isEmpty else { return "empty body" }
    let text = String(decoding: data.prefix(bodyLogLimit), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return "\(data.count) non-text bytes" }
    return data.count > bodyLogLimit ? text + "... (\(data.count) bytes)" : text
  }

  private func checkHTTPResponse(
    _ response: URLResponse, data: Data, context: String
  ) throws {
    // Not an HTTP response at all is a failure, not a success. Returning here
    // let the caller carry on and fail opaquely at the JSON parse instead.
    guard let http = response as? HTTPURLResponse else {
      throw TranscriptionError.transcriptionFailed("\(context): no HTTP response")
    }
    guard (200..<300).contains(http.statusCode) else {
      let envelope = Self.errorEnvelope(from: data)
      let apiMessage = envelope.message ?? "HTTP \(http.statusCode)"
      Log.error(
        Log.transcription, "transcription",
        "\(context) failed (\(http.statusCode) \(envelope.errorType ?? "unknown")): \(apiMessage) [request_id=\(envelope.requestId ?? "none")] body=\(Self.bodyExcerpt(from: data))"
      )
      let detail = "\(context): \(apiMessage)"

      switch http.statusCode {
      case 409:
        throw TranscriptionError.notReady(detail)
      case 402:
        throw TranscriptionError.balanceExhausted(apiMessage)
      case 429, 500...599:
        throw TranscriptionError.serverError(http.statusCode, detail)
      default:
        throw TranscriptionError.transcriptionFailed(detail)
      }
    }
  }
}
