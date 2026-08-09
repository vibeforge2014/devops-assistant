import SwiftUI
import UniformTypeIdentifiers

/// 凭证管理视图。编辑先停留在页面草稿中，用户确认后才批量写入 macOS 钥匙串，
/// 避免输入过程中反复访问钥匙串或保存半截凭证。
struct SettingsView: View {
    @EnvironmentObject private var catalog: ProjectCatalog
    @State private var values: [Credential: String] = [:]
    @State private var savedValues: [Credential: String] = [:]
    @State private var revealedCredentials: Set<Credential> = []
    @State private var validationResults: [CredentialValidationResult] = []
    @State private var validating = false
    @State private var showKeyImporter = false
    @State private var showClearConfirmation = false
    @State private var feedback: Feedback?
    @State private var importError: String?

    private var hasUnsavedChanges: Bool { values != savedValues }

    private var configuredCount: Int {
        Credential.allCases.filter { credential in
            !(values[credential] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                overview

                if let feedback {
                    feedbackBanner(feedback)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                VStack(spacing: 14) {
                    credentialSection(
                        "App Store Connect",
                        detail: "上传 TestFlight 与 App Store 的推荐认证方式",
                        systemImage: "key.horizontal.fill"
                    ) {
                        apiKeyFileRow
                        Divider()
                        credentialRow(.ascAPIKeyID, prompt: "例如 496SRK4K68", monospaced: true)
                        credentialRow(.ascIssuerID, prompt: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx", monospaced: true)
                    }

                    credentialSection(
                        "Apple ID 备用认证",
                        detail: "仅供仍需 Apple ID 登录的旧发布流程使用",
                        systemImage: "person.crop.circle"
                    ) {
                        credentialRow(.appleID, prompt: "name@example.com")
                        credentialRow(.appSpecificPassword, prompt: "xxxx-xxxx-xxxx-xxxx", secure: true)
                    }

                    credentialSection(
                        "开发者团队",
                        detail: "用于代码签名与证书匹配",
                        systemImage: "person.2.badge.gearshape"
                    ) {
                        credentialRow(.appleTeamID, prompt: "10 位 Team ID", monospaced: true)
                    }

                    credentialSection(
                        "Match 签名",
                        detail: "5 个项目共用 aptv-certs 加密仓库",
                        systemImage: "lock.rotation"
                    ) {
                        credentialRow(.matchGitURL, prompt: "git@github.com:vibeforge2014/aptv-certs.git")
                        credentialRow(.matchPassword, prompt: "Match 仓库解密密码", secure: true)
                    }
                }

                validationPanel
            }
            .padding(24)
            .padding(.bottom, 12)
            .frame(maxWidth: 760, alignment: .leading)
            .animation(.easeInOut(duration: 0.18), value: feedback?.id)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actionBar
        }
        .navigationTitle("凭证设置")
        .onAppear { reloadAll() }
        .fileImporter(
            isPresented: $showKeyImporter,
            allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data]
        ) { result in
            importAPIKey(result)
        }
        .confirmationDialog(
            "清除全部凭证？",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除全部凭证", role: .destructive) { clearAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会从本机钥匙串移除所有 Apple 与 Match 凭证，且无法撤销。")
        }
        .alert("无法导入 API Key", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "请选择 App Store Connect 下载的 AuthKey_*.p8 文件。")
        }
    }

    // MARK: - Overview

    private var overview: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "lock.shield.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("本机安全存储")
                        .font(.headline)
                    Text("已配置 \(configuredCount)/\(Credential.allCases.count)")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.secondary.opacity(0.12), in: Capsule())
                }
                Text("凭证仅保存在 macOS 钥匙串，不会写入项目文件或上传到其他服务。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if hasUnsavedChanges {
                    Label("有尚未保存的更改", systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
        }
        .padding(16)
        .background(.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func feedbackBanner(_ feedback: Feedback) -> some View {
        Label(feedback.message, systemImage: feedback.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
            .font(.callout)
            .foregroundStyle(feedback.isError ? Color.red : Color.green)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((feedback.isError ? Color.red : Color.green).opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    // MARK: - Fields

    private func credentialSection<Content: View>(
        _ title: String,
        detail: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }

    private var apiKeyFileRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("API 私钥文件")
                    .font(.subheadline)
                Text(isEmpty(.ascAPIKeyContent) ? "选择 App Store Connect 下载的 AuthKey_*.p8" : apiKeyFilename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 180, alignment: .leading)

            if isEmpty(.ascAPIKeyContent) {
                Label("未导入", systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)
            } else {
                Label(apiKeyFilename, systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                showKeyImporter = true
            } label: {
                Label(isEmpty(.ascAPIKeyContent) ? "导入 .p8…" : "替换…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            if !isEmpty(.ascAPIKeyContent) {
                clearButton(for: .ascAPIKeyContent)
            }
        }
        .padding(.vertical, 2)
    }

    private var apiKeyFilename: String {
        let keyID = (values[.ascAPIKeyID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return keyID.isEmpty ? "API Key 已导入" : "AuthKey_\(keyID).p8"
    }

    @ViewBuilder
    private func credentialRow(
        _ credential: Credential,
        prompt: String,
        secure: Bool = false,
        monospaced: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            Text(credential.label)
                .font(.subheadline)
                .frame(minWidth: 180, alignment: .leading)

            Group {
                if secure && !revealedCredentials.contains(credential) {
                    SecureField(prompt, text: binding(for: credential))
                } else {
                    TextField(prompt, text: binding(for: credential))
                }
            }
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            .textFieldStyle(.roundedBorder)

            if secure {
                Button {
                    if revealedCredentials.contains(credential) {
                        revealedCredentials.remove(credential)
                    } else {
                        revealedCredentials.insert(credential)
                    }
                } label: {
                    Image(systemName: revealedCredentials.contains(credential) ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealedCredentials.contains(credential) ? "隐藏内容" : "显示内容")
            } else {
                Image(systemName: isEmpty(credential) ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(isEmpty(credential) ? Color.secondary.opacity(0.45) : Color.green)
                    .frame(width: 16)
                    .accessibilityLabel(isEmpty(credential) ? "未填写" : "已填写")
            }

            if !isEmpty(credential) {
                clearButton(for: credential)
            }
        }
        .padding(.vertical, 2)
    }

    private func clearButton(for credential: Credential) -> some View {
        Button {
            values[credential] = ""
            validationResults.removeAll()
            feedback = nil
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("清空（保存后生效）")
    }

    private func binding(for credential: Credential) -> Binding<String> {
        Binding(
            get: { values[credential] ?? "" },
            set: { newValue in
                values[credential] = newValue
                validationResults.removeAll()
                feedback = nil
            }
        )
    }

    private func isEmpty(_ credential: Credential) -> Bool {
        (values[credential] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Validation

    private var validationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("发布前检查")
                        .font(.headline)
                    Text("只读检查 Apple 认证、本机签名证书与 Match 仓库")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if validating {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(validationResults.isEmpty ? (hasUnsavedChanges ? "保存并验证" : "验证全部") : "重新验证") {
                    if hasUnsavedChanges && !saveChanges() { return }
                    validateAll()
                }
                .buttonStyle(.borderedProminent)
                .disabled(validating)
            }

            if validationResults.isEmpty {
                Label("尚未运行检查", systemImage: "checklist")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Divider()
                ForEach(validationResults) { item in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: validationIcon(item.status))
                            .foregroundStyle(validationColor(item.status))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.subheadline.weight(.medium))
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let guidance = item.guidance {
                                Text(guidance)
                                    .font(.caption)
                                    .foregroundStyle(item.status == .failed ? .red : .orange)
                            }
                        }
                        Spacer()
                    }
                }
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button(role: .destructive) {
                showClearConfirmation = true
            } label: {
                Label("清除全部", systemImage: "trash")
            }
            .buttonStyle(.borderless)

            Spacer()

            if hasUnsavedChanges {
                Button("放弃更改") { reloadAll() }
            }
            Button("保存更改") { saveChanges() }
                .buttonStyle(.borderedProminent)
                .disabled(!hasUnsavedChanges)
                .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: 760)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Commands

    @discardableResult
    private func saveChanges() -> Bool {
        var failedLabels: [String] = []
        for credential in Credential.allCases {
            let value = values[credential] ?? ""
            let success = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? KeychainStore.delete(credential)
                : KeychainStore.set(value, for: credential)
            if !success { failedLabels.append(credential.label) }
        }

        guard failedLabels.isEmpty else {
            feedback = Feedback(message: "保存失败：\(failedLabels.joined(separator: "、"))", isError: true)
            return false
        }
        reloadAll(showFeedback: false)
        feedback = Feedback(message: "凭证已安全保存到 macOS 钥匙串", isError: false)
        return true
    }

    private func reloadAll(showFeedback: Bool = false) {
        var loaded: [Credential: String] = [:]
        for credential in Credential.allCases {
            loaded[credential] = KeychainStore.get(credential) ?? ""
        }
        values = loaded
        savedValues = loaded
        revealedCredentials.removeAll()
        if !showFeedback { feedback = nil }
    }

    private func clearAll() {
        var succeeded = true
        for credential in Credential.allCases where !KeychainStore.delete(credential) {
            succeeded = false
        }
        reloadAll(showFeedback: false)
        validationResults.removeAll()
        feedback = Feedback(
            message: succeeded ? "已从本机钥匙串清除全部凭证" : "部分凭证未能清除，请重试",
            isError: !succeeded
        )
    }

    private func validateAll() {
        validating = true
        validationResults.removeAll()
        feedback = nil
        Task {
            validationResults = await CredentialValidationService.validate(catalog: catalog.data)
            validating = false
        }
    }

    private func importAPIKey(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            if case .failure(let error) = result { importError = error.localizedDescription }
            return
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        guard url.pathExtension.lowercased() == "p8",
              let content = try? String(contentsOf: url, encoding: .utf8),
              content.contains("-----BEGIN PRIVATE KEY-----"),
              content.contains("-----END PRIVATE KEY-----") else {
            importError = "文件不是有效的 App Store Connect .p8 私钥。"
            return
        }

        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = url.deletingPathExtension().lastPathComponent
        let importedKeyID: String?
        if name.hasPrefix("AuthKey_") {
            importedKeyID = String(name.dropFirst("AuthKey_".count))
        } else {
            importedKeyID = nil
        }

        guard KeychainStore.set(normalizedContent, for: .ascAPIKeyContent),
              importedKeyID.map({ KeychainStore.set($0, for: .ascAPIKeyID) }) ?? true else {
            importError = "无法将私钥保存到 macOS 钥匙串，请检查钥匙串访问权限后重试。"
            return
        }

        values[.ascAPIKeyContent] = normalizedContent
        savedValues[.ascAPIKeyContent] = normalizedContent
        if let importedKeyID {
            values[.ascAPIKeyID] = importedKeyID
            savedValues[.ascAPIKeyID] = importedKeyID
        }
        validationResults.removeAll()
        feedback = Feedback(message: "已导入 \(url.lastPathComponent) 并保存到钥匙串", isError: false)
    }

    private func validationIcon(_ status: CredentialValidationStatus) -> String {
        switch status {
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private func validationColor(_ status: CredentialValidationStatus) -> Color {
        switch status {
        case .passed: .green
        case .warning: .orange
        case .failed: .red
        }
    }
}

private struct Feedback: Identifiable {
    let id = UUID()
    let message: String
    let isError: Bool
}
