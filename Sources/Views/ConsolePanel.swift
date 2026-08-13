import AppKit
import SwiftUI

/// A live terminal-style console that mirrors the ShellRunner's output stream.
/// Designed to be embedded at the bottom of any operation view. Renders meta
/// lines distinctly and auto-scrolls to the newest line.
struct ConsolePanel: View {
    /// The runner whose output this console mirrors. Injected explicitly (not
    /// via environment) so each project/site owns an isolated console and
    /// concurrent operations in different views never cross-talk (M1).
    @ObservedObject var runner: ShellRunner
    @State private var didCopy = false

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
                }
                Button {
                    copyLogs()
                } label: {
                    Label(didCopy ? "已复制" : "复制日志",
                          systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .disabled(runner.lines.isEmpty)
                .help("复制全部日志")

                if !runner.isRunning {
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
                    VStack(alignment: .leading, spacing: 0) {
                        Text(attributedLog)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Color.clear
                            .frame(height: 1)
                            .id("console-bottom")
                    }
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
                .onChange(of: runner.lines.last?.id) { _, last in
                    if last != nil { proxy.scrollTo("console-bottom", anchor: .bottom) }
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

    private var plainLog: String {
        runner.lines.map(\.text).joined(separator: "\n")
    }

    private var attributedLog: AttributedString {
        var result = AttributedString()
        for (index, line) in runner.lines.enumerated() {
            var segment = AttributedString(line.text.isEmpty ? " " : line.text)
            segment.foregroundColor = color(for: line)
            result.append(segment)
            if index < runner.lines.count - 1 {
                result.append(AttributedString("\n"))
            }
        }
        return result
    }

    private func copyLogs() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(plainLog, forType: .string)

        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }
}
