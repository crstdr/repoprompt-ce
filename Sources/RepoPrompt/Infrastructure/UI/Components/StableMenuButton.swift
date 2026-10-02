import AppKit
import SwiftUI

/// A SwiftUI-labelled button that presents an AppKit `NSMenu`.
///
/// Use this instead of SwiftUI `Menu` for long-lived model pickers that sit in highly
/// reactive views. AppKit owns menu tracking, the open menu is screen-anchored, and a
/// shared presenter retains it — so unrelated SwiftUI invalidations and even removal
/// of this button's view do not tear down the open picker.
struct StableMenuButton<Label: View>: View {
    enum TriggerStyle {
        case automatic
        case borderless
        case plain
    }

    let items: () -> [StableMenuItem]
    let triggerStyle: TriggerStyle
    let onOpen: @MainActor () -> Void
    @ViewBuilder let label: () -> Label

    @StateObject private var anchor = StableMenuAnchor()

    init(
        items: @escaping () -> [StableMenuItem],
        triggerStyle: TriggerStyle = .automatic,
        onOpen: @escaping @MainActor () -> Void = {},
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.items = items
        self.triggerStyle = triggerStyle
        self.onOpen = onOpen
        self.label = label
    }

    var body: some View {
        switch triggerStyle {
        case .automatic:
            button
        case .borderless:
            button.buttonStyle(.borderless)
        case .plain:
            button.buttonStyle(.plain)
        }
    }

    private var button: some View {
        Button {
            onOpen()
            if let view = anchor.view {
                view.window?.stableMenuPresenter.present(items(), from: view)
            }
        } label: {
            label()
        }
        .background(
            StableMenuAnchorView(anchor: anchor)
                .allowsHitTesting(false)
        )
    }
}

enum StableMenuItemStyle: Equatable {
    case normal
    case warning
}

struct StableMenuItem {
    private enum Kind {
        case action(() -> Void)
        case submenu([StableMenuItem])
        case separator
        case header
    }

    private let kind: Kind
    let title: String
    let isEnabled: Bool
    let isSelected: Bool
    let imageSystemName: String?
    let style: StableMenuItemStyle
    /// Optional VoiceOver overrides forwarded to the produced `NSMenuItem`: the label
    /// replaces the spoken title, the value carries counts/state, and the hint is help.
    let accessibilityLabel: String?
    let accessibilityValue: String?
    let accessibilityHint: String?

    private init(
        title: String,
        kind: Kind,
        isEnabled: Bool = true,
        isSelected: Bool = false,
        imageSystemName: String? = nil,
        style: StableMenuItemStyle = .normal,
        accessibilityLabel: String? = nil,
        accessibilityValue: String? = nil,
        accessibilityHint: String? = nil
    ) {
        self.title = title
        self.kind = kind
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.imageSystemName = imageSystemName
        self.style = style
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.accessibilityHint = accessibilityHint
    }

    static func action(
        _ title: String,
        isEnabled: Bool = true,
        isSelected: Bool = false,
        imageSystemName: String? = nil,
        style: StableMenuItemStyle = .normal,
        accessibilityLabel: String? = nil,
        accessibilityValue: String? = nil,
        accessibilityHint: String? = nil,
        _ action: @escaping () -> Void
    ) -> StableMenuItem {
        StableMenuItem(
            title: title,
            kind: .action(action),
            isEnabled: isEnabled,
            isSelected: isSelected,
            imageSystemName: imageSystemName,
            style: style,
            accessibilityLabel: accessibilityLabel,
            accessibilityValue: accessibilityValue,
            accessibilityHint: accessibilityHint
        )
    }

    static func submenu(
        _ title: String,
        imageSystemName: String? = nil,
        style: StableMenuItemStyle = .normal,
        accessibilityLabel: String? = nil,
        accessibilityValue: String? = nil,
        accessibilityHint: String? = nil,
        items: [StableMenuItem]
    ) -> StableMenuItem {
        StableMenuItem(
            title: title,
            kind: .submenu(items),
            imageSystemName: imageSystemName,
            style: style,
            accessibilityLabel: accessibilityLabel,
            accessibilityValue: accessibilityValue,
            accessibilityHint: accessibilityHint
        )
    }

    static func header(_ title: String) -> StableMenuItem {
        StableMenuItem(title: title, kind: .header, isEnabled: false)
    }

    static func message(_ title: String) -> StableMenuItem {
        StableMenuItem(title: title, kind: .header, isEnabled: false)
    }

    static var separator: StableMenuItem {
        StableMenuItem(title: "", kind: .separator, isEnabled: false)
    }

