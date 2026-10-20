import Foundation

/// Soniox `context`: biases recognition toward a domain and its vocabulary.
/// An accuracy hint, not a source of truth - nothing here is inferred from the
/// recording; it is only what the user typed in Settings or in the per-run
/// options sheet.
nonisolated struct SonioxContext: Codable, Sendable, Equatable {
  nonisolated struct Entry: Codable, Sendable, Equatable {
    var key: String
    var value: String
  }

  var general: [Entry] = []
  var text: String = ""
  var terms: [String] = []

  var isEmpty: Bool { general.isEmpty && text.isEmpty && terms.isEmpty }

  /// Builds a context from the plain-text editors: `key: value` per line for
  /// `general`, one term per line or comma for `terms`. Lines without a colon
  /// are ignored rather than guessed at.
  init(generalLines: String = "", terms termsText: String = "", text: String = "") {
    general = generalLines.split(whereSeparator: \.isNewline).compactMap { line in
      guard let colon = line.firstIndex(of: ":") else { return nil }
      let key = line[..<colon].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      return key.isEmpty || value.isEmpty ? nil : Entry(key: key, value: value)
    }
    terms = termsText.split(whereSeparator: { $0.isNewline || $0 == "," })
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The request-body shape. Empty sections are omitted: Soniox treats every
  /// section as optional and has no use for empty ones.
  var requestObject: [String: Any] {
    var object: [String: Any] = [:]
    if !general.isEmpty { object["general"] = general.map { ["key": $0.key, "value": $0.value] } }
    if !text.isEmpty { object["text"] = text }
    if !terms.isEmpty { object["terms"] = terms }
    return object
  }
}

/// Everything about a transcription request that the user can steer. Resolved
/// from Settings when a job is first planned, or taken whole from the per-run
/// options sheet, and then persisted in the job so a resumed job asks Soniox
/// for what the paid parts were asked for.
nonisolated struct TranscriptionConfig: Codable, Sendable, Equatable {
  var languageHints: [String]
  /// Soniox `language_hints_strict`: lean harder on the hints.
  var languageHintsStrict: Bool = false
  var languageIdentification: Bool = true
  /// Forces diarization on or off for every job of the recording. Nil keeps the
  /// per-role default (`TranscriptionService.diarizes`): the mic is one known
  /// speaker and is never diarized unless this says so.
  var diarization: Bool?
  var separateTracks: Bool = true
  var context = SonioxContext()

  init(
    languageHints: [String], languageHintsStrict: Bool = false,
    languageIdentification: Bool = true, diarization: Bool? = nil,
    separateTracks: Bool = true, context: SonioxContext = SonioxContext()
  ) {
    self.languageHints = languageHints
    self.languageHintsStrict = languageHintsStrict
    self.languageIdentification = languageIdentification
    self.diarization = diarization
    self.separateTracks = separateTracks
    self.context = context
  }

  /// Hand-written so a job record written before a field existed still decodes:
  /// the synthesized decoder throws on an absent key, and an undecodable job
  /// file strands what it names on Soniox.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    languageHints = try container.decodeIfPresent([String].self, forKey: .languageHints) ?? ["ru"]
    languageHintsStrict =
      try container.decodeIfPresent(Bool.self, forKey: .languageHintsStrict) ?? false
    languageIdentification =
      try container.decodeIfPresent(Bool.self, forKey: .languageIdentification) ?? true
    diarization = try container.decodeIfPresent(Bool.self, forKey: .diarization)
    separateTracks = try container.decodeIfPresent(Bool.self, forKey: .separateTracks) ?? true
    context = try container.decodeIfPresent(SonioxContext.self, forKey: .context) ?? SonioxContext()
  }

  /// Settings -> config. `ru`, split tracks, language identification on and no
  /// context are the defaults a fresh install gets.
  static func fromDefaults(_ defaults: UserDefaults = .standard) -> TranscriptionConfig {
    let diarization: Bool? =
      switch defaults.string(forKey: SettingsKeys.transcriptionDiarization) {
      case "on": true
      case "off": false
      default: nil
      }
    return TranscriptionConfig(
      languageHints: TranscriptionService.languageHints(
        from: defaults.string(forKey: SettingsKeys.transcriptionLanguages)
          ?? defaultTranscriptionLanguages),
      languageHintsStrict: defaults.bool(forKey: SettingsKeys.transcriptionLanguageHintsStrict),
      languageIdentification: defaults.object(
        forKey: SettingsKeys.transcriptionLanguageIdentification) as? Bool ?? true,
      diarization: diarization,
      separateTracks: defaults.object(forKey: SettingsKeys.transcribeSeparateTracks) as? Bool
        ?? true,
      context: SonioxContext(
        generalLines: defaults.string(forKey: SettingsKeys.transcriptionContextGeneral) ?? "",
        terms: defaults.string(forKey: SettingsKeys.transcriptionContextTerms) ?? "",
        text: defaults.string(forKey: SettingsKeys.transcriptionContextText) ?? ""))
  }
}
