import SwiftUI
import UniformTypeIdentifiers

/// First-run onboarding sheet. Auto-probes the machine for existing credentials
/// and imports them in one tap, then asks for the few values that can't be
/// auto-discovered (Issuer ID, Match password).
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var catalog: ProjectCatalog

    @State private var summary = OnboardingService.ImportSummary()
    @State private var issuerID = KeychainStore.get(.ascIssuerID) ?? ""
    @State private var keyID = KeychainStore.get(.ascAPIKeyID) ?? ""
    @State private var teamID = KeychainStore.get(.appleTeamID) ?? ""
    @State private var matchPassword = KeychainStore.get(.matchPassword) ?? ""
    @State private var didImport = false
    @State private var validating = false
    @State private var validationResults: [CredentialValidationResult] = []
    @State private var showKeyImporter = false
    @State private var importError: String?

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
                    Button {
                        showKeyImporter = true
                    } label: {
                        Label("选择 AuthKey_*.p8", systemImage: "doc.badge.plus")
                    }
                    TextField("Key ID（10 位）", text: $keyID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    TextField("Issuer ID", text: $issuerID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .placeholder(when: issuerID.isEmpty) {
                            Text("00000000-0000-0000-0000-000000000000").foregroundStyle(.tertiary)
                        }
                    Text("在 App Store Connect → 用户和访问 → 集成 → 密钥 页面下载并查看")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Label("App Store Connect API Key", systemImage: "person.badge.key")
                }

                Section("Apple Developer") {
                    TextField("Team ID（10 位）", text: $teamID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text("可在 Apple Developer → Membership details 查看")
                        .font(.caption).foregroundStyle(.secondary)
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

                if !validationResults.isEmpty {
                    Section("有效性检查") {
                        ForEach(validationResults) { result in
                            VStack(alignment: .leading, spacing: 2) {
                                Label(result.title, systemImage: result.status == .passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(result.status == .passed ? .green : .red)
                                Text(result.detail).font(.caption).foregroundStyle(.secondary)
                                if let guidance = result.guidance { Text(guidance).font(.caption).foregroundStyle(.orange) }
                            }
                        }
                    }
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
                Button(validating ? "验证中…" : "验证并完成") { validateAndFinish() }
                .buttonStyle(.borderedProminent)
                .disabled(issuerID.isEmpty || keyID.isEmpty || teamID.isEmpty || validating)
            }
            .padding(16)
        }
        .frame(width: 560, height: 680)
        .fileImporter(isPresented: $showKeyImporter, allowedContentTypes: [.data]) { result in
            importAPIKey(result)
        }
        .alert("无法导入 API Key", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } })) {
            Button("好", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private func importNow() {
        summary = OnboardingService.autoImport()
        keyID = KeychainStore.get(.ascAPIKeyID) ?? keyID
        teamID = KeychainStore.get(.appleTeamID) ?? teamID
        didImport = true
    }

    private func saveManual() {
        if !issuerID.isEmpty {
            KeychainStore.set(issuerID, for: .ascIssuerID)
        }
        if !keyID.isEmpty { KeychainStore.set(keyID, for: .ascAPIKeyID) }
        if !teamID.isEmpty { KeychainStore.set(teamID, for: .appleTeamID) }
        if !matchPassword.isEmpty {
            KeychainStore.set(matchPassword, for: .matchPassword)
        }
    }

    private func importAPIKey(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            importError = "无法读取所选文件"
            return
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        // Surface an invalid selection instead of failing silently — picking the
        // wrong file previously did nothing visible (unlike SettingsView).
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            importError = "无法读取文件内容"
            return
        }
        guard content.contains("BEGIN PRIVATE KEY") else {
            importError = "所选文件不是有效的私钥（缺少 BEGIN PRIVATE KEY）。请选择 App Store Connect 下载的 AuthKey_XXXXXXXXXX.p8。"
            return
        }
        KeychainStore.set(content, for: .ascAPIKeyContent)
        let name = url.deletingPathExtension().lastPathComponent
        if name.hasPrefix("AuthKey_") { keyID = String(name.dropFirst("AuthKey_".count)) }
    }

    private func validateAndFinish() {
        saveManual()
        validating = true
        Task {
            let results = await CredentialValidationService.validate(catalog: catalog.data)
            validationResults = results
            validating = false
            if !results.contains(where: { $0.status == .failed }) { dismiss() }
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
