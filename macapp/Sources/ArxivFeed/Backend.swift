import AppKit
import Foundation

struct CommandResult {
    let status: Int32
    let output: String
    var tail: String {
        output.split(separator: "\n", omittingEmptySubsequences: true).suffix(5).joined(separator: "\n")
    }
}

private struct SetupFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Runs the Python backend on this Mac without any terminal work, so the app can ship as a plain DMG.
///
/// The server source travels inside the bundle (Contents/Resources/server). On first launch it is copied to
/// ~/Library/Application Support/ArxivFeed/server, a venv is built with a local python3, dependencies are
/// installed, and a launchd agent keeps uvicorn on 127.0.0.1:8787. Later launches only compare the bundled
/// VERSION with the installed one and re-sync the code when the app was updated.
///
/// Left alone (`managed == false`): a developer running the backend from a checkout (the launchd plist points
/// elsewhere) or anyone with a custom server URL in settings.
///
/// Test overrides (env): ARXIVFEED_ROOT, ARXIVFEED_LABEL, ARXIVFEED_PORT.
@MainActor
final class BackendManager: ObservableObject {
    enum Phase: Equatable {
        case idle, checking, ready, needsPython
        case installing(step: Int, detail: String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var managed = false
    @Published private(set) var firstInstall = false
    @Published private(set) var healthy: Bool?
    @Published private(set) var codexAvailable: Bool?
    @Published private(set) var backendVersion: String?

    static let stepTitles = ["复制后台代码", "创建 Python 环境", "安装依赖", "写配置", "启动后台服务"]

    nonisolated static let label = ProcessInfo.processInfo.environment["ARXIVFEED_LABEL"] ?? "local.arxivfeed.api"
    nonisolated static let root: URL = {
        if let o = ProcessInfo.processInfo.environment["ARXIVFEED_ROOT"], !o.isEmpty {
            return URL(fileURLWithPath: o, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("ArxivFeed/server", isDirectory: true)
    }()
    nonisolated static let plistURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    nonisolated static let codexBin = "/Applications/ChatGPT.app/Contents/Resources/codex"
    nonisolated static var venvPython: String { root.appendingPathComponent("venv/bin/python").path }
    nonisolated static var logURL: URL { root.appendingPathComponent("logs/api.log") }
    nonisolated static var setupLogURL: URL { root.appendingPathComponent("logs/setup.log") }

    nonisolated static var bundledServer: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("server", isDirectory: true),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("app/main.py").path) else { return nil }
        return url
    }
    nonisolated static var bundledVersion: String {
        guard let s = bundledServer,
              let v = try? String(contentsOf: s.appendingPathComponent("VERSION"), encoding: .utf8) else { return "0" }
        return v.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    nonisolated static var installedVersion: String? {
        (try? String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Port from the installed .env (API_PORT); the env override only matters before the first install.
    nonisolated static var port: Int {
        if let text = try? String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8) {
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("API_PORT=") else { continue }
                let value = line.dropFirst("API_PORT=".count).split(separator: "#").first
                    .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                if let p = Int(value), p > 0 { return p }
            }
        }
        if let s = ProcessInfo.processInfo.environment["ARXIVFEED_PORT"], let p = Int(s), p > 0 { return p }
        return 8787
    }

    var baseURL: String { "http://127.0.0.1:\(Self.port)" }
    var showsOverlay: Bool {
        switch phase {
        case .installing, .needsPython, .failed: return true
        default: return false
        }
    }

    private var running = false

    // MARK: - entry points

    /// Called at launch (and from the overlay's buttons). Installs, updates or just health-checks as needed.
    func ensure(force: Bool = false) async {
        guard !running else { return }
        running = true
        defer { running = false }
        managed = shouldManage()
        guard managed else {
            phase = .idle
            return
        }
        phase = .checking
        let installed = Self.installedVersion
        firstInstall = installed == nil
        let health = await refreshHealth()
        if !force, health != nil, installed == Self.bundledVersion {
            phase = .ready
            return
        }
        await install(rebuildVenv: force)
    }

    func retry() async { await ensure() }
    func reinstall() async { await ensure(force: true) }

    func restart() async {
        guard managed else { return }
        let uid = getuid()
        _ = try? await Self.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", Self.plistURL.path])
        _ = try? await Self.run("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/\(Self.label)"])
        _ = await waitHealthy(seconds: 15)
    }

    /// Apple's own installer dialog for the Command Line Tools (which bring python3).
    func installCommandLineTools() {
        Task.detached { _ = try? await Self.run("/usr/bin/xcode-select", ["--install"]) }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Self.root])
    }

