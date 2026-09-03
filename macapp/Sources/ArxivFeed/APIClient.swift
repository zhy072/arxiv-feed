import Foundation

enum APIError: LocalizedError {
    case badURL
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "服务器地址无效，请在设置里检查"
        case .http(let code, let body):
            // FastAPI wraps messages as {"detail": "..."}; show just the message when present.
            if let data = body.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = obj["detail"] as? String {
                return "HTTP \(code)：\(detail)"
            }
            if body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
                return "HTTP \(code)：服务器返回了一个错误页，不是 API 响应"
            }
            return "HTTP \(code)：\(body.prefix(200))"
        }
    }
}

struct APIClient {
    let baseURL: String
    let token: String

    private func request(_ path: String, method: String = "GET", body: Data? = nil,
                         timeout: TimeInterval = 30) throws -> URLRequest {
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        // Plain string concatenation: appending(path:) would percent-encode "?" in query strings.
        guard !base.isEmpty, let url = URL(string: base + path) else {
            throw APIError.badURL
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    private func run<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw APIError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func feed(limit: Int = 30) async throws -> [Paper] {
        let req = try request("/feed?limit=\(limit)")
        return try await run(req, as: FeedResponse.self).papers
    }

    func saved(limit: Int = 200) async throws -> [Paper] {
        let req = try request("/saved?limit=\(limit)")
        return try await run(req, as: FeedResponse.self).papers
    }

    func interpret(id: String) async throws -> String {
        // First-time generation reads the full paper through the LLM — allow several minutes.
        let req = try request("/papers/\(id)/interpret", method: "POST", timeout: 600)
        return try await run(req, as: InterpretResponse.self).interpretation
    }

    func search(topic: String, months: Int, phrases: [String]? = nil) async throws -> SearchResponse {
        struct Body: Codable { let topic: String; let months: Int; let phrases: [String]? }
        let data = try JSONEncoder().encode(Body(topic: topic, months: months, phrases: phrases))
        // Query expansion (Codex) + Semantic Scholar + arXiv lookups: allow a couple of minutes.
        let req = try request("/search", method: "POST", body: data, timeout: 240)
        return try await run(req, as: SearchResponse.self)
    }

    func searchStatus(id: Int) async throws -> SearchResponse {
        let req = try request("/search/\(id)", timeout: 30)
        return try await run(req, as: SearchResponse.self)
    }

    func stats() async throws -> StatsResponse {
        let req = try request("/stats", timeout: 15)
        return try await run(req, as: StatsResponse.self)
    }

    func researchContext() async throws -> String {
        let req = try request("/prefs/context", timeout: 30)
        return try await run(req, as: ContextResponse.self).context
    }

    func saveResearchContext(_ text: String) async throws -> String {
        struct Body: Codable { let context: String }
        let data = try JSONEncoder().encode(Body(context: text))
        let req = try request("/prefs/context", method: "PUT", body: data, timeout: 30)
        return try await run(req, as: ContextResponse.self).context
    }

    func topics() async throws -> [Topic] {
        let req = try request("/prefs/topics", timeout: 30)
        return try await run(req, as: TopicsResponse.self).topics
    }

    func saveTopics(_ names: [String]) async throws -> [Topic] {
        struct Body: Codable { let topics: [String] }
        let data = try JSONEncoder().encode(Body(topics: names))
        // New topics get English keywords from Codex before the backend answers.
        let req = try request("/prefs/topics", method: "PUT", body: data, timeout: 240)
        return try await run(req, as: TopicsResponse.self).topics
    }

    func startUpdate() async throws -> UpdateStartResponse {
        let req = try request("/update", method: "POST", timeout: 60)
        return try await run(req, as: UpdateStartResponse.self)
    }

    func updateStatus() async throws -> UpdateStatus {
        let req = try request("/update/status", timeout: 15)
        return try await run(req, as: UpdateStatus.self)
    }

    func sendEvents(_ events: [EventIn]) async throws {
        struct Body: Codable { let events: [EventIn] }
        struct OK: Codable { let ok: Bool }
        let data = try JSONEncoder().encode(Body(events: events))
        let req = try request("/events", method: "POST", body: data)
        _ = try await run(req, as: OK.self)
    }
}
