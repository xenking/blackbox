import SwiftUI

/// The Soniox request knobs, shared by Settings (where they are the defaults,
/// bound to `AppStorage`) and the per-run sheet (where they are one run's
/// override, bound to local state). Strings are the editable form of
/// `TranscriptionConfig`; `TranscriptionConfig.fromDefaults` and
/// `TranscriptionOptionsDraft.config` parse them the same way.
struct TranscriptionOptionsFields: View {
  @Binding var languages: String
  @Binding var languageHintsStrict: Bool
  @Binding var languageIdentification: Bool
  /// "auto" (per-role default), "on" or "off".
  @Binding var diarization: String
  @Binding var separateTracks: Bool
  @Binding var contextGeneral: String
  @Binding var contextTerms: String
  @Binding var contextText: String

  var body: some View {
    TextField("Languages", text: $languages)
      .help("Comma-separated ISO language codes hinted to Soniox, for example ru or ru,en.")
    Toggle("Rely strictly on language hints", isOn: $languageHintsStrict)
    Toggle("Detect language per segment", isOn: $languageIdentification)

    Picker("Source", selection: $separateTracks) {
      Text("Separate microphone and desktop").tag(true)
      Text("Mixed track with diarization").tag(false)
    }
    .pickerStyle(.segmented)

    Picker("Diarization", selection: $diarization) {
      Text("Automatic").tag("auto")
      Text("Always on").tag("on")
      Text("Always off").tag("off")
    }
    Text(
      "Automatic diarizes the desktop track and the mixed track, never the microphone - it is one known speaker."
    )
    .font(.caption)
    .foregroundStyle(.secondary)

    VStack(alignment: .leading, spacing: 4) {
      Text("Context").font(.headline)
      Text("Helps Soniox with your domain and vocabulary. Roughly 10,000 characters at most.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text("General - one \"key: value\" per line, for example topic: sprint planning")
        .font(.caption)
      TextEditor(text: $contextGeneral)
        .font(.body.monospaced())
        .frame(minHeight: 54)
        .border(.separator)
      Text("Terms - names and jargon to spell correctly, one per line or comma-separated")
        .font(.caption)
      TextEditor(text: $contextTerms)
        .font(.body.monospaced())
        .frame(minHeight: 54)
        .border(.separator)
      Text("Background text - optional longer notes, weaker than the two above")
        .font(.caption)
      TextEditor(text: $contextText)
        .font(.body.monospaced())
        .frame(minHeight: 54)
        .border(.separator)
    }
  }
}

/// "Transcribe with options": starts from the Settings defaults and hands the
/// edited result to the coordinator as this run's whole config. Nothing here
/// is written back to Settings.
struct TranscriptionOptionsSheet: View {
  let hasTranscript: Bool
  let onStart: (TranscriptionConfig) -> Void
  @Environment(\.dismiss) private var dismiss

  @State private var languages: String
  @State private var languageHintsStrict: Bool
  @State private var languageIdentification: Bool
  @State private var diarization: String
  @State private var separateTracks: Bool
  @State private var contextGeneral: String
  @State private var contextTerms: String
  @State private var contextText: String

  init(hasTranscript: Bool, onStart: @escaping (TranscriptionConfig) -> Void) {
    self.hasTranscript = hasTranscript
    self.onStart = onStart
    let defaults = UserDefaults.standard
    _languages = State(
      initialValue: defaults.string(forKey: SettingsKeys.transcriptionLanguages)
        ?? defaultTranscriptionLanguages)
    _languageHintsStrict = State(
      initialValue: defaults.bool(forKey: SettingsKeys.transcriptionLanguageHintsStrict))
    _languageIdentification = State(
      initialValue: defaults.object(forKey: SettingsKeys.transcriptionLanguageIdentification)
        as? Bool ?? true)
    _diarization = State(
      initialValue: defaults.string(forKey: SettingsKeys.transcriptionDiarization) ?? "auto")
    _separateTracks = State(
      initialValue: defaults.object(forKey: SettingsKeys.transcribeSeparateTracks) as? Bool
        ?? true)
    _contextGeneral = State(
      initialValue: defaults.string(forKey: SettingsKeys.transcriptionContextGeneral) ?? "")
    _contextTerms = State(
      initialValue: defaults.string(forKey: SettingsKeys.transcriptionContextTerms) ?? "")
    _contextText = State(
      initialValue: defaults.string(forKey: SettingsKeys.transcriptionContextText) ?? "")
  }

  private var config: TranscriptionConfig {
    TranscriptionConfig(
      languageHints: TranscriptionService.languageHints(from: languages),
      languageHintsStrict: languageHintsStrict,
      languageIdentification: languageIdentification,
      diarization: diarization == "on" ? true : diarization == "off" ? false : nil,
      separateTracks: separateTracks,
      context: SonioxContext(
        generalLines: contextGeneral, terms: contextTerms, text: contextText))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Transcribe With Options").font(.title3.bold())
      Text("Applies to this run only; Settings are not changed.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Form {
        TranscriptionOptionsFields(
          languages: $languages, languageHintsStrict: $languageHintsStrict,
          languageIdentification: $languageIdentification, diarization: $diarization,
          separateTracks: $separateTracks, contextGeneral: $contextGeneral,
          contextTerms: $contextTerms, contextText: $contextText)
      }
      .formStyle(.grouped)
      Text(
        hasTranscript
          ? "This replaces the current transcript and uploads the audio to Soniox again, which is billed."
          : "This uploads the audio to Soniox, which is billed."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button(hasTranscript ? "Transcribe Again" : "Transcribe") {
          onStart(config)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding()
    .frame(width: 520, height: 640)
  }
}
