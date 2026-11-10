import AVFoundation

/// AVAssetWriter 로 동영상 데이터 출력의 프레임을 그대로 .mov 파일에 기록한다.
/// 모든 메서드는 같은 직렬 큐(dataQueue)에서 호출해야 한다.
final class MovieRecorder {
    enum RecorderError: LocalizedError {
        case cannotAddVideoInput
        case noFrames
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .cannotAddVideoInput: return "동영상 기록기를 준비하지 못했습니다."
            case .noFrames: return "녹화된 프레임이 없습니다."
            case .writeFailed: return "동영상 파일을 쓰지 못했습니다."
            }
        }
    }

    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private var sessionStartTime: CMTime?
    private var finished = false

    init(url: URL, videoSettings: [String: Any], audioSettings: [String: Any]?, rotationAngle: CGFloat) throws {
        try? FileManager.default.removeItem(at: url)
        let assetWriter = try AVAssetWriter(outputURL: url, fileType: .mov)

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        video.transform = CGAffineTransform(rotationAngle: rotationAngle * .pi / 180)
        guard assetWriter.canAdd(video) else { throw RecorderError.cannotAddVideoInput }
        assetWriter.add(video)

        var audio: AVAssetWriterInput?
        if let audioSettings {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if assetWriter.canAdd(input) {
                assetWriter.add(input)
                audio = input
            }
        }

        self.url = url
        self.writer = assetWriter
        self.videoInput = video
        self.audioInput = audio
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard !finished else { return }
        if sessionStartTime == nil {
            guard writer.status == .unknown, writer.startWriting() else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: pts)
            sessionStartTime = pts
        }
        guard writer.status == .writing, videoInput.isReadyForMoreMediaData else { return }
        videoInput.append(sampleBuffer)
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard !finished,
              let start = sessionStartTime,
              let audioInput,
              writer.status == .writing,
              audioInput.isReadyForMoreMediaData
        else { return }
        guard CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), start) >= 0 else { return }
        audioInput.append(sampleBuffer)
    }

    func finish(_ completion: @escaping (Result<URL, Error>) -> Void) {
        guard !finished else { return }
        finished = true

        guard sessionStartTime != nil, writer.status == .writing else {
            let error = writer.error
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: url)
            completion(.failure(error ?? RecorderError.noFrames))
            return
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        let writer = self.writer
        let url = self.url
        writer.finishWriting {
            if writer.status == .completed {
                completion(.success(url))
            } else {
                try? FileManager.default.removeItem(at: url)
                completion(.failure(writer.error ?? RecorderError.writeFailed))
            }
        }
    }

    func cancel() {
        finished = true
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }
}
