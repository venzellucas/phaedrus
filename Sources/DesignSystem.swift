// Shared visual language for the SwiftUI settings and the AppKit recording panel.
// Surfaces follow macOS appearance; the recording panel deliberately stays dark.
import AppKit
import SwiftUI

@MainActor
enum PhaedrusTheme {
    static let space: CGFloat = 8
    static let cardPadding: CGFloat = 20
    static let pagePadding: CGFloat = 24
    static let cardRadius: CGFloat = 16
    static let controlRadius: CGFloat = 10
    static let panelRadius: CGFloat = 30
    static let bodySize: CGFloat = 13
    static let captionSize: CGFloat = 11
    static let panelTitleSize: CGFloat = 14

    private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            color(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        }
    }

    nonisolated private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    static let canvas = Color(nsColor: adaptive("canvas", light: 0xF5F3F0, dark: 0x1C1D21))
    static let sidebar = Color(nsColor: adaptive("sidebar", light: 0xEDEAE6, dark: 0x18191C))
    static let surface = Color(nsColor: adaptive("surface", light: 0xFFFFFF, dark: 0x27282D))
    static let inset = Color(nsColor: adaptive("inset", light: 0xF5F3F0, dark: 0x303137))
    static let accent = Color(nsColor: adaptive("accent", light: 0xA74732, dark: 0xF0A18A))
    static let success = Color(nsColor: adaptive("success", light: 0x327455, dark: 0x8DD6B1))
    static let caution = Color(nsColor: adaptive("caution", light: 0x8B5A13, dark: 0xE9BE70))
    static let panelBase = color(0x17181C)
    static let panelTop = color(0x2B2C32)
    static let panelBottom = color(0x17181C)
    static let panelSecondary = color(0xC7C7CE)
    static let ribbonColors = [color(0xFF786E), color(0xCC78FF), color(0x57ABFF), color(0x66E6C4)]
}

struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: PhaedrusTheme.space * 2) {
            Label(title, systemImage: symbol)
                .font(.system(size: PhaedrusTheme.bodySize, weight: .semibold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PhaedrusTheme.cardPadding)
        .background(PhaedrusTheme.surface, in: RoundedRectangle(cornerRadius: PhaedrusTheme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: PhaedrusTheme.cardRadius)
                .strokeBorder(.primary.opacity(contrast == .increased ? 0.4 : 0.07), lineWidth: 1)
        }
    }
}

struct SettingsNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(2)
    }
}

struct SettingsBadge: View {
    let text: String
    var symbol: String? = nil
    var color: Color = PhaedrusTheme.accent

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.system(size: PhaedrusTheme.captionSize, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.opacity(0.10), in: Capsule())
        .fixedSize()
    }
}

/// A native toggle retains keyboard, focus, and accessibility behavior.
struct SettingsToggle: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).fontWeight(.medium)
                if let detail { SettingsNote(detail) }
            }
        }
        .toggleStyle(.switch)
    }
}

struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(PhaedrusTheme.inset, in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.12)) }
    }
}
