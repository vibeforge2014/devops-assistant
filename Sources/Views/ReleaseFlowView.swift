import SwiftUI

/// One-click release wizard. Choose a target (TestFlight / App Store / macOS
/// notarized distribution), optionally set the marketing version, then run the
/// pipeline. Steps render live with success/failure states; the console below
/// mirrors output in real time. Failures stop the pipeline at the offending
/// step so no work is wasted on top of a broken build.
struct ReleaseFlowView: View {
    let app: AppProject
    @Environment(\.dismiss) private var dismiss

    @StateObject private var runner = ShellRunner()
    @StateObject private var coordinator: ReleaseCoordinator

    @State private var target: ReleaseTarget = .testFlight
    @State private var marketingVersion = ""
    @State private var buildNumber = ""
    @State private var showVersionFields = false

    init(app: AppProject) {
        self.app = app
        let runner = ShellRunner()
        _runner = StateObject(wrappedValue: runner)
        _coordinator = StateObject(wrappedValue: ReleaseCoordinator(app: app, runner: runner))
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
                Button("取消") { coordinator.cancellationRequested = true }
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
                ForEach(ReleaseTarget.allCases) { t in
                    Text(t.title).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .disabled(coordinator.isRunning)
            .onChange(of: target) { _ in
                // Reset step state when switching targets.
                coordinator.resetSteps()
            }

            Text(steps.map(\.title).joined(separator: " → "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Version fields

    private var versionFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("2. 版本号").font(.headline)
            HStack(spacing: 12) {
                TextField("Marketing(可选,如 1.2.3)", text: $marketingVersion)
                    .textFieldStyle(.roundedBorder)
                TextField("Build(可选,默认 +1)", text: $buildNumber)
                    .textFieldStyle(.roundedBorder)
            }
            Text("留空则保持当前版本,仅 build 号 +1")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Steps

    private var stepsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("3. 执行步骤").font(.headline)
                Spacer()
                Button(showVersionFields ? "发布" : "发布(仅 bump build)") {
                    runRelease()
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.isRunning)
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
}
