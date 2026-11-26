import AppKit
import SwiftUI

/// The fixed palette a user can assign to a workspace (`workspace.json` key `color`).
///
/// Raw values are the persisted ids and an external contract (see
/// `docs/architecture/workspace-colors.md`): never rename or reuse one. Declaration order is the
/// menu order. Each colour renders its exact light/dark hex value through an appearance-resolving
/// `NSColor`, so external readers that copy the table match pixel for pixel.
enum WorkspaceColor: String, CaseIterable, Identifiable {
    case red
    case orange
    case yellow
    case lime
    case green
    case teal
    case aqua
    case blue
    case indigo
    case violet
    case magenta
    case pink
    case brown
    case grey

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .lime: "Lime"
        case .green: "Green"
        case .teal: "Teal"
        case .aqua: "Aqua"
        case .blue: "Blue"
        case .indigo: "Indigo"
        case .violet: "Violet"
        case .magenta: "Magenta"
        case .pink: "Pink"
        case .brown: "Brown"
        // The id keeps the Map-compatible spelling; the UI uses US English.
        case .grey: "Gray"
        }
    }

    /// VoiceOver label shared by every dot that shows this colour; the workspace stickers also use
    /// it as their accessibility value.
    var accessibilityLabel: String {
        "Workspace color: \(displayName)"
    }

    /// sRGB value for light appearances (darker, for contrast on light chrome).
    var lightHex: UInt32 {
        switch self {
        case .red: 0xDC2626
        case .orange: 0xEA580C
        case .yellow: 0xCA8A04
        case .lime: 0x65A30D
        case .green: 0x16A34A
        case .teal: 0x0D9488
        case .aqua: 0x0891B2
        case .blue: 0x2563EB
        case .indigo: 0x4F46E5
        case .violet: 0x7C3AED
        case .magenta: 0xC026D3
        case .pink: 0xDB2777
        case .brown: 0x92633A
        case .grey: 0x6B7280
        }
    }

    /// sRGB value for dark appearances (brighter, for contrast on dark chrome).
    var darkHex: UInt32 {
        switch self {
        case .red: 0xF87171
        case .orange: 0xFB923C
        case .yellow: 0xFACC15
        case .lime: 0xA3E635
        case .green: 0x4ADE80
        case .teal: 0x2DD4BF
        case .aqua: 0x22D3EE
        case .blue: 0x60A5FA
        case .indigo: 0x818CF8
        case .violet: 0xA78BFA
        case .magenta: 0xE879F9
        case .pink: 0xF472B6
        case .brown: 0xC8A27C
        case .grey: 0x9CA3AF
        }
    }

    /// Appearance-aware colour: the dark value for dark appearances, else the light value.
    var nsColor: NSColor {
        let light = Self.srgb(lightHex)
        let dark = Self.srgb(darkHex)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    var color: Color {
        Color(nsColor: nsColor)
    }

    /// A small filled circle for menu items. Not a template image, so menus keep its colour; it
    /// draws lazily, so it follows the menu's appearance.
    var menuSwatchImage: NSImage {
        let fill = nsColor
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            fill.setFill()
            circle.fill()
            NSColor.labelColor.withAlphaComponent(0.15).setStroke()
            circle.lineWidth = 0.5
            circle.stroke()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = displayName
        return image
    }

    /// Maps a persisted id to a colour. Trims and lowercases; empty or unknown ids mean None.
    static func resolve(_ id: String?) -> WorkspaceColor? {
        guard let id = normalizedID(id) else { return nil }
        return WorkspaceColor(rawValue: id)
    }

    /// The canonical stored form of an id: trimmed and lowercased, nil when empty. Unknown ids are
    /// kept, so an id written by a newer build survives a re-save.
    static func normalizedID(_ id: String?) -> String? {
        guard let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// One swatch in the workspace colour picker: None (`color == nil`) or a palette colour.
struct WorkspaceColorPickerOption: Equatable, Identifiable {
    let color: WorkspaceColor?
    let isSelected: Bool

    var id: String {
        color?.rawValue ?? ""
    }

    /// Tooltip and VoiceOver label for the swatch.
    var label: String {
        color?.displayName ?? "None"
    }

    /// None first, then the palette in declaration order; exactly one option matches `selection`.
    static func options(selection: WorkspaceColor?) -> [WorkspaceColorPickerOption] {
        ([nil] + WorkspaceColor.allCases.map(Optional.some)).map { color in
            WorkspaceColorPickerOption(color: color, isSelected: color == selection)
        }
    }
}
