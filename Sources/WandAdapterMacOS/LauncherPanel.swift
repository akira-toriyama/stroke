// Non-activating panel variant of `LauncherMenu`. Picked at runtime
// when `[launcher].mode = "panel"` (see `LauncherMode`). Goal: do not
// steal keyboard focus from the underlying app while the launcher is
// visible — PopClip parity. The user keeps typing in their editor,
// uses the mouse to pick an item, panel closes.
//
// Trade-offs vs `LauncherMenu` (NSMenu):
//   - No keyboard navigation (panel cannot become key by design).
//   - Submenus are flattened into one list with " › " breadcrumbs;
//     hierarchical pop-out isn't worth re-implementing for the MVP.
//   - Dynamic items are not yet supported (rendered disabled with a
//     placeholder label, so they don't silently vanish).
//   - State markers (✓ / —) prefix the title instead of using
//     NSMenuItem.state's native rendering.
//
// Spec contract vs `LauncherMenu.present`:
//   - `present(...)` returns **immediately** (`NSMenu.popUp` blocks
//     until dismissed; the panel does not). Callers must not assume
//     synchronous selection.
//   - `onSelect` fires asynchronously on click and is followed by
//     the panel closing.
//   - Only one panel is visible at a time. A second `present(...)`
//     dismisses the first.

import AppKit
import Foundation
import WandCore

@MainActor
public enum LauncherPanel {

    /// Strong reference holder for the currently-visible panel. Both
    /// the controller and its event monitors / closures need to live
    /// past the synchronous return of `present(...)`. Replaced when a
    /// new panel opens; cleared in `dismiss()`.
    private static var current: PanelController?

    public static func present(filteredItems items: [LauncherItem],
                                target: Target,
                                cocoaPoint: NSPoint,
                                onSelect: @escaping (LauncherItem, Target) -> Void) {
        current?.dismiss()
        guard !items.isEmpty else {
            Log.line("launcher-panel: no items for \(target.bundleID) — "
                     + "panel suppressed")
            return
        }
        let controller = PanelController(
            items: items, target: target,
            cocoaPoint: cocoaPoint,
            onSelect: onSelect,
            onDismiss: { current = nil })
        current = controller
        controller.show()
    }
}

