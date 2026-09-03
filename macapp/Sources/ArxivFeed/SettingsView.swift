import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var backend: BackendManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("serverURL") private var serverURL = ""
    @AppStorage("apiToken") private var apiToken = ""

    @State private var names: [String] = []
    @State private var context = ""
    @State private var newTopic = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("设置").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.ink)
                    Text("研究背景告诉 Codex 你是谁，关注词条决定发现页先推什么")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkSecondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                field("研究背景", text: $context, placeholder: "一句话，比如：视频生成、全双工语音交互、模型量化与高效推理")
                Text("精搜理解方向、关注词条补关键词时都用它消歧（比如“量化”默认指模型量化，不是 VQ）。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.inkTertiary)
            }

            topicsSection

            Divider().overlay(Theme.divider)

            backendSection

            field("后台地址", text: $serverURL, placeholder: "留空 = \(AppStore.defaultServerURL)")
            field("API Token", text: $apiToken, placeholder: "本机默认不需要，留空")

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存并刷新") {
                    let pending = names
                    let ctx = context
                    dismiss()
                    Task {
                        await store.saveContext(ctx)
                        await store.saveTopics(pending)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(Theme.surface)
        .onAppear {
            names = store.topics.map(\.name)
            context = store.researchContext
        }
        .task { await backend.refreshHealth(baseURL: store.client.baseURL) }
    }

    // MARK: - 关注词条

    private var topicsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("发现页 · 关注词条")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
            if names.isEmpty {
                Text("还没有关注词条，发现页只按新鲜度和你的行为画像排序。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkTertiary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(names, id: \.self) { name in
                        topicChip(name)
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("加一个方向，比如 视频量化 / 全双工语音", text: $newTopic)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit(addTopic)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surfaceSecondary))
                Button("添加", action: addTopic)
                    .buttonStyle(.bordered)
                    .disabled(newTopic.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("保存后 Codex 会给每个方向补一组英文关键词；发现页把命中的论文排前面，卡片上标出命中的方向。中英文都可以。")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.inkTertiary)
        }
    }

    private func topicChip(_ name: String) -> some View {
        let keywords = store.topics.first { $0.name == name }?.keywords ?? []
        return HStack(spacing: 5) {
            Image(systemName: "star.fill").font(.system(size: 9))
            Text(name).font(.system(size: 12, weight: .medium))
            if !keywords.isEmpty {
                Text("· \(keywords.count) 个英文词").font(.system(size: 10)).opacity(0.7)
            }
            Button {
                names.removeAll { $0 == name }
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("移除")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(Theme.accent)
        .background(Capsule().fill(Theme.accent.opacity(0.10)))
        .help(keywords.isEmpty ? "保存后会补英文关键词" : keywords.joined(separator: ", "))
    }

    private func addTopic() {
        let topic = newTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return }
        if !names.contains(topic) { names.append(topic) }
        newTopic = ""
    }

    // MARK: - 后台

    private var backendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("后台")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
            HStack(spacing: 7) {
                Circle()
                    .fill(backend.healthy == true ? Color.green : (backend.healthy == false ? Theme.accent : Theme.inkTertiary))
                    .frame(width: 7, height: 7)
                Text(backendStatus)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink)
            }
            if backend.managed {
                Text("装在 ~/Library/Application Support/ArxivFeed/server。模型、推理强度、订阅分类在那里的 .env 里改，改完点「重启后台」。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("重启后台") { Task { await backend.restart() } }
                    Button("在 Finder 中显示") { backend.revealInFinder() }
                    Button("查看日志") { backend.openLog(setup: false) }
                    Button("重装后台") {
                        dismiss()
                        Task { await backend.reinstall() }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Text("后台由你自己运行（launchd 指向代码仓库）；模型等在 server/.env 里改，改完运行 server/deploy/install_local.sh 重启。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var backendStatus: String {
        guard let healthy = backend.healthy else { return "检查中…" }
        guard healthy else { return "没响应（\(store.client.baseURL)）" }
        var parts = ["运行中"]
        if let v = backend.backendVersion { parts.append("v\(v)") }
        parts.append(backend.codexAvailable == true ? "Codex 已就绪" : "没找到 Codex：装 ChatGPT 桌面版并登录")
        return parts.joined(separator: " · ")
    }

    // MARK: - fields

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surfaceSecondary))
        }
    }
}
