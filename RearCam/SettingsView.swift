import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var camera: CameraManager
    @Environment(\.dismiss) private var dismiss
    @State private var diagnostics = "불러오는 중…"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("사진 방식", selection: $camera.photoMethod) {
                        ForEach(PhotoMethod.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }
                    Text(camera.photoMethod.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Picker("파일 형식", selection: $camera.photoFormat) {
                        ForEach(PhotoFileFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                } header: {
                    Text("사진")
                }

                Section {
                    Picker("화질", selection: $camera.videoQuality) {
                        ForEach(VideoQuality.allCases) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                    Toggle("손떨림 보정", isOn: $camera.stabilization)
                } header: {
                    Text("동영상")
                }

                Section {
                    Toggle("격자", isOn: $camera.showGrid)
                    Toggle("셔터음", isOn: $camera.shutterSound)
                } header: {
                    Text("화면 · 소리")
                }

                Section {
                    Text("• 후면은 초광각(0.5×) 카메라만 사용합니다. 고장 난 광각(1×) 카메라는 전혀 건드리지 않습니다.\n• 1×, 2× 는 초광각 카메라를 디지털로 확대한 것이라 원래 1× 카메라보다 디테일이 떨어집니다.\n• 화면을 탭하면 그 위치로 노출을 맞추고, 위아래로 끌면 밝기를 조절합니다. 두 손가락으로 확대/축소할 수 있습니다.\n• 초광각 카메라는 초점이 고정되어 있어서 아주 가까운(약 10cm 이내) 피사체는 흐릴 수 있습니다.")
                        .font(.footnote)
                } header: {
                    Text("도움말")
                }

                Section {
                    Text(diagnostics)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                    Button("진단 정보 복사") {
                        UIPasteboard.general.string = diagnostics
                    }
                } header: {
                    Text("진단 정보")
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
        .onAppear {
            camera.diagnostics { diagnostics = $0 }
        }
    }
}
