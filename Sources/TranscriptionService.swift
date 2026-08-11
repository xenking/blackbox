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

  var errorDescription: String? {
    switch self {
    case .uploadFailed(let msg): "Upload failed: \(msg)"
    case .transcriptionFailed(let msg): "Transcription failed: \(msg)"
    case .pollTimeout: "Transcription timed out"
    }
  }
}

// MARK: - Soniox API Client

final class TranscriptionService {
  private let apiKey: String
  private static let baseURL = "https://api.soniox.com"

  init(apiKey: String) {
    self.apiKey = apiKey
  }

  /// Transcribes the local mic and far end separately when both are available.
  func transcribe(
    fileURL: URL,
    languageHints: [String],
    onStatus: @escaping @MainActor (TranscriptionStatus) -> Void
  ) async throws -> TranscriptDocument {
    let asset = AVURLAsset(url: fileURL)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let metadata = RecordingMetadata.load(in: fileURL.deletingLastPathComponent())
    let trackMap = RecordingTrackMap.resolve(metadata: metadata, trackCount: tracks.count)

    if let micTrackIndex = trackMap.micIndex,
      let farEndTrackIndex = trackMap.farEndIndex,
      micTrackIndex != farEndTrackIndex,
      tracks.indices.contains(micTrackIndex),
      tracks.indices.contains(farEndTrackIndex)
    {
      Log.info(
        Log.transcription, "transcription",
        "separate mic and far-end tracks detected; transcribing concurrently")
      let micUploadURL = try await Self.extractTrack(from: fileURL, at: micTrackIndex)
      defer { try? FileManager.default.removeItem(at: micUploadURL) }
      let farEndUploadURL = try await Self.extractTrack(from: fileURL, at: farEndTrackIndex)
      defer { try? FileManager.default.removeItem(at: farEndUploadURL) }

      async let micDocument = transcribeUploadedFile(
        micUploadURL,
        languageHints: languageHints,
        enableDiarization: false,
        onStatus: onStatus
      )
      async let farEndDocument = transcribeUploadedFile(
        farEndUploadURL,
        languageHints: languageHints,
        enableDiarization: true,
        onStatus: onStatus
      )
      var (localDocument, remoteDocument) = try await (micDocument, farEndDocument)
      localDocument.segments = localDocument.segments.map {
        var segment = $0
        segment.speaker = -1
        return segment
      }
      remoteDocument.segments = remoteDocument.segments.map {
        var segment = $0
        segment.speaker = max(0, segment.speaker)
        return segment
      }

      let document = Self.mergeDocuments([localDocument, remoteDocument])
      onStatus(.completed)
      return document
    }

    let uploadURL = tracks.count >= 2 ? try await Self.mixTracks(from: fileURL) : fileURL
    defer {
      if uploadURL != fileURL {
        try? FileManager.default.removeItem(at: uploadURL)
      }
    }
    let document = try await transcribeUploadedFile(
      uploadURL,
      languageHints: languageHints,
      enableDiarization: true,
      onStatus: onStatus
    )
    onStatus(.completed)
    return document
  }

  private func transcribeUploadedFile(
    _ fileURL: URL,
    languageHints: [String],
    enableDiarization: Bool,
    onStatus: @escaping @MainActor (TranscriptionStatus) -> Void
  ) async throws -> TranscriptDocument {
    onStatus(.uploading)
    let fileId = try await uploadFile(fileURL)
    var transcriptionId: String?

    do {
      onStatus(.queued)
      transcriptionId = try await createTranscription(
        fileId: fileId,
        languageHints: languageHints,
        enableDiarization: enableDiarization
      )
      try await pollUntilComplete(transcriptionId: transcriptionId!, onStatus: onStatus)
      let document = try await fetchTranscript(transcriptionId: transcriptionId!)
      fireAndForgetCleanup(transcriptionIds: [transcriptionId!], fileIds: [fileId])
      return document
    } catch {
      fireAndForgetCleanup(
        transcriptionIds: [transcriptionId].compactMap { $0 }, fileIds: [fileId])
      throw error
    }
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

  private static func extractTrack(from fileURL: URL, at index: Int) async throws -> URL {
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
    let config: [String: Any] = [
      "model": "stt-async-v5",
      "file_id": fileId,
      "language_hints": languageHints,
      "enable_speaker_diarization": enableDiarization,
      "enable_language_identification": true,
    ]

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
        throw TranscriptionError.transcriptionFailed(message)
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
