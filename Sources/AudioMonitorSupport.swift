import AVFoundation
import AppKit
import CoreAudio
import UserNotifications

protocol RecorderSession: AnyObject {
  var appName: String { get }
  func start() async throws
  func stop() async -> URL?
}

struct RecorderSessionConfiguration: Sendable {
  var bundleID: String?
  var appName: String
  var micEnabled: Bool
  var saveDirectory: URL
  var isManualRecording: Bool
  var titlePrefix: String = ""
}

protocol RecorderSessionFactory {
  func makeRecorder(
    configuration: RecorderSessionConfiguration,
    onFailure: (@Sendable (RecorderFailure) -> Void)?,
    onAudioLevel: (@Sendable (Float) -> Void)?,
    onLowDiskSpace: (@Sendable (Int64) -> Void)?,
    onContinuity: (@Sendable () -> Void)?
  ) -> any RecorderSession
}

struct LiveRecorderSessionFactory: RecorderSessionFactory {
  func makeRecorder(
    configuration: RecorderSessionConfiguration,
    onFailure: (@Sendable (RecorderFailure) -> Void)?,
    onAudioLevel: (@Sendable (Float) -> Void)?,
    onLowDiskSpace: (@Sendable (Int64) -> Void)?,
    onContinuity: (@Sendable () -> Void)?
  ) -> any RecorderSession {
    AudioRecorder(
      bundleID: configuration.bundleID,
      appName: configuration.appName,
      micEnabled: configuration.micEnabled,
      saveDirectory: configuration.saveDirectory,
      isManualRecording: configuration.isManualRecording,
      titlePrefix: configuration.titlePrefix,
      onFailure: onFailure,
      onAudioLevel: onAudioLevel,
      onLowDiskSpace: onLowDiskSpace,
      onContinuity: onContinuity
    )
  }
}

extension AudioRecorder: RecorderSession {}

@MainActor
protocol AudioMonitorHUD: AnyObject {
  func showRecordingStarted(appName: String)
  func showRecordingSaved(appName: String)
  func showError(message: String)
}

extension RecordingHUD: AudioMonitorHUD {}

struct AudioMonitorSettings: Sendable {
  var autoRecord: Bool
  var gracePeriod: TimeInterval
  var micEnabled: Bool
  var saveDirectory: URL
  var notifyOnStart: Bool
  var notifyOnSaved: Bool
  var notifyOnError: Bool
  var namePrefixTemplate: String = ""
  var excludedBundleIDs: Set<String> = []
  /// Lowercased substrings matched against the window titles of a calling app.
  /// A caller whose any open window title contains one of these never triggers
  /// auto-recording - this is how a single browser tab (whose title is the
  /// window title) is excluded without excluding the whole browser.
  var excludedTitlePatterns: Set<String> = []

  /// Parses a comma-separated UserDefaults list value (`excludedBundleIDs`,
  /// `excludedTitlePatterns`). Single source of truth for the storage format
  /// (also written by SettingsView).
  static func parseBundleIDList(_ raw: String) -> [String] {
    raw.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }
}

/// Titles of an app's on-screen windows (layer 0 only, so menu-bar items and
/// overlays are skipped). Needs Screen Recording permission for `kCGWindowName`
/// - the app already requires it for SCStream capture. Browsers report the
/// active tab of each window here, which is what makes tab-title exclusion work.
@MainActor
func liveWindowTitles(forBundleID bundleID: String) -> [String] {
  guard let app = findRunningApplication(bundleID: bundleID) else { return [] }
  let pid = app.processIdentifier
  guard
    let windows = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]]
  else { return [] }

  return windows.compactMap { window in
    guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
      let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
      let name = window[kCGWindowName as String] as? String, !name.isEmpty
    else { return nil }
    return name
  }
}

/// Look up a running app by bundle ID, falling back to a case-insensitive
/// match. Chromium-based browsers report helper bundle IDs in a different case
/// than the registered one (e.g. `company.thebrowser.browser` vs
/// `company.thebrowser.Browser`), and the exact-match API misses those.
@MainActor
func findRunningApplication(bundleID: String) -> NSRunningApplication? {
  if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
    return app
  }
  let lowered = bundleID.lowercased()
  return NSWorkspace.shared.runningApplications.first {
    $0.bundleIdentifier?.lowercased() == lowered
  }
}

