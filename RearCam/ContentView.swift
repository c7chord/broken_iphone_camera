import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSettings = false
    @State private var shutterFlash = false
    @State private var focusPoint: CGPoint?
    @State private var focusToken = UUID()
    @State private var pinchStart: CGFloat?
    @State private var biasStart: Float?
    @State private var showBias = false
    @State private var biasToken = UUID()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.authState == .denied {
                PermissionDeniedView()
            } else {
                cameraUI
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { camera.start() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: camera.start()
            case .background: camera.stop()
            default: break
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(camera: camera)
        }
        .alert(
            "알림",
            isPresented: Binding(
                get: { camera.alertMessage != nil },
                set: { if !$0 { camera.alertMessage = nil } }
            )
        ) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(camera.alertMessage ?? "")
        }
    }

    // MARK: - 레이아웃

    private var cameraUI: some View {
        VStack(spacing: 0) {
            topBar
                .frame(height: 50)

            GeometryReader { geo in
                let aspect: CGFloat = camera.mode == .photo ? 4.0 / 3.0 : 16.0 / 9.0
                let height = min(geo.size.width * aspect, geo.size.height)
                let width = height / aspect
                previewArea
                    .frame(width: width, height: height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            zoomBar
                .padding(.vertical, 10)

            modePicker
                .padding(.bottom, 14)

            bottomBar
                .padding(.bottom, 16)
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                camera.toggleTorch()
            } label: {
                Image(systemName: camera.torchOn ? "bolt.fill" : "bolt.slash.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(camera.torchOn ? .yellow : .white)
                    .frame(width: 44, height: 44)
                    .rotationEffect(camera.iconRotation)
            }
            .disabled(camera.position == .front)
            .opacity(camera.position == .front ? 0.3 : 1)

            Spacer()

            if camera.isRecording {
                Text(timeString(camera.recordingSeconds))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.red))
            } else {
                Text(camera.formatSummary)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(.white.opacity(0.55))
            }

            Spacer()

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .rotationEffect(camera.iconRotation)
            }
            .disabled(camera.isRecording)
            .opacity(camera.isRecording ? 0.3 : 1)
        }
        .padding(.horizontal, 14)
    }

    private var previewArea: some View {
        ZStack {
            CameraPreview(camera: camera)

            if camera.showGrid {
                GridOverlay()
            }

            if let point = focusPoint {
                FocusSquare()
                    .position(point)
                    .allowsHitTesting(false)
            }

            if showBias || camera.exposureBias != 0 {
                VStack {
                    HStack(spacing: 4) {
                        Image(systemName: "sun.max.fill")
                        Text(String(format: "%+.1f", Double(camera.exposureBias)))
                            .monospacedDigit()
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.yellow)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.5)))
                    .padding(.top, 10)
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            if shutterFlash {
                Color.black
                    .allowsHitTesting(false)
            }

            if !camera.isSessionRunning && camera.authState == .authorized {
                ProgressView()
                    .tint(.white)
            }
        }
        .contentShape(Rectangle())
        .gesture(pinchGesture.simultaneously(with: dragGesture))
        .simultaneousGesture(tapGesture)
        .clipped()
    }

    private var zoomBar: some View {
        HStack(spacing: 8) {
            ForEach(camera.zoomPresets, id: \.self) { preset in
                let active = camera.activeZoomPreset == preset
                Button {
                    camera.setZoom(display: preset, animated: true)
                } label: {
                    Text(ZoomFormatter.text(active ? camera.zoomDisplay : preset))
                        .font(.system(size: active ? 13 : 11, weight: .bold))
                        .foregroundColor(active ? .yellow : .white)
                        .frame(width: active ? 42 : 34, height: active ? 42 : 34)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                        .rotationEffect(camera.iconRotation)
                }
            }
        }
        .padding(5)
        .background(Capsule().fill(Color.white.opacity(0.1)))
        .animation(.easeOut(duration: 0.15), value: camera.activeZoomPreset)
    }

    private var modePicker: some View {
        HStack(spacing: 32) {
            ForEach(CaptureMode.allCases) { mode in
                Button {
                    camera.setMode(mode)
                } label: {
                    Text(mode.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(camera.mode == mode ? .yellow : .white.opacity(0.75))
                }
                .disabled(camera.isRecording)
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            Button {
                if let url = URL(string: "photos-redirect://") {
                    UIApplication.shared.open(url)
                }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.12))
                    if let image = camera.lastThumbnail {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.6), lineWidth: 1))
                .rotationEffect(camera.iconRotation)
            }
            .disabled(camera.isRecording)

            Spacer()

            ShutterButton(mode: camera.mode, isRecording: camera.isRecording) {
                shutterTapped()
            }

            Spacer()

            Button {
                camera.flipCamera()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .rotationEffect(camera.iconRotation)
            }
            .disabled(camera.isRecording)
            .opacity(camera.isRecording ? 0.3 : 1)
        }
        .padding(.horizontal, 28)
    }

    // MARK: - 동작

    private func shutterTapped() {
        switch camera.mode {
        case .photo:
            camera.capturePhoto()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            shutterFlash = true
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                shutterFlash = false
            }
        case .video:
            camera.toggleRecording()
        }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchStart == nil { pinchStart = camera.zoomDisplay }
                camera.setZoom(display: (pinchStart ?? 1) * value.magnification, animated: false)
            }
            .onEnded { _ in
                pinchStart = nil
            }
    }

    /// 위/아래로 끌어서 노출 보정
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard pinchStart == nil else { return }
                if biasStart == nil { biasStart = camera.exposureBias }
                showBias = true
                camera.setExposureBias((biasStart ?? 0) - Float(value.translation.height / 120))
            }
            .onEnded { _ in
                biasStart = nil
                let token = UUID()
                biasToken = token
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if biasToken == token { showBias = false }
                }
            }
    }

    private var tapGesture: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                focusPoint = value.location
                camera.focusAndExpose(atLayerPoint: value.location)
                let token = UUID()
                focusToken = token
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if focusToken == token {
                        withAnimation { focusPoint = nil }
                    }
                }
            }
    }

    private func timeString(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - 구성 요소

struct ShutterButton: View {
    let mode: CaptureMode
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 76, height: 76)
                if mode == .photo {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 62, height: 62)
                } else {
                    RoundedRectangle(cornerRadius: isRecording ? 6 : 31)
                        .fill(Color.red)
                        .frame(width: isRecording ? 30 : 62, height: isRecording ? 30 : 62)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isRecording)
        }
        .buttonStyle(ShutterPressStyle())
    }
}

struct ShutterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height
                for i in 1...2 {
                    let x = w * CGFloat(i) / 3
                    let y = h * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

struct FocusSquare: View {
    @State private var appeared = false

    var body: some View {
        Rectangle()
            .stroke(Color.yellow, lineWidth: 1.5)
            .frame(width: 72, height: 72)
            .scaleEffect(appeared ? 1 : 1.3)
            .onAppear {
                withAnimation(.easeOut(duration: 0.2)) { appeared = true }
            }
    }
}

struct PermissionDeniedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 44))
                .foregroundColor(.white.opacity(0.8))
            Text("카메라 접근 권한이 필요합니다")
                .font(.headline)
                .foregroundColor(.white)
            Text("설정 > 후면캠 > 카메라를 켜 주세요.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
            Button("설정 열기") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
