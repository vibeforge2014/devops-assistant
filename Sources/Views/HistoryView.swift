import AppKit
import SwiftUI

/// Browse past releases — app pipelines and site deployments alike. Filter
/// by project, see version/target/time/result for each run, and clear
/// history. The store is the single source of truth; this view only reads
/// (and clears) it. Tapping a row expands its full detail — including the
/// run's persisted log when there is one.
struct HistoryView: View {
    @EnvironmentObject var catalog: ProjectCatalog
    @EnvironmentObject private var historyStore: HistoryStore

    /// Which records the list shows: everything, one app, or one site.
    private enum Filter: Hashable {
        case all
        case app(String)
        case site(String)
    }

    @State private var filter: Filter = .all
    @State private var showClearConfirm = false
    @State private var expandedRecordID: UUID?

    private var filtered: [ReleaseRecord] {
        switch filter {
        case .all:
            return historyStore.records
        case .app(let id):
            return historyStore.records.filter { $0.appID == id && $0.kind == .app }
        case .site(let id):
            return historyStore.records.filter { $0.appID == id && $0.kind == .site }
        }
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
                Text("记录每次发布(App 与站点)的版本、目标与结果。")
                    .font(.callout)
                Text("按项目筛选查看;点击记录可展开详情与运行日志。记录最多保留 \(HistoryStore.maxRecords) 条。")
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
            Picker("项目", selection: $filter) {
                Text("全部项目").tag(Filter.all)
                ForEach(catalog.apps) { app in
                    Text(app.name).tag(Filter.app(app.id))
                }
                ForEach(catalog.sites) { site in
                    Text("站点 · \(site.name)").tag(Filter.site(site.id))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 280)

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
                historyStore.records.isEmpty ? "还没有发布记录" : "该项目暂无记录",
                systemImage: "clock.arrow.circlepath",
                description: Text(historyStore.records.isEmpty
                                  ? "完成一次发布(App 或站点部署)后,记录会出现在这里。"
                                  : "换个项目或选「全部项目」查看。")
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: record.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(record.success ? .green : .red)
                    .font(.title3)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        if record.kind == .site {
                            Image(systemName: "globe")
                                .font(.caption)
                                .foregroundStyle(.tint)
                        }
                        Text(record.appName).font(.headline)
                        Text(record.versionLabel)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                        platformTag(record.platform)
                    }
                    HStack(spacing: 6) {
                        Text(record.targetLabel)
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
                Image(systemName: expandedRecordID == record.id ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedRecordID = expandedRecordID == record.id ? nil : record.id
                }
            }

            if expandedRecordID == record.id {
                recordDetail(record)
                    .padding(.top, 10)
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }

    // MARK: - Expanded detail

    private func recordDetail(_ record: ReleaseRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                detailLine("目标", record.targetLabel)
                detailLine(record.kind == .site ? "提交" : "版本", record.versionLabel)
                detailLine("平台", AppPlatform(rawValue: record.platform)?.displayName ?? record.platform)
                detailLine("时间", record.timestamp.formatted(date: .long, time: .standard))
                if let step = record.failureStep {
                    detailLine("中断步骤", step)
                }
            }

            if let logPath = record.logPath {
                HStack(spacing: 12) {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
                    } label: {
                        Label("打开日志", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!record.logFileExists)

                    Button {
                        NSWorkspace.shared.selectFile(
                            logPath,
                            inFileViewerRootedAtPath: (logPath as NSString).deletingLastPathComponent)
                    } label: {
                        Label("在 Finder 中显示", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!record.logFileExists)

                    if !record.logFileExists {
                        Text("日志文件已被清理")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("此记录早于日志落盘功能(或本次运行未能创建日志)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
        .padding(.leading, 40) // align under the text columns, past the icon
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.callout)
        }
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
}
