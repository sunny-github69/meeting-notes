import AppKit
import CoreAudio
import CoreGraphics

/// The meeting apps the recorder understands.
enum MeetingApp: String, CaseIterable {
    case zoom, meet, teams

    var title: String {
        switch self {
        case .zoom: return "Zoom"
        case .meet: return "Google Meet"
        case .teams: return "Microsoft Teams"
        }
    }

    /// Bundle ids of the apps that host the meeting. Google Meet runs inside a browser.
    var bundleIDs: [String] {
        switch self {
        case .zoom: return ["us.zoom.xos"]
        case .teams: return ["com.microsoft.teams2", "com.microsoft.teams"]
        case .meet: return ["com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.Browser",
                            "com.brave.Browser", "com.apple.Safari", "org.mozilla.firefox"]
        }
    }

    /// Whether a pixel has the colour of this app's active-speaker border.
    /// Zoom draws green; Meet a light blue (≈ #8AB4F8); Teams a lavender (≈ #7F85F5).
    /// The Meet and Teams values are best guesses from their UI; tune them here if detection misses.
    func isHighlight(r: Int, g: Int, b: Int) -> Bool {
        switch self {
        case .zoom: return g > 160 && g - max(r, b) > 70
        case .meet: return b > 200 && b - r > 70 && g > 140 && g < b
        case .teams: return b > 200 && (100...170).contains(r) && b - g > 70
        }
    }

    /// Zoom's audio comes from its own process, so it can be captured on its own. Browsers and Teams
    /// play audio from helper processes, so for them all system audio is recorded.
    var capturesOwnAudioOnly: Bool { self == .zoom }

    /// Does this window belong to the meeting? For Meet only the browser tab titled "Meet – …" counts.
    func isMeetingWindow(title: String) -> Bool {
        self == .meet ? title.hasPrefix("Meet") : true
    }
}

/// Answers "is a meeting going on, and in which app?" without any AI: process names, which apps are
/// using the microphone, and window titles.
enum MeetingDetector {
    /// A call that has just started: the app is using the microphone (Zoom: its meeting helper is
    /// running), and for Meet a "Meet – …" tab is in front.
    static func newCall() -> MeetingApp? {
        if isInCall(.zoom) { return .zoom }
        if isInCall(.teams) { return .teams }
        if isInCall(.meet) && meetingWindow(of: .meet) != nil { return .meet }
        return nil
    }

    /// Looser check used while recording: the Meet tab may be in the background, but the browser
    /// keeps the microphone open until you leave the call.
    static func isInCall(_ app: MeetingApp) -> Bool {
        if app == .zoom && processRunning("CptHost") { return true }
        return appsUsingMicrophone().contains { id in app.bundleIDs.contains { id.hasPrefix($0) } }
    }

    /// Best guess for a manual start: a call in progress, else whichever meeting app is open.
    static func currentApp() -> MeetingApp? {
        newCall() ?? MeetingApp.allCases.first { meetingWindow(of: $0) != nil }
    }

    /// The largest on-screen window of the app's meeting, in global screen points (top-left origin).
    /// Windows covered by other apps count; minimised ones and other Spaces do not.
    static func meetingWindow(of app: MeetingApp) -> CGRect? {
        let pids = Set(app.bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .map(\.processIdentifier))
        guard !pids.isEmpty else { return nil }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows
            .compactMap { window -> CGRect? in
                guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                      window[kCGWindowLayer as String] as? Int == 0,
                      app.isMeetingWindow(title: window[kCGWindowName as String] as? String ?? ""),
                      let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: bounds),
                      rect.width > 400, rect.height > 300 else { return nil }
                return rect
            }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    private static func processRunning(_ name: String) -> Bool {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", name]
        pgrep.standardOutput = FileHandle.nullDevice
        do {
            try pgrep.run()
            pgrep.waitUntilExit()
            return pgrep.terminationStatus == 0
        } catch { return false }
    }

    /// Bundle ids of processes currently recording from a microphone (macOS 14.4+; empty before).
    private static func appsUsingMicrophone() -> [String] {
        guard #available(macOS 14.4, *) else { return [] }
        let system = AudioObjectID(kAudioObjectSystemObject)
        func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
        }

        var listAddress = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &size) == noErr else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &listAddress, 0, nil, &size, &processes) == noErr else { return [] }

        return processes.compactMap { process in
            var runningAddress = address(kAudioProcessPropertyIsRunningInput)
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(process, &runningAddress, 0, nil, &runningSize, &running) == noErr,
                  running != 0 else { return nil }

            var idAddress = address(kAudioProcessPropertyBundleID)
            var bundleID: Unmanaged<CFString>?
            var idSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(process, &idAddress, 0, nil, &idSize, &bundleID) == noErr else { return nil }
            return bundleID?.takeRetainedValue() as String?
        }
    }
}
