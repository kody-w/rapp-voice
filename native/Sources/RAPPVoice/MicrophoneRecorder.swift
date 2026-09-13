import AVFoundation
import Foundation
import RAPPVoiceCore

@MainActor final class MicrophoneRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    var didFinish: ((Bool) -> Void)?
    var didFail: ((Error) -> Void)?

    var level: Float { recorder?.updateMeters(); return recorder?.averagePower(forChannel: 0) ?? -160 }

    func start(url: URL, maximumDuration: Double) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw VoiceError.microphoneDenied }
        guard recorder == nil else { throw VoiceError.recordingFailed("a recording is already active") }
        let next = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        next.delegate = self
        next.isMeteringEnabled = true
        guard next.prepareToRecord(), next.record(forDuration: maximumDuration) else {
            throw VoiceError.recordingFailed("the default microphone could not be opened")
        }
        recorder = next
    }

    func stop() {
        let previous = recorder
        recorder = nil
        previous?.delegate = nil
        previous?.stop()
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard self?.recorder === recorder else { return }
            self?.didFinish?(flag)
        }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard self?.recorder === recorder else { return }
            self?.didFail?(error ?? VoiceError.recordingFailed("audio encoding failed"))
        }
    }
}
