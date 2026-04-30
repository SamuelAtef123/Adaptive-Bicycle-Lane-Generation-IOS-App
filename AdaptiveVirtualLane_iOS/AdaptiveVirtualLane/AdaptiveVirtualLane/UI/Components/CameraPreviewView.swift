import UIKit
import AVFoundation

final class CameraPreviewView: UIView {

    private let overlayLayer = CALayer()
    private let renderer = PathOverlayRenderer()
    private var currentState = FrameRenderState()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .black
        overlayLayer.frame = bounds
        overlayLayer.contentsGravity = .resizeAspectFill
        layer.addSublayer(overlayLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        overlayLayer.frame = bounds
    }

    // MARK: - Preview Layer

    func attachPreviewLayer(_ previewLayer: AVCaptureVideoPreviewLayer) {
        previewLayer.frame = bounds
        layer.insertSublayer(previewLayer, at: 0)
    }

    // MARK: - Update Overlay

    func updateOverlay(state: FrameRenderState) {
        currentState = state

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let size = self.bounds.size
            guard size.width > 0, size.height > 0 else { return }

            UIGraphicsBeginImageContextWithOptions(size, false, UIScreen.main.scale)
            guard let ctx = UIGraphicsGetCurrentContext() else {
                UIGraphicsEndImageContext(); return
            }

            ctx.clear(CGRect(origin: .zero, size: size))
            self.renderer.render(state: state, context: ctx, frameSize: size)

            let image = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.overlayLayer.contents = image?.cgImage
            CATransaction.commit()
        }
    }
}