    func openLog(setup: Bool) {
        let url = setup ? Self.setupLogURL : Self.logURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            revealInFinder()
        }
    }

    @discardableResult
    func refreshHealth(baseURL: String? = nil) async -> HealthResponse? {
        guard let url = URL(string: (baseURL ?? self.baseURL) + "/health") else { return nil }
        do {
            let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 3))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let h = try JSONDecoder().decode(HealthResponse.self, from: data)
            healthy = true
            codexAvailable = h.codex
            backendVersion = h.version
            return h
        } catch {
            healthy = false
            return nil
        }
    }

    private func waitHealthy(seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await refreshHealth() != nil { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    // MARK: - decision

    private func shouldManage() -> Bool { Self.managedBaseURLAtLaunch() != nil }

    /// Where the app-managed backend answers, or nil when nothing should be managed: a custom server URL in
    /// settings, a build without the bundled server, or a launchd agent that runs the backend from a source
    /// checkout. Static so the store can build its very first client with the right port.
    nonisolated static func managedBaseURLAtLaunch() -> String? {
        let stored = (UserDefaults.standard.string(forKey: "serverURL") ?? "").trimmingCharacters(in: .whitespaces)
        if !stored.isEmpty, !stored.contains("cappuccino.cafe"), stored != "http://127.0.0.1:8787" { return nil }
        guard bundledServer != nil else { return nil }
        if let text = try? String(contentsOf: plistURL, encoding: .utf8), !text.contains(root.path) { return nil }
        return "http://127.0.0.1:\(port)"
    }

    // MARK: - install

    private func install(rebuildVenv: Bool) async {
        let fm = FileManager.default
        let uid = getuid()
        do {
            phase = .installing(step: 1, detail: Self.root.path)
            try Self.syncCode()

            phase = .installing(step: 2, detail: "")
            var venvOK = false
            if !rebuildVenv, fm.isExecutableFile(atPath: Self.venvPython) {
                let r = try await Self.run(Self.venvPython, ["-c", "import sys; print('OK' if sys.version_info >= (3, 9) else 'OLD')"])
                venvOK = r.status == 0 && r.output.contains("OK")
            }
            if !venvOK {
                guard let python = await Self.findPython() else {
                    phase = .needsPython
                    return
                }
                phase = .installing(step: 2, detail: python)
                let venv = Self.root.appendingPathComponent("venv")
                _ = try? fm.removeItem(at: venv)
                let r = try await Self.run(python, ["-m", "venv", venv.path])
                guard r.status == 0 else { throw SetupFailure("创建 Python 环境失败：\(r.tail)") }
            }

            phase = .installing(step: 3, detail: firstInstall ? "首次大约一分钟，需要联网" : "")
            _ = try await Self.run(Self.venvPython, ["-m", "pip", "install", "-q", "--upgrade", "pip"], cwd: Self.root)
            let pip = try await Self.run(Self.venvPython, ["-m", "pip", "install", "-q", "-r", "requirements.txt"], cwd: Self.root)
            guard pip.status == 0 else { throw SetupFailure("安装依赖失败（网络不通？）：\(pip.tail)") }

            phase = .installing(step: 4, detail: "")
            try Self.writeConfig()

            phase = .installing(step: 5, detail: "launchd · 127.0.0.1:\(Self.port)")
            try Self.writePlist()
            _ = try await Self.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(Self.label)"])
            for _ in 0..<20 {
                let r = try await Self.run("/bin/launchctl", ["print", "gui/\(uid)/\(Self.label)"])
                if r.status != 0 { break }
                try await Task.sleep(for: .milliseconds(250))
            }
            let boot = try await Self.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", Self.plistURL.path])
            if boot.status != 0 {
                _ = try await Self.run("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/\(Self.label)"])
            }
            guard await waitHealthy(seconds: 40) else {
                throw SetupFailure("后台没有响应。logs/api.log 最后几行：\n\(Self.logTail())")
            }
            try Self.bundledVersion.write(to: Self.root.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Copy the bundled server source over the installed one; data, .env, venv and logs stay.
    nonisolated static func syncCode() throws {
        guard let src = bundledServer else { throw SetupFailure("app 里没有后台代码（构建不完整）") }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["app", "requirements.txt", ".env.example", "run_pipeline.py"] {
            let dst = root.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src.appendingPathComponent(name), to: dst)
        }
    }

    nonisolated static func writeConfig() throws {
        let fm = FileManager.default
        let env = root.appendingPathComponent(".env")
        if !fm.fileExists(atPath: env.path) {
            var text = try String(contentsOf: root.appendingPathComponent(".env.example"), encoding: .utf8)
            if let p = ProcessInfo.processInfo.environment["ARXIVFEED_PORT"], Int(p) != nil {
                text = setLine(text, key: "API_PORT", value: p)
            }
            // Use the model this ChatGPT account already uses in Codex; the example's default may not exist for everyone.
            if let model = codexDefaultModel() {
                text = setLine(text, key: "CODEX_MODEL", value: model)
            }
            try text.write(to: env, atomically: true, encoding: .utf8)
        }
        for d in ["data", "logs"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
    }

    nonisolated static func setLine(_ text: String, key: String, value: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var found = false
        for i in lines.indices where lines[i].hasPrefix(key + "=") {
            lines[i] = "\(key)=\(value)"
            found = true
        }
        if !found { lines.append("\(key)=\(value)") }
        return lines.joined(separator: "\n")
    }

    nonisolated static func codexDefaultModel() -> String? {
        let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return nil }
        for raw in text.split(separator: "\n") {
            let parts = raw.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "model" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty { return value }
        }
        return nil
    }

    nonisolated static func writePlist() throws {
        func xml(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        // `python -m uvicorn` rather than venv/bin/uvicorn: a shebang can't hold "Application Support".
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>AssociatedBundleIdentifiers</key><string>local.arxivfeed</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(xml(venvPython))</string>
                <string>-m</string><string>uvicorn</string>
                <string>app.main:app</string>
                <string>--host</string><string>127.0.0.1</string>
                <string>--port</string><string>\(port)</string>
            </array>
            <key>WorkingDirectory</key><string>\(xml(root.path))</string>
            <key>EnvironmentVariables</key>
            <dict>
                <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string>
                <key>HOME</key><string>\(xml(NSHomeDirectory()))</string>
                <key>PYTHONUNBUFFERED</key><string>1</string>
            </dict>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>StandardOutPath</key><string>\(xml(logURL.path))</string>
            <key>StandardErrorPath</key><string>\(xml(logURL.path))</string>
        </dict>
        </plist>

        """
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
    }

    /// A python3 ≥ 3.9 that can make venvs. The system one counts only once the Command Line Tools exist;
    /// before that /usr/bin/python3 is a stub that pops up Apple's installer instead of running.
    nonisolated static func findPython() async -> String? {
        let home = NSHomeDirectory()
        var candidates: [String] = []
        if let r = try? await run("/usr/bin/xcode-select", ["-p"]), r.status == 0 {
            candidates.append("/usr/bin/python3")
        }
        candidates += [
            "/opt/homebrew/bin/python3", "/usr/local/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            "\(home)/miniconda3/bin/python3", "\(home)/anaconda3/bin/python3", "\(home)/miniforge3/bin/python3",
            "/opt/miniconda3/bin/python3", "/opt/anaconda3/bin/python3", "/opt/homebrew/Caskroom/miniconda/base/bin/python3",
        ]
        let check = "import sys, venv, ensurepip; print('OK' if sys.version_info >= (3, 9) else 'OLD')"
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            if let r = try? await run(c, ["-c", check]), r.status == 0, r.output.contains("OK") { return c }
        }
        return nil
    }

    nonisolated static func logTail() -> String {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "(没有日志)" }
        return text.split(separator: "\n").suffix(4).joined(separator: "\n")
    }

    nonisolated static func run(_ exe: String, _ args: [String], cwd: URL? = nil) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) { () -> CommandResult in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            if let cwd { p.currentDirectoryURL = cwd }
            var env = ProcessInfo.processInfo.environment.filter {
                !$0.key.hasPrefix("PYTHON") && !$0.key.hasPrefix("CONDA") && $0.key != "VIRTUAL_ENV"
            }
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
            env["HOME"] = NSHomeDirectory()
            env["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            appendSetupLog("$ \(exe) \(args.joined(separator: " "))\n\(output)")
            return CommandResult(status: p.terminationStatus, output: output)
        }.value
    }

    nonisolated static func appendSetupLog(_ text: String) {
        let url = setupLogURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(text)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
