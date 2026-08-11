@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Blackbox

/// When the app dies with an `AVAssetWriter` still open, `finishWriting()` never
/// runs, so no `moov` atom is written and the resulting `audio.m4a` cannot be
/// opened at all - the log signature is `[playback] failed to load asset: Cannot
/// Open`. Such a recording still shows up in the recordings list, so every entry
/// point the UI reaches from a selected row has to fail as an error rather than
/// take the process down with it.
@Suite("Interrupted Recording", .serialized)
struct InterruptedRecordingTests {

  @Test("an unfinalized recording cannot be opened at all")
  func fixtureIsGenuinelyBroken() async throws {
    let (root, audioURL) = try await makeInterruptedRecording()
    defer { try? FileManager.default.removeItem(at: root) }

    // If this ever starts loading, the fixture stopped reproducing the bug and
    // the tests below would pass for the wrong reason.
    await #expect(throws: (any Error).self) {
      try await AVURLAsset(url: audioURL).loadTracks(withMediaType: .audio)
    }
  }

  @Test("opening a broken recording does not crash the waveform reduction")
  func waveformSurvives() async throws {
    let (root, audioURL) = try await makeInterruptedRecording()
    defer { try? FileManager.default.removeItem(at: root) }

    // Runs from RecordingDetailView.onAppear - the moment a row is selected.
    let samples = await WaveformExtractor.extract(from: audioURL)
    #expect(samples.isEmpty, "an unreadable asset has no waveform to draw")
  }

  @Test("mixdown leaves a broken recording untouched instead of destroying it")
  func mixdownSurvives() async throws {
    let (root, audioURL) = try await makeInterruptedRecording()
    defer { try? FileManager.default.removeItem(at: root) }

    await TrackMixdown.render(recordingDirectory: root)

    #expect(FileManager.default.fileExists(atPath: audioURL.path))
    // Roles must not be promoted to the 3-track layout when nothing was rendered.
    #expect(RecordingMetadata.load(in: root)?.tracks == nil)
  }

  @Test("transcribing a broken recording throws instead of crashing")
  func transcriptionSurvives() async throws {
    let (root, audioURL) = try await makeInterruptedRecording()
    defer { try? FileManager.default.removeItem(at: root) }

    // Reaches the asset before any network call, so no key is needed.
    let service = TranscriptionService(apiKey: "not-a-real-key")
    await #expect(throws: (any Error).self) {
      try await service.transcribe(fileURL: audioURL, languageHints: ["ru"]) { _ in }
    }
  }

  // MARK: - Fixtures

  /// Writes a complete 2-track recording, then cuts the tail off the file.
  ///
  /// An `AVAssetWriter` lays the `moov` atom down last, so a process that dies
  /// before `finishWriting()` returns leaves exactly this: media data with no
  /// index. Truncating a finalized file reproduces that byte-for-byte and is
  /// deterministic - abandoning a live writer is not, because it keeps flushing
  /// buffered data after the test stops looking.
  private func makeInterruptedRecording() async throws -> (URL, URL) {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "blackbox-interrupted-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let audioURL = root.appendingPathComponent("audio.m4a")

    try RecordingMetadata(
      title: "Interrupted",
      createdAt: .now,
      appName: "Tests",
      speakers: [:],
      perAppBundleID: nil,
      perAppName: nil,
      trackCount: 2,
      tracks: nil
    ).save(in: root)

    let writer = try AVAssetWriter(url: audioURL, fileType: .m4a)
    let sampleRate = RecordingPipeline.writerSampleRate
    let inputs = [(channels: 2, bitRate: 128_000), (channels: 1, bitRate: 64_000)]
      .map { spec in
        AVAssetWriterInput(
          mediaType: .audio,
          outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: spec.channels,
            AVEncoderBitRateKey: spec.bitRate,
          ])
      }
    for input in inputs { writer.add(input) }
    guard writer.startWriting() else { throw InterruptedFixtureError.writerProducedNothing }
    writer.startSession(atSourceTime: .zero)

    let frames = 1024
    for i in 0..<Int(2.0 * sampleRate) / frames {
      let pts = CMTime(value: Int64(i * frames), timescale: Int32(sampleRate))
      for (input, channels) in zip(inputs, [2, 1]) {
        while !input.isReadyForMoreMediaData {
          try await Task.sleep(for: .milliseconds(1))
        }
        guard
          let buffer = Self.makeToneBuffer(
            frames: frames, channels: channels, sampleRate: sampleRate, pts: pts)
        else { continue }
        input.append(buffer)
      }
    }

    for input in inputs { input.markAsFinished() }
    await writer.finishWriting()
    guard writer.status == .completed else {
      throw InterruptedFixtureError.writerProducedNothing
    }

    let handle = try FileHandle(forWritingTo: audioURL)
    defer { try? handle.close() }
    let complete = try handle.seekToEnd()
    guard complete > 0 else { throw InterruptedFixtureError.writerProducedNothing }
    try handle.truncate(atOffset: complete * 3 / 5)

    return (root, audioURL)
  }

  private static func makeToneBuffer(
    frames: Int, channels: Int, sampleRate: Double, pts: CMTime
  ) -> CMSampleBuffer? {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
        channels: AVAudioChannelCount(channels), interleaved: true),
      let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
    else { return nil }
    pcm.frameLength = AVAudioFrameCount(frames)
    if let data = pcm.floatChannelData {
      for i in 0..<(frames * channels) {
        data[0][i] = i % 2 == 0 ? 0.5 : -0.5
      }
    }
    guard var buffer = pcm.asSampleBuffer() else { return nil }
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: Int32(sampleRate)),
      presentationTimeStamp: pts,
      decodeTimeStamp: .invalid)
    var retimed: CMSampleBuffer?
    guard
      CMSampleBufferCreateCopyWithNewTiming(
        allocator: kCFAllocatorDefault, sampleBuffer: buffer, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleBufferOut: &retimed) == noErr,
      let retimed
    else { return buffer }
    buffer = retimed
    return buffer
  }

  private enum InterruptedFixtureError: Error {
    case writerProducedNothing
  }
}
