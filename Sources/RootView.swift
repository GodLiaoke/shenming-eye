import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ZStack {
                PhoenixBackground()
                VStack(spacing: 22) {
                    PhoenixMark(size: 82)
                    ProgressView().tint(PhoenixTheme.cyan)
                    Text(model.recoveryMessage ?? "正在校验授权…")
                        .font(PhoenixType.captionStrong)
                        .foregroundStyle(.secondary)
                }
            }
        case .activation:
            LicenseView()
        case .ready:
            if let grant = model.grant {
                RadarContainerView(grant: grant)
            } else {
                LicenseView()
            }
        }
    }
}
