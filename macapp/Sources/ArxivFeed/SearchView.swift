import SwiftUI

/// 精搜: search a topic over a time window, ranked by citations or by big labs / groups.
struct SearchView: View {
    @EnvironmentObject var store: AppStore
    @FocusState private var focused: Bool

    private let windows: [(months: Int, label: String)] = [
        (3, "3 个月"), (6, "6 个月"), (12, "1 年"), (24, "2 年"), (36, "3 年"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Theme.surface)
            Divider().overlay(Theme.divider)
            content
        }
        .onAppear {
            if store.searchResult == nil { focused = true }
        }
    }

    // MARK: - controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Theme.inkTertiary)
                    TextField("想精搜的方向，比如：视频生成模型 / 全双工语音 / 视频量化", text: $store.searchTopic)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.ink)
                        .focused($focused)
                        .onSubmit { store.runSearch() }
                    if !store.searchTopic.isEmpty {
                        Button {
                            store.searchTopic = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.inkTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Theme.surfaceSecondary))

                Button {
                    store.runSearch()
                } label: {
                    HStack(spacing: 6) {
                        if store.searching {
                            ProgressView().controlSize(.mini)
                        }
                        Text(store.searching ? "搜索中" : "精搜")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(store.searching ? Theme.inkTertiary : Theme.accent))
                }
                .buttonStyle(.plain)
                .disabled(store.searching)
                .linkPointer()
            }

            HStack(spacing: 14) {
                pillGroup("时间", items: windows.map { ($0.label, $0.months == store.searchMonths) }) { i in
                    store.searchMonths = windows[i].months
                }
                Spacer()
                pillGroup("排序", items: [
                    ("按引用量", store.searchSort == .citations),
                    ("按大厂 / 大组", store.searchSort == .labs),
                ]) { i in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        store.searchSort = i == 0 ? .citations : .labs
                    }
                }
            }

            if let result = store.searchResult {
                statusLine(result)
            }
        }
    }

    private func pillGroup(_ label: String, items: [(String, Bool)], select: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkTertiary)
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                Button {
                    select(i)
                } label: {
                    Text(item.0)
                        .font(.system(size: 12, weight: item.1 ? .semibold : .medium))
                        .foregroundStyle(item.1 ? Theme.accent : Theme.inkSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(item.1 ? Theme.accent.opacity(0.12) : Theme.surfaceSecondary))
                }
                .buttonStyle(.plain)
                .linkPointer()
            }
        }
    }

    private func statusLine(_ result: SearchResponse) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let intent = result.intent, !intent.isEmpty, intent != result.topic {
                HStack(spacing: 6) {
                    Text("理解为").foregroundStyle(Theme.inkTertiary)
                    Text(intent).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                }
            }
            HStack(spacing: 6) {
                Text("检索式").foregroundStyle(Theme.inkTertiary)
                Text(result.query ?? result.topic)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button {
                    store.editSearchPhrases()
                } label: {
                    Image(systemName: "pencil").foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .linkPointer()
                .help("把检索式放进搜索框，用 | 分隔改好后直接搜（不再经过翻译）")
                Text("·").foregroundStyle(Theme.inkTertiary)
                if !result.filtered {
                    ProgressView().controlSize(.mini)
                    Text("Codex 正在按你的方向精筛 \(result.papers.count) 篇候选…")
                        .foregroundStyle(Theme.accent)
                } else {
                    Text("相关 \(result.total ?? result.papers.count) 篇，按引用取了 \(result.papers.count) 篇")
                        .foregroundStyle(Theme.inkTertiary)
                        .lineLimit(1)
                    if result.active {
                        Text("·").foregroundStyle(Theme.inkTertiary)
                        ProgressView().controlSize(.mini)
                        Text("速览 / 机构生成中 \(result.pending) 篇").foregroundStyle(Theme.accent)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 11.5))
    }

    // MARK: - results

    @ViewBuilder
    private var content: some View {
        if let msg = store.searchError {
            EmptyState(icon: "exclamationmark.triangle", title: "搜索失败", subtitle: msg, actionTitle: "重试") {
                store.runSearch()
            }
        } else if store.searching && store.searchResult == nil {
            VStack(spacing: 12) {
                ProgressView()
                Text("Codex 正在把方向翻成英文检索词，然后在 arXiv 上找这段时间最相关的工作…")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result = store.searchResult {
            if result.papers.isEmpty {
                EmptyState(
                    icon: "doc.text.magnifyingglass", title: "没搜到 arXiv 上的相关工作",
                    subtitle: "换个说法，或者把时间范围拉长试试"
                )
            } else {
                MasonryGrid(papers: store.searchPapers, trackImpressions: false) {
                    EmptyView()
                }
            }
        } else {
            idleState
        }
    }

    private var idleState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.inkTertiary)
            Text("输入一个方向，精搜近几个月到三年内的高引 / 大厂工作")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.ink)
            Text("中文直接输；想自己指定英文检索词就用 | 分隔，如 video diffusion quantization | W4A4 diffusion。结果先给速览，点开再决定要不要精读。")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.inkSecondary)
            if !store.recentSearches.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(store.recentSearches, id: \.self) { topic in
                        Button {
                            store.searchTopic = topic
                            store.runSearch()
                        } label: {
                            Chip(text: topic, icon: "clock", foreground: Theme.inkSecondary, background: Theme.surfaceSecondary)
                        }
                        .buttonStyle(.plain)
                        .linkPointer()
                    }
                }
                .frame(maxWidth: 520)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
