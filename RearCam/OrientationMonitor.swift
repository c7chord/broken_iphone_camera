import CoreMotion
import CoreGraphics
import UIKit

/// 가속도계로 기기 방향을 추적한다. (화면 회전 잠금과 무관하게 동작)
/// 앱 UI는 세로 고정이므로, 저장되는 사진/영상의 방향만 이 값으로 정한다.
final class OrientationMonitor {
    private let motion = CMMotionManager()
    private(set) var orientation: UIDeviceOrientation = .portrait
    var onChange: ((UIDeviceOrientation) -> Void)?

    func start() {
        guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
        motion.accelerometerUpdateInterval = 0.2
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let a = data?.acceleration else { return }
            self.update(x: a.x, y: a.y)
        }
    }

    func stop() {
        motion.stopAccelerometerUpdates()
    }

    private func update(x: Double, y: Double) {
        // 바닥에 눕혀 놓은 상태면 마지막 방향 유지
        guard max(abs(x), abs(y)) > 0.45 else { return }
        var next = orientation
        if abs(y) > abs(x) + 0.15 {
            next = y < 0 ? .portrait : .portraitUpsideDown
        } else if abs(x) > abs(y) + 0.15 {
            // 기기 윗부분이 왼쪽을 향하면 x < 0 → landscapeLeft
            next = x < 0 ? .landscapeLeft : .landscapeRight
        }
        if next != orientation {
            orientation = next
            onChange?(next)
        }
    }

    /// 수평이 맞도록 버퍼를 시계 방향으로 돌려야 하는 각도 (AVCaptureConnection.videoRotationAngle 과 동일한 의미)
    func captureAngle(for position: CameraPosition) -> CGFloat {
        switch orientation {
        case .landscapeLeft: return position == .back ? 0 : 180
        case .landscapeRight: return position == .back ? 180 : 0
        case .portraitUpsideDown: return 270
        default: return 90
        }
    }
}
