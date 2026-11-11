import AVFoundation
import SwiftUI
import UIKit

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // layerClass 를 AVCaptureVideoPreviewLayer 로 지정했으므로 항상 성공
        layer as! AVCaptureVideoPreviewLayer
    }
}

struct CameraPreview: UIViewRepresentable {
    let camera: CameraManager

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspect
        camera.previewLayer = view.previewLayer
        camera.updatePreviewRotation()
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        camera.updatePreviewRotation()
    }
}
