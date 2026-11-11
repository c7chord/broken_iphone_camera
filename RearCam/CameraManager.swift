import AVFoundation
import AudioToolbox
import CoreImage
import ImageIO
import SwiftUI
import UIKit

/// 고장 난 광각(1×) 카메라를 완전히 피해서 초광각(0.5×) 카메라만 쓰는 카메라 엔진.
///
/// - 후면은 `.builtInUltraWideCamera` 물리 카메라만 연결한다. (가상 듀얼 카메라를 쓰지 않으므로 광각 모듈을 깨우지 않음)
/// - 1×, 2× 는 초광각 카메라의 디지털 줌(2배, 4배)으로 만든다.
/// - 사진은 기본적으로 동영상 데이터 출력에서 프레임을 떠서 저장한다. (시스템 사진 처리 경로에서 생기는 무지개 왜곡 회피)
/// - 동영상은 같은 프레임을 AVAssetWriter 로 기록한다.
final class CameraManager: NSObject, ObservableObject {
    enum AuthState { case unknown, authorized, denied }

    // MARK: UI 상태 (메인 스레드 전용)

    @Published private(set) var authState: AuthState = .unknown
    @Published private(set) var isSessionRunning = false
    @Published private(set) var mode: CaptureMode = .photo
    @Published private(set) var position: CameraPosition = .back
    @Published private(set) var isRecording = false
    @Published private(set) var recordingSeconds = 0
    @Published private(set) var zoomDisplay: CGFloat = 1.0
    @Published private(set) var zoomDisplayRange: ClosedRange<CGFloat> = 0.5...5
    @Published private(set) var zoomMultiplier: CGFloat = 0.5
    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var torchOn = false
    @Published private(set) var lastThumbnail: UIImage?
    @Published private(set) var formatSummary = ""
    @Published private(set) var iconRotation: Angle = .zero
    @Published var alertMessage: String?

    // MARK: 설정 (UserDefaults 에 저장)

    @Published var photoMethod: PhotoMethod = PhotoMethod(rawValue: UserDefaults.standard.string(forKey: "photoMethod") ?? "") ?? .videoFrame {
        didSet {
            UserDefaults.standard.set(photoMethod.rawValue, forKey: "photoMethod")
            if oldValue != photoMethod { applyConfiguration() }
        }
    }

    @Published var photoFormat: PhotoFileFormat = PhotoFileFormat(rawValue: UserDefaults.standard.string(forKey: "photoFormat") ?? "") ?? .heic {
        didSet { UserDefaults.standard.set(photoFormat.rawValue, forKey: "photoFormat") }
    }

    @Published var videoQuality: VideoQuality = VideoQuality(rawValue: UserDefaults.standard.string(forKey: "videoQuality") ?? "") ?? .uhd30 {
        didSet {
            UserDefaults.standard.set(videoQuality.rawValue, forKey: "videoQuality")
            if oldValue != videoQuality, mode == .video { applyConfiguration() }
        }
    }

