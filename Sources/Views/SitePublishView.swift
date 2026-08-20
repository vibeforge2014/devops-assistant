import AppKit
import SwiftUI

/// One-click site publish wizard, the site counterpart of `ReleaseFlowView`.
/// Shows what's pending (dirty files / ahead commits), takes a commit
/// message, then runs pull → commit → publish with live step states; the
/// console below mirrors output in real time. A failed run can be resumed
/// from the failed step with 重试.
///
/// The coordinator is owned by `ReleaseCenter`, not this sheet: dismissing
/// it ("后台运行") never stops a running publish, and reopening shows live
/// progress again.
struct SitePublishView: View {
    let site: SiteProject
    @ObservedObject private var coordinator: SitePublishCoordinator
    @EnvironmentObject private var navigation: NavigationModel
    @Environment(\.dismiss) private var dismiss

    @State private var message = ""
    @State private var status: SiteStatus?
    @State private var statusLoading = false
    @State private var showRollbackConfirm = false
    @State private var rollbackSubject: String?

    init(site: SiteProject, center: ReleaseCenter) {
        self.site = site
        _coordinator = ObservedObject(wrappedValue: center.siteCoordinator(for: site))
    }

    private var steps: [SitePublishStep] { SitePublishCoordinator.publishSteps(for: site) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    changeSummary
                    messageSection
                    stepsPanel
                }
                .padding(24)
            }

            Divider()
            ConsolePanel(runner: coordinator.runner)
                .frame(height: 180)
        }
        .frame(width: 620, height: 640)
        .onAppear { refreshStatus() }
        .onChange(of: coordinator.isRunning) { _, running in
            // A publish that just finished changed the tree — refresh so the
            // change summary doesn't claim stale pending work.
            if !running { refreshStatus() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("发布 \(site.name)").font(.title2.bold())
                if coordinator.isRunning {
                    // Ticks once a second so the total-run timer stays live.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(runningLabel(at: context.date))
                            .font(.caption)
                            .foregroundStyle(statusColor)
                    }
                } else {
                    Text(finishedLabel)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
            }
            Spacer()
            openLogButton
            if coordinator.isRunning {
                Button("取消") { coordinator.cancel() }
                    .buttonStyle(.bordered)
                Button("后台运行") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .help("发布在后台继续,完成后发系统通知;可随时回来查看进度")
            } else {
                Button("关闭") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.regularMaterial)
    }

    /// Jump straight to the run log on disk (Finder-revealed).
    @ViewBuilder
    private var openLogButton: some View {
        if let url = coordinator.logSinkURL,
           FileManager.default.fileExists(atPath: url.path) {
            Button {
                NSWorkspace.shared.selectFile(
                    url.path,
                    inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
            } label: {
                Label("打开日志", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .help(url.path)
        }
    }

    private func runningLabel(at now: Date) -> String {
        var label = "运行中 · \(coordinator.currentStep?.title ?? "准备中…")"
        if let started = coordinator.runStartedAt {
            label += " · \(ReleaseFormatting.duration(now.timeIntervalSince(started)))"
        }
        return label
    }

    private var statusColor: Color {
        if coordinator.isRunning { return .blue }
        switch coordinator.lastOutcome {
        case .success: return .green
        case .failed: return .red
        case .cancelled, .nothingToPublish: return .secondary
        case nil: return .secondary
        }
    }

    private var finishedLabel: String {
        let done = coordinator.completedSteps.count
        let total = steps.count
        if total == 0 { return "准备发布" }
        let elapsed = coordinator.runTotalElapsed
            .map { " · 用时 \(ReleaseFormatting.duration($0))" } ?? ""
        switch coordinator.lastOutcome {
        case .success:
            return "✓ 已完成(\(done)/\(total) 步)\(elapsed)"
        case .failed(let step):
            return "✗ 失败于「\(step)」(\(done)/\(total) 步)\(elapsed)"
        case .cancelled:
            return "已取消(\(done)/\(total) 步)"
        case .nothingToPublish:
            return "没有需要发布的变更"
        case nil:
            return "\(done)/\(total) 步完成"
        }
    }

    // MARK: - Change summary

    private var changeSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("1. 变更概览").font(.headline)
                Spacer()
                if statusLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button("重新检查") { refreshStatus() }
                        .buttonStyle(.borderless)
                }
            }

            if !site.existsOnDisk {
                Label("本地克隆不存在 — 请先在站点页克隆仓库", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            } else if let status {
                summaryRows(status)
            } else {
                Text("读取仓库状态…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func summaryRows(_ status: SiteStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if status.hasPendingWork {
                Label(pendingWorkLabel(status), systemImage: "tray.full")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            } else if status.hasNothingToPublish {
                Label("工作区干净,没有领先远端的提交", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Label("工作区干净,但本地提交领先远端 \(status.ahead) 个", systemImage: "arrow.up.circle")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }

            if let commit = status.lastCommit {
                Text("最近提交 \(commit.shortHash) \(commit.subject) · \(commit.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let branch = status.branch {
                Text("分支 \(branch)\(status.behind > 0 ? " · 落后远端 \(status.behind) 个提交" : "")")
                    .font(.caption)
                    .foregroundStyle(status.behind > 0 ? .orange : .secondary)
            }
        }
    }

    private func pendingWorkLabel(_ status: SiteStatus) -> String {
        var parts: [String] = []
        if status.changedFiles > 0 {
            parts.append("\(status.changedFiles) 个文件待提交")
        }
        if status.ahead > 0 {
            parts.append("领先远端 \(status.ahead) 个提交")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Message

    private var messageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("2. 更新说明").font(.headline)
            TextField("commit message,如:更新下载链接与版本说明", text: $message)
                .textFieldStyle(.roundedBorder)
                .onSubmit { startPublish() }
                .disabled(coordinator.isRunning)
            Text("将按「拉取 → 提交 → \(deployVerb)」执行,\(deployVerb)后站点自动更新。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var deployVerb: String {
        switch site.deploy {
        case .gitPushMain: "推送 main 触发部署"
        case .ghPages: "npm 部署 gh-pages"
        case .cloudflarePages: "wrangler 直传 Cloudflare Pages"
        }
    }

    // MARK: - Steps

    private var stepsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(coordinator.canRetry ? "3. 执行步骤(上次失败)" : "3. 执行步骤").font(.headline)
                Spacer()
                if coordinator.isRunning {
                    EmptyView() // Cancel lives in the header next to 后台运行.
                } else if coordinator.canRetry {
                    Button("重新开始") { startPublish() }
                        .buttonStyle(.bordered)
                        .disabled(publishBlocked)
                        .help("从头重新执行所有步骤")
                    Button {
                        Task { await coordinator.retry() }
                    } label: {
                        Label("从失败步骤重试", systemImage: "arrow.clockwise.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("跳过已成功的步骤,从失败处继续")
                } else {
                    Button("发布") { startPublish() }
                        .buttonStyle(.borderedProminent)
                        .disabled(publishBlocked)
                        .help(publishBlockedReason ?? "开始发布")
                }
            }

            if !coordinator.isRunning, let reason = publishBlockedReason {
                Label(reason, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            ForEach(steps) { step in
                let state = coordinator.stepStates[step] ?? .idle
                HStack(spacing: 10) {
                    Image(systemName: state.icon)
                        .foregroundStyle(state.tint)
                        .frame(width: 20)
                    Text(step.title)
                    if case .failed(let msg) = state {
                        Text(msg).font(.caption).foregroundStyle(.red)
                    }
                    Spacer()
                    if let seconds = coordinator.stepDurations[step],
                       state != .idle, state != .running {
                        Text(ReleaseFormatting.duration(seconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }

            if coordinator.lastOutcome == .success && !coordinator.isRunning {
                successBanner
            }
            if coordinator.lastOutcome == .nothingToPublish && !coordinator.isRunning {
                nothingToPublishBanner
            }

            rollbackSection
        }
    }

    // MARK: - Rollback

    /// Emergency exit: revert the last deployed commit and redeploy the
    /// pre-change content. Confirm first — it rewrites the live site.
    private var rollbackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("回滚", systemImage: "arrow.uturn.backward")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await startRollback() }
                } label: {
                    Label("回滚上一版", systemImage: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(!site.existsOnDisk || coordinator.isRunning)
            }
            Text(rollbackSubject.map { "将撤销最近一次提交「\($0)」并重新部署之前的版本。" }
                 ?? "撤销最近一次提交(git revert)并重新部署之前的版本。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .background(.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.red.opacity(0.15)))
        .confirmationDialog("回滚上一版?", isPresented: $showRollbackConfirm,
                            titleVisibility: .visible) {
            Button("回滚并重新部署", role: .destructive) {
                Task { await coordinator.runRollback() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(rollbackSubject.map { "将撤销「\($0)」并用之前的版本重新部署 \(site.name)。" }
                 ?? "将撤销最近一次提交并用之前的版本重新部署 \(site.name)。")
        }
    }

    private func startRollback() async {
        rollbackSubject = await SitePublishCoordinator.lastCommitSubject(at: site.resolvedPath)
        showRollbackConfirm = true
    }

    /// Post-success quick actions: the things a user does right after a ship.
    private var successBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("站点发布完成").font(.headline)
                if let elapsed = coordinator.runTotalElapsed {
                    Text("\(deployVerb) · 用时 \(ReleaseFormatting.duration(elapsed))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let url = site.liveURL {
                Button("打开站点") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.bordered)
            }
            Button("查看发布历史") {
                navigation.selection = .history
                dismiss()
            }
            .buttonStyle(.bordered)
            Button("完成") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var nothingToPublishBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
            Text("没有需要发布的变更 — 工作区干净,且没有领先远端的提交")
                .font(.subheadline)
            Spacer()
            Button("好") { dismiss() }
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Actions

    private func startPublish() {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !coordinator.isRunning, !trimmed.isEmpty else { return }
        Task { await coordinator.run(message: trimmed) }
    }

    private var publishBlocked: Bool {
        coordinator.isRunning
            || !site.existsOnDisk
            || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Why the primary publish action is unavailable, in one sentence.
    /// nil when it isn't blocked (or the wizard is mid-run).
    private var publishBlockedReason: String? {
        guard !coordinator.isRunning else { return nil }
        if !site.existsOnDisk { return "本地克隆不存在,请先克隆仓库" }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请填写更新说明(commit message)"
        }
        return nil
    }

    private func refreshStatus() {
        statusLoading = true
        let path = site.resolvedPath
        Task {
            status = await SiteStatusService.status(at: path)
            statusLoading = false
        }
    }
}
