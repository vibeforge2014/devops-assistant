import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Exports all configured keychain credentials into one passphrase-encrypted
/// migration file. Values are never shown — only which fields are included.
struct CredentialExportSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Snapshot of what's currently in the keychain (read once on appear).
    @State private var configured: [Credential: String] = [:]
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var errorMessage: String?
    @State private var exportedFileURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            header

            if let exportedFileURL {
                successView(exportedFileURL)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        contentsOverview
                        passphraseFields
                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(20)
                }
                Divider()
                footer
            }
        }
        .frame(width: 480, height: 480)
        .onAppear {
            if configured.isEmpty {
                configured = CredentialMigrationService.readConfiguredCredentials()
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("导出迁移文件").font(.title2.bold())
                Text("凭据将使用口令加密后写入单个文件,用于迁移到其他 Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(.regularMaterial)
    }

    // MARK: - Contents

    private var contentsOverview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("将包含以下 \(configured.count) 项已配置凭据")
                .font(.headline)
            ForEach(Credential.allCases, id: \.self) { credential in
                HStack(spacing: 8) {
                    Image(systemName: configured[credential] != nil ? "checkmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(configured[credential] != nil
                                         ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                    Text(credential.label).font(.subheadline)
                    Spacer()
                    if configured[credential] == nil {
                        Text("未配置,跳过").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            if configured.isEmpty {
                Label(CredentialMigrationError.noConfiguredCredentials.errorDescription ?? "",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Passphrase

    private var passphraseFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("加密口令").font(.headline)
            SecureField("口令(至少 \(CredentialMigrationService.minimumPassphraseLength) 个字符)", text: $passphrase)
                .textFieldStyle(.roundedBorder)
            SecureField("再次输入口令", text: $confirmation)
                .textFieldStyle(.roundedBorder)
            if !confirmation.isEmpty && confirmation != passphrase {
                Label("两次输入的口令不一致", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("口令不会存储在任何地方 — 遗忘口令将无法恢复文件内容")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("取消") { dismiss() }
            Button {
                export()
            } label: {
                Label("导出加密文件…", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canExport)
        }
        .padding(12)
        .background(.regularMaterial)
    }

    private var canExport: Bool {
        !configured.isEmpty
            && passphrase.count >= CredentialMigrationService.minimumPassphraseLength
            && passphrase == confirmation
    }

    private func export() {
        do {
            let data = try CredentialMigrationService.exportContainer(
                credentials: configured, passphrase: passphrase)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = CredentialMigrationService.suggestedFileName()
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url, options: .atomic)
                    exportedFileURL = url
                } catch {
                    errorMessage = "写入文件失败: \(error.localizedDescription)"
                }
            }
        } catch let error as CredentialMigrationError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Success

    private func successView(_ url: URL) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("迁移文件已导出").font(.title3.bold())
            Text(url.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Label("文件已用口令加密,但仍属敏感内容 — 请妥善保管,完成迁移后建议删除",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.leading)
            HStack {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.selectFile(
                        url.path,
                        inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// Imports a passphrase-encrypted migration file back into the keychain:
/// pick file → decrypt → preview what will change → confirm.
struct CredentialImportSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Called once after a successful import with the written credentials.
    var onImported: ([Credential: String]) -> Void = { _ in }

    @State private var fileURL: URL?
    @State private var passphrase = ""
    @State private var payload: CredentialMigrationService.MigrationPayload?
    /// Keychain snapshot taken once at decrypt time — drives the
    /// 新增/覆盖 annotations without re-reading the keychain per render.
    @State private var existing: [Credential: String] = [:]
    @State private var skipExisting = false
    @State private var errorMessage: String?
    @State private var importing = false
    @State private var importedList: [Credential]?
    @State private var showFilePicker = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let importedList {
                        doneView(importedList)
                    } else if let payload {
                        preview(payload)
                    } else {
                        pickFileSection
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 480, height: 520)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.json]
        ) { result in
            guard case .success(let url) = result else { return }
            fileURL = url
            errorMessage = nil
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("导入迁移文件").font(.title2.bold())
                Text("解密后写入本机钥匙串,完成换机/重装后的凭据迁移")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(.regularMaterial)
    }

    // MARK: - Step 1: pick + passphrase

    private var pickFileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("1. 选择迁移文件").font(.headline)
            Button {
                showFilePicker = true
            } label: {
                Label(fileURL.map { "已选择: \($0.lastPathComponent)" } ?? "选择迁移文件…",
                      systemImage: fileURL == nil ? "doc.badge.plus" : "doc.checkmark")
            }
            .buttonStyle(.bordered)

            Text("2. 输入导出时设置的口令").font(.headline)
                .padding(.top, 8)
            SecureField("加密口令", text: $passphrase)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Step 2: preview

    private func preview(_ payload: CredentialMigrationService.MigrationPayload) -> some View {
        let pairs = payload.credentialPairs
        return VStack(alignment: .leading, spacing: 10) {
            Text("文件包含 \(pairs.count) 项凭据,导出于 \(payload.exportedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.headline)

            ForEach(Credential.allCases, id: \.self) { credential in
                if pairs[credential] != nil {
                    HStack(spacing: 8) {
                        Image(systemName: "key.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                        Text(credential.label).font(.subheadline)
                        Spacer()
                        if existing[credential] != nil {
                            if skipExisting {
                                Text("保留本机现有值").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("覆盖本机现有值").font(.caption).foregroundStyle(.orange)
                            }
                        } else {
                            Text("新增").font(.caption).foregroundStyle(.green)
                        }
                    }
                }
            }

            Toggle("跳过本机已有值的项(不覆盖)", isOn: $skipExisting)
                .font(.subheadline)
        }
    }

    // MARK: - Done

    private func doneView(_ written: [Credential]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("已导入 \(written.count) 项凭据到本机钥匙串", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
            ForEach(written, id: \.self) { credential in
                Label(credential.label, systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if payload == nil && importedList == nil {
                Button("取消") { dismiss() }
                Spacer()
                Button {
                    decrypt()
                } label: {
                    Label("解密预览", systemImage: "key.viewfinder")
                }
                .buttonStyle(.borderedProminent)
                .disabled(fileURL == nil || passphrase.isEmpty || importing)
            } else if payload != nil {
                Button("返回重选") {
                    self.payload = nil
                    fileURL = nil
                    passphrase = ""
                    errorMessage = nil
                }
                Spacer()
                Button {
                    importCredentials()
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(importing)
            } else {
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(.regularMaterial)
    }

    // MARK: - Actions

    private func decrypt() {
        guard let url = fileURL else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            payload = try CredentialMigrationService.decryptContainer(data, passphrase: passphrase)
            existing = CredentialMigrationService.readConfiguredCredentials()
            errorMessage = nil
        } catch let error as CredentialMigrationError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "读取文件失败: \(error.localizedDescription)"
        }
    }

    private func importCredentials() {
        guard let payload else { return }
        importing = true
        defer { importing = false }
        do {
            let pairs = payload.credentialPairs
            let written = try CredentialMigrationService.apply(pairs, skipExisting: skipExisting)
            importedList = written.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            onImported(pairs)
        } catch let error as CredentialMigrationError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
