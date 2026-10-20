import AVFoundation
import AppKit

@Observable
final class AudioMonitor {
  private(set) var isRecording = false
  private(set) var currentAppName: String?
  private(set) var recordingStartTime: Date?
  private(set) var permissionNeeded = false
  private(set) var micPermissionNeeded = false
  private(set) var isManualRecording = false
  private(set) var errorMessage: String?
  private(set) var graceCountdown: TimeInterval?
  private(set) var isSaving = false
  private(set) var formattedElapsed: String?
  /// Stored rather than derived from the raw level: `@Observable` notifies on
  /// every assignment, so publishing the 4 Hz level directly would invalidate
  /// the menu bar label on every tick instead of only on a bucket change.
  private(set) var levelSymbol = recordingWaveformIcon(level: 0)
  private(set) var lastSavedRecordingURL: URL?
  private var savingCount = 0

  // Auto-recording triggered by call detection
  private var autoRecorder: (any RecorderSession)?
  private var autoRecordingAppName: String?
  private var autoRecordingBundleID: String?
  // Manual recording triggered by user
  private var manualRecorder: (any RecorderSession)?

  private var settingsTask: Task<Void, Never>?
  private var elapsedTimer: Timer?
  private var graceTask: Task<Void, Never>?
  // Track in-flight start() invocations so stopMonitoring can wait for the
  // catch/cleanup path to unwind even if the recorder.start() awaitable
  // returns slowly.
  private var autoStartTask: Task<Void, Never>?
  private var manualStartTask: Task<Void, Never>?
  /// Every in-flight `recorder.stop()`. The four stop paths nil their recorder
  /// and then launch an unstructured Task to do the stopping, so
  /// `stopMonitoring()` - which only awaited the recorders themselves - was
  /// awaiting two fields that were already nil. Stop a recording, quit within a
  /// second or two, and the process exited mid-`finishWriting`, leaving a file
  /// with no `moov` atom.
  private var savingTasks: [UUID: Task<Void, Never>] = [:]
  // After a user-initiated stop (manual stop, or force-stop on auto), suppress
  // auto-restart of the same parent bundle until it disappears from the caller
  // set for one poll. Single-bundle: covers the reported Chrome case;
  // multi-caller suppression is speculative and out of scope.
  private var suppressedBundleID: String?

  // Restart rate limiting: max 3 restarts within 30 seconds
  private var autoRestartCount = 0
  private var autoRestartWindowStart: Date?
  private var manualRestartCount = 0
  private var manualRestartWindowStart: Date?
  // Display loss gets its own, looser budget: a display sleep is not a recorder
  // fault and must not spend the budget above, but ScreenCaptureKit can also
  // report it repeatedly while a display still enumerates, and every restart
  // creates a recording on disk. 10 in 30s is far past any real sleep/wake.
  private static let displayLostRestartLimit = 10
  private var autoDisplayLostCount = 0
  private var autoDisplayLostWindowStart: Date?
  private var manualDisplayLostCount = 0
  private var manualDisplayLostWindowStart: Date?

  private var micPollingTask: Task<Void, Never>?
  private var lastKnownMicRunning = false
  private var consecutiveInactivePolls = 0
  private var continuityCooldownUntil: Date?
  @ObservationIgnored private let dependencies: AudioMonitorDependencies

  // Settings
  var autoRecord: Bool = true
  var gracePeriod: TimeInterval = 5
  var micEnabled: Bool = true
  var saveDirectory: URL = URL(fileURLWithPath: defaultSaveDirectoryPath)
  var namePrefixTemplate: String = ""
  var notifyOnStart: Bool = true
  var notifyOnSaved: Bool = true
  var notifyOnError: Bool = true
  var excludedBundleIDs: Set<String> = []
  var excludedTitlePatterns: Set<String> = []
  var writeMixedTrack: Bool = true

  private var errorGeneration = 0

  init(dependencies: AudioMonitorDependencies = .live) {
    self.dependencies = dependencies
  }

  // MARK: - Monitoring Lifecycle

