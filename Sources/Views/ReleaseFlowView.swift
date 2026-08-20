import AppKit
import SwiftUI

/// One-click release wizard. Choose a target (TestFlight / App Store / macOS
/// notarized distribution), optionally set the marketing version, then run the
/// pipeline. Steps render live with success/failure states; the console below
/// mirrors output in real time. Failures stop the pipeline at the offending
/// step so no work is wasted on top of a broken build — and can then be
/// resumed from that step with 重试.
///
/// The coordinator is owned by `ReleaseCenter`, not this sheet: dismissing
/// the sheet ("后台运行") never stops a running release, and reopening it
/// shows live progress again.
struct ReleaseFlowView: View {
    let app: AppProject
    @ObservedObject private var coordinator: ReleaseCoordinator
    private let catalogData: ProjectCatalogData
    @EnvironmentObject private var navigation: NavigationModel
    @Environment(\.dismiss) private var dismiss

    @State private var target: ReleaseTarget = .testFlight
    @State private var marketingVersion = ""
    @State private var buildNumber = ""
    @State private var showVersionFields = false
    @State private var preflightChecks: [PreflightCheck] = []
    @State private var preflightRunning = false
    /// Current on-disk version, loaded on appear — anchors the "当前 → 将发布"
    /// preview and the field prefill.
    @State private var currentVersion: VersionPair?
    /// Suppresses the target-change reset for the programmatic sync in
    /// `onAppear` — reopening the sheet over a (finished or running) release
    /// must not wipe its step states.
    @State private var syncingTargetFromRun = false

    init(app: AppProject, center: ReleaseCenter, catalog: ProjectCatalog, historyStore: HistoryStore) {
        self.app = app
        self.catalogData = catalog.data
        _coordinator = ObservedObject(wrappedValue: center.coordinator(for: app))
        _target = State(initialValue: ReleaseTarget.available(for: app).first ?? .testFlight)
    }

