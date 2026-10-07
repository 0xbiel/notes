// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Notes",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Notes", targets: ["Notes"])],
    targets: [
        .target(name: "LectureCore"),
        .executableTarget(name: "Notes", dependencies: ["LectureCore"]),
        .testTarget(name: "LectureCoreTests", dependencies: ["LectureCore"]),
        .testTarget(name: "NotesUITests", dependencies: ["Notes", "LectureCore"])
    ]
)