  func startMonitoring(skipPermissionRequests: Bool = false) {
    guard settingsTask == nil else {
      Log.info(Log.monitor, "monitor", "startMonitoring skipped: already running")
      return
    }
    Log.info(Log.monitor, "monitor", "startMonitoring called (skip=\(skipPermissionRequests))")
    loadSettings()
    Log.info(
      Log.monitor, "monitor",
      "settings loaded: autoRecord=\(autoRecord), gracePeriod=\(gracePeriod), micEnabled=\(micEnabled)"
    )

    // Screen Recording permission is requested at onboarding. `loadSettings`
    // above has already seeded `permissionNeeded` from a preflight, and the
    // 5-second poll below keeps it honest if the user revokes mid-session; the
    // recorder's `.permissionDenied` failure path sets it too, as a backstop
    // for the window between a revoke and the next poll.

    if !skipPermissionRequests {
      Task { @MainActor [weak self] in
        guard let self else { return }
        await self.dependencies.requestMicrophoneAccessIfNeeded()
      }
    }

    // Start call detection polling
    setupCallDetection()

    // Periodically reload settings
    settingsTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.dependencies.sleep(.seconds(5))
        self.loadSettings()
      }
    }
  }

  func stopMonitoring() async {
    settingsTask?.cancel()
    settingsTask = nil
    micPollingTask?.cancel()
    micPollingTask = nil
    stopElapsedTimer()
    cancelGracePeriod()

    // Snapshot start tasks before we await anything. The Task body clears
    // its own field via defer; awaiting the snapshot makes the wait
    // deterministic regardless of completion order.
    let autoTask = autoStartTask
    let manualTask = manualStartTask

    if let recorder = autoRecorder {
      await reportRecordingSaved(await recorder.stop(), renderingMixdown: false)
      autoRecorder = nil
    }

    if let recorder = manualRecorder {
      await reportRecordingSaved(await recorder.stop(), renderingMixdown: false)
      manualRecorder = nil
      isManualRecording = false
    }

    // Wait for any in-flight start() Task to unwind (success or catch path)
    // so applicationShouldTerminate's 8s budget is honored.
    await autoTask?.value
    await manualTask?.value

    // And for any stop already in flight when quit arrived. Not bounded: only
    // the SCStream stop inside it is (3s), and `finishWriting` after that runs
    // as long as it runs - which is the point, since cancelling it deletes the
    // file. The real backstop is `applicationShouldTerminate`'s own 8s reply
    // timer; if finalization outlasts it the process exits mid-write, and the
    // file is recoverable through `movieFragmentInterval` once the first
    // fragment has flushed.
    for task in savingTasks.values { await task.value }

    isRecording = false
    currentAppName = nil
    recordingStartTime = nil
  }

  /// Quit-time only. The delegate has no HUD of its own, and a second instance
  /// would fight this one for the panel.
  func showFinalizingToast() {
    dependencies.hud.showFinalizing()
  }

  // MARK: - Error

  func clearError() { errorMessage = nil }

  func setError(_ message: String) {
    Log.error(Log.monitor, "monitor", message)
    errorMessage = message
    notifyError(message: message)
    errorGeneration += 1
    let gen = errorGeneration
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.dependencies.sleep(.seconds(10))
      if self.errorGeneration == gen { self.errorMessage = nil }
    }
  }

  private func handleLowDiskSpace(_ remainingBytes: Int64) {
    let mb = remainingBytes / 1_000_000
    setError("Low disk space (\(mb) MB remaining)")
  }

  // MARK: - Elapsed Timer

  private func startElapsedTimer() {
    guard elapsedTimer == nil else { return }
    tickElapsed()
    elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.tickElapsed()
      }
    }
  }

  private func stopElapsedTimer() {
    elapsedTimer?.invalidate()
    elapsedTimer = nil
    formattedElapsed = nil
  }

  private func tickElapsed() {
    guard let start = recordingStartTime else {
      formattedElapsed = nil
      return
    }
    let total = max(0, Int(dependencies.now().timeIntervalSince(start)))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    formattedElapsed =
      h > 0
      ? String(format: "%d:%02d:%02d", h, m, s)
      : String(format: "%d:%02d", m, s)
  }

  // MARK: - Manual Recording

  func startManualRecording(resetRestartBudget: Bool = true) {
    guard manualRecorder == nil else {
      Log.info(Log.monitor, "monitor", "startManualRecording skipped: already recording")
      return
    }

    if resetRestartBudget {
      manualRestartCount = 0
      manualRestartWindowStart = nil
      manualDisplayLostCount = 0
      manualDisplayLostWindowStart = nil
    }

    let useMic = micEnabled
    lastSavedRecordingURL = nil
    let recorder = dependencies.recorderFactory.makeRecorder(
      configuration: RecorderSessionConfiguration(
        bundleID: nil,
        appName: "Manual recording",
        micEnabled: useMic,
        saveDirectory: saveDirectory,
        isManualRecording: true,
        titlePrefix: formatNamePrefix(template: namePrefixTemplate, date: dependencies.now())
      ),
      onFailure: makeFailureHandler(isManual: true),
      onAudioLevel: makeAudioLevelHandler(),
      onLowDiskSpace: makeLowDiskSpaceHandler(),
      onContinuity: makeContinuityHandler()
    )

    manualRecorder = recorder
    isManualRecording = true

    self.manualStartTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.manualStartTask = nil }
      do {
        try await recorder.start()
        // Identity guard: if stop arrived during start(), the recorder we
        // hold is no longer the one we kicked off. Don't promote state.
        guard self.manualRecorder === recorder else { return }
        self.permissionNeeded = false
        self.recordingStartTime = self.dependencies.now()
        self.currentAppName = "Manual recording"
        self.isRecording = true
        self.startElapsedTimer()
        self.notifyRecordingStarted(appName: "Manual recording")
      } catch {
        // Suppress error toast for cancellations (stop during start) and
        // lost-race situations (stop nilled the recorder before start
        // returned). Use pattern matching to avoid requiring Equatable on
        // RecorderError.
        var isCancel = false
        if let recError = error as? RecorderError, case .cancelled = recError {
          isCancel = true
        }
        let lostRace = self.manualRecorder !== recorder
        if !(isCancel || lostRace) {
          self.setError("Failed to start recording: \(error.localizedDescription)")
        }
        if !lostRace {
          self.manualRecorder = nil
          self.isManualRecording = false
        }
        self.updateAutoState()
      }
    }
  }

  private func handleManualRecorderFailure(_ failure: RecorderFailure) {
    guard let failedRecorder = manualRecorder else {
      Log.info(Log.monitor, "monitor", "handleManualRecorderFailure skipped: recorder already nil")
      return
    }
    manualRecorder = nil
    isManualRecording = false
    stopElapsedTimer()

    savingCount += 1
    isSaving = true
    trackSaving { [self] in
      let url = await failedRecorder.stop()
      savingCount -= 1
      isSaving = savingCount > 0
      await reportRecordingSaved(url)
    }

    switch failure {
    case .permissionDenied:
      permissionNeeded = true
      notifyPermissionLost()
      updateAutoState()
    case .lowDiskSpace:
      setError("Recording stopped - not enough disk space")
      updateAutoState()
    case .displayLost:
      // Display sleep, not a fault: it does not spend the systemStopped budget.
      // start() waits for a display to come back, but not when one is still
      // enumerated, so a separate bound stops a restart loop.
      if shouldAllowRestart(
        count: &manualDisplayLostCount, windowStart: &manualDisplayLostWindowStart,
        max: Self.displayLostRestartLimit)
      {
        Log.info(Log.monitor, "monitor", "display lost during manual recording, restarting")
        setError("Display slept - resuming recording...")
        startManualRecording(resetRestartBudget: false)
      } else {
        Log.error(Log.monitor, "monitor", "manual recording display-loss restart limit exceeded")
        setError("Recording failed repeatedly")
      }
    case .systemStopped, .other:
      if shouldAllowRestart(
        count: &manualRestartCount, windowStart: &manualRestartWindowStart)
      {
        setError("Recording interrupted - restarting...")
        startManualRecording(resetRestartBudget: false)
      } else {
        setError("Recording failed repeatedly")
      }
    }
  }

  /// Runs a recorder stop as a tracked task, so `stopMonitoring()` can await it.
  ///
  /// The body has to be registered *and* removed from inside the task, because
  /// the `Task` value does not exist until its initializer returns - by which
  /// time a short body may already have finished. Inserting after the fact
  /// would then leave a completed task in the set forever.
  private func trackSaving(_ body: @escaping @MainActor () async -> Void) {
    let id = UUID()
    // Keyed by id rather than by the task itself: the `Task` value does not
    // exist until its initializer returns, so a task cannot remove itself from
    // a set it is not yet in. The assignment lands first regardless - this is
    // main-actor code, so the body cannot start until the current synchronous
    // region yields.
    savingTasks[id] = Task { @MainActor in
      await body()
      savingTasks[id] = nil
    }
  }

  /// Announces a recording that reached disk. Every `stop()` that can return a
  /// URL funnels through here so post-processing sees failure-ended and
  /// quit-time recordings too, not just the two clean stop paths.
  ///
  /// The 3-track mixdown runs first and the consumer is told afterwards:
  /// mixdown atomically replaces `audio.m4a`, so a transcription started
  /// beforehand would be reading a file that is swapped out from under it.
  /// Mixdown is best-effort and never throws - on failure the original
  /// 2-track file stays and the consumer still runs.
  ///
  /// Quit passes `renderingMixdown: false`: the process is about to exit, a
  /// render cut off mid-way is wasted, and awaiting it would stretch shutdown.
  /// The consumer is still told inline, so the job record reaches disk and the
  /// next launch resumes it against the 2-track file, which is fully playable.
  private func reportRecordingSaved(_ recordingDirectory: URL?, renderingMixdown: Bool = true)
    async
  {
    guard let recordingDirectory else { return }
    if renderingMixdown {
      // Before the mixdown, which can outlast the quit budget: the consumer
      // records its intent to transcribe now, so a process that dies mid-render
      // still has a job record for the next launch to resume.
      dependencies.onRecordingPending(recordingDirectory)
      await TrackMixdown.render(
        recordingDirectory: recordingDirectory, includeMixedTrack: writeMixedTrack)
    }
    dependencies.onRecordingSaved(recordingDirectory)
  }

  func forceStopAutoRecording() {
    cancelGracePeriod()
    stopAutoRecording(suppressBundleAfterStop: true)
  }

  func stopManualRecording() {
    guard let recorder = manualRecorder else { return }
    // Snapshot before any state change so we suppress the bundle the user
    // was just recording. Manual recordings have no `autoRecordingBundleID`,
    // so the first currently-active resolved caller is the closest signal.
    suppressedBundleID = firstActiveResolvedCaller()
    let appName = currentAppName ?? recorder.appName
    manualRecorder = nil
    isManualRecording = false
    stopElapsedTimer()
    savingCount += 1
    isSaving = true
    trackSaving { [self] in
      let url = await recorder.stop()
      savingCount -= 1
      isSaving = savingCount > 0
      // `updateAutoState` first: it is what clears `isRecording`, and
      // `reportRecordingSaved` runs a consumer that reads it. Announcing the
      // save while the just-finished recording still reads as live made the
      // transcription coordinator hold every automatic job behind its
      // recording gate for the gate's full duration, every time.
      updateAutoState()
      if url != nil {
        lastSavedRecordingURL = url
        notifyRecordingSaved(appName: appName)
      }
      // Force re-evaluation so auto-recording starts if a call is still active
      lastKnownMicRunning = false
      evaluateCallState()
      // Last: the mixdown inside must not delay the next recording starting.
      await reportRecordingSaved(url)
    }
  }

  // MARK: - Call Detection (macOS 14.2+)

  private func setupCallDetection() {
    let callers = resolvedActiveCallers()
    lastKnownMicRunning = !callers.isEmpty
    Log.info(
      Log.monitor, "monitor",
      "call detection started: polling every 3s, activeCallers=\(callers.count)"
    )

    // Check current state in case app starts mid-call
    if let first = callers.first {
      handleMicBecameActive(appBundleID: first)
    }

    // Poll every 3 seconds for active calling processes
    micPollingTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.dependencies.sleep(.seconds(3))
        self.evaluateCallState()
      }
    }
  }

  // MARK: - Call State Evaluation

  /// Re-evaluate call state by checking which external processes have active calls.
  /// Called from polling loop every 3 seconds.
  private func evaluateCallState() {
    let resolvedCallers = resolvedActiveCallers()

    // Clear suppression once the suppressed bundle disappears from the full
    // caller set. We check against `resolvedCallers` (not `eligibleCallers`)
    // so the bundle leaving its own suppression set actually clears it.
    if let suppressed = suppressedBundleID, !resolvedCallers.contains(suppressed) {
      suppressedBundleID = nil
    }

    // Eligible callers exclude the suppressed bundle, so other apps (e.g.
    // Zoom) can still trigger auto-record while Chrome is suppressed.
    let eligibleCallers: [String]
    if let suppressed = suppressedBundleID {
      eligibleCallers = resolvedCallers.filter { $0 != suppressed }
    } else {
      eligibleCallers = resolvedCallers
    }
    let running = !eligibleCallers.isEmpty

    if running {
      consecutiveInactivePolls = 0
      continuityCooldownUntil = nil
      if running != lastKnownMicRunning {
        Log.info(
          Log.monitor, "monitor",
          "call state changed: eligibleCallers=\(eligibleCallers.count), running=\(running)")
        lastKnownMicRunning = true
        let bundleID = eligibleCallers.count == 1 ? eligibleCallers.first : nil
        handleMicBecameActive(appBundleID: bundleID)
      } else if autoRecord, autoRecorder == nil, !isRecording, !isManualRecording {
        Log.info(Log.monitor, "monitor", "retrying auto-recording for active call")
        handleMicBecameActive(appBundleID: eligibleCallers.first)
      }
      return
    }

    if running != lastKnownMicRunning {
      Log.info(
        Log.monitor, "monitor",
        "call state changed: eligibleCallers=\(eligibleCallers.count), running=\(running)")
      lastKnownMicRunning = running
    }

    guard autoRecorder != nil else { return }

    if shouldSuppressInactiveStop() {
      Log.info(Log.monitor, "monitor", "inactive poll ignored during continuity cooldown")
      return
    }

    consecutiveInactivePolls += 1
    guard consecutiveInactivePolls >= 2 else {
      Log.info(Log.monitor, "monitor", "inactive poll threshold not reached yet")
      return
    }

    handleMicBecameInactive()
  }

  /// Active callers resolved to parent bundle IDs, with excluded apps and
  /// excluded window titles removed. Single source for "who is calling" -
  /// exclusion must also apply to suppression seeding, so an excluded bundle
  /// never occupies the slot.
  private func resolvedActiveCallers() -> [String] {
    dependencies.findActiveCallingProcesses()
      .compactMap { $0 }
      .map(canonicalBundleID)
      .filter { !excludedBundleIDs.contains($0) && !hasExcludedWindowTitle($0) }
  }

  /// Parent bundle ID in the case the app is actually registered under, so
  /// caller sets, `suppressedBundleID`, and window lookups all agree on one
  /// spelling.
  private func canonicalBundleID(_ bundleID: String) -> String {
    let parent = Self.resolveParentBundleID(bundleID)
    return findRunningApplication(bundleID: parent)?.bundleIdentifier ?? parent
  }

  /// True when any window title of `bundleID` contains an excluded pattern.
  /// Skipped entirely when no patterns are set - `CGWindowListCopyWindowInfo`
  /// runs on every 3s poll otherwise.
  private func hasExcludedWindowTitle(_ bundleID: String) -> Bool {
    guard !excludedTitlePatterns.isEmpty else { return false }
    let titles = dependencies.windowTitles(bundleID).map { $0.lowercased() }
    guard
      let matched = titles.first(where: { title in
        excludedTitlePatterns.contains { title.contains($0) }
      })
    else { return false }
    Log.info(
      Log.monitor, "monitor",
      "caller \(bundleID) excluded by window title: \"\(matched)\"")
    return true
  }

  /// Appends the calling app's window title to the recording name, so browser
  /// calls get "Arc — Weekly sync" instead of a wall of identical "Arc" entries.
  /// Falls back to the bare app name when no window title is readable (no
  /// Screen Recording permission, or a windowless helper).
  private func enrichedAppName(_ appName: String, bundleID: String) -> String {
    let titles = dependencies.windowTitles(bundleID)
    let meetingKeywords = ["meet", "zoom", "teams", "huddle", "webex", "slack"]
    let picked =
      titles.first { title in
        let lower = title.lowercased()
        return meetingKeywords.contains { lower.contains($0) }
      } ?? titles.first
    guard let picked, picked != appName else { return appName }
    return RecordingNaming.compose(app: appName, windowTitle: String(picked.prefix(80)))
  }

  /// First currently-active caller resolved to its parent bundle ID. Used by
  /// stop paths that need to seed `suppressedBundleID` when no
  /// `autoRecordingBundleID` is available (e.g. manual stop or multi-caller
  /// auto stop).
  private func firstActiveResolvedCaller() -> String? {
    resolvedActiveCallers().first
  }

  /// Resolve helper subprocess bundle IDs to the parent app.
  /// e.g. "com.google.Chrome.helper.renderer" → "com.google.Chrome"
  private static func resolveParentBundleID(_ bundleID: String) -> String {
    let parts = bundleID.split(separator: ".")
    if let idx = parts.firstIndex(where: { $0 == "helper" }), idx > 1 {
      return parts[..<idx].joined(separator: ".")
    }
    return bundleID
  }

  /// Resolve a bundle ID to a human-readable app name.
  private static func resolveAppName(bundleID: String?) -> String {
    guard let bundleID else { return "Call" }
    let resolved = resolveParentBundleID(bundleID)
    if let app = findRunningApplication(bundleID: resolved), let name = app.localizedName {
      return name
    }
    // Fallback: try original bundle ID if parent resolution found nothing
    if resolved != bundleID, let app = findRunningApplication(bundleID: bundleID),
      let name = app.localizedName
    {
      return name
    }
    // Last resort: extract last component of bundle ID (e.g. "com.zoom.us" -> "zoom")
    let components = bundleID.split(separator: ".")
    if let last = components.last, last != "app" {
      return String(last)
    }
    return "Call"
  }

  // MARK: - Auto Recording

  private func handleMicBecameActive(appBundleID: String? = nil) {
    cancelGracePeriod()
    consecutiveInactivePolls = 0

    guard autoRecord, !isRecording, !isManualRecording else {
      Log.info(
        Log.monitor, "monitor",
        "handleMicBecameActive skipped: autoRecord=\(autoRecord), isRecording=\(isRecording), isManualRecording=\(isManualRecording)"
      )
      return
    }

    // Screen Recording permission is checked when AudioRecorder.start() creates
    // the SCStream. If denied, the failure callback sets permissionNeeded = true.

    autoRecordingBundleID = appBundleID.map(canonicalBundleID)
    autoRecordingAppName = Self.resolveAppName(bundleID: appBundleID)
    loadSettings()
    // Re-check against the freshly loaded set: the poll that got us here may
    // have filtered with exclusions up to 5s stale.
    if let bundleID = autoRecordingBundleID {
      if excludedBundleIDs.contains(bundleID) {
        Log.info(Log.monitor, "monitor", "auto-recording skipped: \(bundleID) is excluded")
        return
      }
      if hasExcludedWindowTitle(bundleID) { return }
      autoRecordingAppName = enrichedAppName(
        autoRecordingAppName ?? "Call", bundleID: bundleID)
    }
    startAutoRecording()
  }

  private func handleMicBecameInactive() {
    guard autoRecorder != nil else {
      Log.info(Log.monitor, "monitor", "handleMicBecameInactive skipped: no active auto-recording")
      return
    }
    guard graceTask == nil else { return }

    Log.info(Log.monitor, "monitor", "mic inactive, starting grace period")
    let period = gracePeriod
    graceTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let start = self.dependencies.now()
      while !Task.isCancelled {
        let remaining = period - self.dependencies.now().timeIntervalSince(start)
        if remaining <= 0 {
          self.graceCountdown = nil
          self.stopAutoRecording()
          return
        }
        self.graceCountdown = remaining
        await self.dependencies.sleep(.seconds(1))
      }
    }
  }

  private func handleRecorderContinuity() {
    let now = dependencies.now()
    continuityCooldownUntil = now.addingTimeInterval(max(gracePeriod, 8))
    consecutiveInactivePolls = 0
    cancelGracePeriod()
    Log.info(Log.monitor, "monitor", "continuity event observed")
  }

  private func shouldSuppressInactiveStop() -> Bool {
    guard let continuityCooldownUntil else { return false }
    if continuityCooldownUntil > dependencies.now() {
      return true
    }
    self.continuityCooldownUntil = nil
    return false
  }

  private func startAutoRecording(resetRestartBudget: Bool = true) {
    guard autoRecorder == nil else {
      Log.info(Log.monitor, "monitor", "startAutoRecording skipped: already recording")
      return
    }

    if resetRestartBudget {
      autoRestartCount = 0
      autoRestartWindowStart = nil
      autoDisplayLostCount = 0
      autoDisplayLostWindowStart = nil
    }

    let useMic = micEnabled
    let appName = autoRecordingAppName ?? "Call"
    lastSavedRecordingURL = nil
    let recorder = dependencies.recorderFactory.makeRecorder(
      configuration: RecorderSessionConfiguration(
        bundleID: autoRecordingBundleID,
        appName: appName,
        micEnabled: useMic,
        saveDirectory: saveDirectory,
        isManualRecording: false,
        titlePrefix: formatNamePrefix(template: namePrefixTemplate, date: dependencies.now())
      ),
      onFailure: makeFailureHandler(isManual: false),
      onAudioLevel: makeAudioLevelHandler(),
      onLowDiskSpace: makeLowDiskSpaceHandler(),
      onContinuity: makeContinuityHandler()
    )

    autoRecorder = recorder
    Log.info(
      Log.monitor, "monitor", "starting auto-recording (call detected, app=\(appName))")

    self.autoStartTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.autoStartTask = nil }
      do {
        try await recorder.start()
        // Identity guard: if stop arrived during start(), the recorder we
        // hold is no longer the one we kicked off. Don't promote state.
        guard self.autoRecorder === recorder else { return }
        self.permissionNeeded = false
        self.isRecording = true
        self.currentAppName = appName
        self.recordingStartTime = self.dependencies.now()
        self.startElapsedTimer()
        self.notifyRecordingStarted(appName: appName)
      } catch {
        // Pattern-match instead of relying on Equatable on RecorderError so
        // future associated values do not silently break this branch.
        var isCancel = false
        if let recError = error as? RecorderError, case .cancelled = recError {
          isCancel = true
        }
        let lostRace = self.autoRecorder !== recorder
        if !(isCancel || lostRace) {
          self.setError("Failed to start recording: \(error.localizedDescription)")
          if let recError = error as? RecorderError,
            case .permissionDenied = recError
          {
            self.permissionNeeded = true
          }
        }
        if !lostRace {
          self.autoRecorder = nil
        }
        self.updateAutoState()
      }
    }
  }

  private func stopAutoRecording(suppressBundleAfterStop: Bool = false) {
    guard let recorder = autoRecorder else { return }
    // Suppress only on user-initiated stops (forceStopAutoRecording). Grace
    // expiry leaves suppression alone so a re-detected call can record again
    // without waiting for the bundle to flap absent->present.
    if suppressBundleAfterStop {
      suppressedBundleID = autoRecordingBundleID ?? firstActiveResolvedCaller()
    }
    let appName = autoRecordingAppName ?? "Call"
    autoRecorder = nil
    autoRecordingAppName = nil
    autoRecordingBundleID = nil
    Log.info(Log.monitor, "monitor", "stopping auto-recording (app=\(appName))")
    savingCount += 1
    isSaving = true
    trackSaving { [self] in
      let url = await recorder.stop()
      savingCount -= 1
      isSaving = savingCount > 0
      // Ordered as in `stopManualRecording`, and for the same reason: the save
      // must not be announced while `isRecording` still reads true.
      updateAutoState()
      if url != nil {
        lastSavedRecordingURL = url
        notifyRecordingSaved(appName: appName)
      }
      await reportRecordingSaved(url)
    }
  }

  private func handleAutoRecorderFailure(_ failure: RecorderFailure) {
    guard let failedRecorder = autoRecorder else {
      Log.info(Log.monitor, "monitor", "handleAutoRecorderFailure skipped: recorder already nil")
      return
    }
    autoRecorder = nil
    stopElapsedTimer()
    cancelGracePeriod()

    savingCount += 1
    isSaving = true
    trackSaving { [self] in
      let url = await failedRecorder.stop()
      savingCount -= 1
      isSaving = savingCount > 0
      await reportRecordingSaved(url)
    }

    switch failure {
    case .permissionDenied:
      permissionNeeded = true
      notifyPermissionLost()
      autoRecordingAppName = nil
      autoRecordingBundleID = nil
      updateAutoState()
    case .displayLost:
      if shouldAllowRestart(
        count: &autoDisplayLostCount, windowStart: &autoDisplayLostWindowStart,
        max: Self.displayLostRestartLimit)
      {
        Log.info(Log.monitor, "monitor", "display lost during auto-recording, restarting")
        startAutoRecording(resetRestartBudget: false)
      } else {
        Log.error(Log.monitor, "monitor", "auto-recording display-loss restart limit exceeded")
        setError("Recording failed repeatedly")
        autoRecordingAppName = nil
        autoRecordingBundleID = nil
        updateAutoState()
      }
    case .systemStopped:
      if shouldAllowRestart(
        count: &autoRestartCount, windowStart: &autoRestartWindowStart)
      {
        Log.info(Log.monitor, "monitor", "auto-recording interrupted, restarting")
        startAutoRecording(resetRestartBudget: false)
      } else {
        Log.error(Log.monitor, "monitor", "auto-recording restart limit exceeded")
        setError("Recording failed repeatedly")
        autoRecordingAppName = nil
        autoRecordingBundleID = nil
        updateAutoState()
      }
    case .lowDiskSpace:
      setError("Recording stopped - not enough disk space")
      autoRecordingAppName = nil
      autoRecordingBundleID = nil
      updateAutoState()
    case .other:
      setError("Recording interrupted")
      autoRecordingAppName = nil
      autoRecordingBundleID = nil
      updateAutoState()
    }
  }

  // MARK: - Grace Period

  private func cancelGracePeriod() {
    graceTask?.cancel()
    graceTask = nil
    graceCountdown = nil
    consecutiveInactivePolls = 0
  }

  // MARK: - State

  private func updateAutoState() {
    guard !isManualRecording else { return }
    if autoRecorder != nil {
      isRecording = true
    } else {
      isRecording = false
      currentAppName = nil
      recordingStartTime = nil
      levelSymbol = recordingWaveformIcon(level: 0)
      stopElapsedTimer()
    }
  }

  private func loadSettings() {
    let settings = dependencies.loadSettings()
    if autoRecord != settings.autoRecord { autoRecord = settings.autoRecord }
    if gracePeriod != settings.gracePeriod { gracePeriod = settings.gracePeriod }
    if micEnabled != settings.micEnabled { micEnabled = settings.micEnabled }
    if saveDirectory != settings.saveDirectory { saveDirectory = settings.saveDirectory }
    if namePrefixTemplate != settings.namePrefixTemplate {
      namePrefixTemplate = settings.namePrefixTemplate
    }
    if notifyOnStart != settings.notifyOnStart { notifyOnStart = settings.notifyOnStart }
    if notifyOnSaved != settings.notifyOnSaved { notifyOnSaved = settings.notifyOnSaved }
    if notifyOnError != settings.notifyOnError { notifyOnError = settings.notifyOnError }
    if excludedBundleIDs != settings.excludedBundleIDs {
      excludedBundleIDs = settings.excludedBundleIDs
    }
    if excludedTitlePatterns != settings.excludedTitlePatterns {
      excludedTitlePatterns = settings.excludedTitlePatterns
    }
    if writeMixedTrack != settings.writeMixedTrack {
      writeMixedTrack = settings.writeMixedTrack
    }

    let nextMicPermissionNeeded =
      micEnabled && dependencies.microphoneAuthorizationStatus() != .authorized
    if micPermissionNeeded != nextMicPermissionNeeded {
      micPermissionNeeded = nextMicPermissionNeeded
    }

    // Asked here rather than only after a capture fails. Recording is the whole
    // product, so an app that cannot record has to say so before the user
    // relies on it, not after they have lost a call to it.
    let nextPermissionNeeded = !dependencies.screenCaptureAccessGranted()
    if permissionNeeded != nextPermissionNeeded {
      Log.info(
        Log.monitor, "monitor",
        "screen recording permission \(nextPermissionNeeded ? "missing" : "granted")")
      permissionNeeded = nextPermissionNeeded
    }
  }

  private func makeFailureHandler(isManual: Bool) -> @Sendable (RecorderFailure) -> Void {
    { [weak self] failure in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if isManual {
          self.handleManualRecorderFailure(failure)
        } else {
          self.handleAutoRecorderFailure(failure)
        }
      }
    }
  }

  private func makeAudioLevelHandler() -> @Sendable (Float) -> Void {
    { [weak self] level in
      let symbol = recordingWaveformIcon(level: level)
      Task { @MainActor [weak self] in
        guard let self, self.levelSymbol != symbol else { return }
        self.levelSymbol = symbol
      }
    }
  }

  private func makeLowDiskSpaceHandler() -> @Sendable (Int64) -> Void {
    { [weak self] remaining in
      Task { @MainActor [weak self] in
        self?.handleLowDiskSpace(remaining)
      }
    }
  }

  private func makeContinuityHandler() -> @Sendable () -> Void {
    { [weak self] in
      Task { @MainActor [weak self] in
        self?.handleRecorderContinuity()
      }
    }
  }

  func testSnapshot() -> BlackboxTestSnapshot {
    BlackboxTestSnapshot(
      isRecording: isRecording,
      isManualRecording: isManualRecording,
      isSaving: isSaving,
      currentAppName: currentAppName,
      errorMessage: errorMessage,
      permissionNeeded: permissionNeeded,
      micPermissionNeeded: micPermissionNeeded,
      lastSavedRecordingPath: lastSavedRecordingURL?.path,
      hudTitle: dependencies.hud.lastToast?.title,
      hudSubtitle: dependencies.hud.lastToast?.subtitle
    )
  }

  // MARK: - Restart Rate Limiting

  private func shouldAllowRestart(
    count: inout Int, windowStart: inout Date?, max: Int = 3, window: TimeInterval = 30
  ) -> Bool {
    let now = dependencies.now()
    if let start = windowStart, now.timeIntervalSince(start) > window {
      count = 0
      windowStart = nil
    }
    if windowStart == nil { windowStart = now }
    count += 1
    return count <= max
  }

  // MARK: - Notifications

  private func notifyRecordingStarted(appName: String) {
    guard notifyOnStart else { return }
    dependencies.hud.showRecordingStarted(appName: appName)
  }

  private func notifyRecordingSaved(appName: String) {
    guard notifyOnSaved else { return }
    dependencies.hud.showRecordingSaved(appName: appName)
  }

  private func notifyError(message: String) {
    guard notifyOnError else { return }
    dependencies.hud.showError(message: message)
  }

  /// Send system notification when audio recording permission is revoked.
  /// Used because the user may be focused on their call app and not see the menu bar.
  private func notifyPermissionLost() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.dependencies.notifyPermissionLost()
    }
  }
}

extension Double {
  func clamped(to range: ClosedRange<Double>, default defaultValue: Double) -> Double {
    self == 0 ? defaultValue : min(max(self, range.lowerBound), range.upperBound)
  }
}