    private var steps: [ReleaseStep] {
        coordinator.steps(for: target)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    targetPicker
                    preflightPanel
                    if showVersionFields { versionFields }
                    stepsPanel
                }
                .padding(24)
            }

            Divider()
            ConsolePanel(runner: coordinator.runner)
                .frame(height: 180)
        }
        .frame(width: 640, height: 720)
        .onAppear {
            // Reopened over a backgrounded run: follow the target that's
            // actually executing instead of the picker default.
            if let active = coordinator.activeTarget, active != target {
                syncingTargetFromRun = true
                target = active
            }
            currentVersion = VersionManager.read(app)
            refreshPreflight()
        }
        .onChange(of: showVersionFields) { _, shown in
            // First toggle on: prefill with the next plausible version (same
            // marketing, build +1) so "设置版本号" starts from reality instead
            // of two blank fields.
            if shown, marketingVersion.isEmpty, buildNumber.isEmpty,
               let current = currentVersion ?? VersionManager.read(app) {
                marketingVersion = current.marketing
                buildNumber = ReleaseFormatting.bumped(current).build
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("发布 \(app.name)").font(.title2.bold())
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

    /// Jump straight to the run log on disk ( Finder-revealed) — the fastest
    /// path from "failed" to the actual error context after the app quit or
    /// the console scrolled away.
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
        if total == 0 { return "选择目标后运行" }
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

    // MARK: - Target picker

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("1. 选择发布目标").font(.headline)
            Picker("发布目标", selection: $target) {
                ForEach(ReleaseTarget.available(for: app)) { t in
                    Text(t.title).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .disabled(coordinator.isRunning)
            .onChange(of: target) { _, _ in
                if syncingTargetFromRun {
                    syncingTargetFromRun = false
                } else if !coordinator.isRunning {
                    // A real user switch: reset step state for the new target.
                    coordinator.resetSteps()
                }
                refreshPreflight()
            }

            Text(steps.map(\.title).joined(separator: " → "))
                .font(.caption)
                .foregroundStyle(.secondary)

            if ReleaseTarget.available(for: app).isEmpty {
                Label("当前发布引擎尚未配置可用的上传目标", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Toggle("设置版本号", isOn: $showVersionFields)
                .disabled(coordinator.isRunning)
                .font(.subheadline)

            if !coordinator.isRunning, let planned = plannedVersion {
                HStack(spacing: 6) {
                    if let current = currentVersion {
                        Text("当前 \(current.marketing) (\(current.build))")
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text("将发布 \(planned.marketing) (\(planned.build))")
                        .fontWeight(.semibold)
                }
                .font(.caption)
            }
        }
    }

    // MARK: - Preflight

    private var preflightPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("2. 发布预检").font(.headline)
                Spacer()
                if preflightRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button("重新检查") { refreshPreflight() }
                        .buttonStyle(.borderless)
                }
            }
            ForEach(preflightChecks) { check in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: preflightIcon(check.status))
                        .foregroundStyle(preflightColor(check.status))
                        .frame(width: 16)
                    Text(check.title).font(.subheadline)
                    Spacer()
                    Text(check.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(check.detail)
                }
            }
        }
        .padding(12)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Version fields

    private var versionFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("3. 版本号").font(.headline)
            HStack(spacing: 12) {
                TextField("Marketing(可选,如 1.2.3)", text: $marketingVersion)
                    .textFieldStyle(.roundedBorder)
                TextField("Build(可选,默认 +1)", text: $buildNumber)
                    .textFieldStyle(.roundedBorder)
            }
            Text("留空则保持当前版本,仅 build 号 +1")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !versionInputValid {
                Label("Marketing 需为数字版本号,Build 需为非负整数", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Steps

    private var stepsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(coordinator.canRetry ? "4. 执行步骤(上次失败)" : "4. 执行步骤").font(.headline)
                Spacer()
                if coordinator.isRunning {
                    // Cancel lives in the header next to 后台运行.
                    EmptyView()
                } else if coordinator.canRetry {
                    Button("重新开始") { runRelease() }
                        .buttonStyle(.bordered)
                        .disabled(preflightRunning || hasBlockingPreflight || !versionInputValid)
                        .help(publishBlockedReason ?? "从头重新执行所有步骤")
                    Button {
                        Task { await coordinator.retry() }
                    } label: {
                        Label("从失败步骤重试", systemImage: "arrow.clockwise.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(steps.isEmpty)
                    .help("跳过已成功的步骤,从失败处继续")
                } else {
                    Button(showVersionFields ? "发布" : "发布(仅 bump build)") {
                        runRelease()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(steps.isEmpty || preflightRunning ||
                              hasBlockingPreflight || !versionInputValid)
                    .help(publishBlockedReason ?? "开始发布")
                }
            }

            // Why is 发布 greyed out? A disabled primary button with no reason
            // reads as broken — state the blocker next to it.
            if !coordinator.isRunning, let reason = publishBlockedReason {
                Label(reason, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            ForEach(steps, id: \.rawValue) { step in
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
        }
    }

    /// Post-success quick actions: the two things a user does right after a
    /// ship — check the record, or get back to work.
    private var successBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("发布完成").font(.headline)
                if let planned = lastShippedLabel {
                    Text(planned).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
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

    private var lastShippedLabel: String? {
        guard let elapsed = coordinator.runTotalElapsed else { return nil }
        let targetTitle = coordinator.activeTarget?.title ?? target.title
        return "\(targetTitle) · 用时 \(ReleaseFormatting.duration(elapsed))"
    }

    // MARK: - Actions

    private func runRelease() {
        guard !coordinator.isRunning, !hasBlockingPreflight, versionInputValid else { return }
        let onDisk = VersionManager.read(app)
        currentVersion = onDisk
        let version = ReleaseFormatting.resolvedVersion(
            current: onDisk, marketing: marketingVersion, build: buildNumber)
        Task {
            await coordinator.run(target: target, version: version)
            // The bump (or explicit write) changed what's on disk — refresh
            // the preview anchor so a follow-up run previews correctly.
            currentVersion = VersionManager.read(app)
        }
    }

    /// Version this run would ship with the current field state — drives the
    /// "当前 → 将发布" preview under the target picker.
    private var plannedVersion: VersionPair? {
        ReleaseFormatting.previewVersion(
            current: currentVersion,
            marketing: showVersionFields ? marketingVersion : "",
            build: showVersionFields ? buildNumber : "")
    }

    /// Why the primary publish action is unavailable, in one sentence.
    /// nil when it isn't blocked (or the wizard is mid-run).
    private var publishBlockedReason: String? {
        guard !coordinator.isRunning else { return nil }
        if !versionInputValid {
            return "版本号格式有误:Marketing 需为数字版本号,Build 需为非负整数"
        }
        if preflightRunning { return "预检进行中…" }
        if steps.isEmpty { return "当前发布引擎没有可用的发布步骤" }
        if preflightChecks.isEmpty { return "等待预检结果…" }
        let failed = preflightChecks.filter { $0.status == .failed }
        if !failed.isEmpty {
            return "预检未通过(\(failed.count) 项失败):\(failed.map(\.title).joined(separator: "、")) — 修复后点「重新检查」"
        }
        return nil
    }

    private var hasBlockingPreflight: Bool {
        preflightChecks.isEmpty || preflightChecks.contains { $0.status == .failed }
    }

    private var versionInputValid: Bool {
        guard showVersionFields else { return true }
        let marketing = marketingVersion.trimmingCharacters(in: .whitespaces)
        let build = buildNumber.trimmingCharacters(in: .whitespaces)
        let marketingOK = marketing.isEmpty || marketing.range(
            of: #"^\d+(?:\.\d+){1,3}(?:[-+][0-9A-Za-z.-]+)?$"#,
            options: .regularExpression
        ) != nil
        let buildOK = build.isEmpty || (Int(build).map { $0 >= 0 } ?? false)
        return marketingOK && buildOK
    }

    private func refreshPreflight() {
        let app = app
        let target = target
        let data = catalogData
        preflightRunning = true
        Task {
            let checks = await Task.detached(priority: .userInitiated) {
                ReleasePreflight.run(app: app, target: target, catalog: data)
            }.value
            preflightChecks = checks
            preflightRunning = false
        }
    }

    private func preflightIcon(_ status: PreflightStatus) -> String {
        switch status {
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private func preflightColor(_ status: PreflightStatus) -> Color {
        switch status {
        case .passed: .green
        case .warning: .orange
        case .failed: .red
        }
    }
}
