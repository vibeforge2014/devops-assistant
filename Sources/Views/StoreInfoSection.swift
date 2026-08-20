import SwiftUI

/// The "App Store 信息" block on an app's detail page: storefront prices,
/// current version/rating, and the full in-app purchase list (including
/// auto-renewable subscriptions) with CN/US prices and review states.
/// Read-only; safe to browse while a release runs in the background.
struct StoreInfoSection: View {
    @EnvironmentObject private var storeInfo: AppStoreInfoService
    let app: AppProject

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            switch storeInfo.state(for: app) {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在获取 App Store 信息…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 16)

            case .failed(let reason):
                failureView(reason)

            case .idle, .loaded:
                if let info = storeInfo.info(for: app) {
                    contentView(info)
                } else {
                    // Idle with nothing cached (first open of this app).
                    HStack {
                        Text("尚未获取")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("获取") { Task { await storeInfo.refresh(app) } }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        .onAppear { storeInfo.refreshIfNeeded(app) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cart")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("App Store 信息").font(.headline)
                if let info = storeInfo.info(for: app) {
                    Text("更新于 \(info.fetchedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let url = storeInfo.info(for: app)?.storeURL, let link = URL(string: url) {
                Link(destination: link) {
                    Label("在 App Store 查看", systemImage: "safari")
                }
                .buttonStyle(.borderless)
            }
            if storeInfo.state(for: app) == .loading {
                EmptyView()
            } else {
                Button {
                    Task { await storeInfo.refresh(app) }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func contentView(_ info: StoreAppInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                if info.isLive {
                    priceBadge(info.priceSummary)
                    versionRatingLine(info)
                } else if info.storeFetchFailed {
                    // The lookups themselves died (network/proxy) — must not
                    // read as "not released".
                    Label("售价获取失败(店面查询未成功)",
                          systemImage: "wifi.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Label("未上架 — App Store 查无此应用(尚未发布或仅在部分店面)",
                          systemImage: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !info.appPrices.isEmpty {
                        priceBadge(info.priceSummary)
                    }
                }
            }

            Divider()

            if info.inAppPurchases.isEmpty {
                Text(info.ascAppName == nil && !info.isLive
                     ? "App Store Connect 中未找到该 bundle id 的应用记录"
                     : "无内购项目")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("内购 \(info.inAppPurchases.count) 项")
                    .font(.subheadline.weight(.medium))
                let failedPrices = info.inAppPurchases.filter(\.priceFetchFailed).count
                if failedPrices > 0 {
                    Text("\(failedPrices) 项价格获取失败(网络或限流),可点击刷新重试")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                VStack(spacing: 6) {
                    ForEach(info.inAppPurchases) { purchase in
                        iapRow(purchase)
                    }
                }
            }
        }
    }

    private func priceBadge(_ summary: String) -> some View {
        Text(summary)
            .font(.subheadline.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private func versionRatingLine(_ info: StoreAppInfo) -> some View {
        HStack(spacing: 6) {
            if let version = info.currentVersion {
                Text("v\(version)")
            }
            if let rating = info.rating {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                Text(String(format: "%.1f", rating))
                if let count = info.ratingCount {
                    Text("(\(count.formatted()))").foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func iapRow(_ purchase: IAPInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(purchase.name).font(.subheadline.weight(.medium))
                    kindTag(purchase)
                    if let period = purchase.periodLabel {
                        Text(period)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(purchase.productId)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(purchase.priceSummary)
                    .font(.caption.monospacedDigit())
                stateTag(purchase.state)
            }
        }
        .padding(.vertical, 2)
    }

    private func kindTag(_ purchase: IAPInfo) -> some View {
        Text(purchase.kind.displayName)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(purchase.kind == .autoRenewable ? Color.indigo.opacity(0.15) : Color.orange.opacity(0.15),
                        in: Capsule())
            .foregroundStyle(purchase.kind == .autoRenewable ? .indigo : .orange)
    }

    @ViewBuilder
    private func stateTag(_ raw: String) -> some View {
        let label = IAPStateInfo.label(for: raw)
        Text(label)
            .font(.caption2)
            .foregroundStyle(stateColor(raw))
            .help("审核状态: \(raw)")
    }

    private func stateColor(_ raw: String) -> Color {
        if IAPStateInfo.isLive(raw) { return .green }
        if IAPStateInfo.isProblem(raw) { return .red }
        return .secondary
    }

    // MARK: - Failure

    private func failureView(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button("重试") { Task { await storeInfo.refresh(app) } }
                .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
