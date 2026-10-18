import AVFoundation
import ScreenCaptureKit

/// Records a screen region, display or window with ScreenCaptureKit, adding the microphone through AVCapture.
/// Frames and audio go to a `RecordingWriter`. Callbacks arrive on private queues, so this class is not main-actor bound.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Configuration {
        var filter: SCContentFilter
        /// Region of the display, in display points with a top-left origin. Nil records the whole filter.
        var sourceRect: CGRect?
        var pixelSize: CGSize
        var options: RecordingOptions
        var outputURL: URL
    }

    enum RecorderError: LocalizedError {
        case alreadyRunning
        case notRunning

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "A recording is already running."
            case .notRunning: return "There is no recording to stop."
            }
        }
    }

    private var stream: SCStream?
    private var writer: RecordingWriter?
    private var micSession: AVCaptureSession?
    private let videoQueue = DispatchQueue(label: "com.snapshotx.recorder.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.snapshotx.recorder.audio", qos: .userInteractive)
    private let micQueue = DispatchQueue(label: "com.snapshotx.recorder.mic", qos: .userInteractive)

    /// Called if the stream dies on its own, for example when the display is disconnected.
    var onStreamError: ((Error) -> Void)?
    /// True when the microphone was requested but couldn't be used (permission denied or no device).
    private(set) var microphoneUnavailable = false

    func start(_ configuration: Configuration) async throws {
        guard stream == nil else { throw RecorderError.alreadyRunning }
        let options = configuration.options
        let width = Int(configuration.pixelSize.width)
        let height = Int(configuration.pixelSize.height)

        var useMicrophone = options.microphone
        if useMicrophone {
            useMicrophone = await Self.microphoneAllowed()
            microphoneUnavailable = !useMicrophone
        }

        let writer = try RecordingWriter(url: configuration.outputURL, width: width, height: height, fps: options.fps,
                                         systemAudio: options.systemAudio, microphone: useMicrophone)
        self.writer = writer

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        if let rect = configuration.sourceRect { config.sourceRect = rect }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        config.queueDepth = 8
        config.showsCursor = options.showCursor && !(options.studioMode && options.format == .mp4)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        if options.systemAudio {
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true // don't record SnapShotX's own shutter sounds
        }

        let stream = SCStream(filter: configuration.filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            if options.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
            self.stream = stream
            if useMicrophone { startMicrophone() }
            try await stream.startCapture()
        } catch {
            micSession?.stopRunning()
            micSession = nil
            self.stream = nil
            writer.cancel()
            self.writer = nil
            throw error
        }
    }

    /// Stops capturing and finishes the file. The summary's duration is the length of the recording.
    func stop() async throws -> RecordingWriter.Summary {
        guard let stream, let writer else { throw RecorderError.notRunning }
        self.stream = nil
        self.writer = nil
        micSession?.stopRunning()
        micSession = nil
        try? await stream.stopCapture()
        return try await writer.finish(at: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    /// Stops and throws the recording away.
    func cancel() async {
        let stream = self.stream
        let writer = self.writer
        self.stream = nil
        self.writer = nil
        micSession?.stopRunning()
        micSession = nil
        try? await stream?.stopCapture()
        writer?.cancel()
    }

    // MARK: Microphone

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func startMicrophone() {
        guard let device = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: device) else {
            microphoneUnavailable = true
            return
        }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        // Mono 48 kHz float PCM is what the writer's microphone track expects.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: micQueue)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            microphoneUnavailable = true
            return
        }
        session.addInput(input)
        session.addOutput(output)
        session.startRunning()
        micSession = session
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        writer?.appendMicrophone(sampleBuffer)
    }

    // MARK: ScreenCaptureKit

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            if Self.isCompleteFrame(sampleBuffer) { writer?.appendVideo(sampleBuffer) }
        case .audio:
            writer?.appendSystemAudio(sampleBuffer)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamError?(error)
    }

    /// ScreenCaptureKit also sends status-only buffers (idle, blank, suspended) that carry no picture.
    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }
}
