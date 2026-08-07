import SwiftUI

/// 凭据管理视图。所有凭据保存在 macOS 钥匙串中(service:
/// com.vibeforge.devops-assistant),按分组展示并提供即时编辑与单条/全部删除。
struct SettingsView: View {
    /// Credential → 当前值缓存,onAppear 时从钥匙串批量读取。
    @State private var values: [Credential: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                notice

                Form {
                    Section("App Store Connect") {
                        credentialRow(.ascAPIKeyContent, secure: true)
                        credentialRow(.ascAPIKeyID)
                        credentialRow(.ascIssuerID)
                    }

                    Section("Match 签名") {
                        credentialRow(.matchGitURL)
                        credentialRow(.matchPassword, secure: true)
                    }

                    Section("通用") {
                        credentialRow(.appleTeamID)
                    }
                }
                .scrollDisabled(true)

                clearAllButton
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .navigationTitle("凭据设置")
        .onAppear { reloadAll() }
    }

    // MARK: - Notice

    private var notice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("凭据存储在 macOS 钥匙串(service: com.vibeforge.devops-assistant)")
                    .font(.callout)
                Text("字段变更会即时写入钥匙串;删除单条请点击对应行右侧的按钮。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Rows

    @ViewBuilder
    private func credentialRow(_ cred: Credential, secure: Bool = false) -> some View {
        HStack(spacing: 12) {
            Text(cred.label)
                .font(.subheadline)
                .frame(minWidth: 170, alignment: .leading)
            Group {
                if secure {
                    SecureField("未设置", text: binding(for: cred))
                } else {
                    TextField("未设置", text: binding(for: cred))
                }
            }
            .textFieldStyle(.roundedBorder)

            Button(role: .destructive) {
                delete(cred)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除该凭据")
        }
    }

    /// 字段绑定:输入变更时同步写入钥匙串。
    private func binding(for cred: Credential) -> Binding<String> {
        Binding(
            get: { values[cred] ?? "" },
            set: { newValue in
                values[cred] = newValue
                _ = KeychainStore.set(newValue, for: cred)
            }
        )
    }

    // MARK: - Clear all

    private var clearAllButton: some View {
        Button(role: .destructive) {
            for cred in Credential.allCases {
                _ = KeychainStore.delete(cred)
            }
            reloadAll()
        } label: {
            Label("全部清除", systemImage: "trash.fill")
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Commands

    /// 删除单条:先从钥匙串移除,再清空缓存(直接改 state,不触发 binding 写回)。
    private func delete(_ cred: Credential) {
        _ = KeychainStore.delete(cred)
        values[cred] = nil
    }

    private func reloadAll() {
        values.removeAll()
        for cred in Credential.allCases {
            values[cred] = KeychainStore.get(cred) ?? ""
        }
    }
}
