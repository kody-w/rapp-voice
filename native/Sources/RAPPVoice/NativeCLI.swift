import AppKit
import AVFoundation
import RAPPDesktopSupport
import RAPPVoiceCore

@MainActor enum NativeCLI {
    static func run() -> Int32 {
        var action = "unknown"
        do {
            var data = Data()
            while data.count < 65_537,
                  let chunk = try FileHandle.standardInput.read(upToCount: min(16_384, 65_537 - data.count)),
                  !chunk.isEmpty {
                data.append(chunk)
            }
            let request = try NativeRequest.decode(data)
            action = request.action.rawValue
            let paths = try AppPaths()
            let settings = try paths.settings.read()
            let text: String
            switch request.action {
            case .doctor:
                let modelStore = ModelStore(directory: paths.modelDirectory)
                let model = SpeechModels.all.first { $0.id == settings.modelID }
                let runtime: String
                do { runtime = try RuntimeTools.executable(named: "whisper-cli").path }
                catch { runtime = "MISSING — \(error.localizedDescription)" }
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: "io.rapp.voice").contains {
                    $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                }
                text = """
                RAPP Voice 1.1.1 native environment
                  App running: \(running) (this action does not start capture)
                  Microphone: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3 = authorized)
                  Accessibility: \(AXIsProcessTrusted())
                  Input Monitoring: \(CGPreflightListenEventAccess())
                  Shortcut: \(settings.shortcut.rawValue), enabled: \(settings.shortcutEnabled)
                  Model installed: \(model.map(modelStore.isInstalled) ?? false)
                  whisper-cli: \(runtime)
                  Dictionary: \(paths.dictionary.url.path)
                  Optional polish: \(settings.polish.hasConsent ? "consented: " + settings.polish.provider : "OFF")
                Hammerspoon, Homebrew, and a localhost speech server are not required.
                State and permissions must be verified in the GUI before recording.
                """
            case .dictionary:
                let dictionary = try paths.dictionary.read()
                text = dictionary.isEmpty ? "No dictionary yet at \(paths.dictionary.url.path). Use add_term." : dictionary
            case .add_term:
                let added = try paths.dictionary.append(request.term ?? "")
                text = added ? "Added to \(paths.dictionary.url.path). Applies on the next dictation." : "Already in the dictionary."
            case .process:
                guard let raw = request.text, !raw.isEmpty else { throw VoiceError.invalidAction("process needs text") }
                let app = request.app ?? "TextEdit"
                text = TextProcessor.process(raw, rawMode: TextProcessor.isRawApp(name: app, bundleID: app, settings: settings),
                                             dictionary: VoiceDictionary(try paths.dictionary.read()), settings: settings)
            case .stats:
                if FileManager.default.fileExists(atPath: paths.logURL.path) {
                    let contents = try String(contentsOf: paths.logURL, encoding: .utf8)
                    var dictations = 0
                    var characters = 0
                    var unreadable = 0
                    for line in contents.split(separator: "\n") {
                        do {
                            let entry = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                            if entry?["event"] as? String == "dictation" {
                                dictations += 1; characters += entry?["characters"] as? Int ?? 0
                            }
                        } catch { unreadable += 1 }
                    }
                    text = "\(dictations) native dictation(s), \(characters) characters processed. \(unreadable) unreadable log line(s). No transcripts are logged."
                } else { text = "No native dictations logged yet. Legacy logs are preserved at \(paths.legacy.appendingPathComponent("logs").path)." }
            }
            try output(.init(ok: true, action: action, text: text))
            return 0
        } catch {
            do { try output(.init(ok: false, action: action, text: error.localizedDescription)) }
            catch { FileHandle.standardError.write(Data("Could not encode action response.\n".utf8)) }
            return 1
        }
    }
    private static func output(_ response: NativeResponse) throws {
        var data = try JSONEncoder().encode(response)
        data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}
