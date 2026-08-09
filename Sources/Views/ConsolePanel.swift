import SwiftUI

/// A live terminal-style console that mirrors the ShellRunner's output stream.
/// Designed to be embedded at the bottom of any operation view. Renders meta
/// lines distinctly and auto-scrolls to the newest line.
struct ConsolePanel: View {
    /// The runner whose output this console mirrors. Injected explicitly (not
    /// via environment) so each project/site owns an isolated console and
    /// concurrent operations in different views never cross-talk (M1).
    @ObservedObject var runner: ShellRunner

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("控制台", systemImage: "terminal")
                    .font(.headline)
                Spacer()
                if runner.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text("运行中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("清空") { runner.clear() }
                        .buttonStyle(.borderless)
                        .disabled(runner.lines.isEmpty)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(runner.lines) { line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(color(for: line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
                .onChange(of: runner.lines.last?.id) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
        .background(.regularMaterial)
    }

    private func color(for line: LogLine) -> Color {
        switch line.stream {
        case .meta: .secondary
        case .stdout: .primary
        case .stderr: .red.opacity(0.85)
        }
    }
}
