import AppKit
import SwiftUI

/// Top bar in the style of a social feed: wordmark on the left, "发现 / 收藏" tabs centred, tools on the right.
struct HeaderBar: View {
    @EnvironmentObject var store: AppStore
    @Namespace private var underline

    var body: some View {
        ZStack {
            HStack(spacing: 6) {
                logo
                Spacer()
                if store.loading && !store.papers.isEmpty {
                    ProgressView().controlSize(.small).padding(.trailing, 4)
                }
                updateButton
                    .padding(.trailing, 6)
                IconButton(
                    systemName: "arrow.clockwise", help: "刷新 (⌘R)",
                    shortcut: KeyboardShortcut("r", modifiers: .command)
                ) {
                    Task { await store.refresh() }
                }
                .disabled(store.loading)
                IconButton(
                    systemName: "gearshape", help: "设置 (⌘,)",
                    shortcut: KeyboardShortcut(",", modifiers: .command)
                ) {
                    store.showSettings = true
                }
            }
            HStack(spacing: 30) {
                tabButton("发现", .discover)
                tabButton("精搜", .search)
                tabButton("收藏", .saved)
            }
        }
        .padding(.leading, 84) // room for the traffic lights
        .padding(.trailing, 12)
        .padding(.bottom, 9) // nudges the row up towards the traffic lights' centre line
        .frame(height: 48)
        .background(Theme.surface)
    }

    /// Red pill when idle; grey pill with a spinner and stage progress while the backend updates.
    private var updateButton: some View {
        let running = store.updateRunning
        return Button {
            store.triggerUpdate()
        } label: {
            HStack(spacing: 6) {
                if running {
                    ProgressView().controlSize(.mini)
                    Text(store.update?.shortLabel ?? "更新中")
                } else {
                    Image(systemName: "sparkles")
                    Text("更新")
                }
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(running ? Theme.ink : Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(running ? Theme.surfaceSecondary : Theme.accent))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .linkPointer()
        .keyboardShortcut("u", modifiers: .command)
        .help(running ? (store.update?.message ?? "更新中")
              : "抓今天的新论文并用 Codex 生成速览 (⌘U)")
        .animation(.easeInOut(duration: 0.2), value: running)
    }

    private var logo: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
            (Text("arXiv").foregroundStyle(Theme.accent) + Text("Feed").foregroundStyle(Theme.ink))
                .font(.system(size: 17, weight: .heavy, design: .rounded))
        }
    }

    private func tabButton(_ title: String, _ tab: FeedTab) -> some View {
        let selected = store.tab == tab
        return Button {
            withAnimation(.spring(duration: 0.3)) { store.tab = tab }
        } label: {
            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 15, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? Theme.ink : Theme.inkSecondary)
                ZStack {
                    Capsule().fill(Color.clear).frame(width: 18, height: 3)
                    if selected {
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: 18, height: 3)
                            .matchedGeometryEffect(id: "underline", in: underline)
                    }
                }
            }
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkPointer()
    }
}
