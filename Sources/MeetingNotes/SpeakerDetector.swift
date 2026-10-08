import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Works out who is talking from the meeting app's own UI. Zoom, Meet and Teams draw a coloured border
/// around the active speaker's tile (see `MeetingApp.isHighlight`), with the participant's name in that
/// tile's bottom-left corner. Every ~15 s it also reads all name labels to build a participant list.
/// Frames are analysed in memory about once a second and never saved.
///
/// When the meeting window is minimised, on another Space, or (Meet) its tab is in the background,
/// detection pauses (those lines are labelled "Not recognised") and resumes when the window is back.
final class SpeakerDetector {
    static let unknownSpeaker = "Not recognised"

    enum Status: Equatable {
        case speaking(String)
        case noHighlight  // meeting visible, but no highlighted tile (speaker view, or nobody talking)
        case appHidden
    }

    struct Sample {
        let time: TimeInterval  // seconds from the start of the meeting
        let name: String
    }

    private let app: MeetingApp
    private let sessionStart: Date
    private let displayOrigin: CGPoint
    private let pixelsPerPoint: CGFloat
    private let onChange: @MainActor (Status) -> Void
    private let queue = DispatchQueue(label: "speaker-detector")
    private var samples: [Sample] = []
    private var nameCounts: [String: Int] = [:]
    private var lastNameScan: TimeInterval = -.infinity
    private var window: CGRect?  // meeting window in frame pixels; nil while hidden
    private var status: Status = .noHighlight
    private var visibilityTimer: DispatchSourceTimer?

