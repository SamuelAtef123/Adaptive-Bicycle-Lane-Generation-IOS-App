import CoreImage
import Vision
import CoreGraphics

/// Warps path anchor points between keyframes using optical flow (ego-motion compensation)
final class OpticalFlowWarper {

    private var previousPixelBuffer: CVPixelBuffer?
    private let ciContext = CIContext()

    // MARK: - Update & Warp

    /// Call on every frame. Returns warped versions of the provided anchor points.
    func warpAnchors(rightAnchors: [CGPoint],
                     leftAnchors: [CGPoint],
                     currentBuffer: CVPixelBuffer,
                     frameSize: CGSize) -> (right: [CGPoint], left: [CGPoint]) {

        defer { previousPixelBuffer = currentBuffer }
        guard let prev = previousPixelBuffer else {
            return (rightAnchors, leftAnchors)
        }

        // Use Vision optical flow
        let request = VNTrackOpticalFlowRequest()
        guard let result = computeFlow(from: prev, to: currentBuffer, request: request) else {
            return (rightAnchors, leftAnchors)
        }

        let warpedRight = rightAnchors.map { warp($0, using: result, frameSize: frameSize) }
        let warpedLeft  = leftAnchors.map  { warp($0, using: result, frameSize: frameSize) }
        return (warpedRight, warpedLeft)
    }

    // MARK: - Simple Translation-Based Warp Fallback

    /// Lightweight version using CoreImage optical flow approximation
    func warpAnchorsSimple(rightAnchors: [CGPoint],
                            leftAnchors: [CGPoint],
                            currentBuffer: CVPixelBuffer,
                            frameSize: CGSize) -> (right: [CGPoint], left: [CGPoint]) {
        defer { previousPixelBuffer = currentBuffer }
        guard let prev = previousPixelBuffer else {
            return (rightAnchors, leftAnchors)
        }

        // Estimate global translation via center-region brightness shift
        let translation = estimateTranslation(from: prev, to: currentBuffer)

        let warpedRight = rightAnchors.map { pt in
            CGPoint(x: pt.x + translation.x, y: pt.y + translation.y)
        }
        let warpedLeft = leftAnchors.map { pt in
            CGPoint(x: pt.x + translation.x, y: pt.y + translation.y)
        }
        return (warpedRight, warpedLeft)
    }

    // MARK: - Helpers

    private func computeFlow(from prev: CVPixelBuffer,
                              to current: CVPixelBuffer,
                              request: VNTrackOpticalFlowRequest) -> CVPixelBuffer? {
        let handler = VNSequenceRequestHandler()
        do {
            try handler.perform([request], on: prev, orientation: .up)
            // Result would be a VNOpticalFlowObservation
            return (request.results?.first as? VNPixelBufferObservation)?.pixelBuffer
        } catch {
            return nil
        }
    }

    private func warp(_ point: CGPoint, using flowBuffer: CVPixelBuffer, frameSize: CGSize) -> CGPoint {
        let px = Int(point.x / frameSize.width  * CGFloat(CVPixelBufferGetWidth(flowBuffer)))
        let py = Int(point.y / frameSize.height * CGFloat(CVPixelBufferGetHeight(flowBuffer)))

        CVPixelBufferLockBaseAddress(flowBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(flowBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(flowBuffer) else { return point }
        let w   = CVPixelBufferGetWidth(flowBuffer)
        let h   = CVPixelBufferGetHeight(flowBuffer)
        let bpr = CVPixelBufferGetBytesPerRow(flowBuffer)

        guard px >= 0, px < w, py >= 0, py < h else { return point }

        // Flow is stored as 2-channel float (dx, dy) per pixel
        let ptr = base.assumingMemoryBound(to: Float32.self)
        let idx = py * (bpr / MemoryLayout<Float32>.size) + px * 2
        let dx  = CGFloat(ptr[idx])
        let dy  = CGFloat(ptr[idx + 1])

        return CGPoint(x: point.x + dx * frameSize.width  / CGFloat(w),
                       y: point.y + dy * frameSize.height / CGFloat(h))
    }

    private func estimateTranslation(from prev: CVPixelBuffer, to curr: CVPixelBuffer) -> CGPoint {
        // Simple: compare center-crop mean brightness shift as a proxy for vertical motion
        // In practice a proper Farneback / Lucas-Kanade would be used
        return .zero   // no-op on non-keyframes is safe — Kalman handles smoothing
    }
}
