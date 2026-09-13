import AppKit
import AVFoundation
import Combine
import Carbon
import RAPPDesktopSupport
import RAPPVoiceCore

@MainActor final class VoiceController: ObservableObject {
    @Published var settings = VoiceSettings()
    @Published private(set) var mode = DictationMode.idle
    @Published private(set) var status = "Ready. Capture starts only when you hold the shortcut or press Start."
    @Published private(set) var errorState = false
    @Published private(set) var transcript = ""
    @Published private(set) var cleanupLabel = "Local cleanup only — optional polish is off"
    @Published private(set) var microphone = MicrophonePermission.undetermined
    @Published private(set) var accessibility = false
    @Published private(set) var inputMonitoring = false
    @Published private(set) var shortcutStatus = ""
    @Published private(set) var runtimeStatus = ""
    @Published private(set) var level: Double = 0
    @Published private(set) var elapsed: Double = 0
    @Published var dictionaryText = ""
    @Published var dictionaryMessage = ""
    @Published var downloadMessage = ""
    @Published var diagnostics = ""
    let models: ModelStore
    private let paths: AppPaths?
    private var initializationError: String?
    private var dictionaryOriginal = ""
    private var state = DictationState()
    private let recorder = MicrophoneRecorder()
    private let shortcut = ShortcutMonitor()
    private let input = MacInput()
    private let pasteboard = MacPasteboard()
    private var maximumTask: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
    private var pendingPipelines: [UInt64: Task<Void, Never>] = [:]
    private var modelTask: Task<Void, Never>?
    private var activeInsertion: InsertionEngine?
    private var meterTimer: Timer?
    private var permissionTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var activeCapture: Capture?
    private var pendingTarget: FocusSnapshot?
    private var targetChanged = false
    private var reloadingPermissions = false

    private struct Capture {
        let session: UInt64
        let directory: URL
        let target: FocusSnapshot
        let request: DictationRequest
        let startedAt: Date
    }

