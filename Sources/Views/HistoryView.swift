import SwiftUI

/// Browse past releases. Filter by app, see version/target/time/result for
/// each run, and clear history. The store is the single source of truth;
/// this view only reads (and clears) it.
struct HistoryView: View {
    @EnvironmentObject var catalog: ProjectCatalog
    @EnvironmentObject private var historyStore: HistoryStore

    /// "" = all apps; otherwise an app id.
    @State private var filterAppID: String = ""
    @State private var showClearConfirm = false

    private var filtered: [ReleaseRecord] {
        historyStore.records(forAppID: filterAppID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                intro
                filterBar
                listOrEmpty
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("发布历史")
        .confirmationDialog("清空所有发布记录?",
                            isPresented: $showClearConfirm,
                            titleVisibility: .visible) {
            Button("清空", role: .destructive) { historyStore.clear() }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - Intro

    private var intro: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.arrow.circlepath.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("记录每次发布的版本、目标与结果。")
                    .font(.callout)
                Text("按应用筛选查看;记录最多保留 \(HistoryStore.maxRecords) 条。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("应用", selection: $filterAppID) {
                Text("全部应用").tag("")
                ForEach(catalog.apps) { app in
                    Text(app.name).tag(app.id)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 240)

            Spacer()

            if !historyStore.records.isEmpty {
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label("清空", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - List

    @ViewBuilder
    private var listOrEmpty: some View {
        if filtered.isEmpty {
            ContentUnavailableView(
                historyStore.records.isEmpty ? "还没有发布记录" : "该应用暂无记录",
                systemImage: "clock.arrow.circlepath",
                description: Text(historyStore.records.isEmpty
                                  ? "完成一次发布后,记录会出现在这里。"
                                  : "换个应用或选「全部应用」查看。")
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
        } else {
            VStack(spacing: 8) {
                ForEach(filtered) { record in
                    recordRow(record)
                }
            }
        }
    }

    private func recordRow(_ record: ReleaseRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: record.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(record.success ? .green : .red)
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(record.appName).font(.headline)
                    Text(record.versionLabel)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    platformTag(record.platform)
                }
                HStack(spacing: 6) {
                    Text(targetLabel(record.target))
                    Text("·").foregroundStyle(.tertiary)
                    Text(record.timestamp.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let step = record.failureStep {
                Text("失败于 \(step)")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .help("中断步骤")
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }

    // MARK: - Helpers

    private func platformTag(_ raw: String) -> some View {
        let name = AppPlatform(rawValue: raw)?.displayName ?? raw
        return Text(name)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
    }

    private func targetLabel(_ raw: String) -> String {
        ReleaseTarget(rawValue: raw)?.title ?? raw
    }
}
