import SwiftUI

/// First-run onboarding sheet. Auto-probes the machine for existing credentials
/// and imports them in one tap, then asks for the few values that can't be
/// auto-discovered (Issuer ID, Match password).
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var summary = OnboardingService.ImportSummary()
    @State private var issuerID = KeychainStore.get(.ascIssuerID) ?? ""
    @State private var matchPassword = KeychainStore.get(.matchPassword) ?? ""
    @State private var didImport = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                Text("配置凭据").font(.title.bold())
                Text("首次运行需配置 Apple 发布凭据。已自动探测本机现有凭据,补齐缺失项即可。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(.top, 28)
            .padding(.bottom, 20)

            Divider()

            // Content
            Form {
                Section("自动探测") {
                    if didImport {
                        if summary.imported.isEmpty {
                            Text("未探测到可自动导入的凭据")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(summary.imported, id: \.self) { item in
                            Label(item, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    } else {
                        Button {
                            importNow()
                        } label: {
                            Label("一键导入本机凭据", systemImage: "wand.and.stars")
                        }
                    }
                }

                Section {
                    TextField("Issuer ID", text: $issuerID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .placeholder(when: issuerID.isEmpty) {
                            Text("00000000-0000-0000-0000-000000000000").foregroundStyle(.tertiary)
                        }
                    Text("在 App Store Connect → 用户和访问 → 密钥 页面查看")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Label("Issuer ID(需手动填写)", systemImage: "person.badge.key")
                }

                Section {
                    SecureField("Match 仓库加密密码", text: $matchPassword)
                        .textFieldStyle(.roundedBorder)
                    if let url = KeychainStore.get(.matchGitURL) {
                        Text("仓库:\(url)").font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Label("Match 密码(需手动填写)", systemImage: "lock")
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer
            HStack {
                if !summary.missing.isEmpty {
                    Label("\(summary.missing.count) 项待补齐", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("稍后") { dismiss() }
                Button("完成") {
                    saveManual()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(issuerID.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 540, height: 560)
    }

    private func importNow() {
        summary = OnboardingService.autoImport()
        didImport = true
    }

    private func saveManual() {
        if !issuerID.isEmpty {
            KeychainStore.set(issuerID, for: .ascIssuerID)
        }
        if !matchPassword.isEmpty {
            KeychainStore.set(matchPassword, for: .matchPassword)
        }
    }
}

private extension View {
    /// Shows a placeholder overlay when `condition` is true (field is empty).
    func placeholder<Content: View>(when shouldShow: Bool,
                                    alignment: Alignment = .leading,
                                    @ViewBuilder placeholder: () -> Content) -> some View {
        ZStack(alignment: alignment) {
            placeholder().opacity(shouldShow ? 1 : 0)
            self
        }
    }
}
