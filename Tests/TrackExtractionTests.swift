@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Blackbox

/// Per-track transcription stands or falls on `extractTrack`: whatever it writes is
/// literally what Soniox hears. These run the real extraction against a real
/// 3-track recording, so a silently empty or wrong-track export cannot reach the API.
@Suite("Track Extraction")
struct TrackExtractionTests {

  @Test("extracts each declared role as a full-length single-track file")
  func extractsRolesIndependently() async throws {
    let root = try await makeThreeTrackRecording()
    defer { try? FileManager.default.removeItem(at: root) }

    let audioURL = root.appendingPathComponent("audio.m4a")
    let metadata = try #require(RecordingMetadata.load(in: root))
    let sourceTracks = try await AVURLAsset(url: audioURL).loadTracks(withMediaType: .audio)
    let map = RecordingTrackMap.resolve(metadata: metadata, trackCount: sourceTracks.count)

    let micIndex = try #require(map.micIndex)
    let farEndIndex = try #require(map.farEndIndex)
    #expect(micIndex != farEndIndex, "mic and far-end must be different tracks")

    let sourceDuration = try await AVURLAsset(url: audioURL).load(.duration).seconds

    for (label, index) in [("mic", micIndex), ("far-end", farEndIndex)] {
      let extracted = try await TranscriptionService.extractTrack(from: audioURL, at: index)
      defer { try? FileManager.default.removeItem(at: extracted) }

      let asset = AVURLAsset(url: extracted)
      let tracks = try await asset.loadTracks(withMediaType: .audio)
      #expect(tracks.count == 1, "\(label) upload must carry exactly one track")

      // An empty or near-empty export is the failure that would waste a paid API
      // call and return an empty transcript, so pin the duration to the source.
      let duration = try await asset.load(.duration).seconds
      #expect(
        abs(duration - sourceDuration) < 0.2,
        "\(label) upload is \(duration)s but the recording is \(sourceDuration)s")

      // The file has to be decodable, not merely present: a non-zero byte count
      // says nothing about whether AVAssetExportSession produced usable audio.
      let samples = try await decodeFirstSamples(from: extracted)
      #expect(samples > 0, "\(label) upload decoded no audio samples")
    }
  }

  @Test("extracting a track that does not exist throws instead of uploading junk")
  func rejectsMissingTrack() async throws {
    let root = try await makeThreeTrackRecording()
    defer { try? FileManager.default.removeItem(at: root) }
    let audioURL = root.appendingPathComponent("audio.m4a")

    await #expect(throws: (any Error).self) {
      _ = try await TranscriptionService.extractTrack(from: audioURL, at: 7)
    }
  }

  /// The two roles must not come back with identical audio - that would mean the
  /// index mapping collapsed and both Soniox jobs transcribe the same voice.
  @Test("mic and far-end extractions differ in content")
  func rolesCarryDifferentAudio() async throws {
    let root = try await makeThreeTrackRecording()
    defer { try? FileManager.default.removeItem(at: root) }

    let audioURL = root.appendingPathComponent("audio.m4a")
    let metadata = try #require(RecordingMetadata.load(in: root))
    let count = try await AVURLAsset(url: audioURL).loadTracks(withMediaType: .audio).count
    let map = RecordingTrackMap.resolve(metadata: metadata, trackCount: count)

    let micURL = try await TranscriptionService.extractTrack(
      from: audioURL, at: try #require(map.micIndex))
    defer { try? FileManager.default.removeItem(at: micURL) }
    let farEndURL = try await TranscriptionService.extractTrack(
      from: audioURL, at: try #require(map.farEndIndex))
    defer { try? FileManager.default.removeItem(at: farEndURL) }

    let micEnergy = try await rms(of: micURL)
    let farEndEnergy = try await rms(of: farEndURL)
    #expect(micEnergy > 0.001, "mic extraction is silent")
    #expect(farEndEnergy > 0.001, "far-end extraction is silent")
    // The fixture writes distinct amplitudes per role, so equal RMS means the
    // same source track was exported twice.
    #expect(
      abs(micEnergy - farEndEnergy) > 0.01,
      "mic RMS \(micEnergy) matches far-end \(farEndEnergy) - same track exported twice")
  }

  // MARK: - Fixtures

  /// Produces a real canonical 3-track recording by running the production
  /// pipeline and then the production mixdown, so the layout under test is the
  /// one the app actually writes rather than a hand-built approximation.
  private func makeThreeTrackRecording() async throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "blackbox-extract-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let pipeline = RecordingPipeline(
      appName: "Extraction Test",
      micEnabled: true,
      saveDirectory: root,
      alignmentMode: .waitForAllTracks
    )
    try pipeline.start()

    let sampleRate = RecordingPipeline.writerSampleRate
    let frames = 1024
    for i in 0..<Int(2.0 * sampleRate) / frames {
      let pts = CMTime(value: Int64(i * frames), timescale: Int32(sampleRate))
      // Distinct amplitudes so the two roles are distinguishable by RMS, and
      // in-band frequencies so AAC does not filter the signal away - an
      // alternating-sample tone sits at Nyquist and survives encoding as silence.
      if let system = Self.makeToneBuffer(
        frames: frames, channels: 2, sampleRate: sampleRate,
        frequency: 300, amplitude: 0.8, startFrame: i * frames, pts: pts)
      {
        pipeline.appendSystemSample(system)
      }
      if let mic = Self.makeToneBuffer(
        frames: frames, channels: 1, sampleRate: sampleRate,
        frequency: 440, amplitude: 0.25, startFrame: i * frames, pts: pts)
      {
        pipeline.appendMicSample(mic)
      }
    }

    guard let directory = await pipeline.stop() else {
      throw ExtractionFixtureError.pipelineProducedNothing
    }
    await TrackMixdown.render(recordingDirectory: directory)
    let rendered = try await AVURLAsset(url: directory.appendingPathComponent("audio.m4a"))
      .loadTracks(withMediaType: .audio).count
    guard rendered == 3 else {
      throw ExtractionFixtureError.mixdownFailed(tracks: rendered)
    }
    return directory
  }

  private func decodeFirstSamples(from url: URL) async throws -> Int {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    guard let track = tracks.first else { return 0 }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ])
    guard reader.canAdd(output) else { return 0 }
    reader.add(output)
    guard reader.startReading() else { return 0 }

    var total = 0
    while let buffer = output.copyNextSampleBuffer() {
      total += CMSampleBufferGetNumSamples(buffer)
    }
    return total
  }

  private func rms(of url: URL) async throws -> Double {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    guard let track = tracks.first else { return 0 }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ])
    guard reader.canAdd(output) else { return 0 }
    reader.add(output)
    guard reader.startReading() else { return 0 }

    var sumSquares = 0.0
    var count = 0
    while let buffer = output.copyNextSampleBuffer() {
      guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }
      let length = CMBlockBufferGetDataLength(blockBuffer)
      guard length > 0 else { continue }
      var scratch = [Int16](repeating: 0, count: length / MemoryLayout<Int16>.size)
      let copied = scratch.withUnsafeMutableBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return false }
        return CMBlockBufferCopyDataBytes(
          blockBuffer, atOffset: 0, dataLength: length, destination: base) == kCMBlockBufferNoErr
      }
      guard copied else { continue }
      for sample in scratch {
        let value = Double(sample) / 32768.0
        sumSquares += value * value
      }
      count += scratch.count
    }
    guard count > 0 else { return 0 }
    return (sumSquares / Double(count)).squareRoot()
  }

  /// Continuous sine across buffers: `startFrame` keeps the phase unbroken so the
  /// encoder sees one steady tone rather than a click train.
  private static func makeToneBuffer(
    frames: Int, channels: Int, sampleRate: Double, frequency: Double, amplitude: Float,
    startFrame: Int, pts: CMTime
  ) -> CMSampleBuffer? {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
        channels: AVAudioChannelCount(channels), interleaved: true),
      let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
    else { return nil }
    pcm.frameLength = AVAudioFrameCount(frames)
    guard let data = pcm.floatChannelData else { return nil }
    let step = 2.0 * Double.pi * frequency / sampleRate
    for frame in 0..<frames {
      let value = Float(sin(Double(startFrame + frame) * step)) * amplitude
      // Interleaved: one contiguous plane of frames * channels values.
      for channel in 0..<channels {
        data[0][frame * channels + channel] = value
      }
    }
    guard let buffer = pcm.asSampleBuffer() else { return nil }
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: Int32(sampleRate)),
      presentationTimeStamp: pts,
      decodeTimeStamp: .invalid)
    var retimed: CMSampleBuffer?
    guard
      CMSampleBufferCreateCopyWithNewTiming(
        allocator: kCFAllocatorDefault, sampleBuffer: buffer, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleBufferOut: &retimed) == noErr
    else { return buffer }
    return retimed ?? buffer
  }

  private enum ExtractionFixtureError: Error {
    case pipelineProducedNothing
    case mixdownFailed(tracks: Int)
  }
}