    init() {
        var resolved: AppPaths?
        var startupError: String?
        do { resolved = try AppPaths() } catch { startupError = error.localizedDescription }
        paths = resolved
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/io.rapp.voice/Models", isDirectory: true)
        models = ModelStore(directory: resolved?.modelDirectory ?? fallback)
        if let resolved {
            do { settings = try resolved.settings.read() } catch { startupError = error.localizedDescription }
            if settings.polish.hookPath.isEmpty {
                settings.polish.hookPath = resolved.legacy.appendingPathComponent("hooks/polish.sh").path
            }
        }
        initializationError = startupError
        if let startupError { status = "Setup error: \(startupError)"; diagnostics = status; errorState = true }
        cleanupLabel = settings.polish.hasConsent
            ? "Local ASR; triggered polish consented for \(settings.polish.provider)"
            : "Local cleanup only — optional polish is off"
        state = DictationState(tapMaxSeconds: settings.tapMaxSeconds, doubleTapSeconds: settings.doubleTapSeconds)
        shortcut.onPress = { [weak self] time in self?.send(.keyDown(time)) }
        shortcut.onRelease = { [weak self] time in self?.send(.keyUp(time)) }
        shortcut.onCancel = { [weak self] message in self?.cancel(message, resetShortcut: true) }
        recorder.didFinish = { [weak self] success in
            guard let self, let capture = self.activeCapture else { return }
            if success { self.send(.maximumDuration(capture.session)) }
            else { self.recordingFailed(VoiceError.recordingFailed("the device stopped unexpectedly"), session: capture.session) }
        }
        recorder.didFail = { [weak self] error in
            guard let self, let capture = self.activeCapture else { return }
            self.recordingFailed(error, session: capture.session)
        }
        refreshPermissions()
        reloadDictionary()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions(reconnect: false) }
        }
        let notifications = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.cancel("Cancelled because the session locked or the Mac is sleeping.") }
            })
        }
        observers.append(notifications.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.mode != .idle, let target = self.pendingTarget else { return }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processID {
                    self.targetChanged = true
                    if !self.shortcut.hasGlobalTap, target.ownApp, self.recording {
                        self.cancel("Own-app shortcut lost focus. Recording cancelled; use the global grants for cross-app dictation.",
                                    resetShortcut: true)
                    }
                }
            }
        })
    }

    var selectedModel: SpeechModel? { SpeechModels.all.first { $0.id == settings.modelID } }
    var recording: Bool { mode == .recording || mode == .latched }
    var busy: Bool { mode != .idle }
    var canDownload: Bool { modelTask == nil }
    var dictionaryPath: String { paths?.dictionary.url.path ?? "Storage unavailable" }
    var supportPath: String { paths?.support.path ?? "Storage unavailable" }
    var displayState: String { errorState && mode == .idle ? "Error" : mode.rawValue.capitalized }
    var menuTitle: String { mode == .idle && !errorState ? "RAPP Voice" : "RAPP Voice — \(displayState)" }
    var indicator: String {
        if recording { return "record.circle.fill" }
        if mode == .working { return "ellipsis.circle" }
        if errorState { return "exclamationmark.triangle.fill" }
        return "waveform.circle"
    }

    func refreshPermissions(reconnect: Bool = true) {
        guard !reloadingPermissions else { return }
        reloadingPermissions = true
        defer { reloadingPermissions = false }
        let oldAccess = accessibility
        let oldInput = inputMonitoring
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .authorized
        case .notDetermined: microphone = .undetermined
        default: microphone = .denied
        }
        accessibility = AXIsProcessTrusted()
        inputMonitoring = CGPreflightListenEventAccess()
        do { runtimeStatus = try RuntimeTools.executable(named: "whisper-cli").path }
        catch { runtimeStatus = error.localizedDescription }
        if microphone != .authorized, recording { cancel("Microphone permission was revoked. Recording cancelled.") }
        if mode == .recording, IsSecureEventInputEnabled() {
            cancel("Secure Input interrupted the held shortcut. Recording cancelled.", resetShortcut: true)
        }
        if reconnect || oldAccess != accessibility || oldInput != inputMonitoring {
            if busy { cancel("Shortcut permission changed. Start a new dictation after setup.") }
            send(.shortcutLost)
            shortcut.configure(shortcut: settings.shortcut, enabled: settings.shortcutEnabled)
        }
        shortcutStatus = shortcut.status
    }
    func requestMicrophone() {
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refreshPermissions()
            status = microphone == .authorized
                ? "Microphone allowed. Nothing was recorded; start a new dictation when ready."
                : VoiceError.microphoneDenied.localizedDescription
            errorState = microphone != .authorized
        }
    }
    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        openPrivacy("Privacy_Accessibility")
    }
    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        openPrivacy("Privacy_ListenEvent")
    }
    func openPrivacy(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        if !NSWorkspace.shared.open(url) { status = "Open System Settings → Privacy & Security manually." }
    }

    func start() { send(.startButton) }
    func stop() { send(.stopButton) }
    func cancel(_ message: String = "Cancelled.", resetShortcut: Bool = false) {
        let sent = activeInsertion?.eventWasSent == true
        send(resetShortcut ? .shortcutLost : .cancel)
        errorState = false
        status = message + (sent ? " Input already sent cannot be undone; review the target." : " No further input will be sent.")
    }
    private func send(_ event: DictationState.Event) {
        let effects = state.handle(event)
        mode = state.mode
        shortcut.setBusy(mode != .idle)
        for effect in effects {
            switch effect {
            case .start(let session, let latched): begin(session: session, latched: latched)
            case .stop(let session, let discard): finishCapture(session: session, discard: discard)
            case .cancel:
                maximumTask?.cancel(); maximumTask = nil
                pipelineTask?.cancel(); pipelineTask = nil
                activeInsertion = nil
                recorder.stop()
                meterTimer?.invalidate(); meterTimer = nil
                if let capture = activeCapture { removeJob(capture.directory) }
                activeCapture = nil; pendingTarget = nil; level = 0
            }
        }
    }

    private func begin(session: UInt64, latched: Bool) {
        var job: URL?
        do {
            guard let paths else { throw VoiceError.invalidAction(initializationError ?? "application storage is unavailable") }
            if let initializationError { throw VoiceError.invalidAction("save valid native settings first: \(initializationError)") }
            let config = try settings.validated()
            let model = selectedModel
            let runtimeAvailable: Bool
            do { _ = try RuntimeTools.executable(named: "whisper-cli"); runtimeAvailable = true }
            catch { runtimeAvailable = false }
            try CaptureReadiness.check(microphone: microphone, modelInstalled: model.map(models.isInstalled) ?? false,
                                       runtimeAvailable: runtimeAvailable)
            guard let model else { throw VoiceError.modelMissing }
            let dictionary = VoiceDictionary(try paths.dictionary.read())
            let target = input.capture()
            let directory = try paths.createJob()
            job = directory
            let audio = directory.appendingPathComponent("capture.wav")
            let request = DictationRequest(audioURL: audio, modelURL: models.fileURL(for: model),
                                           appName: input.targetAppName, bundleID: input.targetBundleID,
                                           dictionary: dictionary, settings: config)
            try recorder.start(url: audio, maximumDuration: config.maxRecordSeconds)
            activeCapture = .init(session: session, directory: directory, target: target, request: request, startedAt: Date())
            pendingTarget = target
            targetChanged = false
            errorState = false
            transcript = ""
            elapsed = 0
            cleanupLabel = config.polish.hasConsent ? "Local ASR; disclosed polish only after its spoken trigger" : "Local cleanup only — optional polish is off"
            status = latched ? "Recording hands-free — tap the shortcut or press Stop to finish." : "Recording — release the shortcut to finish."
            maximumTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(config.maxRecordSeconds * 1_000_000_000))
                    self?.send(.maximumDuration(session))
                } catch is CancellationError {
                    // A stop, tap discard, or explicit cancellation owns the recorder now.
                } catch { self?.recordingFailed(error, session: session) }
            }
            meterTimer?.invalidate()
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let capture = self.activeCapture else { return }
                    self.level = max(0, min(1, Double(self.recorder.level + 60) / 60))
                    self.elapsed = Date().timeIntervalSince(capture.startedAt)
                }
            }
        } catch {
            recorder.stop()
            if let job { removeJob(job) }
            activeCapture = nil; pendingTarget = nil
            state.handle(.failed(session)); mode = state.mode
            shortcut.setBusy(false)
            status = error.localizedDescription
            errorState = true
            diagnostics = "Start failed: \(error.localizedDescription)"
        }
    }

    private func finishCapture(session: UInt64, discard: Bool) {
        guard let capture = activeCapture, capture.session == session else { return }
        recorder.stop()
        maximumTask?.cancel(); maximumTask = nil
        meterTimer?.invalidate(); meterTimer = nil
        activeCapture = nil; level = 0
        if discard {
            removeJob(capture.directory)
            status = "Short tap discarded. Hold to dictate, or double-tap for hands-free."
            return
        }
        status = "Transcribing locally… Cancel remains available."
        pipelineTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.removeJob(capture.directory)
                self.pendingPipelines.removeValue(forKey: session)
                if self.state.session == session { self.pipelineTask = nil; self.activeInsertion = nil; self.pendingTarget = nil }
            }
            do {
                let result = try await VoicePipeline.run(capture.request, transcribe: { audio, model, language, prompt in
                    do {
                        return try await VoiceSpeechTranscriber.transcribe(audioURL: audio, modelURL: model, language: language, prompt: prompt)
                    } catch DesktopSupportError.noSpeech {
                        return ""
                    }
                }, polish: { text, config, directory in
                    guard config.hasConsent else { throw VoiceError.invalidAction("polish consent is absent") }
                    let executable = URL(fileURLWithPath: config.hookPath)
                    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                        throw VoiceError.invalidAction("the approved hook is not executable")
                    }
                    let input = directory.appendingPathComponent("polish-input.txt")
                    try text.write(to: input, atomically: true, encoding: .utf8)
                    return try await ProcessRunner.run(executable: executable, arguments: [input.path], directory: directory).stdout
                })
                try Task.checkCancellation()
                guard self.state.session == session else { return }
                self.transcript = result.text
                self.cleanupLabel = result.cleanup.label
                if result.text.isEmpty {
                    self.status = "No speech to insert (\(result.silenceReason ?? "silence"))."
                } else {
                    self.status = "Preparing safe insertion…"
                    let engine = InsertionEngine(pasteboard: self.pasteboard, input: self.input)
                    self.activeInsertion = engine
                    let outcome: InsertionOutcome
                    if self.targetChanged {
                        outcome = .manual(.focusChanged)
                    } else {
                        outcome = try await engine.insert(result.text, target: capture.target, settings: capture.request.settings)
                    }
                    try Task.checkCancellation()
                    guard self.state.session == session else { return }
                    self.status = outcome.label
                    if let error = engine.restorationError { self.status += " Clipboard restore failed: \(error)" }
                    do { try self.paths?.log(event: "dictation", detail: String(describing: outcome), characters: result.text.count) }
                    catch { self.diagnostics = "Diagnostics could not be saved: \(error.localizedDescription)" }
                }
                self.state.handle(.completed(session)); self.mode = self.state.mode
                self.shortcut.setBusy(false)
            } catch is CancellationError {
                if self.state.session == session {
                    self.state.handle(.failed(session)); self.mode = self.state.mode
                    self.shortcut.setBusy(false)
                    self.status = "Cancelled. No further input will be sent."
                }
            } catch {
                guard self.state.session == session else { return }
                self.state.handle(.failed(session)); self.mode = self.state.mode
                self.shortcut.setBusy(false)
                self.status = error.localizedDescription
                self.errorState = true
                self.diagnostics = "Dictation failed: \(error.localizedDescription)"
            }
        }
        pendingPipelines[session] = pipelineTask
    }

    private func recordingFailed(_ error: Error, session: UInt64) {
        guard state.session == session else { return }
        cancel("Recording error: \(error.localizedDescription)")
        errorState = true
        diagnostics = status
    }
    private func removeJob(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch { diagnostics = "Could not delete app-owned work file at \(url.path): \(error.localizedDescription)" }
    }
    func copyTranscript() {
        guard !transcript.isEmpty else { return }
        do {
            _ = try pasteboard.writeText(transcript)
            status = "Copied only — paste manually when safe. No keyboard input was sent."
            errorState = false
        } catch { status = "Copy failed: \(error.localizedDescription)"; errorState = true }
    }
    @discardableResult func saveSettings() -> Bool {
        do {
            guard let paths else { throw VoiceError.invalidAction("native storage is unavailable") }
            _ = try settings.validated()
            if busy { cancel("Cancelled to apply new settings.") }
            try paths.settings.save(settings)
            initializationError = nil
            state.tapMaxSeconds = settings.tapMaxSeconds
            state.doubleTapSeconds = settings.doubleTapSeconds
            mode = .idle
            refreshPermissions()
            status = "Native settings saved. Legacy Lua configuration was not changed."
            errorState = false
            return true
        } catch {
            status = "Settings not saved: \(error.localizedDescription)"
            errorState = true
            return false
        }
    }
    func reloadDictionary() {
        do {
            guard let paths else { throw VoiceError.invalidAction("dictionary path is unavailable") }
            dictionaryOriginal = try paths.dictionary.read()
            dictionaryText = dictionaryOriginal
            dictionaryMessage = "Reloaded. Changes apply to the next dictation."
        } catch { dictionaryMessage = error.localizedDescription }
    }
    func saveDictionary() {
        do {
            guard let paths else { throw VoiceError.invalidAction("dictionary path is unavailable") }
            try paths.dictionary.save(dictionaryText, expecting: dictionaryOriginal)
            dictionaryOriginal = dictionaryText
            dictionaryMessage = "Dictionary saved. Existing Lua installations use the same file."
        } catch { dictionaryMessage = error.localizedDescription }
    }
    func downloadModel() {
        guard modelTask == nil, let model = selectedModel else { return }
        downloadMessage = "Downloading \(model.title)…"
        modelTask = Task {
            defer { modelTask = nil; objectWillChange.send() }
            do {
                try await models.download(model)
                downloadMessage = "Verified and ready: \(model.title)"
            } catch is CancellationError { downloadMessage = "Download cancelled. Retry when ready." }
            catch {
                downloadMessage = Task.isCancelled ? "Download cancelled. Retry when ready."
                    : "Download failed: \(error.localizedDescription). Retry is available."
            }
        }
    }
    func cancelDownload() { models.cancel(); modelTask?.cancel() }
    func approvePolish() {
        do {
            guard !settings.polish.provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  settings.polish.hookPath.hasPrefix("/") else {
                throw VoiceError.invalidAction("provide the actual recipient and an absolute executable hook path")
            }
            try settings.polish.approve()
            if !saveSettings() {
                settings.polish.revoke()
                status = "Consent remains disabled because native settings could not be saved."
            }
        } catch {
            settings.polish.revoke()
            status = "Consent was not enabled: \(error.localizedDescription)"
            errorState = true
        }
    }
    func disablePolish() { settings.polish.revoke(); saveSettings() }
    func polishSelectionChanged() {
        guard settings.polish.approvedProvider != nil || settings.polish.approvedHookPath != nil ||
                settings.polish.approvedFingerprint != nil else { return }
        settings.polish.revoke()
        if busy { cancel("Cancelled because the polish provider or hook changed.") }
        do {
            try paths?.settings.save(settings)
            status = "Polish consent revoked. Review the new provider and hook before enabling them."
        } catch { status = "Consent revoked in this session; saving failed: \(error.localizedDescription)"; errorState = true }
    }
    func revealHook() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: settings.polish.hookPath)])
    }
    func shutdown() {
        cancel("Application stopping.")
        for task in pendingPipelines.values { task.cancel() }
        cancelDownload()
        shortcut.stop()
        permissionTimer?.invalidate()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }
    func shutdownAndWait() async {
        let transcriptions = Array(pendingPipelines.values)
        let download = modelTask
        shutdown()
        for transcription in transcriptions { await transcription.value }
        await download?.value
    }
}
