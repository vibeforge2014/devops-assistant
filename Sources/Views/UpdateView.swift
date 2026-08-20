import SwiftUI

/// The update sheet: renders whatever phase the controller is in — a new
/// version with its release notes, progress through download/verify/
/// install, or the outcome of a manual check.
struct UpdateView: View {
    @EnvironmentObject private var controller: UpdateController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)

            actionBar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.regularMaterial)
                .overlay(alignment: .top) { Divider() }
        }
        .frame(width: 460)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("软件更新")
                    .font(.headline)
                Text("当前版本 \(controller.currentVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle, .checking:
            checkingView
        case .upToDate:
            upToDateView
        case .available(let info):
            availableView(info)
        case .downloading, .verifying, .installing:
            progressView
        case .failed(let message):
            failedView(message)
        }
    }

    private var checkingView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("正在检查更新…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var upToDateView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("已是最新版本", systemImage: "checkmark.seal.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
            Text("GitHub 上的最新发布就是当前运行的 \(controller.currentVersion)。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private func availableView(_ info: AppUpdateInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("发现新版本 \(info.version)")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: info.assetSize, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let date = info.publishedAt {
                Text("发布于 \(date.formatted(.dateTime.year().month().day()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let notes = info.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                ScrollView {
                    Text(notes)
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(0.88))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 230)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    private var progressView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(progressLabel)
                .font(.callout)
        }
        .padding(.vertical, 8)
    }

    private var progressLabel: String {
        switch controller.phase {
        case .downloading:
            let size = controller.latest
                .map { ByteCountFormatter.string(fromByteCount: $0.assetSize, countStyle: .file) } ?? ""
            return size.isEmpty ? "正在下载新版本…" : "正在下载新版本(约 \(size))…"
        case .verifying:
            return "正在验证 Apple 公证签名…"
        case .installing:
            return "正在安装,应用即将重启…"
        default:
            return ""
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("更新未完成", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: 10) {
            switch controller.phase {
            case .available(let info):
                if info.htmlURL != nil {
                    Button {
                        controller.openReleasePage(info)
                    } label: {
                        Label("前往 GitHub", systemImage: "safari")
                    }
                }
                Spacer()
                Button("稍后") { dismiss() }
                Button("立即更新") { controller.downloadAndInstall() }
                    .buttonStyle(.borderedProminent)
            case .idle, .checking:
                Spacer()
                Button("隐藏") { dismiss() }
            case .upToDate:
                Spacer()
                Button("好") { dismiss() }
            case .downloading:
                Spacer()
                Button("取消") {
                    controller.cancelDownload()
                    dismiss()
                }
            case .verifying, .installing:
                // Seconds away from relaunch — no dismissal offered.
                Spacer()
            case .failed:
                Button("重试") { controller.retry() }
                Spacer()
                Button("好") { dismiss() }
            }
        }
    }
}