/// NSPanel subclass that refuses key/main status. With
/// `canBecomeKey = false` the panel can receive mouse events but
/// macOS won't deliver key events to it — the underlying app keeps
/// its first responder.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class PanelController {
    private let panel: NonActivatingPanel
    private let target: Target
    private let onSelect: (LauncherItem, Target) -> Void
    private let onDismiss: () -> Void
    private var globalMouseMonitor: Any?
    private var globalKeyMonitor: Any?

    init(items: [LauncherItem], target: Target, cocoaPoint: NSPoint,
         onSelect: @escaping (LauncherItem, Target) -> Void,
         onDismiss: @escaping () -> Void) {
        self.target = target
        self.onSelect = onSelect
        self.onDismiss = onDismiss

        let content = Self.buildContent(items: items, target: target)
        let size = content.fittingSize
        // Cursor sits at the panel's top-left corner — same anchor as
        // NSMenu.popUp. NSPanel's contentRect is bottom-left origin,
        // so subtract the height to put the top there.
        let raw = NSRect(
            origin: NSPoint(x: cocoaPoint.x, y: cocoaPoint.y - size.height),
            size: size)
        let placed = Self.clampToScreen(raw, anchor: cocoaPoint)

        self.panel = NonActivatingPanel(
            contentRect: placed,
            styleMask: [.nonactivatingPanel, .borderless,
                        .fullSizeContentView],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces,
                                    .fullScreenAuxiliary, .transient]
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = content

        // Wire each row's tap closure to dispatch + dismiss. Rows are
        // built without a back-reference to the controller; we patch
        // it in here so PanelController owns the closure lifetime.
        wireRowTaps(in: content)
    }

    func show() {
        panel.orderFront(nil)
        installDismissMonitors()
    }

    func dismiss() {
        if let g = globalMouseMonitor {
            NSEvent.removeMonitor(g)
            globalMouseMonitor = nil
        }
        if let k = globalKeyMonitor {
            NSEvent.removeMonitor(k)
            globalKeyMonitor = nil
        }
        panel.orderOut(nil)
        onDismiss()
    }

    // MARK: - Dismiss monitors

    private func installDismissMonitors() {
        // Global monitor (other-app events). Because wand is
        // LSUIElement + the panel is non-activating, "another app" is
        // effectively every app — including our own underlying
        // target. So a click anywhere routes here. We deliberately
        // DON'T install a local monitor for clicks inside the panel
        // — the row buttons handle those via their own action.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            // addGlobalMonitor delivers on the main thread already,
            // but the closure is non-isolated; hop to MainActor
            // explicitly so the dismiss call type-checks.
            Task { @MainActor in self?.dismiss() }
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] ev in
            // 53 = kVK_Escape. The underlying editor still receives
            // the Esc (global monitor doesn't consume), so the user's
            // Esc-as-vim-mode-exit still works. Acceptable trade.
            if ev.keyCode == 53 {
                Task { @MainActor in self?.dismiss() }
            }
        }
    }

    // MARK: - Content building

    private func wireRowTaps(in view: NSView) {
        for sub in view.subviews {
            if let row = sub as? ItemRow {
                row.onTap = { [weak self] item in
                    guard let self else { return }
                    self.onSelect(item, self.target)
                    self.dismiss()
                }
            } else {
                wireRowTaps(in: sub)
            }
        }
    }

    /// Panel internal width target. Wide enough for typical
    /// breadcrumbed labels (e.g. "ウィンドウ › 最大化(ズーム)") without
    /// wrapping; narrow enough not to feel like a dialog. Each row
    /// constrains to this so right edges align and the hover
    /// highlight is rectangular.
    static let contentWidth: CGFloat = 260

    private static func buildContent(items: [LauncherItem],
                                      target: Target) -> NSView {
        // Background blur — matches the gesture overlay's dark
        // vibrant look (see overlayBlurEnabled in WandConfig).
        let bg = NSVisualEffectView()
        bg.material = .menu
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 8
        bg.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
        stack.translatesAutoresizingMaskIntoConstraints = false

        var rows: [NSView] = []
        if let header = makeHeader(for: target) {
            rows.append(header)
            rows.append(makeSeparator())
        }
        for item in items {
            if item.separatorBefore && !rows.isEmpty {
                rows.append(makeSeparator())
            }
            rows.append(makeRow(item))
        }

        // Constrain each row to a fixed width so right edges align
        // and ItemRow's hover-highlight fills the full row. The stack's
        // `.leading` alignment otherwise lets each row size to its own
        // intrinsic width.
        for row in rows {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        }

        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: bg.topAnchor),
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])
        bg.frame = NSRect(origin: .zero, size: stack.fittingSize)
        return bg
    }

    private static func makeHeader(for target: Target) -> NSView? {
        let (name, icon) = AppIconCache.shared.lookup(
            bundleID: target.bundleID, iconSize: 16)
        if name.isEmpty && icon == nil { return nil }
        let row = ItemRow(label: name, icon: icon, item: nil)
        row.isEnabled = false
        row.isHeader = true
        return row
    }

    private static func makeRow(_ item: LauncherItem) -> NSView {
        if !item.dynamic.isEmpty {
            // Dynamic items aren't supported in panel mode yet —
            // expanding them would mean rendering a child panel /
            // disclosure section, which is out of MVP scope. Show a
            // disabled placeholder so the user notices instead of
            // wondering why their dynamic item silently vanished.
            let row = ItemRow(
                label: "\(item.name) (dynamic — N/A in panel)",
                icon: nil, item: nil)
            row.isEnabled = false
            return row
        }
        let label = renderLabel(item)
        let icon = item.icon.isEmpty
            ? nil
            : LauncherMenu.resolveItemIcon(item.icon)
        return ItemRow(label: label, icon: icon, item: item)
    }

    /// Build the row title from the item, folding in group breadcrumb
    /// and state marker. Submenu nesting isn't rendered — the path
    /// becomes a prefix so the user still sees the grouping.
    private static func renderLabel(_ item: LauncherItem) -> String {
        var parts: [String] = []
        switch item.state {
        case "on":    parts.append("✓")
        case "mixed": parts.append("–")
        default:
            if item.state.hasPrefix("shell:") {
                let cmd = String(item.state.dropFirst("shell:".count))
                switch BoundedShell.run(cmd, timeoutMs: 100) {
                case .exited(_, let exit) where exit == 0:
                    parts.append("✓")
                default: break
                }
            }
        }
        if !item.group.isEmpty {
            parts.append(item.group.joined(separator: " › ") + " ›")
        }
        parts.append(item.name)
        return parts.joined(separator: " ")
    }

    private static func makeSeparator() -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            wrap.heightAnchor.constraint(equalToConstant: 7),
            line.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor,
                                          constant: 8),
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor,
                                           constant: -8),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        return wrap
    }

    /// Nudge `rect` so it stays on the screen containing `anchor`.
    /// PopClip-style: prefer down-right; if it falls off the bottom
    /// or right, flip / clamp.
    private static func clampToScreen(_ rect: NSRect,
                                       anchor: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return rect }
        var r = rect
        if r.maxX > visible.maxX { r.origin.x = visible.maxX - r.width }
        if r.minX < visible.minX { r.origin.x = visible.minX }
        if r.minY < visible.minY {
            // Falls off bottom — flip above the cursor instead.
            r.origin.y = anchor.y
            if r.maxY > visible.maxY { r.origin.y = visible.maxY - r.height }
        }
        if r.maxY > visible.maxY { r.origin.y = visible.maxY - r.height }
        return r
    }
}

