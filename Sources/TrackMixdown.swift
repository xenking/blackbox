@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Rewrites completed dual-track recordings into `[mixed, mic, system]`.
/// Live capture stays untouched so a post-processing failure cannot lose samples.
enum TrackMixdown {

  /// Rewrites `audio.m4a` in place into the canonical 3-track layout.
  /// When disabled, recording remains the native `[system, mic]` layout.
  static func render(recordingDirectory: URL, includeMixedTrack: Bool = true) async {
    do {
      let didRender = try await Task.detached {
        try await Self.run(
          recordingDirectory: recordingDirectory, includeMixedTrack: includeMixedTrack)
      }.value
      if didRender {
        Log.info(Log.recorder, "mixdown", "rendered mixed, mic, and system tracks")
      }
    } catch {
      Log.error(Log.recorder, "mixdown", "failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Background Pipeline

  nonisolated private static func run(
    recordingDirectory: URL, includeMixedTrack: Bool
  ) async throws -> Bool {
    let originalURL = recordingDirectory.appendingPathComponent("audio.m4a")
    let metadata = RecordingMetadata.load(in: recordingDirectory)
    let asset = AVURLAsset(url: originalURL)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let map = RecordingTrackMap.resolve(metadata: metadata, trackCount: tracks.count)

    guard includeMixedTrack else {
      guard var metadata, tracks.count == 2, map.mixedIndex == nil else { return false }
      metadata.tracks = [.system, .mic]
      metadata.trackCount = 2
      try metadata.save(in: recordingDirectory)
      return false
    }

    guard map.mixedIndex == nil else { return false }
    guard let micIndex = map.micIndex, let farEndIndex = map.farEndIndex else { return false }
    guard tracks.indices.contains(micIndex), tracks.indices.contains(farEndIndex) else {
      throw TrackMixdownError.invalidTrackMap
    }
    guard metadata != nil else { throw TrackMixdownError.metadataMissing }

    let duration = try await asset.load(.duration)
    guard duration.isValid, duration.seconds > 0 else { throw TrackMixdownError.invalidDuration }

    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
    let mixedURL = temporaryDirectory.appendingPathComponent(
      "blackbox-mixed-\(UUID().uuidString).m4a")
    let remuxedURL = temporaryDirectory.appendingPathComponent(
      "blackbox-audio-3track-\(UUID().uuidString).m4a")
    defer {
      try? fileManager.removeItem(at: mixedURL)
      try? fileManager.removeItem(at: remuxedURL)
    }

    try await exportMixedTrack(
      micTrack: tracks[micIndex],
      farEndTrack: tracks[farEndIndex],
      duration: duration,
      outputURL: mixedURL
    )

    let mixedAsset = AVURLAsset(url: mixedURL)
    let mixedTracks = try await mixedAsset.loadTracks(withMediaType: .audio)
    guard mixedTracks.count == 1, let mixedTrack = mixedTracks.first else {
      throw TrackMixdownError.missingMixedTrack
    }

    try await remux(
      mixedTrack: mixedTrack,
      mixedAsset: mixedAsset,
      micTrack: tracks[micIndex],
      systemTrack: tracks[farEndIndex],
      originalAsset: asset,
      outputURL: remuxedURL
    )

    // Declare the new roles *before* swapping the file in. `RecordingTrackMap`
    // only trusts declared roles when their count matches the file's real track
    // count, so the intermediate state (3 roles declared, 2-track file still on
    // disk) resolves to the correct legacy `[system, mic]` pair. The reverse
    // order has no safe intermediate: a 3-track file with no declared roles
    // resolves as the pre-v0.7.0 `[system, perApp, mic]` layout, which silently
    // swaps mic and system for AEC and transcription.
    guard var updatedMetadata = RecordingMetadata.load(in: recordingDirectory) else {
      throw TrackMixdownError.metadataMissing
    }
    updatedMetadata.tracks = [.mixed, .mic, .system]
    updatedMetadata.trackCount = 3
    try updatedMetadata.save(in: recordingDirectory)

    _ = try fileManager.replaceItemAt(originalURL, withItemAt: remuxedURL)
    return true
  }

  nonisolated private static func exportMixedTrack(
    micTrack: AVAssetTrack,
    farEndTrack: AVAssetTrack,
    duration: CMTime,
    outputURL: URL
  ) async throws {
    let composition = AVMutableComposition()
    for sourceTrack in [micTrack, farEndTrack] {
      guard
        let compositionTrack = composition.addMutableTrack(
          withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
      else {
        throw TrackMixdownError.cannotCreateCompositionTrack
      }
      try compositionTrack.insertTimeRange(
        CMTimeRange(start: .zero, duration: duration),
        of: sourceTrack,
        at: .zero
      )
    }

    guard
      let exporter = AVAssetExportSession(
        asset: composition, presetName: AVAssetExportPresetAppleM4A)
    else {
      throw TrackMixdownError.cannotCreateExporter
    }
    try await exporter.export(to: outputURL, as: .m4a)
  }

  nonisolated private static func remux(
    mixedTrack: AVAssetTrack,
    mixedAsset: AVAsset,
    micTrack: AVAssetTrack,
    systemTrack: AVAssetTrack,
    originalAsset: AVAsset,
    outputURL: URL
  ) async throws {
    // Passthrough inputs (`outputSettings: nil`) carry no format of their own,
    // so the writer cannot validate them and `canAdd` returns false. Hand each
    // one the source track's format description.
    let mixedHint = try await Self.formatHint(for: mixedTrack)
    let micHint = try await Self.formatHint(for: micTrack)
    let systemHint = try await Self.formatHint(for: systemTrack)

    let writer = try AVAssetWriter(url: outputURL, fileType: .m4a)
    let mixedInput = AVAssetWriterInput(
      mediaType: .audio, outputSettings: nil, sourceFormatHint: mixedHint)
    let micInput = AVAssetWriterInput(
      mediaType: .audio, outputSettings: nil, sourceFormatHint: micHint)
    let systemInput = AVAssetWriterInput(
      mediaType: .audio, outputSettings: nil, sourceFormatHint: systemHint)
    guard writer.canAdd(mixedInput), writer.canAdd(micInput), writer.canAdd(systemInput) else {
      throw TrackMixdownError.cannotAddWriterInput
    }
    writer.add(mixedInput)
    writer.add(micInput)
    writer.add(systemInput)

    var copies = [
      try TrackCopy(track: mixedTrack, asset: mixedAsset, input: mixedInput),
      try TrackCopy(track: micTrack, asset: originalAsset, input: micInput),
      try TrackCopy(track: systemTrack, asset: originalAsset, input: systemInput),
    ]
    guard writer.startWriting() else {
      throw TrackMixdownError.writeFailed(
        writer.error?.localizedDescription ?? "could not start writer")
    }
    writer.startSession(atSourceTime: .zero)

    do {
      try copyTracks(&copies, writer: writer)
      await writer.finishWriting()
    } catch {
      writer.cancelWriting()
      throw error
    }

    guard writer.status == .completed else {
      throw TrackMixdownError.writeFailed(writer.error?.localizedDescription ?? "writer failed")
    }
  }

  nonisolated private static func formatHint(
    for track: AVAssetTrack
  ) async throws -> CMFormatDescription {
    let descriptions = try await track.load(.formatDescriptions)
    guard let hint = descriptions.first else {
      throw TrackMixdownError.readFailed("track carries no format description")
    }
    return hint
  }

  nonisolated private static func copyTracks(
    _ copies: inout [TrackCopy],
    writer: AVAssetWriter
  ) throws {
    for copy in copies {
      guard copy.reader.startReading() else {
        throw TrackMixdownError.readFailed(
          copy.reader.error?.localizedDescription ?? "could not start reader")
      }
    }

    while copies.contains(where: { !$0.isFinished }) {
      var appendedSample = false
      // Advance ready inputs round-robin so no track gets far ahead in the writer.
      for index in copies.indices {
        guard !copies[index].isFinished else { continue }
        guard copies[index].input.isReadyForMoreMediaData else { continue }
        guard let sampleBuffer = copies[index].output.copyNextSampleBuffer() else {
          let reader = copies[index].reader
          guard reader.status != .failed, reader.status != .cancelled else {
            throw TrackMixdownError.readFailed(
              reader.error?.localizedDescription ?? "reader stopped")
          }
          copies[index].input.markAsFinished()
          copies[index].isFinished = true
          continue
        }
        guard copies[index].input.append(sampleBuffer) else {
          throw TrackMixdownError.writeFailed(
            writer.error?.localizedDescription ?? "writer rejected a sample")
        }
        appendedSample = true
      }

      if !appendedSample, copies.contains(where: { !$0.isFinished }) {
        guard writer.status == .writing else {
          throw TrackMixdownError.writeFailed(
            writer.error?.localizedDescription ?? "writer stopped accepting samples")
        }
        usleep(10_000)
      }
    }
  }

  nonisolated private struct TrackCopy {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    let input: AVAssetWriterInput
    var isFinished = false

    init(track: AVAssetTrack, asset: AVAsset, input: AVAssetWriterInput) throws {
      let reader = try AVAssetReader(asset: asset)
      let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
      output.alwaysCopiesSampleData = false
      reader.add(output)
      self.reader = reader
      self.output = output
      self.input = input
    }
  }
}

nonisolated private enum TrackMixdownError: Error, LocalizedError {
  case metadataMissing
  case invalidTrackMap
  case invalidDuration
  case cannotCreateCompositionTrack
  case cannotCreateExporter
  case missingMixedTrack
  case cannotAddWriterInput
  case readFailed(String)
  case writeFailed(String)

  var errorDescription: String? {
    switch self {
    case .metadataMissing: "metadata.json is missing"
    case .invalidTrackMap: "track metadata does not match the audio file"
    case .invalidDuration: "recording has no valid duration"
    case .cannotCreateCompositionTrack: "could not create composition track"
    case .cannotCreateExporter: "could not create export session"
    case .missingMixedTrack: "mixed export did not produce exactly one audio track"
    case .cannotAddWriterInput: "could not add passthrough writer inputs"
    case .readFailed(let message): "reader failed: \(message)"
    case .writeFailed(let message): "writer failed: \(message)"
    }
  }
}
