import AppKit
import Foundation
import SwiftUI

enum FeedTab {
    case discover, search, saved
}

enum SearchSort {
    case citations, labs
}

@MainActor
final class AppStore: ObservableObject {
    @Published var tab: FeedTab = .discover

    @Published var papers: [Paper] = []
    @Published var loading = false
    @Published var exhausted = false
    @Published var errorMessage: String?
    /// Total papers in the backend, fetched only when the feed comes back empty: 0 means a fresh install that
    /// has never run an update, anything else means the user has simply seen everything.
    @Published var paperCount: Int?

    @Published var savedPapers: [Paper] = []
    @Published var savedLoading = false
    @Published var savedError: String?

    @Published var likedIDs: Set<String> = []
    @Published var savedIDs: Set<String> = []

    @Published var selected: Paper?
    @Published var showSettings = false
    @Published var toast: Toast?
    @Published var update: UpdateStatus?
    @Published var topics: [Topic] = []
    @Published var researchContext = ""

    // 精搜
    @Published var searchTopic = ""
    @Published var searchMonths = 12
    @Published var searchSort: SearchSort = .citations
    @Published var searchResult: SearchResponse?
    @Published var searching = false
    @Published var searchError: String?
    @Published var recentSearches: [String] = UserDefaults.standard.stringArray(forKey: "recentSearches") ?? []

    private var pendingEvents: [EventIn] = []
    private var impressed: Set<String> = []
    private var flushTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var updatePollTask: Task<Void, Never>?
    private var searchPollTask: Task<Void, Never>?

    /// The backend runs on this Mac (launchd agent); the settings sheet can still point elsewhere.
    static let defaultServerURL = "http://127.0.0.1:8787"
    /// Set when the app runs its own backend (see BackendManager); its port comes from the installed .env.
    @Published var managedBaseURL: String? = BackendManager.managedBaseURLAtLaunch()

    var client: APIClient {
        let stored = (UserDefaults.standard.string(forKey: "serverURL") ?? "")
            .trimmingCharacters(in: .whitespaces)
        // Legacy: the first version talked to a remote server that has since been retired.
        let legacyRemote = stored.contains("cappuccino.cafe")
        return APIClient(
            baseURL: stored.isEmpty || legacyRemote ? (managedBaseURL ?? Self.defaultServerURL) : stored,
            token: legacyRemote ? "" : UserDefaults.standard.string(forKey: "apiToken") ?? ""
        )
    }

    // MARK: - feed

