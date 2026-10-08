// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeetingNotes",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "MeetingNotes", path: "Sources/MeetingNotes")]
)
