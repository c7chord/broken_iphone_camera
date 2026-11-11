import CoreGraphics
import Foundation
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

enum PhotoLibraryError: LocalizedError {
    case denied
    case unknown

    var errorDescription: String? {
        switch self {
        case .denied: return "사진 보관함 접근이 거부되었습니다. 설정 > 후면캠 > 사진에서 '사진 추가만 허용'을 켜 주세요."
        case .unknown: return "사진 보관함에 저장하지 못했습니다."
        }
    }
}

enum PhotoLibrary {
    static func requestAccess(_ completion: ((Bool) -> Void)? = nil) {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            completion?(true)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                completion?(status == .authorized || status == .limited)
            }
        default:
            completion?(false)
        }
    }

    static func savePhoto(data: Data, completion: @escaping (Error?) -> Void) {
        requestAccess { granted in
            guard granted else { completion(PhotoLibraryError.denied); return }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }, completionHandler: { success, error in
                completion(success ? nil : (error ?? PhotoLibraryError.unknown))
            })
        }
    }

    static func saveVideo(url: URL, completion: @escaping (Error?) -> Void) {
        requestAccess { granted in
            guard granted else {
                completion(PhotoLibraryError.denied)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: url, options: options)
            }, completionHandler: { success, error in
                if !success { try? FileManager.default.removeItem(at: url) }
                completion(success ? nil : (error ?? PhotoLibraryError.unknown))
            })
        }
    }
}

enum ImageEncoder {
    /// HEIF 로 먼저 시도하고, 실패하면 JPEG 로 인코딩한다.
    static func encode(_ image: CGImage, format: PhotoFileFormat, properties: [CFString: Any]) -> Data? {
        if format == .heic, let data = encode(image, type: .heic, properties: properties) {
            return data
        }
        return encode(image, type: .jpeg, properties: properties)
    }

    private static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func thumbnail(_ image: UIImage, maxSide: CGFloat = 200) -> UIImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = maxSide / max(size.width, size.height)
        return image.preparingThumbnail(of: CGSize(width: size.width * scale, height: size.height * scale))
    }

    static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()
}
