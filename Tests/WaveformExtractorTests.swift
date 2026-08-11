@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Blackbox

/// Regression cover for the waveform reduction that runs in
/// `RecordingDetailView.onAppear` - i.e. on every recording the user opens.
///
/// Two properties are pinned:
///   * the reduction covers the WHOLE recording (floor-division bucketing used
///     to silently drop the tail of any file whose chunk count was not a
///     multiple of `bucketCount`), and
///   * its memory is bounded by the bucket count, not by the recording length.
///     The previous implementation buffered every decoded PCM sample: measured
///     1.43 GB on a 70-minute recording, which jetsam-killed the app on long
///     calls.
/// Serialized: the memory assertion samples the process-wide footprint, which a
/// concurrently-running fixture would contaminate.
@Suite("Waveform Extraction", .serialized)
struct WaveformExtractorTests {

  // MARK: - Fixtures

  /// Writes a real 2-track recording through `RecordingPipeline` - the same
  /// writer production uses - so the fixture matches on-disk recordings.
  /// `loudFraction` of the duration carries a full-scale tone, the remainder
  /// is silence.
  private func makeRecording(seconds: Double, loudFraction: Double) async throws -> (URL, URL) {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "blackbox-waveform-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let audioURL = root.appendingPathComponent("audio.m4a")

    // Written directly rather than through RecordingPipeline: the pipeline
    // DROPS buffers while `isReadyForMoreMediaData` is false, so a tight
    // feeding loop silently yields a fraction of the requested duration and
    // the memory assertion below would prove nothing.
    let writer = try AVAssetWriter(url: audioURL, fileType: .m4a)
    let systemInput = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: RecordingPipeline.writerSampleRate,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 128_000,
      ])
    let micInput = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: RecordingPipeline.writerSampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000,
      ])
    writer.add(systemInput)
    writer.add(micInput)
    guard writer.startWriting() else { throw WaveformFixtureError.writerProducedNothing }
    writer.startSession(atSourceTime: .zero)

    let sampleRate = RecordingPipeline.writerSampleRate
    let frames = 1024
    let total = Int(seconds * sampleRate) / frames
    let loudUntil = Int(Double(total) * loudFraction)

    for i in 0..<total {
      let pts = CMTime(value: Int64(i * frames), timescale: Int32(sampleRate))
      let amplitude: Float = i < loudUntil ? 0.9 : 0
      for (input, channels) in [(systemInput, 2), (micInput, 1)] {
        while !input.isReadyForMoreMediaData {
          try await Task.sleep(for: .milliseconds(1))
        }
        guard
          let buffer = Self.makeToneBuffer(
            frames: frames, channels: channels, sampleRate: sampleRate,
            amplitude: amplitude, pts: pts)
        else { continue }
        input.append(buffer)
      }
    }

    systemInput.markAsFinished()
    micInput.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
      throw WaveformFixtureError.writerProducedNothing
    }

    // Prove the fixture really is as long as requested - otherwise the memory
    // assertion is vacuous.
    let written = try await AVURLAsset(url: audioURL).load(.duration).seconds
    guard written >= seconds * 0.95 else {
      throw WaveformFixtureError.shortFixture(expected: seconds, got: written)
    }
    return (root, audioURL)
  }

  private enum WaveformFixtureError: Error {
    case writerProducedNothing
    case shortFixture(expected: Double, got: Double)
  }

  /// Full-scale square-ish tone (constant magnitude) so every bucket in the
  /// loud region reduces to the same RMS - makes the boundary unambiguous.
  private static func makeToneBuffer(
    frames: Int, channels: Int, sampleRate: Double, amplitude: Float, pts: CMTime
  ) -> CMSampleBuffer? {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
        channels: AVAudioChannelCount(channels), interleaved: true),
      let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
    else { return nil }
    pcm.frameLength = AVAudioFrameCount(frames)
    if let data = pcm.floatChannelData {
      // Interleaved: one contiguous plane of frames * channels values.
      for i in 0..<(frames * channels) {
        data[0][i] = i % 2 == 0 ? amplitude : -amplitude
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
      let out = retimed
    else { return buffer }
    buffer = out
    return buffer
  }

  nonisolated private static func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard kr == KERN_SUCCESS else { return -1 }
    return Double(info.phys_footprint) / 1_048_576
  }

  // MARK: - Tests

  @Test("reduction spans the whole recording, not just its head")
  func coversEntireRecording() async throws {
    // 60s of audio is ~1400 internal chunks. Floor-division bucketing
    // (1400 / 300 = 4 chunks per bucket) would cover only 1200 of them, so the
    // waveform would render the first 85% of the recording stretched across
    // the full width and the tone boundary would land near bucket 87 instead
    // of 75. The tolerance below is what separates those two outcomes.
    let (root, audioURL) = try await makeRecording(seconds: 60, loudFraction: 0.25)
    defer { try? FileManager.default.removeItem(at: root) }

    let samples = await WaveformExtractor.extract(from: audioURL)
    #expect(samples.count == WaveformExtractor.bucketCount)

    // Last bucket still carrying real signal marks where the tone ended.
    let boundary = samples.lastIndex(where: { $0 > 0.5 }) ?? -1
    let expected = Int(Double(WaveformExtractor.bucketCount) * 0.25)
    print("waveform tone boundary: bucket \(boundary), expected ~\(expected)")
    #expect(
      abs(boundary - expected) <= 4,
      "tone ends at bucket \(boundary), expected ~\(expected) - tail dropped or stretched")

    // And the silent region really is silent.
    let tail = samples[(expected + 10)...]
    #expect(tail.allSatisfy { $0 < 0.1 })
  }

  @Test("memory stays bounded by bucket count, not recording length")
  func memoryIsBounded() async throws {
    // The old reduction buffered every decoded sample before bucketing:
    // measured 1.43 GB on a 70-minute recording. The cost is transient - the
    // buffer is released when extraction returns - so a before/after delta
    // misses it entirely. Sample the footprint WHILE extraction runs.
    let (root, audioURL) = try await makeRecording(seconds: 900, loudFraction: 1.0)
    defer { try? FileManager.default.removeItem(at: root) }

    let baseline = Self.footprintMB()
    let peak = PeakSampler()
    let sampler = Task.detached {
      while !Task.isCancelled {
        peak.observe(Self.footprintMB())
        try? await Task.sleep(for: .milliseconds(20))
      }
    }
    let samples = await WaveformExtractor.extract(from: audioURL)
    sampler.cancel()

    let growth = peak.value - baseline
    print("waveform peak growth: \(Int(growth)) MB over 15 minutes of audio")
    #expect(samples.count == WaveformExtractor.bucketCount)
    #expect(
      growth < 40,
      "peak footprint grew \(Int(growth)) MB reducing 15 min - buffering samples again")
  }

  /// Max-tracking box shared with the sampling task.
  nonisolated private final class PeakSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Double = 0

    func observe(_ mb: Double) {
      lock.lock()
      defer { lock.unlock() }
      if mb > peak { peak = mb }
    }

    var value: Double {
      lock.lock()
      defer { lock.unlock() }
      return peak
    }
  }
}