    init(app: MeetingApp, sessionStart: Date, displayFrame: CGRect, frameWidth: Int,
         onChange: @escaping @MainActor (Status) -> Void) {
        self.app = app
        self.sessionStart = sessionStart
        self.displayOrigin = displayFrame.origin
        self.pixelsPerPoint = CGFloat(frameWidth) / displayFrame.width
        self.onChange = onChange
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2)
        timer.setEventHandler { [weak self] in self?.checkVisibility() }
        timer.resume()
        visibilityTimer = timer
    }

    func process(_ frame: CVPixelBuffer) {
        let time = Date().timeIntervalSince(sessionStart)
        queue.async { [self] in
            guard let window else { return }
            if time - lastNameScan >= 15 {
                lastNameScan = time
                for name in Self.nameLabels(in: frame, region: window) { nameCounts[name, default: 0] += 1 }
            }
            if let tile = activeTile(in: frame, region: window), let name = Self.readName(in: frame, tile: tile) {
                samples.append(Sample(time: time, name: name))
                update(.speaking(name))
            } else {
                update(.noHighlight)
            }
        }
    }

    /// The speaker timeline, and names seen on screen in at least two scans (fewer is likely noise).
    func finish() -> (samples: [Sample], participants: [String]) {
        queue.sync {
            visibilityTimer?.cancel()
            visibilityTimer = nil
            let speakers = Set(samples.map(\.name))
            let seen = nameCounts.filter { $0.value >= 2 }.map(\.key)
            return (samples, Array(speakers.union(seen)).sorted())
        }
    }

    /// The name seen most often while a segment was spoken. Meeting apps move the highlight about a
    /// second after someone starts talking, so the window reaches a little past the segment.
    static func dominantSpeaker(in samples: [Sample], from start: TimeInterval, to end: TimeInterval) -> String? {
        let names = samples.filter { $0.time >= start - 0.5 && $0.time <= end + 1.5 }.map(\.name)
        return Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +).max { $0.value < $1.value }?.key
    }

    private func checkVisibility() {
        window = MeetingDetector.meetingWindow(of: app).map { points in
            CGRect(x: (points.minX - displayOrigin.x) * pixelsPerPoint,
                   y: (points.minY - displayOrigin.y) * pixelsPerPoint,
                   width: points.width * pixelsPerPoint, height: points.height * pixelsPerPoint)
        }
        if window == nil {
            update(.appHidden)
        } else if status == .appHidden {
            update(.noHighlight)  // back on screen: the next frame resumes detection
        }
    }

    private func update(_ new: Status) {
        guard new != status else { return }
        status = new
        Task { @MainActor [onChange] in onChange(new) }
    }

    /// Bounding box (pixels, top-left origin) of the active-speaker border inside the meeting window.
    /// Only long straight runs of the highlight colour count, so similar colours in someone's video
    /// (plants, shirts) or elsewhere in the UI are ignored.
    private func activeTile(in frame: CVPixelBuffer, region: CGRect) -> CGRect? {
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(frame) else { return nil }
        let bounds = region.intersection(CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(frame),
                                                height: CVPixelBufferGetHeight(frame))).integral
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let (x0, y0, width, height) = (Int(bounds.minX), Int(bounds.minY), Int(bounds.width), Int(bounds.height))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(frame)
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        var rowCounts = [Int](repeating: 0, count: height)
        var colCounts = [Int](repeating: 0, count: width)
        for y in 0..<height {
            let row = pixels + (y0 + y) * bytesPerRow + x0 * 4
            for x in 0..<width {
                let p = row + x * 4  // BGRA
                if app.isHighlight(r: Int(p[2]), g: Int(p[1]), b: Int(p[0])) {
                    rowCounts[y] += 1
                    colCounts[x] += 1
                }
            }
        }
        let rows = rowCounts.indices.filter { rowCounts[$0] > width / 10 }
        let cols = colCounts.indices.filter { colCounts[$0] > height / 10 }
        guard let top = rows.first, let bottom = rows.last, let left = cols.first, let right = cols.last,
              bottom - top > height / 10, right - left > width / 10 else { return nil }
        return CGRect(x: x0 + left, y: y0 + top, width: right - left, height: bottom - top)
    }

    private static func readName(in frame: CVPixelBuffer, tile: CGRect) -> String? {
        // Bottom-left quarter of the tile; the name label is the lowest line of text there.
        let label = CGRect(x: tile.minX, y: tile.maxY - tile.height * 0.25, width: tile.width * 0.75,
                           height: tile.height * 0.25)
        guard let text = recognizeText(in: frame, region: label)
            .min(by: { $0.boundingBox.minY < $1.boundingBox.minY })?
            .topCandidates(1).first?.string else { return nil }
        let name = String(text.drop { !$0.isLetter }).trimmingCharacters(in: .whitespaces)  // drop mic icons
        return (2...40).contains(name.count) ? name : nil
    }

    /// Short Title-Case lines in the meeting window that look like participant names.
    private static func nameLabels(in frame: CVPixelBuffer, region: CGRect) -> Set<String> {
        let uiText: Set<String> = [
            "mute", "unmute", "start video", "stop video", "share", "share screen", "chat", "participants",
            "people", "leave", "end", "more", "reactions", "raise hand", "record", "recording", "view",
            "gallery", "speaker", "security", "apps", "captions", "meeting details", "activities",
            "present now", "host tools", "you", "camera", "mic", "rooms", "notes", "join", "settings",
        ]
        let lines = recognizeText(in: frame, region: region).compactMap { $0.topCandidates(1).first?.string }
        return Set(lines.compactMap { line in
            let name = String(line.drop { !$0.isLetter }).trimmingCharacters(in: .whitespaces)
            let words = name.split(separator: " ")
            guard (1...4).contains(words.count), (2...32).contains(name.count),
                  !uiText.contains(name.lowercased()),
                  words.allSatisfy({ word in
                      word.first?.isUppercase == true && word.allSatisfy { $0.isLetter || "'.-".contains($0) }
                  }) else { return nil }
            return name
        })
    }

    /// Runs on-device OCR on a pixel rectangle (top-left origin) of the frame.
    private static func recognizeText(in frame: CVPixelBuffer, region: CGRect) -> [VNRecognizedTextObservation] {
        let width = CGFloat(CVPixelBufferGetWidth(frame))
        let height = CGFloat(CVPixelBufferGetHeight(frame))
        // Vision wants the region normalised with a bottom-left origin.
        let normalized = CGRect(x: region.minX / width, y: (height - region.maxY) / height,
                                width: region.width / width, height: region.height / height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !normalized.isNull, normalized.width > 0, normalized.height > 0 else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.regionOfInterest = normalized
        try? VNImageRequestHandler(cvPixelBuffer: frame).perform([request])
        return request.results ?? []
    }
}
