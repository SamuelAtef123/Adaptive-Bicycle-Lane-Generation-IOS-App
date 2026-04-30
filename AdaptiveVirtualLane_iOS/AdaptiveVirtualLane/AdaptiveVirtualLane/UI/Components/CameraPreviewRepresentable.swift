import SwiftUI
import AVFoundation

struct CameraPreviewRepresentable: UIViewRepresentable {

    let previewLayer: AVCaptureVideoPreviewLayer?
    @Binding var renderState: FrameRenderState

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        if let layer = previewLayer {
            view.attachPreviewLayer(layer)
        }
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {
        if let layer = previewLayer, layer.superlayer == nil {
            uiView.attachPreviewLayer(layer)
        }
        uiView.updateOverlay(state: renderState)
    }
}
