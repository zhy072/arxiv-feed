import SwiftUI

@main
struct ArxivFeedApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var backend = BackendManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(backend)
                .tint(Theme.accent)
                .frame(minWidth: 780, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1160, height: 860)
    }
}

/// Header + current tab, with the detail modal and toasts layered on top.
struct RootView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var backend: BackendManager

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HeaderBar()
                Divider().overlay(Theme.divider)
                ZStack {
                    switch store.tab {
                    case .discover: FeedView()
                    case .search: SearchView()
                    case .saved: SavedView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.pageBackground)

            if let paper = store.selected {
                DetailOverlay(paper: paper)
                    .id(paper.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(10)
            }
            if backend.showsOverlay {
                BackendSetupView().zIndex(30).transition(.opacity)
            }
            ToastHost().zIndex(20)
        }
        // Hidden title bar: let the header run right up under the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $store.showSettings) {
            SettingsView().environmentObject(store).environmentObject(backend)
        }
        .task {
            // Managed backend (DMG install): install/update it before anything else talks to it.
            await backend.ensure()
            if backend.managed { store.managedBaseURL = backend.baseURL }
            store.startStatusLoop()
            await store.loadTopics()
            await store.loadContext()
        }
        .onChange(of: backend.phase) { _, phase in
            guard phase == .ready else { return }
            store.managedBaseURL = backend.baseURL
            if backend.codexAvailable == false {
                store.showToast("没找到 ChatGPT 桌面版的 Codex，速览和解读会失败；装好并登录后到设置里重启后台",
                                icon: "exclamationmark.triangle", seconds: 8)
            }
            if store.papers.isEmpty, !store.loading {
                Task {
                    await store.refresh()
                    await store.loadTopics()
                    await store.loadContext()
                }
            }
        }
    }
}