/// Resolves a recording-name prefix template into a concrete string.
/// Plain substitution of YYYY/YY/MM/DD tokens - deliberately not DateFormatter,
/// where uppercase YY/DD mean week-based year and day-of-year.
func formatNamePrefix(template: String, date: Date) -> String {
  guard !template.isEmpty else { return "" }
  let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
  let year = parts.year ?? 0
  return
    template
    .replacingOccurrences(of: "YYYY", with: String(format: "%04d", year))
    .replacingOccurrences(of: "YY", with: String(format: "%02d", year % 100))
    .replacingOccurrences(of: "MM", with: String(format: "%02d", parts.month ?? 0))
    .replacingOccurrences(of: "DD", with: String(format: "%02d", parts.day ?? 0))
}

struct AudioMonitorDependencies {
  var recorderFactory: any RecorderSessionFactory
  var hud: any AudioMonitorHUD
  var loadSettings: @MainActor () -> AudioMonitorSettings
  var microphoneAuthorizationStatus: @MainActor () -> AVAuthorizationStatus
  var requestMicrophoneAccessIfNeeded: @MainActor () async -> Void
  var notifyPermissionLost: @MainActor () async -> Void
  var findActiveCallingProcesses: @MainActor () -> [String?]
  var windowTitles: @MainActor (String) -> [String]
  var now: @MainActor () -> Date
  var sleep: @Sendable (Duration) async -> Void

  static let live = AudioMonitorDependencies(
    recorderFactory: LiveRecorderSessionFactory(),
    hud: RecordingHUD(),
    loadSettings: {
      if BlackboxTestMode.isEnabled {
        return AudioMonitorSettings(
          autoRecord: false,
          gracePeriod: 5,
          micEnabled: true,
          saveDirectory: BlackboxTestMode.saveDirectoryOverride
            ?? URL(fileURLWithPath: defaultSaveDirectoryPath),
          notifyOnStart: false,
          notifyOnSaved: false,
          notifyOnError: false,
          namePrefixTemplate: ""
        )
      }

      let defaults = UserDefaults.standard
      let path = defaults.string(forKey: "saveDirectoryPath") ?? defaultSaveDirectoryPath
      return AudioMonitorSettings(
        autoRecord: defaults.object(forKey: "autoRecord") as? Bool ?? true,
        gracePeriod: defaults.double(forKey: "gracePeriod").clamped(to: 5...60, default: 5),
        micEnabled: defaults.object(forKey: "micEnabled") as? Bool ?? true,
        saveDirectory: URL(fileURLWithPath: path),
        notifyOnStart: defaults.object(forKey: "notifyOnStart") as? Bool ?? true,
        notifyOnSaved: defaults.object(forKey: "notifyOnSaved") as? Bool ?? true,
        notifyOnError: defaults.object(forKey: "notifyOnError") as? Bool ?? true,
        namePrefixTemplate: defaults.string(forKey: "namePrefixTemplate") ?? "YYMM-DD-",
        excludedBundleIDs: Set(
          AudioMonitorSettings.parseBundleIDList(
            defaults.string(forKey: "excludedBundleIDs") ?? "")),
        excludedTitlePatterns: Set(
          AudioMonitorSettings.parseBundleIDList(
            defaults.string(forKey: "excludedTitlePatterns") ?? ""
          ).map { $0.lowercased() })
      )
    },
    microphoneAuthorizationStatus: {
      AVCaptureDevice.authorizationStatus(for: .audio)
    },
    requestMicrophoneAccessIfNeeded: {
      if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
        await AVCaptureDevice.requestAccess(for: .audio)
      }
    },
    notifyPermissionLost: {
      let content = UNMutableNotificationContent()
      content.title = "Recording stopped"
      content.body =
        "System Audio Recording permission was revoked. Re-authorize in System Settings > Privacy & Security to resume."
      content.sound = .default
      let request = UNNotificationRequest(
        identifier: "audioRecordingPermissionLost",
        content: content,
        trigger: nil
      )
      try? await UNUserNotificationCenter.current().add(request)
    },
    findActiveCallingProcesses: {
      let myPID = ProcessInfo.processInfo.processIdentifier
      guard let processes = try? AudioHardwareSystem.shared.processes else { return [] }
      return
        processes
        .filter { (try? $0.isRunningInput) == true && (try? $0.isRunningOutput) == true }
        .filter {
          guard let pid = try? $0.pid else { return false }
          return pid != myPID
        }
        .map { try? $0.bundleID }
    },
    windowTitles: { liveWindowTitles(forBundleID: $0) },
    now: { Date() },
    sleep: { duration in
      try? await Task.sleep(for: duration)
    }
  )
}
