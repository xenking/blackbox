@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Blackbox

@Suite("Track Mixdown", .serialized)
struct TrackMixdownTests {
  private static let sampleRate: Double = 48_000
  private static let framesPerBuffer = 1024
  private static let fixtureSeconds = 4.0

  @Test("resolves legacy and declared track roles")
  func resolvesTrackRoles() {
    let dualTrack = RecordingTrackMap.resolve(metadata: nil, trackCount: 2)
    #expect(dualTrack.roles == [.system, .mic])
    #expect(dualTrack.micIndex == 1)
    #expect(dualTrack.farEndIndex == 0)
    #expect(dualTrack.mixedIndex == nil)

    let legacyMetadata = RecordingMetadata(
      title: "Legacy three-track recording",
      createdAt: .now,
      appName: "Tests",
      speakers: [:],
      perAppBundleID: nil,
      perAppName: nil,
      trackCount: 3,
      tracks: nil
    )

    let legacyTriple = RecordingTrackMap.resolve(metadata: legacyMetadata, trackCount: 3)
    #expect(legacyTriple.roles == [.system, .perApp, .mic])
    #expect(legacyTriple.micIndex == 2)
    #expect(legacyTriple.farEndIndex == 1)
    #expect(legacyTriple.mixedIndex == nil)

    let declaredMetadata = RecordingMetadata(
      title: "Three-track recording",
      createdAt: .now,
      appName: "Tests",
      speakers: [:],
      perAppBundleID: nil,
      perAppName: nil,
      trackCount: 3,
      tracks: [.mixed, .mic, .system]
    )
    let declaredTriple = RecordingTrackMap.resolve(metadata: declaredMetadata, trackCount: 3)
    #expect(declaredTriple.roles == [.mixed, .mic, .system])
    #expect(declaredTriple.micIndex == 1)
    #expect(declaredTriple.farEndIndex == 2)
    #expect(declaredTriple.mixedIndex == 0)
  }

