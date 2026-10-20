import Foundation
import Testing

@testable import Blackbox

@Suite("Transcription Grouping")
struct TranscriptionGroupingTests {
  @Test("splits a mic track after a pause")
  func splitsMicTrackOnGap() {
    let document = TranscriptionService.groupTokensIntoDocument([
      SonioxTranscriptToken(
        text: "First ", startMilliseconds: 0, endMilliseconds: 300, speaker: -1),
      SonioxTranscriptToken(
        text: "second", startMilliseconds: 1_201, endMilliseconds: 1_600, speaker: -1),
    ])

    #expect(document.segments.count == 2)
    #expect(document.segments[0].time == 0)
    #expect(document.segments[0].endTime == 0.3)
    #expect(document.segments[1].time == 1.201)
    #expect(document.segments[1].endTime == 1.6)
  }

  @Test("splits when the diarized speaker changes")
  func splitsOnSpeakerChange() {
    let document = TranscriptionService.groupTokensIntoDocument([
      SonioxTranscriptToken(
        text: "Hello ", startMilliseconds: 0, endMilliseconds: 300, speaker: 0),
      SonioxTranscriptToken(
        text: "there", startMilliseconds: 350, endMilliseconds: 700, speaker: 1),
    ])

    #expect(document.segments.count == 2)
    #expect(document.segments[0].speaker == 0)
    #expect(document.segments[1].speaker == 1)
  }

  @Test("does not split an uninterrupted long run")
  func keepsUninterruptedRunTogether() {
    let document = TranscriptionService.groupTokensIntoDocument([
      SonioxTranscriptToken(
        text: "one ", startMilliseconds: 0, endMilliseconds: 1_000, speaker: -1),
      SonioxTranscriptToken(
        text: "two ", startMilliseconds: 1_000, endMilliseconds: 5_000, speaker: -1),
      SonioxTranscriptToken(
        text: "three ", startMilliseconds: 5_000, endMilliseconds: 10_000, speaker: -1),
      SonioxTranscriptToken(
        text: "four", startMilliseconds: 10_000, endMilliseconds: 15_000, speaker: -1),
    ])

    #expect(document.segments.count == 1)
    #expect(document.segments[0].time == 0)
    #expect(document.segments[0].endTime == 15)
  }

  @Test("merges local and far-end segments by timeline")
  func mergesTracksByTime() {
    let mic = TranscriptDocument(
      segments: [
        TranscriptSegment(speaker: -1, time: 1, text: "me one", endTime: 1.5),
        TranscriptSegment(speaker: -1, time: 4, text: "me two", endTime: 4.5),
      ],
      language: "ru",
      createdAt: .now
    )
    let farEnd = TranscriptDocument(
      segments: [
        TranscriptSegment(speaker: 0, time: 0.5, text: "them one", endTime: 0.9),
        TranscriptSegment(speaker: 1, time: 3, text: "them two", endTime: 3.5),
      ],
      language: "ru",
      createdAt: .now
    )

    let merged = TranscriptionService.mergeDocuments([mic, farEnd])

    #expect(merged.segments.count == 4)
    #expect(merged.segments.map(\.time) == [0.5, 1, 3, 4])
    #expect(merged.segments.map(\.speaker) == [0, -1, 1, -1])
    #expect(merged.segments.map(\.text) == ["them one", "me one", "them two", "me two"])
    #expect(merged.segments.allSatisfy { $0.endTime != nil })
  }

  @Test("parses Soniox language hints")
  func parsesLanguageHints() {
    #expect(TranscriptionService.languageHints(from: "ru") == ["ru"])
    #expect(TranscriptionService.languageHints(from: " ru , en ") == ["ru", "en"])
    #expect(TranscriptionService.languageHints(from: "") == ["ru"])
  }

  @Test("separate tracks keep the local mic out of desktop diarization")
  func separateTrackRequestContract() {
    let metadata = RecordingMetadata(
      title: "Current three-track recording",
      createdAt: .now,
      appName: "Tests",
      speakers: [:],
      trackCount: 3,
      tracks: [.mixed, .mic, .system]
    )
    let map = RecordingTrackMap.resolve(metadata: metadata, trackCount: 3)
    let roles = TranscriptionService.planRoles(
      separateTracks: true, map: map, trackCount: 3)

    #expect(roles == [.mic, .farEnd])
    #expect(roles.map(TranscriptionService.diarizes) == [false, true])

    let mic = TranscriptionService.transcriptionConfiguration(
      model: TranscriptionService.defaultModel, fileId: "mic", role: roles[0],
      config: TranscriptionConfig(languageHints: ["ru"]))
    let desktop = TranscriptionService.transcriptionConfiguration(
      model: TranscriptionService.defaultModel, fileId: "desktop", role: roles[1],
      config: TranscriptionConfig(languageHints: ["ru"]))
    #expect(mic["enable_speaker_diarization"] as? Bool == false)
    #expect(desktop["enable_speaker_diarization"] as? Bool == true)
    #expect(mic["context"] == nil)
    #expect(desktop["context"] == nil)
  }
}
