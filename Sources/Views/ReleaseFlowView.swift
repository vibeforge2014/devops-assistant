import SwiftUI

/// One-click release wizard. Choose a target (TestFlight / App Store / macOS
/// notarized distribution), optionally set the marketing version, then run the
/// pipeline. Steps render live with success/failure states; the console below
/// mirrors output in real time. Failures stop the pipeline at the offending
/// step so no work is wasted on top of a broken build.
struct ReleaseFlowView: View {
    let app: AppProject
    private let catalogData: ProjectCatalogData
    @Environment(\.dismiss) private var dismiss

    @StateObject private var runner = ShellRunner()
    @StateObject private var coordinator: ReleaseCoordinator

    @State private var target: ReleaseTarget = .testFlight
    @State private var marketingVersion = ""
    @State private var buildNumber = ""
    @State private var showVersionFields = false
    @State private var preflightChecks: [PreflightCheck] = []
    @State private var preflightRunning = false

    /// `catalog` & `historyStore` are passed in (rather than read via
    /// @EnvironmentObject) because the coordinator is built in `init`, before
    /// the environment is available — and the coordinator must own the same
    /// `runner` the console binds to, so it can't be rebuilt later.
    init(app: AppProject, catalog: ProjectCatalog, historyStore: HistoryStore) {
        self.app = app
        self.catalogData = catalog.data
        let runner = ShellRunner()
        let firstTarget = ReleaseTarget.available(for: app).first ?? .testFlight
        _runner = StateObject(wrappedValue: runner)
        _target = State(initialValue: firstTarget)
        _coordinator = StateObject(wrappedValue: ReleaseCoordinator(
            app: app, runner: runner, catalog: catalog, historyStore: historyStore))
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
            ConsolePanel(runner: runner)
                .frame(height: 180)
        }
        .frame(width: 640, height: 720)
        .onAppear { refreshPreflight() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("发布 \(app.name)").font(.title2.bold())
                Text(coordinator.isRunning ? "运行中…" : finishedLabel)
                    .font(.caption)
                    .foregroundStyle(coordinator.isRunning ? .blue : .secondary)
            }
            Spacer()
            if coordinator.isRunning {
                Button("取消") { coordinator.cancel() }
                    .buttonStyle(.bordered)
            } else {
                Button("关闭") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.regularMaterial)
    }

    private var finishedLabel: String {
        let done = coordinator.completedSteps.count
        let total = steps.count
        if total == 0 { return "选择目标后运行" }
        return "\(done)/\(total) 步完成"
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
                // Reset step state when switching targets.
                coordinator.resetSteps()
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
                Text("4. 执行步骤").font(.headline)
                Spacer()
                Button(showVersionFields ? "发布" : "发布(仅 bump build)") {
                    runRelease()
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.isRunning || steps.isEmpty || preflightRunning ||
                          hasBlockingPreflight || !versionInputValid)
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
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Actions

    private func runRelease() {
        guard !hasBlockingPreflight, versionInputValid else { return }
        // Build the target version pair from the fields (if marketing given).
        var version: VersionPair? = nil
        let mkt = marketingVersion.trimmingCharacters(in: .whitespaces)
        let bld = buildNumber.trimmingCharacters(in: .whitespaces)
        if !mkt.isEmpty || !bld.isEmpty {
            version = VersionPair(
                marketing: mkt.isEmpty ? (VersionManager.read(app)?.marketing ?? "") : mkt,
                build: bld.isEmpty ? (VersionManager.read(app)?.build ?? "1") : bld
            )
        }
        Task {
            await coordinator.run(target: target, version: version)
        }
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
