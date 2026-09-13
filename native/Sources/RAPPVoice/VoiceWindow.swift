import SwiftUI
import RAPPDesktopSupport
import RAPPVoiceCore

@MainActor struct VoiceWindow: View {
    @ObservedObject var controller: VoiceController
    @State private var scratch = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: controller.indicator).font(.largeTitle)
                    .foregroundStyle(controller.recording ? .red : (controller.errorState ? .orange : .accentColor))
                VStack(alignment: .leading) {
                    Text("RAPP Voice").font(.title.bold())
                    Text("Native, on-device dictation · 1.1.0").foregroundStyle(.secondary)
                }
                Spacer()
                Text(controller.displayState).font(.headline)
                    .accessibilityIdentifier("voice.state")
            }
            Text(controller.status).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("voice.status").textSelection(.enabled)
            HStack {
                Button("Start hands-free") { controller.start() }.disabled(controller.busy)
                    .accessibilityIdentifier("voice.start")
                Button("Stop & transcribe") { controller.stop() }.disabled(!controller.recording)
                    .accessibilityIdentifier("voice.stop")
                Button("Cancel") { controller.cancel() }.disabled(!controller.busy)
                    .accessibilityIdentifier("voice.cancel")
                if controller.recording {
                    ProgressView(value: controller.level).frame(width: 110)
                    Text("\(Int(controller.elapsed))s").monospacedDigit()
                } else if controller.mode == .working { ProgressView().controlSize(.small) }
            }
            TabView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Hold \(controller.settings.shortcut.title), speak, release. A single short tap is discarded. Double-tap for hands-free; tap again to stop. Escape cancels.")
                    Text(controller.cleanupLabel).font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("voice.cleanup")
                    ScrollView {
                        Text(controller.transcript.isEmpty ? "Your transcript will appear here." : controller.transcript)
                            .textSelection(.enabled).frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                            .accessibilityIdentifier("voice.transcript")
                    }
                    .padding(10).background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 8))
                    Button("Copy — paste manually") { controller.copyTranscript() }
                        .disabled(controller.transcript.isEmpty || controller.busy)
                        .accessibilityIdentifier("voice.copy")
                    Text("Try dictating into this native editor").font(.headline)
                    TextEditor(text: $scratch).font(.body).frame(minHeight: 100)
                        .border(.secondary.opacity(0.3)).accessibilityIdentifier("voice.editor")
                    Text("No capture on launch. Audio work files are deleted after transcription or cancellation. No transcript history is saved.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding().tabItem { Label("Dictate", systemImage: "waveform") }
                SetupView(controller: controller, models: controller.models)
                    .tabItem { Label("Setup", systemImage: "checklist") }
                settingsView.tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                dictionaryView.tabItem { Label("Dictionary", systemImage: "text.book.closed") }
                polishView.tabItem { Label("Optional polish", systemImage: "wand.and.stars") }
                diagnosticsView.tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            }
        }.padding(22).frame(minWidth: 730, minHeight: 620)
    }
    private var settingsView: some View {
        Form {
            Toggle("Enable reserved dictation shortcut", isOn: $controller.settings.shortcutEnabled)
                .accessibilityIdentifier("voice.shortcut.enabled")
            Picker("Shortcut", selection: $controller.settings.shortcut) {
                ForEach(VoiceShortcut.allCases) { Text($0.title).tag($0) }
            }.accessibilityIdentifier("voice.shortcut")
            Text("The selected modifier is reserved exclusively, including inside RAPP Voice. Use its opposite-side key for ordinary shortcuts. Without event permissions it works only inside this app.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Insertion", selection: $controller.settings.insertMethod) {
                Text("Paste, preserving the clipboard").tag(InsertMethod.paste)
                Text("Type (no clipboard changes)").tag(InsertMethod.type)
                Text("Copy / manual paste only").tag(InsertMethod.manual)
            }.accessibilityIdentifier("voice.insertion.method")
            Text("Automatic insertion requires the original safe field and selection to remain focused. Protected fields and Secure Input are never forced. Keyboard-event delivery is not claimed as confirmed insertion.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Language (en, or auto for a multilingual model)", text: $controller.settings.language)
            HStack {
                Text("Maximum recording seconds (1–600)")
                TextField("600", value: $controller.settings.maxRecordSeconds, format: .number).frame(width: 90)
            }
            HStack {
                Text("Clipboard restore delay (0.1–5 seconds)")
                TextField("0.25", value: $controller.settings.clipboardRestoreDelay, format: .number).frame(width: 90)
            }
            Button("Save native settings") { controller.saveSettings() }.accessibilityIdentifier("voice.settings.save")
        }.padding()
    }
    private var dictionaryView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("One term per line, or heard text => Canonical Term. Terms are weighted twice in the recognizer prompt; exact spelling is enforced afterwards. No fuzzy replacement.")
            Text(controller.dictionaryPath).font(.caption.monospaced()).textSelection(.enabled)
            TextEditor(text: $controller.dictionaryText).font(.system(.body, design: .monospaced))
                .border(.secondary.opacity(0.3)).accessibilityIdentifier("voice.dictionary")
            HStack {
                Button("Save dictionary") { controller.saveDictionary() }.accessibilityIdentifier("voice.dictionary.save")
                Button("Reload from disk") { controller.reloadDictionary() }.accessibilityIdentifier("voice.dictionary.reload")
            }
            Text(controller.dictionaryMessage).font(.callout).textSelection(.enabled)
        }.padding()
    }
    private var polishView: some View {
        Form {
            Text(controller.settings.polish.hasConsent ? "Explicitly enabled for \(controller.settings.polish.provider)" : "OFF — local cleanup works without any cloud service")
                .font(.headline).accessibilityIdentifier("voice.polish.state")
            Text("Only after you enable a reviewed hook and say “\(controller.settings.polishTrigger)” first, the remaining transcript is passed to that executable as a file. It can send your text to the provider you name, run subprocesses, and incur charges. Microphone audio is not given to the hook. Review the script and the provider’s privacy policy before consenting. Changing the provider or path invalidates consent.")
            TextField("Provider / actual data recipient", text: $controller.settings.polish.provider)
                .accessibilityIdentifier("voice.polish.provider")
                .onChange(of: controller.settings.polish.provider) { _, _ in controller.polishSelectionChanged() }
            TextField("Absolute path to reviewed executable hook", text: $controller.settings.polish.hookPath)
                .accessibilityIdentifier("voice.polish.hook")
                .onChange(of: controller.settings.polish.hookPath) { _, _ in controller.polishSelectionChanged() }
            Button("Reveal hook for review") { controller.revealHook() }
            Button("I reviewed this hook and consent to send triggered text to this provider") { controller.approvePolish() }
                .accessibilityIdentifier("voice.polish.consent")
            Button("Disable and revoke consent") { controller.disablePolish() }
                .accessibilityIdentifier("voice.polish.disable")
            Text("The shipped legacy hook uses the Claude CLI / Anthropic. It is NOT enabled by installing the native app. Native dictation needs no API key or subscription. When polish fails or times out, local text is kept and labeled as local fallback.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
    }
    private var diagnosticsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Microphone: \(controller.microphone.rawValue)")
                Text("Accessibility: \(controller.accessibility ? "granted" : "not granted")")
                Text("Input Monitoring: \(controller.inputMonitoring ? "granted" : "not granted")")
                Text("Shortcut: \(controller.shortcutStatus)")
                Text("Runtime: \(controller.runtimeStatus)").font(.caption.monospaced())
                Text("Native support: \(controller.supportPath)").font(.caption.monospaced())
                Text("Legacy dictionaries, hooks, models, and logs are preserved. Native model downloads are separate and checksum-verified. Diagnostics log counts/status, not transcripts.")
                Text(controller.diagnostics.isEmpty ? "No diagnostic errors." : controller.diagnostics)
                    .accessibilityIdentifier("voice.diagnostics")
                Button("Refresh permissions and reconnect shortcut") { controller.refreshPermissions() }
            }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }.padding()
    }
}

