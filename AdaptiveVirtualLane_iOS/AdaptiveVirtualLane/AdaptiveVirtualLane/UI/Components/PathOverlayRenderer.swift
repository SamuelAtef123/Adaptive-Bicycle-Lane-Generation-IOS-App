import UIKit
import CoreGraphics

final class PathOverlayRenderer {

    // MARK: - Colors
    static let laneColor      = UIColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 0.40)
    static let borderColor    = UIColor(red: 0.2, green: 0.9, blue: 0.2, alpha: 0.90)
    static let centerColor    = UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.70)
    static let obstacleColors: [String: UIColor] = [
        "person":       .systemYellow,
        "car":          .systemRed,
        "bicycle":      .systemGreen,
        "motorcycle":   .systemOrange,
        "bus":          .systemRed,
        "truck":        .systemRed,
        "traffic light":.systemBlue,
        "stop sign":    .systemPurple
    ]

    // MARK: - Main Render

    func render(state: FrameRenderState,
                context: CGContext,
                frameSize: CGSize) {

        // 1. Draw virtual lane
        if let path = state.virtualPath {
            drawVirtualLane(path: path, context: context)
        }

        // 2. Draw obstacles
        for obstacle in state.obstacles {
            drawObstacle(obstacle, context: context, frameSize: frameSize)
        }

        // 3. Draw warnings overlay
        if !state.warnings.isEmpty {
            drawWarnings(state.warnings, context: context, frameSize: frameSize)
        }

        // 4. Draw HUD
        drawHUD(state: state, context: context, frameSize: frameSize)
    }

    // MARK: - Virtual Lane Drawing

    private func drawVirtualLane(path: VirtualLanePath, context: CGContext) {
        guard path.rightAnchors.count == 4, path.leftAnchors.count == 4 else { return }

        guard
            let rightCurve = BezierCurve.from(path.rightAnchors),
            let leftCurve  = BezierCurve.from(path.leftAnchors)
        else { return }

        let steps  = 40
        let rightPts = rightCurve.points(steps: steps)
        let leftPts  = leftCurve.points(steps: steps)

        // Filled polygon
        let polygon = CGMutablePath()
        if let first = rightPts.first { polygon.move(to: first) }
        rightPts.forEach { polygon.addLine(to: $0) }
        leftPts.reversed().forEach { polygon.addLine(to: $0) }
        polygon.closeSubpath()

        context.setFillColor(Self.laneColor.cgColor)
        context.addPath(polygon)
        context.fillPath()

        // Right border
        drawCurve(pts: rightPts, color: Self.borderColor, lineWidth: 3, context: context)

        // Left border
        drawCurve(pts: leftPts, color: Self.borderColor, lineWidth: 3, context: context)

        // Dashed centreline
        let centerPts = zip(rightPts, leftPts).map { r, l in
            CGPoint(x: (r.x + l.x) / 2, y: (r.y + l.y) / 2)
        }
        drawCurve(pts: centerPts, color: Self.centerColor, lineWidth: 1.5, context: context, dashed: true)
    }

    private func drawCurve(pts: [CGPoint], color: UIColor, lineWidth: CGFloat,
                            context: CGContext, dashed: Bool = false) {
        guard let first = pts.first else { return }
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if dashed { context.setLineDash(phase: 0, lengths: [12, 8]) }
        context.beginPath()
        context.move(to: first)
        pts.dropFirst().forEach { context.addLine(to: $0) }
        context.strokePath()
        context.restoreGState()
    }

    // MARK: - Obstacle Drawing

    private func drawObstacle(_ obstacle: TrackedObstacle, context: CGContext, frameSize: CGSize) {
        let box   = obstacle.boundingBox
        let color = (Self.obstacleColors[obstacle.className] ?? .systemYellow)

        context.saveGState()

        // Bounding box
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(2.5)
        context.setFillColor(color.withAlphaComponent(0.10).cgColor)
        context.addRect(box)
        context.drawPath(using: .fillStroke)

        // Label background
        let label = "\(obstacle.className) #\(obstacle.trackID)"
        let fontSize: CGFloat = 13
        let font = UIFont.boldSystemFont(ofSize: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white
        ]
        let textSize = label.size(withAttributes: attrs)
        let labelRect = CGRect(x: box.minX, y: box.minY - textSize.height - 4,
                                width: textSize.width + 8, height: textSize.height + 4)
        context.setFillColor(color.withAlphaComponent(0.75).cgColor)
        context.fill(labelRect)
        context.restoreGState()

        // Draw text (UIKit bridge)
        UIGraphicsPushContext(context)
        label.draw(in: CGRect(x: labelRect.minX + 4, y: labelRect.minY + 2,
                              width: labelRect.width, height: labelRect.height),
                   withAttributes: attrs)
        UIGraphicsPopContext()
    }

    // MARK: - Warnings

    private func drawWarnings(_ warnings: Set<WarningType>, context: CGContext, frameSize: CGSize) {
        var messages = [String]()
        if warnings.contains(.narrowRoad)      { messages.append("⚠️ NARROW ROAD") }
        if warnings.contains(.narrowCorridor)  { messages.append("⚠️ NARROW CORRIDOR") }
        if warnings.contains(.obstacleAhead)   { messages.append("⚠️ OBSTACLE AHEAD") }
        if warnings.contains(.intersectionAhead){ messages.append("🔀 INTERSECTION") }

        let font = UIFont.boldSystemFont(ofSize: 16)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]

        UIGraphicsPushContext(context)
        var yOffset: CGFloat = 80
        for msg in messages {
            let sz = msg.size(withAttributes: attrs)
            let rect = CGRect(x: (frameSize.width - sz.width) / 2 - 8, y: yOffset,
                              width: sz.width + 16, height: sz.height + 8)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 8)
            UIColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 0.85).setFill()
            path.fill()
            msg.draw(in: CGRect(x: rect.minX + 8, y: rect.minY + 4,
                                width: sz.width, height: sz.height), withAttributes: attrs)
            yOffset += sz.height + 16
        }
        UIGraphicsPopContext()
    }

    // MARK: - HUD

    private func drawHUD(state: FrameRenderState, context: CGContext, frameSize: CGSize) {
        UIGraphicsPushContext(context)

        let lines: [String] = [
            state.bikeLaneDetected ? "🚲 Bike Lane Detected" : "🛣️ Open Road",
            state.roadType.map { "Road: \($0 == .oneWay ? "One-Way" : "Two-Way")" } ?? "",
            state.trafficLevel.map { "Traffic: \($0.rawValue)" } ?? "",
            state.laneDecision.map { String(format: "Lane: %.1fm", $0.finalWidth) } ?? "",
            state.intersectionMode ? "🔀 Intersection Mode" : ""
        ].filter { !$0.isEmpty }

        let font  = UIFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]

        // Bottom-left HUD panel
        let panelWidth: CGFloat = 200
        let lineH: CGFloat = 18
        let panelH = CGFloat(lines.count) * lineH + 12
        let panelX: CGFloat = 12
        let panelY = frameSize.height - panelH - 30

        let panelRect = CGRect(x: panelX, y: panelY, width: panelWidth, height: panelH)
        let panelPath = UIBezierPath(roundedRect: panelRect, cornerRadius: 8)
        UIColor.black.withAlphaComponent(0.55).setFill()
        panelPath.fill()

        for (i, line) in lines.enumerated() {
            line.draw(at: CGPoint(x: panelX + 8, y: panelY + 6 + CGFloat(i) * lineH), withAttributes: attrs)
        }

        UIGraphicsPopContext()
    }
}
