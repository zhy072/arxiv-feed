import SwiftUI

/// Centred modal over the feed, like a social app's post view: cover panel on the left,
/// TL;DR / interpretation / abstract on the right, actions along the bottom.
struct DetailOverlay: View {
    @EnvironmentObject var store: AppStore
    let paper: Paper

    @State private var interpretation: String?
    @State private var generating = false
    @State private var errorMessage: String?
    @State private var openedAt = Date()

    private var cover: Theme.Cover { Theme.cover(for: paper.coverKey) }
    private var liked: Bool { store.likedIDs.contains(paper.id) }
    private var saved: Bool { store.savedIDs.contains(paper.id) }

    private var authorsText: String {
        let shown = paper.authors.prefix(12).joined(separator: ", ")
        return paper.authors.count > 12 ? shown + " 等 \(paper.authors.count) 人" : shown
    }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 960
            ZStack {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { store.closeDetail() }
                VStack(spacing: 0) {
                    if wide {
                        HStack(spacing: 0) {
                            sidePanel.frame(width: 320)
                            content
                        }
                    } else {
                        VStack(spacing: 0) {
                            compactHeader
                            content
                        }
                    }
                    Divider().overlay(Theme.divider)
                    actionBar
                }
                .frame(width: min(geo.size.width - 72, 1080), height: geo.size.height - 56)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 32, y: 12)
                .overlay(alignment: .topTrailing) {
                    IconButton(systemName: "xmark", help: "关闭 (Esc)", size: 28) { store.closeDetail() }
                        .padding(10)
                }
            }
        }
        .onExitCommand { store.closeDetail() }
        .onAppear {
            openedAt = Date()
            store.event("click", paper)
            interpretation = paper.interpretation
            // Only fetch what's already cached on the backend; a fresh deep-read is a button press.
            if interpretation == nil && paper.hasInterpretation { generate() }
        }
        .onDisappear {
            let seconds = Date().timeIntervalSince(openedAt)
            store.event("dwell", paper, value: seconds.rounded())
        }
    }

    // MARK: - left / top panel

    private var categoryChips: some View {
        HStack(spacing: 6) {
            ForEach(paper.categories.prefix(3), id: \.self) { cat in
                Chip(text: cat, foreground: cover.ink.opacity(0.9), background: Color.white.opacity(0.55))
            }
        }
    }

    private var sidePanel: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [cover.start, cover.end], startPoint: .top, endPoint: .bottom)
            Circle()
                .fill(Color.white.opacity(0.35))
                .frame(width: 260, height: 260)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(x: 90, y: 90)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    categoryChips
                    Text(paper.title)
                        .font(.system(size: 20, weight: .bold))
                        .lineSpacing(3)
                        .foregroundStyle(cover.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text(authorsText)
                        .font(.system(size: 12.5))
                        .lineSpacing(2)
                        .foregroundStyle(cover.ink.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    HStack(spacing: 5) {
                        Image(systemName: "calendar")
                        Text(paper.publishedDay)
                        Text("·")
                        Text(paper.id)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(cover.ink.opacity(0.6))
                    if paper.citationCount != nil || !(paper.affiliations ?? []).isEmpty {
                        HStack(spacing: 10) {
                            if let citations = paper.citationCount {
                                Label("\(citations.formatted()) 引用", systemImage: "quote.opening")
                            }
                            if let labs = paper.affiliations, !labs.isEmpty {
                                Label(labs.joined(separator: " · "), systemImage: "building.2")
                            }
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(cover.ink.opacity(0.7))
                    }
                    HStack(spacing: 8) {
                        linkPill("arXiv", "safari", paper.absUrl)
                        linkPill("PDF", "doc.text", paper.pdfUrl)
                    }
                    .padding(.top, 4)
                }
                .padding(22)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .clipped()
    }

    private var compactHeader: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [cover.start, cover.end], startPoint: .leading, endPoint: .trailing)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    categoryChips
                    Spacer()
                    linkPill("arXiv", "safari", paper.absUrl)
                    linkPill("PDF", "doc.text", paper.pdfUrl)
                }
                .padding(.trailing, 34) // keep clear of the close button
                Text(paper.title)
                    .font(.system(size: 18, weight: .bold))
                    .lineSpacing(2)
                    .foregroundStyle(cover.ink)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(authorsText + "  ·  " + paper.publishedDay)
                    .font(.system(size: 12))
                    .foregroundStyle(cover.ink.opacity(0.75))
                    .lineLimit(2)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func linkPill(_ title: String, _ icon: String, _ url: String) -> some View {
        Button {
            store.openURL(url)
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(cover.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.white.opacity(0.65)))
        }
        .buttonStyle(.plain)
        .linkPointer()
    }

    // MARK: - right panel

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let tldr = paper.tldr, !tldr.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("速览", systemImage: "bolt.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.accent)
                        Text(tldr)
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .foregroundStyle(Theme.ink)
                            .textSelection(.enabled)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent.opacity(0.07)))
                }
                if !paper.tags.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(paper.tags, id: \.self) { tag in
                            Chip(text: "#" + tag, foreground: Theme.topic, background: Theme.topic.opacity(0.1))
                        }
                    }
                }
                if !(paper.task ?? "").isEmpty || !(paper.method ?? "").isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if let task = paper.task, !task.isEmpty { metaRow("任务", task) }
                        if let method = paper.method, !method.isEmpty { metaRow("方法", method) }
                    }
                }

                sectionHeader("深度解读")
                interpretationBody

                if let abstract = paper.abstract, !abstract.isEmpty {
                    sectionHeader("原文摘要")
                    Text(abstract)
                        .font(.system(size: 13.5))
                        .lineSpacing(4)
                        .foregroundStyle(Theme.inkSecondary)
                        .textSelection(.enabled)
                }
            }
            .padding(24)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var interpretationBody: some View {
        if let text = interpretation {
            MarkdownView(text: text)
        } else if generating {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在用 Codex 通读全文生成解读（xhigh 推理，通常要几分钟），可以先看下面的摘要…")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkSecondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surfaceSecondary))
        } else if let msg = errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Text("解读生成失败")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
                    .textSelection(.enabled)
                Button("重试") { generate() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surfaceSecondary))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("速览不够用的话，再让 Codex 通读全文做精读（xhigh 推理，通常要几分钟，结果会缓存）。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkSecondary)
                Button {
                    generate()
                } label: {
                    Label("生成深度解读", systemImage: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Theme.accent))
                }
                .buttonStyle(.plain)
                .linkPointer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surfaceSecondary))
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 4, height: 16)
            Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
        }
        .padding(.top, 4)
    }

    private func metaRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
                .frame(width: 30, alignment: .leading)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
        }
    }

    // MARK: - bottom bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            actionButton(liked ? "已喜欢" : "喜欢", icon: liked ? "heart.fill" : "heart", active: liked) {
                store.toggleLike(paper)
            }
            actionButton(saved ? "已收藏" : "收藏", icon: saved ? "bookmark.fill" : "bookmark", active: saved) {
                store.toggleSave(paper)
            }
            actionButton("不感兴趣", icon: "hand.thumbsdown", active: false) {
                store.dislike(paper)
            }
            Spacer()
            Button("关闭") { store.closeDetail() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.surface)
    }

    private func actionButton(_ title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? Theme.accent : Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(active ? Theme.accent.opacity(0.12) : Theme.surfaceSecondary))
        }
        .buttonStyle(.plain)
        .linkPointer()
    }

    private func generate() {
        generating = true
        errorMessage = nil
        Task {
            do {
                interpretation = try await store.interpret(paper)
            } catch {
                errorMessage = error.localizedDescription
            }
            generating = false
        }
    }
}
