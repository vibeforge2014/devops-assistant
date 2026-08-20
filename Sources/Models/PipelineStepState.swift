import SwiftUI

/// State of one step in a release/publish pipeline, shared by the app
/// (`ReleaseCoordinator`) and site (`SitePublishCoordinator`) flows so their
/// wizards render identical step rows.
enum PipelineStepState: Equatable {
    case idle, running, succeeded, failed(String)

    var icon: String {
        switch self {
        case .idle: "circle"
        case .running: "arrow.triangle.2.circlepath"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .idle: .secondary
        case .running: .blue
        case .succeeded: .green
        case .failed: .red
        }
    }
}

/// Outcome of one pipeline attempt. `.nothingToPublish` is site-specific: the
/// working tree was clean with nothing ahead of upstream, so the pipeline
/// stopped before touching the remote — not a failure, not a shipped release.
enum PipelineOutcome: Equatable {
    case success
    case failed(String)   // step title (or short reason)
    case cancelled
    case nothingToPublish
}