    fileprivate func makeMenuItem(fontPreset: FontScalePreset = .current) -> NSMenuItem {
        switch kind {
        case .separator:
            return .separator()
        case .header:
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            configureImage(on: item)
            configureTitle(on: item, fontPreset: fontPreset)
            configureAccessibility(on: item)
            return item
        case let .action(action):
            let item = NSMenuItem(title: title, action: #selector(StableMenuActionBox.invoke), keyEquivalent: "")
            let actionBox = StableMenuActionBox(action: action)
            item.target = actionBox
            item.representedObject = actionBox
            item.isEnabled = isEnabled
            item.state = isSelected ? .on : .off
            configureImage(on: item)
            configureTitle(on: item, fontPreset: fontPreset)
            configureAccessibility(on: item)
            return item
        case let .submenu(childItems):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = isEnabled
            item.state = isSelected ? .on : .off
            item.submenu = NSMenu.stableMenu(from: childItems, fontPreset: fontPreset)
            configureImage(on: item)
            configureTitle(on: item, fontPreset: fontPreset)
            configureAccessibility(on: item)
            return item
        }
    }

    private func configureAccessibility(on item: NSMenuItem) {
        if let accessibilityLabel {
            item.setAccessibilityLabel(accessibilityLabel)
        }
        if let accessibilityValue {
            item.setAccessibilityValue(accessibilityValue)
        }
        if let accessibilityHint {
            item.setAccessibilityHelp(accessibilityHint)
        }
    }

    private func configureImage(on item: NSMenuItem) {
        guard let imageSystemName,
              let image = NSImage(systemSymbolName: imageSystemName, accessibilityDescription: title)
        else {
            return
        }
        if style == .warning,
           let warningImage = image.withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
        {
            warningImage.isTemplate = false
            item.image = warningImage
        } else {
            image.isTemplate = true
            item.image = image
        }
    }

    private func configureTitle(on item: NSMenuItem, fontPreset: FontScalePreset) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: fontPreset.nsFont(sizeAtNormal: CGFloat(NSFont.systemFontSize), rounded: false)
        ]
        if style == .warning {
            attributes[.foregroundColor] = NSColor.systemOrange
        }
        item.attributedTitle = NSAttributedString(string: title, attributes: attributes)
    }
}

extension NSMenu {
    static func stableMenu(from items: [StableMenuItem], fontPreset: FontScalePreset = .current) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            menu.addItem(item.makeMenuItem(fontPreset: fontPreset))
        }
        return menu
    }
}

/// Per-button mount state used only to locate the trigger's on-screen position at
/// click time. The open menu's lifetime is owned by the window's `StableMenuPresenter`,
/// so tearing down or rebuilding the trigger cannot dismiss it mid-track.
@MainActor
private final class StableMenuAnchor: ObservableObject {
    weak var view: NSView?
}

private var stableMenuPresenterKey = 0

extension NSWindow {
    /// The presenter owning this window's open `StableMenuButton` menu. Window-scoped
    /// rather than view-scoped so a trigger that unmounts mid-track cannot release the
    /// tracking menu — and window teardown can still dismiss it.
    var stableMenuPresenter: StableMenuPresenter {
        if let existing = objc_getAssociatedObject(self, &stableMenuPresenterKey) as? StableMenuPresenter {
            return existing
        }
        let presenter = StableMenuPresenter()
        objc_setAssociatedObject(self, &stableMenuPresenterKey, presenter, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return presenter
    }
}

/// Owner of the one AppKit menu currently tracking for `StableMenuButton` on a given
/// window. Retention lives on the window rather than in view-scoped state, so trigger
/// teardown cannot release the menu or break tracking.
@MainActor
final class StableMenuPresenter: NSObject, NSMenuDelegate {
    /// The menu currently presented, retained for the duration of tracking.
    /// Exposed for tests that need to assert lifetime across trigger teardown.
    private(set) var openMenu: NSMenu?
    private var windowCloseObserver: NSObjectProtocol?

    /// Presents `items` with its top corner at `anchorView`'s lower-left on-screen
    /// position, resolved once at click time. The `in: nil` popup interprets the
    /// point in screen coordinates, so tracking is not bound to the anchor view and
    /// survives the anchor leaving its window.
    func present(_ items: [StableMenuItem], from anchorView: NSView?) {
        guard !items.isEmpty, let anchorView, let window = anchorView.window else { return }

        closeOpenMenu()
        let menu = NSMenu.stableMenu(from: items, fontPreset: FontScalePreset.current)
        menu.delegate = self
        openMenu = menu
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closeOpenMenu()
            }
        }

        let popupPoint = NSPoint(x: 0, y: anchorView.bounds.height + 2)
        let windowPoint = anchorView.convert(popupPoint, to: nil)
        let screenPoint = window.convertToScreen(NSRect(origin: windowPoint, size: .zero)).origin
        menu.popUp(positioning: nil, at: screenPoint, in: nil)

        // `popUp` is synchronous: tracking has ended by now. `menuDidClose` clears
        // `openMenu` when tracking ran; this line covers the case where tracking
        // never began (for example, no usable user session in a test host).
        if openMenu === menu {
            releaseMenu()
        }
    }

    /// Cancels any in-flight tracking and releases the retained menu. Used when the
    /// owning window closes so an orphaned menu cannot linger.
    func closeOpenMenu() {
        openMenu?.cancelTracking()
        releaseMenu()
    }

    private func releaseMenu() {
        openMenu = nil
        if let observer = windowCloseObserver {
            windowCloseObserver = nil
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard openMenu === menu else { return }
        releaseMenu()
    }
}

private final class StableMenuActionBox: NSObject {
    let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func invoke() {
        action()
    }
}

@MainActor
private struct StableMenuAnchorView: NSViewRepresentable {
    let anchor: StableMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        // Intentionally empty: the presented menu is screen-anchored and owned by the
        // window's `StableMenuPresenter`, so dismantling the trigger must not touch it.
    }
}
