import SwiftUI

// MARK: - 发现

struct FeedView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Group {
            // Only show a full-screen state once we actually know there's nothing to show;
            // before the first load the grid (with its loading footer) is the right thing.
            if store.papers.isEmpty && !store.loading
                && (store.errorMessage != nil || store.exhausted) {
                if let msg = store.errorMessage {
                    EmptyState(
                        icon: "bolt.horizontal.circle", title: "加载失败",
                        subtitle: msg + "\n后台没响应。打开设置（⌘,）可以重启或重装本机后台。",
                        actionTitle: "重试"
                    ) { Task { await store.refresh() } }
                } else if store.paperCount == 0 {
                    EmptyState(
                        icon: "arrow.down.circle", title: "还没有论文",
                        subtitle: "点「更新」抓最近 7 天的 arXiv 新论文并生成速览。第一次几百篇，大约十几分钟；以后每天早上点一次就行。",
                        actionTitle: "更新"
                    ) { store.triggerUpdate() }
                } else {
                    EmptyState(
                        icon: "sparkles", title: "今天的都刷完了",
                        subtitle: "明天再来，或者刷新试试", actionTitle: "刷新"
                    ) { Task { await store.refresh() } }
                }
            } else {
                MasonryGrid(papers: store.papers, onNearEnd: { Task { await store.loadMore() } }) {
                    feedFooter
                }
            }
        }
        .task {
            if store.papers.isEmpty { await store.loadMore() }
        }
    }

    @ViewBuilder
    private var feedFooter: some View {
        if store.loading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("加载中…")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.inkTertiary)
        } else if let msg = store.errorMessage {
            VStack(spacing: 8) {
                Text(msg).font(.system(size: 12)).foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                Button("重试") { Task { await store.loadMore() } }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        } else if store.exhausted {
            Text("今天的都刷完了 ✨")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkTertiary)
        }
    }
}

// MARK: - 收藏

struct SavedView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Group {
            if store.savedPapers.isEmpty {
                if store.savedLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let msg = store.savedError {
                    EmptyState(
                        icon: "wifi.exclamationmark", title: "加载失败",
                        subtitle: msg, actionTitle: "重试"
                    ) { Task { await store.loadSaved() } }
                } else {
                    EmptyState(
                        icon: "bookmark", title: "还没有收藏",
                        subtitle: "卡片上的书签、详情页底部或右键菜单都能收藏"
                    )
                }
            } else {
                MasonryGrid(papers: store.savedPapers, trackImpressions: false) {
                    EmptyView()
                }
            }
        }
        .task { await store.loadSaved() }
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var action: () -> Void = {}

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.inkTertiary)
                .padding(.bottom, 4)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 瀑布流

/// Multi-column masonry: each paper goes into the currently shortest column (by estimated height).
struct MasonryGrid<Footer: View>: View {
    @EnvironmentObject var store: AppStore
    let papers: [Paper]
    var trackImpressions = true
    var onNearEnd: () -> Void = {}
    @ViewBuilder var footer: () -> Footer

    private let spacing: CGFloat = 16
    private let padding: CGFloat = 20
    private let minColumnWidth: CGFloat = 250

    var body: some View {
        GeometryReader { geo in
            let usable = geo.size.width - padding * 2
            let columns = max(2, min(5, Int((usable + spacing) / (minColumnWidth + spacing))))
            let width = (usable - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let laid = distribute(columns: columns, width: width)
            let tail = Set(papers.suffix(columns * 2).map(\.id))
            ScrollView {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(0..<columns, id: \.self) { c in
                            LazyVStack(spacing: spacing) {
                                ForEach(laid[c]) { paper in
                                    PaperCard(paper: paper)
                                        .onAppear {
                                            if trackImpressions { store.impression(paper) }
                                            if tail.contains(paper.id) { onNearEnd() }
                                        }
                                }
                            }
                            .frame(width: width)
                        }
                    }
                    .padding(.horizontal, padding)
                    .padding(.top, 20)
                    footer()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                }
            }
        }
    }

    private func distribute(columns: Int, width: CGFloat) -> [[Paper]] {
        var cols = Array(repeating: [Paper](), count: columns)
        var heights = Array(repeating: CGFloat(0), count: columns)
        for paper in papers {
            let i = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            cols[i].append(paper)
            heights[i] += estimateHeight(paper, width: width) + spacing
        }
        return cols
    }

    /// Rough card height so columns stay balanced; only relative accuracy matters.
    private func estimateHeight(_ p: Paper, width: CGFloat) -> CGFloat {
        let inner = width - 28
        func lines(_ s: String, charWidth: CGFloat, max cap: Int) -> Int {
            var w: CGFloat = 0
            for scalar in s.unicodeScalars {
                w += scalar.value > 0x2E80 ? charWidth * 1.9 : charWidth // CJK is ~2x wide
            }
            return max(1, min(cap, Int((w / inner).rounded(.up))))
        }
        var h: CGFloat = 14 + 22 + 10 + 14 // cover paddings + chip row
        h += CGFloat(lines(p.title, charWidth: 8.3, max: 5)) * 20
        h += 12
        if !p.cardSummary.isEmpty {
            h += CGFloat(lines(p.cardSummary, charWidth: 6.8, max: 4)) * 18 + 8
        }
        if !p.tags.isEmpty { h += 18 + 8 }
        h += 24 + 12
        return h
    }
}

