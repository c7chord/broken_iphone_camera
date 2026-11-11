import AVFoundation
import CoreGraphics
import ImageIO
import UIKit

enum CaptureMode: String, CaseIterable, Identifiable {
    case photo
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photo: return "사진"
        case .video: return "동영상"
        }
    }
}

enum CameraPosition: String {
    case back
    case front
}

enum VideoQuality: String, CaseIterable, Identifiable {
    case uhd30
    case fhd30
    case fhd60

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uhd30: return "4K · 30fps"
        case .fhd30: return "1080p · 30fps"
        case .fhd60: return "1080p · 60fps"
        }
    }

    var width: Int32 { self == .uhd30 ? 3840 : 1920 }
    var height: Int32 { self == .uhd30 ? 2160 : 1080 }
    var fps: Double { self == .fhd60 ? 60 : 30 }
}

enum PhotoMethod: String, CaseIterable, Identifiable {
    /// 동영상 파이프라인(AVCaptureVideoDataOutput)에서 프레임을 떠서 저장한다.
    case videoFrame
    /// AVCapturePhotoOutput(속도 우선)으로 촬영한다. 비교/테스트용.
    case systemPhoto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .videoFrame: return "영상 프레임 캡처 (권장)"
        case .systemPhoto: return "시스템 사진 (테스트용)"
        }
    }

    var detail: String {
        switch self {
        case .videoFrame:
            return "동영상과 같은 경로에서 프레임 한 장을 그대로 저장합니다. 고장 난 기기에서도 무지개 왜곡이 생기지 않았던 경로입니다."
        case .systemPhoto:
            return "iOS 사진 처리 경로(AVCapturePhotoOutput, 속도 우선)를 사용합니다. 무지개 왜곡이 다시 생길 수 있으니 비교 테스트할 때만 쓰세요. (사진 비율 설정은 적용되지 않고 항상 4:3으로 찍힙니다)"
        }
    }
}

/// 사진 비율. 세로로 들면 3:4 / 9:16 / 1:1, 가로로 들면 4:3 / 16:9 / 1:1 로 저장된다.
enum PhotoAspect: String, CaseIterable, Identifiable {
    case standard = "4:3"
    case tall = "9:16"
    case square = "1:1"

    var id: String { rawValue }
    var title: String { rawValue }

    /// 긴 변 / 짧은 변
    var longShort: CGFloat {
        switch self {
        case .standard: return 4.0 / 3.0
        case .tall: return 16.0 / 9.0
        case .square: return 1
        }
    }

    var next: PhotoAspect {
        switch self {
        case .standard: return .tall
        case .tall: return .square
        case .square: return .standard
        }
    }

    /// 가운데를 기준으로 (긴 변 : 짧은 변) = longShort 가 되도록 자른 영역.
    /// 센서 버퍼는 항상 가로(긴 변이 가로)이므로 기기를 세로/가로로 들어도 같은 영역이 된다.
    func centerCrop(_ extent: CGRect) -> CGRect {
        let r = longShort
        let w = extent.width
        let h = extent.height
        var cw = w
        var ch = h
        if w >= h {
            if w / h > r { cw = h * r } else { ch = w / r }
        } else {
            if h / w > r { ch = w * r } else { cw = h / r }
        }
        cw = (cw / 2).rounded(.down) * 2
        ch = (ch / 2).rounded(.down) * 2
        return CGRect(x: (extent.midX - cw / 2).rounded(), y: (extent.midY - ch / 2).rounded(), width: cw, height: ch)
    }
}

enum PhotoFileFormat: String, CaseIterable, Identifiable {
    case heic
    case jpeg

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heic: return "HEIF (고효율)"
        case .jpeg: return "JPEG (호환성)"
        }
    }
}

struct SessionConfig {
    var position: CameraPosition
    var mode: CaptureMode
    var quality: VideoQuality
    var photoMethod: PhotoMethod
    var stabilization: Bool
    var audio: Bool
    var zoomDisplay: CGFloat
}

