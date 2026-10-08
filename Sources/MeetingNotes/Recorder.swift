import AVFoundation
import ScreenCaptureKit

struct Track {
    static let you = "You"
    static let others = "Others"

    let speaker: String
    let chunks: [ChunkedWavWriter.Chunk]
}

/// Writes mono 16 kHz PCM into 10-minute WAV chunks, so each stays under Whisper's 25 MB upload limit.
final class ChunkedWavWriter {
    struct Chunk {
        let url: URL
        let offset: TimeInterval  // seconds from the start of the meeting
    }

    private static let sampleRate = 16_000.0
    private static let chunkFrames = AVAudioFramePosition(sampleRate * 600)

    private let dir: URL
    private let name: String
    private let sessionStart: Date
    private let queue = DispatchQueue(label: "wav-writer")
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var framesInChunk: AVAudioFramePosition = 0
    private var chunks: [Chunk] = []

    init(dir: URL, name: String, sessionStart: Date) {
        self.dir = dir
        self.name = name
        self.sessionStart = sessionStart
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async {
            do { try self.write(buffer) } catch { NSLog("Audio write failed: \(error)") }
        }
    }

    func finish() -> [Chunk] {
        queue.sync {
            file = nil
            return chunks
        }
    }

    private func write(_ input: AVAudioPCMBuffer) throws {
        if file == nil || framesInChunk >= Self.chunkFrames { try openChunk() }
        guard let file else { return }
        let outFormat = file.processingFormat
        if converter == nil || converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: outFormat)
        }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * outFormat.sampleRate / input.format.sampleRate) + 1024
        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        try file.write(from: out)
        framesInChunk += AVAudioFramePosition(out.frameLength)
    }

    private func openChunk() throws {
        let offset = chunks.last.map { $0.offset + Double(framesInChunk) / Self.sampleRate }
            ?? Date().timeIntervalSince(sessionStart)
        let url = dir.appendingPathComponent("\(name)-\(chunks.count).wav")
        file = try AVAudioFile(
            forWriting: url,
            settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate,
                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false],
            commonFormat: .pcmFormatInt16, interleaved: true)
        framesInChunk = 0
        chunks.append(Chunk(url: url, offset: offset))
    }
}

private extension CMSampleBuffer {
    func pcmBuffer() -> AVAudioPCMBuffer? {
        guard let desc = formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(numSamples)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    var completeFrame: CVPixelBuffer? {
        guard let info = (CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]])?.first,
              let status = info[.status] as? Int, SCFrameStatus(rawValue: status) == .complete else { return nil }
        return imageBuffer
    }
}

struct Recording {
    let tracks: [Track]
    let speakers: [SpeakerDetector.Sample]
}

/// Captures Zoom's audio (the other participants) through ScreenCaptureKit and your microphone
/// through AVAudioEngine. Everything stays on this Mac; Zoom is never told.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    static let zoomBundleID = "us.zoom.xos"

    private var stream: SCStream?
    private let engine = AVAudioEngine()
    private var others: ChunkedWavWriter?
    private var mine: ChunkedWavWriter?
    private var detector: SpeakerDetector?

    func start(into dir: URL, detectSpeakers: Bool,
               onSpeaker: @escaping @MainActor (SpeakerDetector.Status) -> Void) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw AppError("Microphone access denied. Enable it in System Settings → Privacy & Security.")
        }
        let started = Date()
        others = ChunkedWavWriter(dir: dir, name: "others", sessionStart: started)
        mine = ChunkedWavWriter(dir: dir, name: "you", sessionStart: started)
        try await startCapture(sessionStart: started, detectSpeakers: detectSpeakers, onSpeaker: onSpeaker)
        try startMicrophone()
    }

    func stop() async -> Recording {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? await stream?.stopCapture()
        stream = nil
        return Recording(
            tracks: [Track(speaker: Track.others, chunks: others?.finish() ?? []),
                     Track(speaker: Track.you, chunks: mine?.finish() ?? [])],
            speakers: detector?.finish() ?? [])
    }

    private func startCapture(sessionStart: Date, detectSpeakers: Bool,
                              onSpeaker: @escaping @MainActor (SpeakerDetector.Status) -> Void) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw AppError("No display found.") }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 fps is plenty for speaker detection
        config.showsCursor = false

        // Only Zoom's audio and windows when it is running; otherwise all system audio and no speaker detection.
        let filter: SCContentFilter
        detector = nil
        if let zoom = content.applications.first(where: { $0.bundleIdentifier == Self.zoomBundleID }) {
            filter = SCContentFilter(display: display, including: [zoom], exceptingWindows: [])
            if detectSpeakers {
                detector = SpeakerDetector(sessionStart: sessionStart, zoomPID: zoom.processID, onChange: onSpeaker)
            }
        } else {
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }
        if detector != nil {
            // Retina-sharp name labels for OCR, capped so the per-frame pixel scan stays cheap.
            let scale = min(2, 2560 / Double(display.width))
            config.width = Int(Double(display.width) * scale)
            config.height = Int(Double(display.height) * scale)
            config.pixelFormat = kCVPixelFormatType_32BGRA
        } else {
            config.width = 2  // audio only; keep the unavoidable video stream tiny
            config.height = 2
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "zoom-frames"))
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "system-audio"))
        try await stream.startCapture()
        self.stream = stream
    }

    private func startMicrophone() throws {
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { [mine] buffer, _ in
            mine?.append(buffer)
        }
        try engine.start()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid else { return }
        switch type {
        case .audio:
            if let pcm = buffer.pcmBuffer() { others?.append(pcm) }
        case .screen:
            if let detector, let frame = buffer.completeFrame { detector.process(frame) }
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Capture stopped: \(error)")
    }
}