// MARK: - 卡片

struct PaperCard: View {
    @EnvironmentObject var store: AppStore
    let paper: Paper
    @State private var hovering = false

    private var cover: Theme.Cover { Theme.cover(for: paper.coverKey) }
    private var liked: Bool { store.likedIDs.contains(paper.id) }
    private var saved: Bool { store.savedIDs.contains(paper.id) }
    private var interpreted: Bool { paper.hasInterpretation || paper.interpretation != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            coverView
            VStack(alignment: .leading, spacing: 8) {
                if !paper.cardSummary.isEmpty {
                    Text(paper.cardSummary)
                        .font(.system(size: 13))
                        .lineSpacing(2.5)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !paper.tags.isEmpty {
                    Text(paper.tags.prefix(3).map { "#" + $0 }.joined(separator: "  "))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.topic)
                        .lineLimit(1)
                }
                footer
            }
            .padding(12)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(hovering ? 0.12 : 0.05), radius: hovering ? 16 : 6, y: hovering ? 8 : 2)
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.easeOut(duration: 0.18), value: hovering)
        .onHover { hovering = $0 }
        .linkPointer()
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { store.open(paper) }
        .contextMenu { menu }
    }

    private var coverView: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [cover.start, cover.end], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle()
                .fill(Color.white.opacity(0.35))
                .frame(width: 150, height: 150)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(x: 50, y: 60)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Chip(text: paper.primaryCategory, foreground: cover.ink.opacity(0.9), background: Color.white.opacity(0.55))
                    if let topic = paper.matchedTopic, !topic.isEmpty {
                        Chip(text: topic, icon: "star.fill", foreground: Theme.accent, background: Color.white.opacity(0.7))
                    }
                    if let labs = paper.affiliations, !labs.isEmpty {
                        Chip(text: labs.prefix(2).joined(separator: " · "), icon: "building.2",
                             foreground: cover.ink.opacity(0.9), background: Color.white.opacity(0.55))
                    }
                    if interpreted {
                        Chip(text: "已解读", icon: "sparkles", foreground: Theme.accent, background: Color.white.opacity(0.7))
                    }
                    Spacer(minLength: 0)
                    if hovering {
                        Button {
                            store.dislike(paper)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(cover.ink.opacity(0.7))
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(Color.white.opacity(0.6)))
                        }
                        .buttonStyle(.plain)
                        .help("不感兴趣")
                    }
                }
                Text(paper.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineSpacing(2)
                    .foregroundStyle(cover.ink)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
        }
        .frame(minHeight: 118)
        .clipped()
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Text(paper.authorInitial)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(cover.accent))
            Text(paper.authorLabel)
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if let citations = paper.citationCount {
                HStack(spacing: 3) {
                    Image(systemName: "quote.opening").font(.system(size: 9, weight: .semibold))
                    Text(citations.formatted())
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.inkTertiary)
                .help("引用数（Semantic Scholar）")
            }
            Text(paper.displayDate)
                .font(.system(size: 11))
                .foregroundStyle(Theme.inkTertiary)
            if saved || hovering {
                IconToggle(systemName: "bookmark", filled: saved) { store.toggleSave(paper) }
                    .help(saved ? "取消收藏" : "收藏")
            }
            IconToggle(systemName: "heart", filled: liked) { store.toggleLike(paper) }
                .help(liked ? "取消喜欢" : "喜欢")
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button(liked ? "取消喜欢" : "喜欢") { store.toggleLike(paper) }
        Button(saved ? "取消收藏" : "收藏") { store.toggleSave(paper) }
        Button("不感兴趣") { store.dislike(paper) }
        Divider()
        Button("在 arXiv 打开") { store.openURL(paper.absUrl) }
        Button("打开 PDF") { store.openURL(paper.pdfUrl) }
        Divider()
        Button("复制标题") { store.copy(paper.title) }
        Button("复制 arXiv ID") { store.copy(paper.id) }
    }
}