/// One clickable launcher row. Custom NSView containing a fixed-size
/// NSImageView + an NSTextField, laid out manually so every row has
/// the same height regardless of icon kind (SF Symbol vs emoji glyph
/// vs app .icns). Hover highlight fills the row corner-to-corner.
///
/// Built without the target controller — PanelController patches
/// `onTap` in after construction so it owns the closure lifetime.
@MainActor
private final class ItemRow: NSView {

    var onTap: ((LauncherItem) -> Void)?
    var isEnabled: Bool = true {
        didSet { applyEnabledStyle() }
    }
    /// Header rows (app icon + name) render with a muted title and
    /// don't react to hover. Same disabled visual as `isEnabled =
    /// false`, but without the placeholder-row connotation.
    var isHeader: Bool = false {
        didSet { applyEnabledStyle() }
    }

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let item: LauncherItem?
    private static let iconSize: CGFloat = 16
    private static let rowHeight: CGFloat = 22

    init(label: String, icon: NSImage?, item: LauncherItem?) {
        self.item = item
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 4

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = icon
        addSubview(iconView)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.stringValue = label
        titleField.font = .menuFont(ofSize: 0)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.cell?.usesSingleLineMode = true
        addSubview(titleField)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.rowHeight),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor,
                                                constant: 8),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor,
                                                 constant: -10),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func applyEnabledStyle() {
        if isHeader {
            titleField.textColor = .secondaryLabelColor
        } else {
            titleField.textColor = isEnabled
                ? .labelColor : .tertiaryLabelColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas { removeTrackingArea(ta) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp,
                      .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled, !isHeader else { return }
        layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(0.85).cgColor
        titleField.textColor = .white
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
        applyEnabledStyle()
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, !isHeader, let item else { return }
        onTap?(item)
    }
}
