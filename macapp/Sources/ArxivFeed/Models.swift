import Foundation

struct Paper: Identifiable, Codable, Hashable {
    let arxivId: String
    let title: String
    let abstract: String?
    let authors: [String]
    let categories: [String]
    let published: String?
    let tldr: String?
    let tags: [String]
    let task: String?
    let method: String?
    let hasInterpretation: Bool
    let absUrl: String
    let pdfUrl: String
    let liked: Bool?
    let saved: Bool?
    let citationCount: Int?
    let venue: String?
    let affiliations: [String]?
    let affilScore: Int?
    let matchedTopic: String?
    var interpretation: String?

    var id: String { arxivId }

    enum CodingKeys: String, CodingKey {
        case arxivId = "arxiv_id"
        case title, abstract, authors, categories, published, tldr, tags, task, method
        case hasInterpretation = "has_interpretation"
        case absUrl = "abs_url"
        case pdfUrl = "pdf_url"
        case liked, saved, interpretation, venue, affiliations
        case citationCount = "citation_count"
        case affilScore = "affil_score"
        case matchedTopic = "matched_topic"
    }

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return f
    }()

    private static let fullFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var publishedDay: String {
        guard let published, published.count >= 10 else { return "" }
        return String(published.prefix(10))
    }

    var publishedDate: Date? {
        published.flatMap { Paper.isoParser.date(from: $0) }
    }

    /// "今天" / "昨天" / "MM-dd", the way a social feed dates posts.
    var displayDate: String {
        guard let date = publishedDate else { return publishedDay }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今天" }
        if cal.isDateInYesterday(date) { return "昨天" }
        if cal.isDate(date, equalTo: Date(), toGranularity: .year) {
            return Paper.dayFormatter.string(from: date)
        }
        return Paper.fullFormatter.string(from: date) // 精搜 results can be years old
    }

    var cardSummary: String {
        if let tldr, !tldr.isEmpty { return tldr }
        if let abstract, !abstract.isEmpty { return String(abstract.prefix(220)) + "…" }
        return ""
    }

    var hasSummary: Bool { !(tldr ?? "").isEmpty }

    var primaryCategory: String {
        if let cat = categories.first { return cat }
        if let venue, !venue.isEmpty { return venue }
        return "arXiv"
    }

    var firstAuthor: String { authors.first ?? "未知作者" }

    var authorLabel: String {
        guard let first = authors.first else { return "未知作者" }
        return authors.count > 1 ? "\(first) 等 \(authors.count) 人" : first
    }

    var authorInitial: String {
        let trimmed = firstAuthor.trimmingCharacters(in: .whitespaces)
        guard let ch = trimmed.first else { return "?" }
        return String(ch).uppercased()
    }

    /// Colour key: same topic → same cover colour once tags exist; otherwise vary per paper.
    var coverKey: String { tags.first ?? arxivId }
}

struct FeedResponse: Codable {
    let papers: [Paper]
}

/// A followed topic for the 发现 feed (关注词条); keywords are filled in by Codex on the backend.
struct Topic: Codable, Identifiable, Hashable {
    let name: String
    let keywords: [String]
    var id: String { name }
}

struct TopicsResponse: Codable {
    let topics: [Topic]
}

/// 研究背景: one line about what the user works on; Codex uses it to disambiguate topics.
struct ContextResponse: Codable {
    let context: String
}

struct HealthResponse: Codable {
    let ok: Bool
    let codex: Bool?
    let version: String?
}

struct StatsResponse: Codable {
    let papers: Int
}

/// One 精搜 run: the expanded query plus its arXiv papers (summaries fill in while `pending` > 0).
struct SearchResponse: Codable {
    let searchId: Int
    let topic: String
    let intent: String?
    let query: String?
    let label: String?
    let months: Int
    let total: Int?
    let pending: Int
    let filtered: Bool
    let citationsReady: Bool
    let active: Bool
    var papers: [Paper]

    enum CodingKeys: String, CodingKey {
        case searchId = "search_id"
        case citationsReady = "citations_ready"
        case topic, intent, query, label, months, total, pending, filtered, active, papers
    }
}

/// Progress of the daily update pipeline running inside the local backend.
struct UpdateStatus: Codable, Equatable {
    let running: Bool
    let stage: String
    let message: String
    let startedAt: String?
    let finishedAt: String?
    let error: String?
    let fetched: Int
    let new: Int
    let summarized: Int
    let summaryTotal: Int
    let embedded: Int
    let interpreted: Int
    let interpretTotal: Int
    let log: [String]

    enum CodingKeys: String, CodingKey {
        case running, stage, message, error, fetched, new, summarized, embedded, interpreted, log
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case summaryTotal = "summary_total"
        case interpretTotal = "interpret_total"
    }

    /// Short label for the header pill while running.
    var shortLabel: String {
        switch stage {
        case "starting", "fetch": return "抓取中"
        case "summarize": return "速览 \(summarized)/\(summaryTotal)"
        case "embed": return "算向量"
        case "interpret": return "解读 \(interpreted)/\(interpretTotal)"
        case "done": return "完成"
        case "error": return "失败"
        default: return stage
        }
    }

    var summaryLine: String {
        var s = "新增 \(new) 篇，速览 \(summarized) 篇"
        if interpreted > 0 { s += "，解读 \(interpreted) 篇" }
        return s
    }
}

struct UpdateStartResponse: Codable {
    let started: Bool
    let status: UpdateStatus
}

struct InterpretResponse: Codable {
    let interpretation: String
    let cached: Bool
}

struct EventIn: Codable {
    let arxivId: String
    let kind: String
    let value: Double?

    enum CodingKeys: String, CodingKey {
        case arxivId = "arxiv_id"
        case kind, value
    }
}
