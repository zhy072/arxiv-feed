import AppKit
import SwiftUI

/// Full-window card shown while the app installs/updates its backend, or when that needs the user's help.
struct BackendSetupView: View {
    @EnvironmentObject var backend: BackendManager

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.ink)
                    Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.inkSecondary)
                }
            }

            switch backend.phase {
            case .installing(let step, let detail): steps(current: step, detail: detail)
            case .needsPython: pythonHelp
            case .failed(let message): failure(message)
            default: EmptyView()
            }

            Text("后台装在 ~/Library/Application Support/ArxivFeed，只监听本机 127.0.0.1；论文数据和你的阅读记录都不出这台电脑。")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(width: 520)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(0.08), radius: 24, y: 8)
        )
    }

    private var title: String {
        switch backend.phase {
        case .installing: return backend.firstInstall ? "第一次运行，先把后台装到这台 Mac 上" : "正在更新后台"
        case .needsPython: return "需要 Python 3"
        case .failed: return "后台没装好"
        default: return ""
        }
    }

    private var subtitle: String {
        switch backend.phase {
        case .installing: return backend.firstInstall ? "只需要一次，大约一分钟；需要联网下载依赖。" : "app 升级了，把新的后台代码同步过去。"
        case .needsPython: return "后台是 Python 写的，这台 Mac 上还没找到能用的 python3。"
        case .failed: return "多半是网络或 Python 环境的问题，看下面的提示。"
        default: return ""
        }
    }

    private func steps(current: Int, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(BackendManager.stepTitles.enumerated()), id: \.offset) { index, name in
                let n = index + 1
                HStack(spacing: 10) {
                    Group {
                        if n < current {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                        } else if n == current {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(Theme.inkTertiary)
                        }
                    }
                    .frame(width: 18, height: 18)
                    Text(name)
                        .font(.system(size: 13, weight: n == current ? .semibold : .regular))
                        .foregroundStyle(n <= current ? Theme.ink : Theme.inkTertiary)
                    if n == current, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    private var pythonHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("macOS 的「命令行工具」自带 python3，点下面按钮会弹出 Apple 的安装框（几百 MB，几分钟）。装好后点「重试」。已经有 Homebrew / conda / python.org 的 python3 也会被自动识别。")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("安装命令行工具") { backend.installCommandLineTools() }
                    .buttonStyle(.borderedProminent)
                Button("重试") { Task { await backend.retry() } }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.accent)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: 160)
            HStack(spacing: 8) {
                Button("重试") { Task { await backend.retry() } }
                    .buttonStyle(.borderedProminent)
                Button("重装") { Task { await backend.reinstall() } }
                    .buttonStyle(.bordered)
                Button("查看日志") { backend.openLog(setup: true) }
                    .buttonStyle(.bordered)
            }
        }
    }
}