    func loadMore() async {
        guard !loading, !exhausted else { return }
        loading = true
        errorMessage = nil
        await flushEvents()
        do {
            let fresh = try await client.feed(limit: 30)
            let known = Set(papers.map(\.id))
            let new = fresh.filter { !known.contains($0.id) }
            papers.append(contentsOf: new)
            exhausted = new.isEmpty
            paperCount = papers.isEmpty ? (try? await client.stats())?.papers : nil
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    func refresh() async {
        exhausted = false
        papers = []
        impressed = []
        await loadMore()
    }

    func loadSaved() async {
        guard !savedLoading else { return }
        savedLoading = true
        savedError = nil
        await flushEvents()
        do {
            let list = try await client.saved()
            savedPapers = list
            savedIDs = Set(list.map(\.id))
            for p in list where p.liked == true {
                likedIDs.insert(p.id)
            }
        } catch {
            savedError = error.localizedDescription
        }
        savedLoading = false
    }

    // MARK: - 关注词条

    func loadContext() async {
        if let text = try? await client.researchContext() { researchContext = text }
    }

    /// Settings → 研究背景. Only hits the backend when the text changed.
    func saveContext(_ text: String) async {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != researchContext else { return }
        do {
            researchContext = try await client.saveResearchContext(cleaned)
        } catch {
            showToast("研究背景保存失败：\(error.localizedDescription)", icon: "exclamationmark.triangle", seconds: 5)
        }
    }

    func loadTopics() async {
        if let list = try? await client.topics() { topics = list }
    }

    /// Settings → 关注词条. Saves when changed (Codex adds English keywords for new ones), then reloads the feed.
    func saveTopics(_ names: [String]) async {
        let cleaned = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if cleaned != topics.map(\.name) {
            showToast("正在保存关注词条，Codex 补英文关键词中…", icon: "star", seconds: 4)
            do {
                topics = try await client.saveTopics(cleaned)
                showToast("关注词条已更新", icon: "star.fill", seconds: 3)
            } catch {
                showToast("保存失败：\(error.localizedDescription)", icon: "exclamationmark.triangle", seconds: 5)
            }
        }
        await refresh()
    }

    // MARK: - 精搜

    /// Results in the chosen order. Server order (index) breaks ties, so relevance order holds
    /// until citations / labs have arrived from the background job.
    var searchPapers: [Paper] {
        guard let result = searchResult else { return [] }
        let indexed = Array(result.papers.enumerated())
        let sorted: [(offset: Int, element: Paper)]
        switch searchSort {
        case .citations:
            sorted = indexed.sorted { a, b in
                let ca = a.element.citationCount ?? -1, cb = b.element.citationCount ?? -1
                return ca != cb ? ca > cb : a.offset < b.offset
            }
        case .labs:
            sorted = indexed.sorted { a, b in
                let sa = a.element.affilScore ?? 0, sb = b.element.affilScore ?? 0
                if sa != sb { return sa > sb }
                let ca = a.element.citationCount ?? -1, cb = b.element.citationCount ?? -1
                return ca != cb ? ca > cb : a.offset < b.offset
            }
        }
        return sorted.map(\.element)
    }

    func runSearch() {
        let topic = searchTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty, !searching else { return }
        // "a | b | c" = explicit English search phrases; skips the Codex translation step.
        let phrases: [String]? = topic.contains("|")
            ? topic.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            : nil
        searching = true
        searchError = nil
        searchPollTask?.cancel()
        Task {
            do {
                let result = try await client.search(topic: topic, months: searchMonths, phrases: phrases)
                searchResult = result
                rememberSearch(topic)
                if result.active { pollSearch(id: result.searchId) }
            } catch {
                searchError = error.localizedDescription
            }
            searching = false
        }
    }

    /// Citations, summaries and labs arrive from a background job; refresh until it finishes.
    private func pollSearch(id: Int) {
        searchPollTask = Task { [weak self] in
            for _ in 0..<160 { // ≤ 8 minutes
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                guard let fresh = try? await self.client.searchStatus(id: id) else { continue }
                if self.searchResult?.searchId == id {
                    withAnimation(.easeInOut(duration: 0.3)) { self.searchResult = fresh }
                }
                if !fresh.active { return }
            }
        }
    }

    /// Puts the current English phrases into the box so they can be tweaked and re-run.
    func editSearchPhrases() {
        if let query = searchResult?.query, !query.isEmpty { searchTopic = query }
    }

    private func rememberSearch(_ topic: String) {
        var list = recentSearches.filter { $0 != topic }
        list.insert(topic, at: 0)
        recentSearches = Array(list.prefix(8))
        UserDefaults.standard.set(recentSearches, forKey: "recentSearches")
    }

    // MARK: - daily update

    var updateRunning: Bool { update?.running ?? false }

    /// The header "更新" button: fetch today's papers and generate Codex summaries in the backend.
    func triggerUpdate() {
        if updateRunning {
            let msg = update?.message ?? ""
            showToast(msg.isEmpty ? "正在更新中…" : msg, icon: "sparkles", seconds: 3)
            return
        }
        Task {
            do {
                let resp = try await client.startUpdate()
                update = resp.status
                showToast(resp.started ? "开始更新：先抓今天的论文…" : "已有更新在跑", icon: "sparkles", seconds: 3)
            } catch {
                showToast("无法开始更新：\(error.localizedDescription)", icon: "exclamationmark.triangle", seconds: 5)
            }
        }
    }

    /// Keeps `update` fresh no matter where the run was started (button, CLI, API):
    /// every 2s while running, every 6s otherwise. Cheap — the backend is on this Mac.
    func startStatusLoop() {
        guard updatePollTask == nil else { return }
        updatePollTask = Task { [weak self] in
            var wasRunning = false
            while !Task.isCancelled {
                guard let self else { return }
                if let status = try? await self.client.updateStatus() {
                    self.update = status
                    // finishedAt guards against a backend restart, whose fresh state is idle but never "finished".
                    if wasRunning && !status.running && status.finishedAt != nil {
                        if let err = status.error {
                            self.showToast("更新失败：\(err)", icon: "exclamationmark.triangle", seconds: 6)
                        } else {
                            self.showToast("更新完成：\(status.summaryLine)", icon: "checkmark.circle.fill", seconds: 5)
                            await self.refresh()
                        }
                    }
                    wasRunning = status.running
                }
                try? await Task.sleep(for: .seconds(self.updateRunning ? 2 : 6))
            }
        }
    }

    // MARK: - detail

    func open(_ paper: Paper) {
        // Prefer the copy that may already carry a cached interpretation.
        let latest = papers.first { $0.id == paper.id }
            ?? savedPapers.first { $0.id == paper.id }
            ?? searchResult?.papers.first { $0.id == paper.id }
            ?? paper
        withAnimation(.spring(duration: 0.28)) { selected = latest }
    }

    func closeDetail() {
        withAnimation(.easeOut(duration: 0.18)) { selected = nil }
    }

    func interpret(_ paper: Paper) async throws -> String {
        let text = try await client.interpret(id: paper.id)
        if let i = papers.firstIndex(where: { $0.id == paper.id }) {
            papers[i].interpretation = text
        }
        if let i = savedPapers.firstIndex(where: { $0.id == paper.id }) {
            savedPapers[i].interpretation = text
        }
        if let i = searchResult?.papers.firstIndex(where: { $0.id == paper.id }) {
            searchResult?.papers[i].interpretation = text
        }
        return text
    }

    // MARK: - actions

    func toggleLike(_ paper: Paper) {
        if likedIDs.contains(paper.id) {
            likedIDs.remove(paper.id)
            queue(EventIn(arxivId: paper.id, kind: "unlike", value: nil))
            showToast("已取消喜欢", icon: "heart")
        } else {
            likedIDs.insert(paper.id)
            queue(EventIn(arxivId: paper.id, kind: "like", value: nil))
            showToast("已喜欢，会多推这类", icon: "heart.fill")
        }
    }

    func toggleSave(_ paper: Paper) {
        if savedIDs.contains(paper.id) {
            savedIDs.remove(paper.id)
            withAnimation(.easeInOut(duration: 0.25)) {
                savedPapers.removeAll { $0.id == paper.id }
            }
            queue(EventIn(arxivId: paper.id, kind: "unsave", value: nil))
            showToast("已取消收藏", icon: "bookmark")
        } else {
            savedIDs.insert(paper.id)
            if !savedPapers.contains(where: { $0.id == paper.id }) {
                savedPapers.insert(paper, at: 0)
            }
            queue(EventIn(arxivId: paper.id, kind: "save", value: nil))
            showToast("已收藏", icon: "bookmark.fill")
        }
    }

    func dislike(_ paper: Paper) {
        queue(EventIn(arxivId: paper.id, kind: "dislike", value: nil))
        if selected?.id == paper.id { closeDetail() }
        withAnimation(.easeInOut(duration: 0.25)) {
            papers.removeAll { $0.id == paper.id }
            searchResult?.papers.removeAll { $0.id == paper.id }
        }
        showToast("已隐藏，会少推这类", icon: "hand.thumbsdown")
    }

    func openURL(_ string: String) {
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }

    func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        showToast("已复制", icon: "doc.on.doc")
    }

    func showToast(_ text: String, icon: String, seconds: Double = 1.6) {
        toastTask?.cancel()
        toast = Toast(text: text, icon: icon)
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: - behaviour signals

    func impression(_ paper: Paper) {
        guard !impressed.contains(paper.id) else { return }
        impressed.insert(paper.id)
        queue(EventIn(arxivId: paper.id, kind: "impression", value: nil))
    }

    func event(_ kind: String, _ paper: Paper, value: Double? = nil) {
        queue(EventIn(arxivId: paper.id, kind: kind, value: value))
    }

    private func queue(_ e: EventIn) {
        pendingEvents.append(e)
        if pendingEvents.count >= 10 {
            Task { await flushEvents() }
        } else if flushTask == nil {
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                await self?.flushEvents()
                self?.flushTask = nil
            }
        }
    }

    func flushEvents() async {
        guard !pendingEvents.isEmpty else { return }
        let batch = pendingEvents
        pendingEvents = []
        do {
            try await client.sendEvents(batch)
        } catch APIError.http(let code, _) where (400..<500).contains(code) {
            // The server rejected the batch outright; re-queueing would retry forever.
            NSLog("dropping %d events after HTTP %d", batch.count, code)
        } catch {
            pendingEvents.insert(contentsOf: batch, at: 0) // retry on next flush
        }
    }
}