  @Test("renders mixed mic and system tracks")
  func rendersCanonicalLayout() async throws {
    let directory = try await makeRecording(includeMic: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let audioURL = directory.appendingPathComponent("audio.m4a")

    let sourceAsset = AVURLAsset(url: audioURL)
    let sourceTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
    try #require(sourceTracks.count == 2, "Fixture should have system and mic tracks")
    let sourceSystemRange = try await sourceTracks[0].load(.timeRange)
    let sourceMicRange = try await sourceTracks[1].load(.timeRange)

    await TrackMixdown.render(recordingDirectory: directory)

    let mixedAsset = AVURLAsset(url: audioURL)
    let mixedTracks = try await mixedAsset.loadTracks(withMediaType: .audio)
    try #require(mixedTracks.count == 3, "Expected mixed, mic, and system tracks")

    let metadata = try #require(
      RecordingMetadata.load(in: directory),
      "Mixdown should preserve and update metadata")
    #expect(metadata.tracks == [.mixed, .mic, .system])
    #expect(metadata.trackCount == 3)

    let remuxedMicRange = try await mixedTracks[1].load(.timeRange)
    let remuxedSystemRange = try await mixedTracks[2].load(.timeRange)
    #expect(
      abs(remuxedMicRange.duration.seconds - sourceMicRange.duration.seconds) < 0.05,
      "Mic duration changed from \(sourceMicRange.duration.seconds) to \(remuxedMicRange.duration.seconds)"
    )
    #expect(
      abs(remuxedSystemRange.duration.seconds - sourceSystemRange.duration.seconds) < 0.05,
      "System duration changed from \(sourceSystemRange.duration.seconds) to \(remuxedSystemRange.duration.seconds)"
    )

    let mixedRMS = try await rms(of: mixedTracks[0], in: mixedAsset)
    #expect(mixedRMS > 0.001, "Mixed track is silent (RMS=\(mixedRMS))")
  }

  @Test("can retain the native separate-track recording")
  func skipsMixedTrackWhenDisabled() async throws {
    let directory = try await makeRecording(includeMic: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let audioURL = directory.appendingPathComponent("audio.m4a")
    let originalData = try Data(contentsOf: audioURL)

    await TrackMixdown.render(recordingDirectory: directory, includeMixedTrack: false)

    #expect(try await audioTrackCount(at: audioURL) == 2)
    #expect(try Data(contentsOf: audioURL) == originalData)
    #expect(RecordingMetadata.load(in: directory)?.tracks == [.system, .mic])
  }

  @Test("leaves recordings without work unchanged")
  func leavesNoopInputsUntouched() async throws {
    let singleTrackDirectory = try await makeRecording(includeMic: false)
    defer { try? FileManager.default.removeItem(at: singleTrackDirectory) }
    try await expectNoopMixdown(in: singleTrackDirectory)

    let renderedDirectory = try await makeRecording(includeMic: true)
    defer { try? FileManager.default.removeItem(at: renderedDirectory) }
    await TrackMixdown.render(recordingDirectory: renderedDirectory)
    let renderedTrackCount = try await audioTrackCount(
      at: renderedDirectory.appendingPathComponent("audio.m4a"))
    try #require(renderedTrackCount == 3, "Fixture should render before its no-op pass")
    try await expectNoopMixdown(in: renderedDirectory)
  }

  // MARK: - Fixtures

  private func makeRecording(includeMic: Bool) async throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("blackbox-track-mixdown-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let audioURL = directory.appendingPathComponent("audio.m4a")
    let metadata = RecordingMetadata(
      title: "Track mixdown fixture",
      createdAt: .now,
      appName: "Tests",
      speakers: [:],
      perAppBundleID: nil,
      perAppName: nil,
      trackCount: includeMic ? 2 : 1,
      tracks: includeMic ? [.system, .mic] : [.system]
    )
    try metadata.save(in: directory)

    let writer = try AVAssetWriter(url: audioURL, fileType: .m4a)
    let systemInput = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: Self.sampleRate,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 128_000,
      ])
    writer.add(systemInput)

    var inputs: [(input: AVAssetWriterInput, channels: Int, amplitude: Float)] = [
      (systemInput, 2, 0.15)
    ]
    if includeMic {
      let micInput = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: Self.sampleRate,
          AVNumberOfChannelsKey: 1,
          AVEncoderBitRateKey: 64_000,
        ])
      writer.add(micInput)
      inputs.append((micInput, 1, 0.45))
    }

    guard writer.startWriting() else { throw TrackMixdownFixtureError.writerFailed }
    writer.startSession(atSourceTime: .zero)

    let bufferCount = Int(Self.fixtureSeconds * Self.sampleRate) / Self.framesPerBuffer
    for bufferIndex in 0..<bufferCount {
      let pts = CMTime(
        value: Int64(bufferIndex * Self.framesPerBuffer), timescale: Int32(Self.sampleRate))
      for source in inputs {
        while !source.input.isReadyForMoreMediaData {
          try await Task.sleep(for: .milliseconds(1))
        }
        let buffer = try #require(
          Self.toneSampleBuffer(
            frames: Self.framesPerBuffer,
            channels: source.channels,
            amplitude: source.amplitude,
            startFrame: bufferIndex * Self.framesPerBuffer,
            presentationTime: pts),
          "Could not create fixture audio buffer")
        guard source.input.append(buffer) else {
          throw TrackMixdownFixtureError.writerFailed
        }
      }
    }

    for source in inputs {
      source.input.markAsFinished()
    }
    await writer.finishWriting()
    guard writer.status == .completed else { throw TrackMixdownFixtureError.writerFailed }

    // Assert the real duration before any mixdown assertion uses this fixture.
    let writtenDuration = try await AVURLAsset(url: audioURL).load(.duration).seconds
    guard writtenDuration >= Self.fixtureSeconds * 0.95 else {
      throw TrackMixdownFixtureError.shortFixture
    }
    return directory
  }

  private static func toneSampleBuffer(
    frames: Int,
    channels: Int,
    amplitude: Float,
    startFrame: Int,
    presentationTime: CMTime
  ) -> CMSampleBuffer? {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Self.sampleRate,
        channels: AVAudioChannelCount(channels),
        interleaved: true),
      let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
    else { return nil }
    pcm.frameLength = AVAudioFrameCount(frames)
    if let data = pcm.floatChannelData {
      for frame in 0..<frames {
        let phase = 2 * Float.pi * 440 * Float(startFrame + frame) / Float(Self.sampleRate)
        let sample = amplitude * sin(phase)
        for channel in 0..<channels {
          data[0][frame * channels + channel] = sample
        }
      }
    }

    guard let buffer = pcm.asSampleBuffer() else { return nil }
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: Int32(Self.sampleRate)),
      presentationTimeStamp: presentationTime,
      decodeTimeStamp: .invalid)
    var retimed: CMSampleBuffer?
    guard
      CMSampleBufferCreateCopyWithNewTiming(
        allocator: kCFAllocatorDefault,
        sampleBuffer: buffer,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleBufferOut: &retimed) == noErr
    else { return buffer }
    return retimed
  }

  private func expectNoopMixdown(in directory: URL) async throws {
    let audioURL = directory.appendingPathComponent("audio.m4a")
    let sizeBefore = try fileSize(at: audioURL)
    let trackCountBefore = try await audioTrackCount(at: audioURL)

    await TrackMixdown.render(recordingDirectory: directory)

    let sizeAfter = try fileSize(at: audioURL)
    let trackCountAfter = try await audioTrackCount(at: audioURL)
    #expect(
      sizeAfter == sizeBefore,
      "No-op mixdown changed file size from \(sizeBefore) to \(sizeAfter)")
    #expect(
      trackCountAfter == trackCountBefore,
      "No-op mixdown changed track count from \(trackCountBefore) to \(trackCountAfter)")
  }

  private func audioTrackCount(at url: URL) async throws -> Int {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    return tracks.count
  }

  private func fileSize(at url: URL) throws -> Int {
    try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
  }

  private func rms(of track: AVAssetTrack, in asset: AVAsset) async throws -> Double {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: Self.sampleRate,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ])
    reader.add(output)
    guard reader.startReading() else { throw TrackMixdownFixtureError.readerFailed }

    var sumOfSquares = 0.0
    var sampleCount = 0
    while let buffer = output.copyNextSampleBuffer() {
      guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }
      let length = CMBlockBufferGetDataLength(blockBuffer)
      let floatCount = length / MemoryLayout<Float>.size
      guard floatCount > 0 else { continue }
      var samples = [Float](repeating: 0, count: floatCount)
      let copied = samples.withUnsafeMutableBufferPointer { pointer -> Bool in
        guard let base = pointer.baseAddress else { return false }
        return CMBlockBufferCopyDataBytes(
          blockBuffer, atOffset: 0, dataLength: length, destination: base) == kCMBlockBufferNoErr
      }
      guard copied else { throw TrackMixdownFixtureError.readerFailed }
      for sample in samples {
        sumOfSquares += Double(sample * sample)
      }
      sampleCount += samples.count
    }
    guard reader.status != .failed, sampleCount > 0 else {
      throw TrackMixdownFixtureError.readerFailed
    }
    return (sumOfSquares / Double(sampleCount)).squareRoot()
  }
}

private enum TrackMixdownFixtureError: Error {
  case writerFailed
  case shortFixture
  case readerFailed
}
