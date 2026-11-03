import SwiftUI
import UIKit

/// 初めての許可の画面（#66）。先生が理由を話し、「いいよ」でシステムのダイアログを出す
struct PermissionOnboardingView: View {
    let onboarding: PermissionOnboarding
    let lipSync: LipSyncPlayer

    var body: some View {
        GeometryReader { geometry in
            let isWide = geometry.size.width > geometry.size.height
            let layout = isWide ? AnyLayout(HStackLayout(spacing: 32)) : AnyLayout(VStackLayout(spacing: 24))
            layout {
                AvatarView(state: .talking, lipSync: lipSync)
                    .background(
                        RoundedRectangle(cornerRadius: 28)
                            .fill(LinearGradient(
                                colors: [Color(red: 0.86, green: 0.93, blue: 1.0), Color(red: 0.98, green: 0.96, blue: 0.90)],
                                startPoint: .top, endPoint: .bottom
                            ))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 28))
                    .frame(width: isWide ? geometry.size.width * 0.42 : nil)
                    .frame(height: isWide ? nil : geometry.size.height * 0.45)
                VStack(spacing: 28) {
                    if let permission = onboarding.current {
                        Label(Self.title(permission), systemImage: Self.symbol(permission))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text(PermissionOnboarding.explanation(for: permission))
                            .font(.system(size: 26, weight: .medium, design: .rounded))
                            .multilineTextAlignment(.leading)
                            .padding(24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white, in: RoundedRectangle(cornerRadius: 24))
                        Button {
                            onboarding.proceed()
                        } label: {
                            Text("いいよ")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: 420, minHeight: 84)
                                .background(Capsule().fill(.orange))
                        }
                        .buttonStyle(.plain)
                        Text("このあと出てくる画面で「許可」を押してね")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView("準備中…").font(.title2)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(32)
        }
        .background(Color(red: 0.97, green: 0.95, blue: 0.90).ignoresSafeArea())
    }

    static func title(_ permission: AppPermission) -> String {
        switch permission {
        case .microphone: "マイク"
        case .speech: "音声認識"
        case .camera: "カメラ"
        }
    }

    static func symbol(_ permission: AppPermission) -> String {
        switch permission {
        case .microphone: "mic.fill"
        case .speech: "text.bubble.fill"
        case .camera: "camera.fill"
        }
    }
}

/// 保護者向けの案内（許可が拒否されている・Worker につながらない）。画面の上に小さく出す
struct ParentNoticeBanner: View {
    let message: String
    /// 設定アプリを開くボタンを出すか（許可のとき）
    var opensSettings = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("保護者の方へ")
                    .font(.subheadline.bold())
                Text(message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if opensSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                Button("設定アプリを開く") { UIApplication.shared.open(url) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}
