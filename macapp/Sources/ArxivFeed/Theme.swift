import AppKit
import SwiftUI

/// Visual language: white surfaces on a warm grey page, one red accent, pastel "covers" for cards.
enum Theme {
    static let accent = Color(hex: 0xFF2442)
    static let topic = dynamic(light: 0x3B6FB5, dark: 0x82ACE8)

    static let pageBackground = dynamic(light: 0xF5F5F7, dark: 0x111113)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1C1C1F)
    static let surfaceSecondary = dynamic(light: 0xF2F2F5, dark: 0x27272B)
    static let divider = dynamic(light: 0xE8E8EC, dark: 0x2B2B30)
    static let ink = dynamic(light: 0x1F1F24, dark: 0xF2F2F5)
    static let inkSecondary = dynamic(light: 0x6E6E78, dark: 0xA3A3AC)
    static let inkTertiary = dynamic(light: 0xA3A3AB, dark: 0x6F6F78)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    /// Pastel gradient + matching ink used for a card's cover block and author avatar.
    struct Cover {
        let start: Color
        let end: Color
        let ink: Color
        let accent: Color

        init(_ start: UInt32, _ end: UInt32, ink: UInt32, accent: UInt32) {
            self.start = Color(hex: start)
            self.end = Color(hex: end)
            self.ink = Color(hex: ink)
            self.accent = Color(hex: accent)
        }
    }

    static let covers: [Cover] = [
        Cover(0xFFE9EC, 0xFFCFD8, ink: 0x5C1D2B, accent: 0xFF6B81), // rose
        Cover(0xFFF0E3, 0xFFD9BF, ink: 0x6A3418, accent: 0xFF9A5C), // peach
        Cover(0xFFF7D6, 0xFFEBA8, ink: 0x5C480A, accent: 0xE8B520), // lemon
        Cover(0xE4F7EC, 0xC3ECD6, ink: 0x14503A, accent: 0x2FB37C), // mint
        Cover(0xE5F0FF, 0xC9DEFF, ink: 0x173B6C, accent: 0x4A8CFF), // sky
        Cover(0xEEE8FF, 0xDBD0FF, ink: 0x3B2A6B, accent: 0x8A6CF5), // lavender
        Cover(0xF6F0E4, 0xE9DCC3, ink: 0x4E3E24, accent: 0xC29B57), // sand
        Cover(0xECEFF5, 0xD6DCE8, ink: 0x2B3547, accent: 0x6A7A94), // slate
        Cover(0xE3F6F8, 0xC2EAF0, ink: 0x0F4A55, accent: 0x2BA9BD), // aqua
        Cover(0xFDE7F4, 0xF9CBE6, ink: 0x5E1F45, accent: 0xE45CA5), // pink
    ]

    static func cover(for key: String) -> Cover {
        covers[stableHash(key) % covers.count]
    }

    /// FNV-1a. `String.hashValue` is salted per process, so it can't pick stable colours.
    static func stableHash(_ s: String) -> Int {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return Int(h % UInt64(Int32.max))
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension View {
    /// Hand cursor on hover (macOS 15+ API; earlier systems keep the arrow).
    @ViewBuilder
    func linkPointer() -> some View {
        if #available(macOS 15, *) {
            self.pointerStyle(.link)
        } else {
            self
        }
    }
}

/// Small rounded label for categories and tags.
struct Chip: View {
    let text: String
    var icon: String? = nil
    var foreground: Color = Theme.inkSecondary
    var background: Color = Theme.surfaceSecondary

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            }
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(foreground)
        .background(Capsule().fill(background))
    }
}

/// Round icon button used in the header and overlays.
struct IconButton: View {
    let systemName: String
    var help: String = ""
    var tint: Color = Theme.inkSecondary
    var size: CGFloat = 32
    var shortcut: KeyboardShortcut? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(hovering ? Theme.surfaceSecondary : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Heart / bookmark toggle with a bounce when it flips.
struct IconToggle: View {
    let systemName: String
    let filled: Bool
    var tint: Color = Theme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: filled ? systemName + ".fill" : systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(filled ? tint : Theme.inkTertiary)
                .symbolEffect(.bounce, value: filled)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Wraps chips onto multiple lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: maxWidth == .infinity ? widest : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