@MainActor private struct SetupView: View {
    @ObservedObject var controller: VoiceController
    @ObservedObject var models: ModelStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("1. Allow the microphone").font(.headline)
                Text("Current status: \(controller.microphone.rawValue). Permission setup does not start a recording.")
                HStack {
                    Button("Enable Microphone") { controller.requestMicrophone() }
                        .accessibilityIdentifier("voice.permission.microphone")
                    Button("Microphone settings") { controller.openPrivacy("Privacy_Microphone") }
                }
                Text("2. Enable shortcuts and safe automatic insertion (optional)").font(.headline)
                Text("Copy/manual paste and app buttons work without Accessibility or Input Monitoring. Grant both for the exclusive all-app shortcut and event-based insertion. Reopen the app if macOS requires it.")
                HStack {
                    Button("Accessibility") { controller.requestAccessibility() }.accessibilityIdentifier("voice.permission.accessibility")
                    Button("Input Monitoring") { controller.requestInputMonitoring() }.accessibilityIdentifier("voice.permission.input")
                    Button("Refresh grants") { controller.refreshPermissions() }
                }
                Text(controller.shortcutStatus).font(.caption)
                Text("3. Download a local speech model").font(.headline)
                Picker("Model", selection: $controller.settings.modelID) {
                    ForEach(SpeechModels.all) { model in
                        Text("\(model.title) · \(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file))").tag(model.id)
                    }
                }.disabled(!controller.canDownload || controller.busy).accessibilityIdentifier("voice.model")
                if let model = controller.selectedModel {
                    Text(models.isInstalled(model) ? "Verified model installed" : "Model not installed")
                    Link("Model license", destination: model.licenseURL)
                    Text("Download source: \(model.url.host ?? model.url.absoluteString). This downloads model weights only; no voice data is sent.")
                        .font(.caption)
                }
                if let progress = models.progress { ProgressView(value: progress).accessibilityIdentifier("voice.model.progress") }
                Text(models.status)
                Text(controller.downloadMessage).accessibilityIdentifier("voice.model.status")
                HStack {
                    Button("Download / retry") { controller.downloadModel() }
                        .disabled(!controller.canDownload || controller.selectedModel == nil || controller.busy)
                        .accessibilityIdentifier("voice.model.download")
                    Button("Cancel download") { controller.cancelDownload() }.disabled(controller.canDownload)
                        .accessibilityIdentifier("voice.model.cancel")
                    Button("Save model selection") { controller.saveSettings() }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding()
    }
}
