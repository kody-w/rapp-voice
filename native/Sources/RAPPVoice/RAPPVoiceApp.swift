import AppKit
import SwiftUI
import RAPPVoiceCore

@main @MainActor enum RAPPVoiceMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--version"] { print("RAPPVoice 1.1.1"); return }
        if arguments == ["--action"] { exit(NativeCLI.run()) }
        if arguments == ["--help"] {
            print("RAPPVoice [--version | --action]\n--action reads one JSON request from stdin: doctor, dictionary, add_term, stats, process. No capture or insertion actions are exposed.")
            return
        }
        guard arguments.isEmpty || arguments.allSatisfy({ $0.hasPrefix("-psn_") }) else {
            FileHandle.standardError.write(Data("Unknown arguments. Use --help.\n".utf8))
            exit(2)
        }
        NativeVoiceApplication.main()
    }
}

@MainActor final class VoiceAppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: VoiceController?
    private var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task { @MainActor in
            await controller?.shutdownAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { controller?.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@MainActor struct NativeVoiceApplication: App {
    @NSApplicationDelegateAdaptor(VoiceAppDelegate.self) private var delegate
    @StateObject private var controller = VoiceController()
    var body: some Scene {
        WindowGroup("RAPP Voice", id: "voice") {
            VoiceWindow(controller: controller)
                .onAppear { delegate.controller = controller }
        }
        .defaultSize(width: 800, height: 720)
        MenuBarExtra {
            VoiceMenu(controller: controller)
        } label: {
            Label(controller.menuTitle, systemImage: controller.indicator)
        }
    }
}

@MainActor private struct VoiceMenu: View {
    @ObservedObject var controller: VoiceController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(controller.recording ? "● Recording \(Int(controller.elapsed))s" : controller.displayState)
        Text(controller.status)
        Divider()
        Button("Open RAPP Voice") { openWindow(id: "voice"); NSApp.activate(ignoringOtherApps: true) }
            .accessibilityIdentifier("voice.open")
        Button("Start hands-free dictation") { controller.start() }.disabled(controller.busy)
            .accessibilityIdentifier("voice.start")
        Button("Stop and transcribe") { controller.stop() }.disabled(!controller.recording)
            .accessibilityIdentifier("voice.stop")
        Button("Cancel") { controller.cancel() }.disabled(!controller.busy)
            .accessibilityIdentifier("voice.cancel")
        Button("Copy last transcript") { controller.copyTranscript() }.disabled(controller.transcript.isEmpty || controller.busy)
        Divider()
        Button("Quit RAPP Voice") { NSApp.terminate(nil) }
    }
}
