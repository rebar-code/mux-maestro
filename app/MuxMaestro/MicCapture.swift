import AVFoundation

/// Push-to-talk capture: an `AVAudioEngine` input tap, resampled to the 16 kHz
/// mono floats `VoiceEngine.transcribe` takes. `start` opens the mic (macOS
/// asks once, per `NSMicrophoneUsageDescription`); `stop` returns the take.
/// No end-of-speech detection: the talk button decides when a take ends.
final class MicCapture {
    enum CaptureError: LocalizedError {
        case noInput
        case denied

        var errorDescription: String? {
            switch self {
            case .noInput: return "No microphone input"
            case .denied: return "Microphone access is off for MuxMaestro in System Settings"
            }
        }
    }

    static var authorization: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Prompts on first use; later calls answer from the stored grant.
    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private(set) var startedAt: Date?

    var isRecording: Bool { engine.isRunning }

    /// Seconds captured so far.
    var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / AudioResample.sampleRate
    }

    func start() throws {
        guard Self.authorization != .denied, Self.authorization != .restricted else { throw CaptureError.denied }
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw CaptureError.noInput }
        converter = AVAudioConverter(from: inFormat, to: AudioResample.format)
        lock.lock()
        samples = []
        lock.unlock()
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        startedAt = Date()
    }

    /// Stop the mic and return everything captured since `start`.
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        startedAt = nil
        lock.lock()
        defer { lock.unlock() }
        let take = samples
        samples = []
        return take
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let out = AudioResample.convert(buffer, with: converter, flush: false)
        lock.lock()
        samples.append(contentsOf: out)
        lock.unlock()
    }
}

extension MicCapture: VoiceRecorder {
    func requestAccess() async -> Bool {
        switch Self.authorization {
        case .authorized: return true
        case .notDetermined: return await Self.requestAccess()
        default: return false
        }
    }
}

/// Resampling to the STT input format, shared by the mic tap and file input.
enum AudioResample {
    static let sampleRate: Double = 16_000
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    enum ResampleError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            if case .unreadable(let path) = self { return "Could not read audio from \(path)" }
            return nil
        }
    }

    /// Convert one buffer. `flush` drains the converter's tail (end of a file);
    /// a live tap passes `false` so the next buffer continues the stream.
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, flush: Bool) -> [Float] {
        let ratio = sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = flush ? .endOfStream : .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }

    /// The whole file as 16 kHz mono floats.
    static func samples(from url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ResampleError.unreadable(url.path)
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
            let converter = AVAudioConverter(from: file.processingFormat, to: format)
        else { throw ResampleError.unreadable(url.path) }
        try file.read(into: buffer)
        return convert(buffer, with: converter, flush: true)
    }
}