    @Published var stabilization: Bool = UserDefaults.standard.object(forKey: "stabilization") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(stabilization, forKey: "stabilization")
            if oldValue != stabilization, mode == .video { applyConfiguration() }
        }
    }

    @Published var showGrid: Bool = UserDefaults.standard.bool(forKey: "showGrid") {
        didSet { UserDefaults.standard.set(showGrid, forKey: "showGrid") }
    }

    @Published var shutterSound: Bool = UserDefaults.standard.object(forKey: "shutterSound") as? Bool ?? true {
        didSet { UserDefaults.standard.set(shutterSound, forKey: "shutterSound") }
    }

    @Published var photoAspect: PhotoAspect = PhotoAspect(rawValue: UserDefaults.standard.string(forKey: "photoAspect") ?? "") ?? .standard {
        didSet { UserDefaults.standard.set(photoAspect.rawValue, forKey: "photoAspect") }
    }

    func cycleAspect() {
        photoAspect = photoAspect.next
    }

    /// 세로 화면에서 미리보기의 (세로 / 가로) 비율
    var previewRatio: CGFloat {
        mode == .photo ? photoAspect.longShort : 16.0 / 9.0
    }

    // MARK: 세션 (sessionQueue 전용)

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "rearcam.session")
    private let dataQueue = DispatchQueue(label: "rearcam.data", qos: .userInitiated)
    private let processingQueue = DispatchQueue(label: "rearcam.processing", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var outputsPrepared = false

    // MARK: 데이터 (dataQueue 전용)

    private struct FrameCaptureRequest {
        let angle: CGFloat
        let format: PhotoFileFormat
        let aspect: PhotoAspect
    }

    private var pendingFrameCapture: FrameCaptureRequest?
    private var recorder: MovieRecorder?
    private var wantsRecording = false

    // MARK: 기타

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let orientationMonitor = OrientationMonitor()
    weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var desiredZoom: [CameraPosition: CGFloat] = [.back: 1.0, .front: 1.0]
    private var recordingTimer: Timer?
    private var recordingStart: Date?
    private var started = false
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        orientationMonitor.onChange = { [weak self] orientation in
            withAnimation(.easeInOut(duration: 0.25)) {
                self?.iconRotation = Self.uiRotation(for: orientation)
            }
        }
        addObservers()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - 수명 주기

    func start() {
        guard !started else { return }
        started = true
        orientationMonitor.start()

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authState = .authorized
            PhotoLibrary.requestAccess()
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.authState = granted ? .authorized : .denied
                    if granted {
                        PhotoLibrary.requestAccess()
                        self.startSession()
                    }
                }
            }
        default:
            authState = .denied
        }
    }

    func stop() {
        guard started else { return }
        started = false
        if isRecording { stopRecording() }
        orientationMonitor.stop()
        torchOn = false
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isSessionRunning = false }
        }
    }

    private func startSession() {
        applyConfiguration()
        sessionQueue.async {
            if !self.session.isRunning { self.session.startRunning() }
            let running = self.session.isRunning
            DispatchQueue.main.async { self.isSessionRunning = running }
        }
    }

    // MARK: - 구성

    private func applyConfiguration() {
        guard authState == .authorized else { return }
        let config = SessionConfig(
            position: position,
            mode: mode,
            quality: videoQuality,
            photoMethod: photoMethod,
            stabilization: stabilization,
            audio: mode == .video && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            zoomDisplay: desiredZoom[position] ?? 1
        )
        sessionQueue.async { self.configureSession(config) }
    }

    static func camera(for position: CameraPosition) -> AVCaptureDevice? {
        switch position {
        case .back:
            // 광각(1×)은 고장 → 초광각 물리 카메라만 사용. (초광각이 없는 기기에서만 광각으로 대체)
            return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        case .front:
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }
    }

    private func configureSession(_ c: SessionConfig) {
        if !outputsPrepared {
            videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
            videoOutput.alwaysDiscardsLateVideoFrames = false
            audioOutput.setSampleBufferDelegate(self, queue: dataQueue)
            outputsPrepared = true
        }

        guard let device = Self.camera(for: c.position) else {
            report("카메라를 찾을 수 없습니다.")
            return
        }

        session.beginConfiguration()
        if session.canSetSessionPreset(.inputPriority) {
            session.sessionPreset = .inputPriority
        }

        // 카메라 입력
        if videoInput?.device != device {
            if let old = videoInput {
                session.removeInput(old)
                videoInput = nil
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) {
                    session.addInput(input)
                    videoInput = input
                } else {
                    report("카메라 입력을 추가할 수 없습니다.")
                }
            } catch {
                report("카메라를 열 수 없습니다: \(error.localizedDescription)")
            }
        }

        // 마이크 입력 (동영상 모드에서만)
        if c.audio {
            if audioInput == nil,
               let mic = AVCaptureDevice.default(for: .audio),
               let input = try? AVCaptureDeviceInput(device: mic),
               session.canAddInput(input) {
                session.addInput(input)
                audioInput = input
            }
        } else if let input = audioInput {
            session.removeInput(input)
            audioInput = nil
        }

        // 출력
        if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        if audioInput != nil {
            if !session.outputs.contains(audioOutput), session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
            }
        } else if session.outputs.contains(audioOutput) {
            session.removeOutput(audioOutput)
        }
        let wantsPhotoOutput = c.mode == .photo && c.photoMethod == .systemPhoto
        if wantsPhotoOutput {
            if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
            }
        } else if session.outputs.contains(photoOutput) {
            session.removeOutput(photoOutput)
        }

        // 포맷 / 프레임레이트 / 노출 / 줌
        let format: AVCaptureDevice.Format?
        switch c.mode {
        case .photo: format = FormatPicker.photoFormat(for: device)
        case .video: format = FormatPicker.videoFormat(for: device, quality: c.quality)
        }

        let multiplier: CGFloat = device.deviceType == .builtInUltraWideCamera ? 0.5 : 1.0
        do {
            try device.lockForConfiguration()
            if let format { device.activeFormat = format }

            switch c.mode {
            case .photo:
                // 어두운 곳에서는 15fps 까지 내려가서 노출 시간을 확보 (노이즈 감소)
                Self.setFrameRate(device, minFPS: 15, maxFPS: 30)
            case .video:
                Self.setFrameRate(device, minFPS: c.quality.fps, maxFPS: c.quality.fps)
            }

            if device.activeFormat.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = false
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.setExposureTargetBias(0, completionHandler: nil)

            let factor = c.zoomDisplay / multiplier
            device.videoZoomFactor = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            device.unlockForConfiguration()
        } catch {
            report("카메라 설정 실패: \(error.localizedDescription)")
        }

        // 데이터 출력 픽셀 포맷 = 카메라 포맷 그대로 (변환 비용 없음)
        let subtype = FormatPicker.subtype(device.activeFormat)
        if videoOutput.availableVideoPixelFormatTypes.contains(subtype) {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: subtype]
        }
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = (c.mode == .video && c.stabilization) ? .standard : .off
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }

        session.commitConfiguration()

        if wantsPhotoOutput {
            let dims = device.activeFormat.supportedMaxPhotoDimensions
            if let largest = dims.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
                photoOutput.maxPhotoDimensions = largest
            }
        }

        // UI 갱신
        let maxFactor = min(device.maxAvailableVideoZoomFactor, 10)
        let minFactor = device.minAvailableVideoZoomFactor
        let range = (minFactor * multiplier)...(max(minFactor, maxFactor) * multiplier)
        let currentDisplay = device.videoZoomFactor * multiplier
        let summary = Self.summary(for: device)
        DispatchQueue.main.async {
            self.zoomMultiplier = multiplier
            self.zoomDisplayRange = range
            self.zoomDisplay = currentDisplay
            self.exposureBias = 0
            self.formatSummary = summary
            self.updatePreviewRotation()
        }
    }

    private static func setFrameRate(_ device: AVCaptureDevice, minFPS: Double, maxFPS: Double) {
        guard let range = device.activeFormat.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { return }
        let hi = min(maxFPS, range.maxFrameRate)
        let lo = max(min(minFPS, hi), range.minFrameRate)
        let minDuration = hi >= range.maxFrameRate - 0.01 ? range.minFrameDuration : CMTime(value: 1, timescale: CMTimeScale(hi.rounded()))
        let maxDuration = lo <= range.minFrameRate + 0.01 ? range.maxFrameDuration : CMTime(value: 1, timescale: CMTimeScale(lo.rounded()))
        device.activeVideoMinFrameDuration = minDuration
        device.activeVideoMaxFrameDuration = maxDuration
    }

    private static func summary(for device: AVCaptureDevice) -> String {
        let d = FormatPicker.dimensions(device.activeFormat)
        let fps = Int((1.0 / max(device.activeVideoMinFrameDuration.seconds, 0.001)).rounded())
        let name: String
        switch device.deviceType {
        case .builtInUltraWideCamera: name = "초광각"
        case .builtInWideAngleCamera: name = device.position == .front ? "전면" : "광각"
        default: name = device.localizedName
        }
        return "\(name) · \(d.width)×\(d.height) · \(fps)fps"
    }

    func updatePreviewRotation() {
        guard let connection = previewLayer?.connection else { return }
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }

    private static func uiRotation(for orientation: UIDeviceOrientation) -> Angle {
        switch orientation {
        case .landscapeLeft: return .degrees(90)
        case .landscapeRight: return .degrees(-90)
        case .portraitUpsideDown: return .degrees(180)
        default: return .zero
        }
    }

    // MARK: - 사용자 조작

    func setMode(_ newMode: CaptureMode) {
        guard !isRecording, newMode != mode else { return }
        mode = newMode
        applyConfiguration()
        if newMode == .video, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted, self.mode == .video { self.applyConfiguration() }
                }
            }
        }
    }

    func flipCamera() {
        guard !isRecording else { return }
        if torchOn { setTorch(on: false) }
        position = position == .back ? .front : .back
        zoomDisplay = desiredZoom[position] ?? 1
        applyConfiguration()
    }

    var zoomPresets: [CGFloat] {
        if position == .back && zoomMultiplier < 1 {
            return [0.5, 1]
        }
        return [1, 2]
    }

    var activeZoomPreset: CGFloat {
        zoomPresets.last(where: { $0 <= zoomDisplay + 0.01 }) ?? zoomPresets[0]
    }

    func setZoom(display: CGFloat, animated: Bool) {
        let clamped = min(max(display, zoomDisplayRange.lowerBound), zoomDisplayRange.upperBound)
        zoomDisplay = clamped
        desiredZoom[position] = clamped
        let factor = clamped / zoomMultiplier
        sessionQueue.async {
            guard let device = self.videoInput?.device else { return }
            do {
                try device.lockForConfiguration()
                let f = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
                if animated {
                    device.ramp(toVideoZoomFactor: f, withRate: 6)
                } else {
                    if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
                    device.videoZoomFactor = f
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func focusAndExpose(atLayerPoint layerPoint: CGPoint) {
        guard let layer = previewLayer else { return }
        let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        exposureBias = 0
        sessionQueue.async {
            self.setPointOfInterest(devicePoint, monitorSubjectChange: true)
        }
    }

    private func setPointOfInterest(_ point: CGPoint, monitorSubjectChange: Bool) {
        guard let device = videoInput?.device else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusPointOfInterest = point
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposurePointOfInterest = point
                device.exposureMode = .continuousAutoExposure
            }
            device.setExposureTargetBias(0, completionHandler: nil)
            device.isSubjectAreaChangeMonitoringEnabled = monitorSubjectChange
            device.unlockForConfiguration()
        } catch {}
    }

    func setExposureBias(_ value: Float) {
        let v = min(max(value, -2), 2)
        exposureBias = v
        sessionQueue.async {
            guard let device = self.videoInput?.device else { return }
            do {
                try device.lockForConfiguration()
                let clamped = min(max(v, device.minExposureTargetBias), device.maxExposureTargetBias)
                device.setExposureTargetBias(clamped, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func toggleTorch() {
        setTorch(on: !torchOn)
    }

    private func setTorch(on: Bool) {
        sessionQueue.async {
            let candidates = [
                self.videoInput?.device,
                AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            ]
            guard let device = candidates.compactMap({ $0 }).first(where: { $0.position == .back && $0.hasTorch }) else {
                if on { self.report("손전등을 찾을 수 없습니다.") }
                return
            }
            do {
                try device.lockForConfiguration()
                if on {
                    try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
                } else {
                    device.torchMode = .off
                }
                device.unlockForConfiguration()
                let isOn = device.torchMode == .on
                DispatchQueue.main.async { self.torchOn = isOn }
                if on && !isOn { self.report("손전등을 켤 수 없습니다. (하드웨어 고장일 수 있습니다)") }
            } catch {
                DispatchQueue.main.async { self.torchOn = false }
                if on { self.report("손전등을 켤 수 없습니다: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: - 사진

    func capturePhoto() {
        guard mode == .photo, isSessionRunning else { return }
        let angle = orientationMonitor.captureAngle(for: position)
        let format = photoFormat
        let aspect = photoAspect
        if shutterSound { AudioServicesPlaySystemSound(1108) }

        switch photoMethod {
        case .videoFrame:
            dataQueue.async {
                self.pendingFrameCapture = FrameCaptureRequest(angle: angle, format: format, aspect: aspect)
            }
        case .systemPhoto:
            sessionQueue.async { self.captureSystemPhoto(angle: angle, format: format) }
        }
    }

    private func saveFrame(_ pixelBuffer: CVPixelBuffer, attachments: [String: Any]?, request: FrameCaptureRequest) {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let cropRect = request.aspect.centerCrop(image.extent)
        guard let cgImage = ciContext.createCGImage(image, from: cropRect) else {
            report("프레임을 이미지로 변환하지 못했습니다.")
            return
        }

        let orientation = CGImagePropertyOrientation(rotationAngle: request.angle)
        let now = Date()
        let dateString = ImageEncoder.exifDateFormatter.string(from: now)

        var exif = (attachments?[kCGImagePropertyExifDictionary as String] as? [String: Any]) ?? [:]
        exif[kCGImagePropertyExifDateTimeOriginal as String] = dateString
        exif[kCGImagePropertyExifDateTimeDigitized as String] = dateString
        exif[kCGImagePropertyExifPixelXDimension as String] = cgImage.width
        exif[kCGImagePropertyExifPixelYDimension as String] = cgImage.height

        let tiff: [String: Any] = [
            kCGImagePropertyTIFFMake as String: "Apple",
            kCGImagePropertyTIFFModel as String: Self.hardwareModel(),
            kCGImagePropertyTIFFSoftware as String: "RearCam",
            kCGImagePropertyTIFFDateTime as String: dateString,
        ]

        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation.rawValue,
            kCGImageDestinationLossyCompressionQuality: 0.92,
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff,
        ]

        guard let data = ImageEncoder.encode(cgImage, format: request.format, properties: properties) else {
            report("사진 인코딩에 실패했습니다.")
            return
        }

        let preview = UIImage(cgImage: cgImage, scale: 1, orientation: UIImage.Orientation(rotationAngle: request.angle))
        let thumb = ImageEncoder.thumbnail(preview)
        DispatchQueue.main.async { self.lastThumbnail = thumb }

        PhotoLibrary.savePhoto(data: data) { error in
            if let error { self.report(error.localizedDescription) }
        }
    }

    private func captureSystemPhoto(angle: CGFloat, format: PhotoFileFormat) {
        guard session.outputs.contains(photoOutput) else {
            report("시스템 사진 출력이 준비되지 않았습니다.")
            return
        }
        let settings: AVCapturePhotoSettings
        if format == .heic, photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        }
        // 다중 프레임 합성(Deep Fusion 등)을 최소화
        settings.photoQualityPrioritization = .speed
        if photoOutput.supportedFlashModes.contains(.off) {
            settings.flashMode = .off
        }
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        if let connection = photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - 동영상

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard mode == .video, isSessionRunning, !isRecording else { return }
        let angle = orientationMonitor.captureAngle(for: position)
        if shutterSound { AudioServicesPlaySystemSound(1117) }

        isRecording = true
        recordingSeconds = 0
        recordingStart = Date()
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStart else { return }
            self.recordingSeconds = Int(Date().timeIntervalSince(start))
        }
        UIApplication.shared.isIdleTimerDisabled = true

        dataQueue.async { self.wantsRecording = true }

        sessionQueue.async {
            let codecs = self.videoOutput.availableVideoCodecTypesForAssetWriter(writingTo: .mov)
            let codec: AVVideoCodecType = codecs.contains(.hevc) ? .hevc : .h264
            var videoSettings = self.videoOutput.recommendedVideoSettings(forVideoCodecType: codec, assetWriterOutputFileType: .mov)
            if videoSettings == nil, let device = self.videoInput?.device {
                let d = FormatPicker.dimensions(device.activeFormat)
                videoSettings = [
                    AVVideoCodecKey: codec,
                    AVVideoWidthKey: Int(d.width),
                    AVVideoHeightKey: Int(d.height),
                ]
            }
            var audioSettings: [String: Any]?
            if self.session.outputs.contains(self.audioOutput) {
                audioSettings = self.audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any]
            }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("RearCam-\(UUID().uuidString)")
                .appendingPathExtension("mov")

            guard let videoSettings else {
                self.recordingFailed("동영상 설정을 만들 수 없습니다.")
                return
            }

            do {
                let recorder = try MovieRecorder(url: url, videoSettings: videoSettings, audioSettings: audioSettings, rotationAngle: angle)
                self.dataQueue.async {
                    if self.wantsRecording {
                        self.recorder = recorder
                    } else {
                        recorder.cancel()
                    }
                }
            } catch {
                self.recordingFailed("녹화를 시작할 수 없습니다: \(error.localizedDescription)")
            }
        }
    }

    private func recordingFailed(_ message: String) {
        dataQueue.async { self.wantsRecording = false }
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil
            UIApplication.shared.isIdleTimerDisabled = false
            self.alertMessage = message
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        if shutterSound { AudioServicesPlaySystemSound(1118) }

        dataQueue.async {
            self.wantsRecording = false
            guard let recorder = self.recorder else { return }
            self.recorder = nil
            recorder.finish { result in
                switch result {
                case .success(let url):
                    self.finishSavingVideo(url)
                case .failure(let error):
                    self.report("녹화 저장 실패: \(error.localizedDescription)")
                }
            }
        }
    }

    private func finishSavingVideo(_ url: URL) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 300, height: 300)
        generator.generateCGImageAsynchronously(for: .zero) { cgImage, _, _ in
            if let cgImage {
                let image = UIImage(cgImage: cgImage)
                DispatchQueue.main.async { self.lastThumbnail = image }
            }
            PhotoLibrary.saveVideo(url: url) { error in
                if let error { self.report(error.localizedDescription) }
            }
        }
    }

    // MARK: - 알림

    private func addObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            guard let self else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            if self.isRecording { self.stopRecording() }
            if self.started {
                self.sessionQueue.async {
                    self.session.startRunning()
                    let running = self.session.isRunning
                    DispatchQueue.main.async {
                        self.isSessionRunning = running
                        if !running {
                            self.alertMessage = "카메라 오류: \(error?.localizedDescription ?? "알 수 없음")"
                        }
                    }
                }
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.isRecording { self.stopRecording() }
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async {
                self.setPointOfInterest(CGPoint(x: 0.5, y: 0.5), monitorSubjectChange: false)
            }
        })
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { self.alertMessage = message }
    }

    // MARK: - 진단

    static func hardwareModel() -> String {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        return mirror.children.reduce(into: "") { result, element in
            if let value = element.value as? Int8, value != 0 {
                result.append(Character(UnicodeScalar(UInt8(value))))
            }
        }
    }

    func diagnostics(_ completion: @escaping (String) -> Void) {
        let systemVersion = UIDevice.current.systemVersion
        sessionQueue.async {
            var lines: [String] = []
            lines.append("기기: \(Self.hardwareModel())  iOS \(systemVersion)")
            let types: [AVCaptureDevice.DeviceType] = [
                .builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera,
                .builtInDualWideCamera, .builtInDualCamera, .builtInTripleCamera,
            ]
            let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
            lines.append("")
            lines.append("[카메라 목록]")
            for d in discovery.devices {
                let pos = d.position == .back ? "후면" : (d.position == .front ? "전면" : "?")
                lines.append("• \(d.localizedName) (\(pos)) 연결=\(d.isConnected) 중단=\(d.isSuspended) 손전등=\(d.hasTorch)")
            }
            if let d = self.videoInput?.device {
                let dims = FormatPicker.dimensions(d.activeFormat)
                lines.append("")
                lines.append("[사용 중]")
                lines.append("카메라: \(d.localizedName)")
                lines.append("포맷: \(dims.width)×\(dims.height)  최대 \(Int(FormatPicker.maxFrameRate(d.activeFormat)))fps  binned=\(d.activeFormat.isVideoBinned)")
                lines.append("줌: \(String(format: "%.2f", Double(d.videoZoomFactor))) (최대 \(String(format: "%.1f", Double(d.maxAvailableVideoZoomFactor))))")
                lines.append("ISO: \(Int(d.iso))  셔터: 1/\(Int((1 / max(d.exposureDuration.seconds, 0.0001)).rounded()))")
                lines.append("초점 고정: \(!d.isFocusModeSupported(.continuousAutoFocus))")
                let photoDims = d.activeFormat.supportedMaxPhotoDimensions.map { "\($0.width)×\($0.height)" }.joined(separator: ", ")
                lines.append("사진 최대 크기: \(photoDims)")
                let all = d.formats.filter { FormatPicker.is8Bit420($0) }.map { f -> String in
                    let fd = FormatPicker.dimensions(f)
                    return "\(fd.width)×\(fd.height)@\(Int(FormatPicker.maxFrameRate(f)))"
                }
                var seen = Set<String>()
                let unique = all.filter { seen.insert($0).inserted }
                lines.append("지원 포맷: " + unique.joined(separator: ", "))
            }
            let text = lines.joined(separator: "\n")
            DispatchQueue.main.async { completion(text) }
        }
    }
}

// MARK: - 샘플 버퍼

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            if let request = pendingFrameCapture, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                pendingFrameCapture = nil
                var attachments: [String: Any]?
                if let raw = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault, target: sampleBuffer, attachmentMode: CMAttachmentMode(kCMAttachmentMode_ShouldPropagate)) {
                    attachments = (raw as NSDictionary) as? [String: Any]
                }
                processingQueue.async {
                    self.saveFrame(pixelBuffer, attachments: attachments, request: request)
                }
            }
            recorder?.appendVideo(sampleBuffer)
        } else if output === audioOutput {
            recorder?.appendAudio(sampleBuffer)
        }
    }
}

// MARK: - 시스템 사진

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            report("사진 촬영 실패: \(error.localizedDescription)")
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            report("사진 데이터를 만들지 못했습니다.")
            return
        }
        if let image = UIImage(data: data) {
            let thumb = ImageEncoder.thumbnail(image)
            DispatchQueue.main.async { self.lastThumbnail = thumb }
        }
        PhotoLibrary.savePhoto(data: data) { error in
            if let error { self.report(error.localizedDescription) }
        }
    }
}
