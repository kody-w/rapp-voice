import Foundation

public struct WAVAudio: Sendable {
    public let duration: Double
    public let peak: Double
    public let rootMeanSquare: Double
    public let sampleCount: Int

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE" else {
            throw VoiceError.invalidWAV("expected RIFF/WAVE")
        }
        func uint16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func uint32(_ at: Int) -> Int { uint16(at) | uint16(at + 2) << 16 }
        guard uint32(4) + 8 <= bytes.count else { throw VoiceError.invalidWAV("truncated RIFF payload") }
        let limit = uint32(4) + 8
        var offset = 12
        var validFormat = false
        var samples: Range<Int>?
        while offset + 8 <= limit {
            let size = uint32(offset + 4)
            let begin = offset + 8
            guard size <= limit - begin else { throw VoiceError.invalidWAV("truncated audio chunk") }
            let kind = String(bytes: bytes[offset..<offset + 4], encoding: .ascii)
            if kind == "fmt " {
                guard size >= 16, uint16(begin) == 1, uint16(begin + 2) == 1,
                      uint32(begin + 4) == 16_000, uint32(begin + 8) == 32_000,
                      uint16(begin + 12) == 2, uint16(begin + 14) == 16 else {
                    throw VoiceError.invalidWAV("capture must be mono 16 kHz, signed 16-bit PCM")
                }
                validFormat = true
            } else if kind == "data" {
                guard size % 2 == 0 else { throw VoiceError.invalidWAV("unaligned PCM samples") }
                samples = begin..<begin + size
            }
            offset = begin + size + size % 2
        }
        guard validFormat, let samples else { throw VoiceError.invalidWAV("missing format or audio data") }
        sampleCount = samples.count / 2
        duration = Double(sampleCount) / 16_000
        var sum = 0.0
        var maximum = 0.0
        for index in stride(from: samples.lowerBound, to: samples.upperBound, by: 2) {
            let signed = Int16(bitPattern: UInt16(uint16(index)))
            let sample = Double(signed) / 32_768
            sum += sample * sample
            maximum = max(maximum, abs(sample))
        }
        peak = maximum
        rootMeanSquare = sampleCount > 0 ? sqrt(sum / Double(sampleCount)) : 0
    }

    public static func read(_ url: URL) throws -> Self {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 40_000_000 else { throw VoiceError.invalidWAV("recording exceeds the 600-second limit") }
        return try .init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func pcm16(samples: [Int16]) -> Data {
        var data = Data()
        func word(_ value: UInt16) {
            data.append(UInt8(value & 255))
            data.append(UInt8(value >> 8))
        }
        func dword(_ value: UInt32) {
            word(UInt16(value & 65535))
            word(UInt16(value >> 16))
        }
        data.append(contentsOf: "RIFF".utf8)
        dword(UInt32(36 + samples.count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        dword(16); word(1); word(1); dword(16_000); dword(32_000); word(2); word(16)
        data.append(contentsOf: "data".utf8)
        dword(UInt32(samples.count * 2))
        for sample in samples { word(UInt16(bitPattern: sample)) }
        return data
    }
}
