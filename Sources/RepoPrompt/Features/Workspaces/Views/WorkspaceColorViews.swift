import AppKit
import SwiftUI

/// The 8 pt workspace-colour dot shown before a workspace name (toolbar title, picker rows,
/// Manage Workspaces rows). The hairline keeps pale colours legible on light backgrounds.
struct WorkspaceColorDot: View {
    let color: WorkspaceColor

    var body: some View {
        Circle()
            .fill(color.color)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            .frame(width: 8, height: 8)
            .accessibilityElement()
            .accessibilityLabel(color.accessibilityLabel)
    }
}

/// The `Workspace Color` context-menu section shared by the toolbar title and Manage Workspaces
/// rows: None plus the fixed palette, with a native checkmark on the current choice.
struct WorkspaceColorMenuSection: View {
    let selection: WorkspaceColor?
    let onSelect: (WorkspaceColor?) -> Void

    var body: some View {
        Section("Workspace Color") {
            Picker(
                "Workspace Color",
                selection: Binding(get: { selection }, set: { onSelect($0) })
            ) {
                Text("None").tag(WorkspaceColor?.none)
                ForEach(WorkspaceColor.allCases) { color in
                    Label {
                        Text(color.displayName)
                    } icon: {
                        Image(nsImage: color.menuSwatchImage)
                    }
                    .labelStyle(.titleAndIcon)
                    .tag(WorkspaceColor?.some(color))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

extension WorkspaceColor {
    /// The AppKit counterpart of `WorkspaceColorMenuSection` for `StableMenuItem` menus (toolbar
    /// title right-click, Chat Options submenu): None, then the palette in menu order, with a
    /// checkmark on `selection`. No header: callers add their own section title or parent item.
    static func stableMenuItems(
        selection: WorkspaceColor?,
        onSelect: @escaping (WorkspaceColor?) -> Void
    ) -> [StableMenuItem] {
        [.action("None", isSelected: selection == nil) { onSelect(nil) }]
            + allCases.map { color in
                .action(color.displayName, isSelected: selection == color, image: color.menuSwatchImage) {
                    onSelect(color)
                }
            }
    }
}

extension View {
    /// Attaches the `Workspace Color` context menu only when `onSelect` is provided, so surfaces
    /// that cannot be coloured (System, recovery copies) keep their default right-click.
    @ViewBuilder
    func workspaceColorContextMenu(
        selection: WorkspaceColor?,
        onSelect: ((WorkspaceColor?) -> Void)?
    ) -> some View {
        if let onSelect {
            contextMenu {
                WorkspaceColorMenuSection(selection: selection, onSelect: onSelect)
            }
        } else {
            self
        }
    }

    /// A 2 pt workspace-colour rule along the top content edge, directly below the toolbar (and
    /// below the DEBUG rule in debug builds). Drawn as an overlay, so it reserves no height, never
    /// shifts content, and sits above inset banners. Draws nothing for None.
    func workspaceColorWindowEdge(_ color: WorkspaceColor?) -> some View {
        overlay(alignment: .top) {
            if let color {
                color.color
                    .frame(height: 2)
                    .padding(.top, DebugBuildIdentity.isEnabled ? DebugBuildIdentity.windowEdgeRuleHeight : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