/// 카메라 포맷 선택. 10비트(HDR) 포맷은 피하고 8비트 420 포맷만 고른다.
enum FormatPicker {
    static func dimensions(_ format: AVCaptureDevice.Format) -> CMVideoDimensions {
        CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    }

    static func subtype(_ format: AVCaptureDevice.Format) -> FourCharCode {
        CMFormatDescriptionGetMediaSubType(format.formatDescription)
    }

    static func maxFrameRate(_ format: AVCaptureDevice.Format) -> Double {
        format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
    }

    static func isFullRange(_ format: AVCaptureDevice.Format) -> Bool {
        subtype(format) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }

    static func is8Bit420(_ format: AVCaptureDevice.Format) -> Bool {
        let s = subtype(format)
        return s == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || s == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    static func aspect(_ format: AVCaptureDevice.Format) -> Double {
        let d = dimensions(format)
        guard d.height > 0 else { return 0 }
        return Double(d.width) / Double(d.height)
    }

    /// 사진 모드: 4:3 중 가장 큰 해상도(최대 4032×3024), 30fps 이상.
    static func photoFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let candidates = device.formats.filter { f in
            is8Bit420(f)
                && abs(aspect(f) - 4.0 / 3.0) < 0.02
                && maxFrameRate(f) >= 29
                && dimensions(f).width <= 4032
        }
        return candidates.max { a, b in photoKey(a) < photoKey(b) }
    }

    private static func photoKey(_ f: AVCaptureDevice.Format) -> (Int, Int, Int) {
        let d = dimensions(f)
        return (Int(d.width) * Int(d.height), isFullRange(f) ? 1 : 0, f.isVideoBinned ? 0 : 1)
    }

    /// 동영상 모드: 요청한 해상도/프레임레이트와 정확히 맞는 포맷, 없으면 비슷한 16:9 포맷.
    static func videoFormat(for device: AVCaptureDevice, quality: VideoQuality) -> AVCaptureDevice.Format? {
        let exact = device.formats.filter { f in
            let d = dimensions(f)
            return is8Bit420(f)
                && d.width == quality.width
                && d.height == quality.height
                && maxFrameRate(f) >= quality.fps - 0.5
        }
        if let best = exact.max(by: { videoKey($0) < videoKey($1) }) {
            return best
        }
        let fallback = device.formats.filter { f in
            is8Bit420(f)
                && abs(aspect(f) - 16.0 / 9.0) < 0.02
                && maxFrameRate(f) >= quality.fps - 0.5
                && dimensions(f).width <= quality.width
        }
        if let best = fallback.max(by: { area($0) < area($1) }) {
            return best
        }
        return photoFormat(for: device)
    }

    private static func area(_ f: AVCaptureDevice.Format) -> Int {
        let d = dimensions(f)
        return Int(d.width) * Int(d.height)
    }

    private static func videoKey(_ f: AVCaptureDevice.Format) -> (Int, Int, Int) {
        (
            f.isVideoStabilizationModeSupported(.standard) ? 1 : 0,
            isFullRange(f) ? 0 : 1,
            f.isVideoBinned ? 1 : 0
        )
    }
}

extension CGImagePropertyOrientation {
    /// AVCaptureConnection.videoRotationAngle 과 같은 의미의 각도(시계 방향)를 EXIF 방향으로 변환.
    init(rotationAngle: CGFloat) {
        switch (Int(rotationAngle.rounded()) % 360 + 360) % 360 {
        case 90: self = .right
        case 180: self = .down
        case 270: self = .left
        default: self = .up
        }
    }
}

extension UIImage.Orientation {
    init(rotationAngle: CGFloat) {
        switch (Int(rotationAngle.rounded()) % 360 + 360) % 360 {
        case 90: self = .right
        case 180: self = .down
        case 270: self = .left
        default: self = .up
        }
    }
}

enum ZoomFormatter {
    static func text(_ value: CGFloat) -> String {
        let rounded = (value * 10).rounded() / 10
        let s: String
        if rounded == rounded.rounded() {
            s = String(format: "%.0f", Double(rounded))
        } else {
            s = String(format: "%.1f", Double(rounded))
        }
        return s + "×"
    }
}
