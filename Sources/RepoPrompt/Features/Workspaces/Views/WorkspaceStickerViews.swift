import SwiftUI

/// The workspace sticker's face: a rounded square filled with the workspace colour, or a dashed
/// placeholder for None. Decorative; the enclosing button carries the label.
struct WorkspaceSticker: View {
    let color: WorkspaceColor?
    var size: CGFloat = 20

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size / 4, style: .continuous)
        Group {
            if let color {
                shape
                    .fill(color.color)
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            } else {
                shape.strokeBorder(
                    Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                )
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// One row of swatches: None, then the palette. A click applies at once and leaves the picker open;
/// the ring follows `selection` when the caller re-renders with the stored colour.
struct WorkspaceColorSwatchPicker: View {
    let selection: WorkspaceColor?
    let onSelect: (WorkspaceColor?) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(WorkspaceColorPickerOption.options(selection: selection)) { option in
                Button {
                    onSelect(option.color)
                } label: {
                    WorkspaceSticker(color: option.color, size: 16)
                        .frame(width: 22, height: 22)
                        .overlay {
                            if option.isSelected {
                                RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                    .strokeBorder(Color.accentColor, lineWidth: 2)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverTooltip(option.label)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(option.isSelected ? .isSelected : [])
            }
        }
        .padding(10)
    }
}

/// Where a sticker is shown: the sidebar's titlebar cluster, or the leading titlebar accessory
/// while the sidebar is collapsed.
enum WorkspaceStickerHost: Equatable {
    case sidebarToolbar
    case titlebarAccessory
}

/// Window-scoped sticker state, fed by `WindowState` from the resolved title, plus the picker's
/// presentation. The popover lives here rather than in toolbar `@State` so toolbar re-evaluation
/// cannot drop it, and so the two hosts share one code path.
@MainActor
final class WorkspaceStickerModel: ObservableObject {
    struct State: Equatable {
        /// The colourable workspace the title shows; nil (System or no workspace) shows no sticker.
        var workspaceID: UUID?
        var color: WorkspaceColor?
    }

    /// An open picker, bound to the workspace it was opened for and the host presenting it.
    struct PickerPresentation: Equatable {
        let workspaceID: UUID
        let host: WorkspaceStickerHost
    }

    @Published private(set) var state = State()
    /// nil while the picker is closed.
    @Published private(set) var picker: PickerPresentation?
    /// Applies a colour to the given workspace if the title still shows it.
    var onSelectColor: (UUID, WorkspaceColor?) -> Void = { _, _ in }

    /// Installs the title's workspace and colour, closing a picker opened for another workspace.
    /// Returns true only when the sticker appeared or disappeared, so a host whose width follows its
    /// content knows to re-measure.
    @discardableResult
    func update(workspaceID: UUID?, color: WorkspaceColor?) -> Bool {
        if let picker, picker.workspaceID != workspaceID {
            self.picker = nil
        }
        let next = State(workspaceID: workspaceID, color: workspaceID == nil ? nil : color)
        guard state != next else { return false }
        let visibilityFlipped = (state.workspaceID == nil) != (next.workspaceID == nil)
        state = next
        return visibilityFlipped
    }

    func togglePicker(from host: WorkspaceStickerHost) {
        if picker?.host == host {
            picker = nil
            return
        }
        guard let workspaceID = state.workspaceID else { return }
        picker = PickerPresentation(workspaceID: workspaceID, host: host)
    }

    func dismissPicker() {
        guard picker != nil else { return }
        picker = nil
    }

    /// Applies `color` to the workspace the open picker was opened for. The picker stays open.
    func select(_ color: WorkspaceColor?) {
        guard let picker else { return }
        onSelectColor(picker.workspaceID, color)
    }

    func isPickerPresented(in host: WorkspaceStickerHost) -> Bool {
        picker?.host == host
    }
}
