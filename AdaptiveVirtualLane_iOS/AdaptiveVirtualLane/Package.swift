// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AdaptiveVirtualLane",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "AdaptiveVirtualLane", targets: ["AdaptiveVirtualLane"])
    ],
    dependencies: [
        // No mandatory third-party dependencies required.
        // All core functionality uses Apple frameworks:
        //   - CoreML       (model inference)
        //   - Vision       (VNCoreMLRequest, optical flow)
        //   - AVFoundation (camera capture, speech synthesis)
        //   - CoreLocation (GPS)
        //   - CoreImage    (preprocessing)
        //   - SwiftUI      (UI)
        //   - Metal        (GPU rendering)
        //   - Accelerate   (fast array ops)
    ],
    targets: [
        .target(
            name: "AdaptiveVirtualLane",
            path: "AdaptiveVirtualLane",
            resources: [.process("Resources")]
        )
    ]
)

// ============================================================
// OPTIONAL third-party packages (add via Xcode SPM UI):
//
// 1. If you want a full Farneback optical flow Swift wrapper:
//    No public Swift package exists yet — use Vision framework's
//    VNTrackOpticalFlowRequest (already used in OpticalFlowWarper.swift)
//
// 2. For a production DeepSORT tracker with re-ID network:
//    Implement your own CoreML-based appearance descriptor
//    or port from: https://github.com/nicktindall/cyclon.p2p
//
// 3. Logging (optional):
//    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0")
// ============================================================
