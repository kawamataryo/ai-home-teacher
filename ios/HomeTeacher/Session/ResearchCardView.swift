import SwiftUI

/// 調べものカード（#115）。何を、どこで調べているかを見せる。答えを話し始めたら小さくして、調べたサイトだけを残す。
struct ResearchCardView: View {
    let status: ResearchStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if status.isCompact { compact } else { full }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .animation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.2), value: status)
    }

    private var full: some View {
        HStack(alignment: .top, spacing: 16) {
            ResearchIndicator(status: status)
            VStack(alignment: .leading, spacing: 8) {
                Text(status.headline)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Self.ink)
                    .contentTransition(.opacity)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if !status.query.isEmpty {
                    Text("「\(status.query)」")
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundStyle(Self.inkSoft)
                        .lineLimit(2)
                }
                if status.phase != .failed {
                    ResearchSiteRow(status: status)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .background(Self.paper, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Self.edge, lineWidth: 2))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    private var compact: some View {
        HStack(spacing: 10) {
            HStack(spacing: -8) {
                ForEach(status.sites.prefix(3)) { site in
                    ResearchFavicon(site: site, size: 28)
                }
            }
            Text(status.headline)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Self.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(Self.paper, in: Capsule())
        .overlay(Capsule().strokeBorder(Self.edge, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
    }

    private var accessibilityText: String {
        let sites = status.sites.map(\.name).joined(separator: "、")
        return [status.headline, status.query, sites].filter { !$0.isEmpty }.joined(separator: "。")
    }

    static let ink = Color(red: 0.16, green: 0.20, blue: 0.27)
    static let inkSoft = Color(red: 0.36, green: 0.41, blue: 0.48)
    static let paper = Color(red: 1.0, green: 0.99, blue: 0.96)
    static let edge = Color(red: 0.92, green: 0.86, blue: 0.72)
}

/// 虫めがね。探している間はゆっくり動き、見つかったらチェックに変わる
private struct ResearchIndicator: View {
    let status: ResearchStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var symbol: String {
        switch status.phase {
        case .searching, .slow: "magnifyingglass"
        case .found, .answered: "checkmark"
        case .failed: "questionmark"
        }
    }

    private var tint: Color {
        switch status.phase {
        case .searching, .slow: Color(red: 0.20, green: 0.48, blue: 0.86)
        case .found, .answered: Color(red: 0.16, green: 0.62, blue: 0.40)
        case .failed: Color(red: 0.85, green: 0.52, blue: 0.16)
        }
    }

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.14))
            if status.isWorking, !reduceMotion {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    Image(systemName: symbol)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(tint)
                        .offset(x: cos(t * 2.6) * 6, y: sin(t * 2.6) * 6)
                }
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(tint)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 64, height: 64)
    }
}

/// 見つかったサイトを 1 つずつ見せる。見つかるまでは、これから出てくる場所を薄く出しておく
private struct ResearchSiteRow: View {
    let status: ResearchStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visibleCount = 0

    private static let maxSites = 4

    private var sites: [ResearchSite] { Array(status.sites.prefix(Self.maxSites)) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(sites.count)
            row(min(sites.count, 3))
            row(min(sites.count, 2))
            row(min(sites.count, 1))
        }
        .frame(minHeight: 40, alignment: .leading)
        .task(id: status.sites) { await reveal() }
    }

    private func row(_ limit: Int) -> some View {
        HStack(spacing: 8) {
            if sites.isEmpty {
                ForEach(0..<3, id: \.self) { index in
                    ResearchPlaceholder(index: index)
                }
            } else {
                ForEach(Array(sites.prefix(limit).enumerated()), id: \.element.id) { index, site in
                    if index < visibleCount {
                        ResearchSiteChip(site: site)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                // 入りきらないサイトも、数だけ伝える
                if status.sites.count > limit, visibleCount >= limit {
                    Text("ほか\(status.sites.count - limit)つ")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(ResearchCardView.inkSoft)
                        .fixedSize()
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.35), value: visibleCount)
    }

    private func reveal() async {
        guard !reduceMotion else {
            visibleCount = sites.count
            return
        }
        while visibleCount < sites.count {
            visibleCount += 1
            try? await Task.sleep(for: .milliseconds(180))
            if Task.isCancelled { return }
        }
    }
}

private struct ResearchSiteChip: View {
    let site: ResearchSite

    var body: some View {
        HStack(spacing: 6) {
            ResearchFavicon(site: site, size: 26)
            Text(site.name)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(ResearchCardView.ink)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.vertical, 6)
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .background(Color.white, in: Capsule())
        .overlay(Capsule().strokeBorder(ResearchCardView.edge, lineWidth: 1))
    }
}

/// サイトが見つかるまでの薄いしるし。順番に明るくなる
private struct ResearchPlaceholder: View {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = reduceMotion ? 0.5 : (sin(t * 3.2 - Double(index) * 0.8) + 1) / 2
            Capsule()
                .fill(ResearchCardView.edge.opacity(0.35 + pulse * 0.45))
                .frame(width: 92, height: 38)
        }
    }
}

/// サイトの favicon。取れないときは頭文字を出す
struct ResearchFavicon: View {
    let site: ResearchSite
    let size: CGFloat

    var body: some View {
        AsyncImage(url: site.faviconURL) { phase in
            if case .success(let image) = phase {
                image.resizable().interpolation(.high).scaledToFit().padding(size * 0.1)
            } else {
                Text(site.initial)
                    .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                    .foregroundStyle(ResearchCardView.inkSoft)
            }
        }
        .frame(width: size, height: size)
        .background(Color.white, in: Circle())
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(ResearchCardView.edge, lineWidth: 1))
    }
}
