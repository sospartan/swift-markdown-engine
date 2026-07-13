//
//  NativeTextView+TableEditor.swift
//  MarkdownEngine
//
//  Creates, positions, and destroys host-provided table editor views
//  that sit on top of the engine's rendered table image while the caret
//  is inside the table.
//

import AppKit

extension NativeTextView {

    /// Coalesce overlay updates to one per runloop tick.
    func updateTableEditors() {
        if tableEditors.isEmpty {
            performTableEditorUpdate()
            return
        }
        if pendingTableEditorUpdate { return }
        pendingTableEditorUpdate = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingTableEditorUpdate = false
            self.performTableEditorUpdate()
        }
    }

    /// Full source range of the currently active custom table editor, if any.
    func currentCustomTableEditorRange() -> NSRange? {
        guard let storage = textStorage else { return nil }
        let full = NSRange(location: 0, length: storage.length)
        var found: NSRange?
        storage.enumerateAttribute(.customTableEditorAnchor, in: full, options: []) { value, range, stop in
            if value is Int {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    /// Walk storage; create / position / destroy editor views to match
    /// `.customTableEditorAnchor` attributes.
    private func performTableEditorUpdate() {
        guard let storage = textStorage,
              let bridge = layoutBridge,
              let container = bridge.firstTextContainer,
              let tlm = textLayoutManager else {
            removeAllTableEditors()
            return
        }

        let delegate = configuration.services.tableDelegate
        let fullRange = NSRange(location: 0, length: storage.length)
        let containerWidth = container.size.width

        // Cheap presence-check first.
        var hasAny = false
        storage.enumerateAttribute(.customTableEditorAnchor, in: fullRange, options: []) { value, _, stop in
            if value is Int { hasAny = true; stop.pointee = true }
        }
        guard hasAny else {
            removeAllTableEditors()
            return
        }

        tlm.ensureLayout(for: tlm.documentRange)

        var seenIDs: Set<Int> = []
        let nsText = string as NSString

        storage.enumerateAttribute(.customTableEditorAnchor, in: fullRange, options: []) { value, attrRange, _ in
            guard let editorID = value as? Int else { return }
            seenIDs.insert(editorID)

            // Find the anchor character that carries the image to get the precise position.
            let anchorLocation: Int? = {
                guard let storage = textStorage else { return nil }
                var loc: Int = attrRange.location
                while loc < NSMaxRange(attrRange) {
                    if storage.attribute(.latexImage, at: loc, effectiveRange: nil) is NSImage {
                        return loc
                    }
                    loc += 1
                }
                return nil
            }()
            guard let al = anchorLocation else { return }

            // Prefer the full collapsed-source range (same as WideTableOverlay) so
            // inactive image and active editor share one top-left; single-char
            // segments can sit a few points lower than the line box used for image draw.
            let rangeAnchorRect = bridge.boundingRect(forCharacterRange: attrRange, in: container)
            let charAnchorRect = bridge.boundingRect(
                forCharacterRange: NSRange(location: al, length: 1), in: container
            )
            let actualAnchorRect = !rangeAnchorRect.isEmpty ? rangeAnchorRect : charAnchorRect
            guard !actualAnchorRect.isEmpty else { return }

            let imageBounds: CGRect
            if let boundsVal = storage.attribute(
                .customTableEditorImageBounds, at: attrRange.location, effectiveRange: nil
            ),
               let boundsRect = (boundsVal as? NSValue)?.rectValue {
                imageBounds = boundsRect
            } else {
                imageBounds = actualAnchorRect
            }

            let contentSize = imageBounds.size
            let usableContainer = (containerWidth.isFinite && containerWidth > 0) ? containerWidth : contentSize.width
            // Always host in a clip view so wide tables never paint past the column.
            let hostWidth = min(contentSize.width, usableContainer)
            let needsHScroll = contentSize.width > usableContainer + 0.5
            // Match WideTableOverlay reserved height (image + scroller strip when wide)
            // so inactive ↔ active host chrome lines up; document still shows only the grid.
            let reservedHeight: CGFloat = {
                if let total = storage.attribute(
                    .scrollableBlockTotalHeight, at: attrRange.location, effectiveRange: nil
                ) as? CGFloat, total > contentSize.height {
                    return total
                }
                return contentSize.height
            }()
            // Same parent / coordinate space as WideTableOverlay (breakout reading column).
            let breakout = configuration.readingWidth != nil
            let hostParent: NSView = breakout ? (superview ?? self) : self
            let columnLeft = (breakout ? frame.origin.x : 0) + textContainerOrigin.x + actualAnchorRect.minX
            let top = (breakout ? frame.origin.y : 0) + textContainerOrigin.y + actualAnchorRect.minY
            var hostFrame = NSRect(
                x: columnLeft,
                y: top,
                width: hostWidth,
                height: reservedHeight
            )
            // Pixel-align to avoid sub-pixel vertical wobble when swapping image ↔ editor.
            hostFrame = hostParent.backingAlignedRect(hostFrame, options: [.alignAllEdgesNearest])

            if let existing = tableEditors[editorID] {
                if existing.superview !== hostParent {
                    existing.removeFromSuperview()
                    hostParent.addSubview(existing)
                }
                applyHostFrame(existing, hostFrame: hostFrame, contentSize: contentSize, needsHScroll: needsHScroll)
                if let scroll = existing as? TableEditorScrollView {
                    scroll.setEdgeShadowsVisible(needsHScroll)
                }
                return
            }

            guard let parsed = MarkdownTableParser.parse(nsText.substring(with: attrRange)) else { return }

            guard let editorView = delegate.makeEditorView(
                for: parsed,
                range: attrRange,
                textView: self,
                baseFont: baseFont,
                commit: { [weak self] replacement in
                    guard let self, let handler = self.tableEditorCommitHandler else { return }
                    handler(attrRange, replacement)
                }
            ) else { return }

            // Always wrap in NSScrollView: clips overflow and provides H-scroll when wide.
            // Vertical scrolling is intentionally disabled — table height is fully reserved.
            // Document height must equal the grid height (not reserved strip) so the grid
            // stays top-aligned inside a host that may include the scroller strip.
            editorView.frame = NSRect(
                origin: .zero,
                size: CGSize(width: contentSize.width, height: contentSize.height)
            )
            editorView.autoresizingMask = []
            let scroll = TableEditorScrollView(frame: hostFrame)
            scroll.hasHorizontalScroller = true
            scroll.hasVerticalScroller = false
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.borderType = .noBorder
            scroll.drawsBackground = false
            scroll.backgroundColor = .clear
            scroll.horizontalScrollElasticity = .none
            scroll.verticalScrollElasticity = .none
            scroll.usesPredominantAxisScrolling = true
            scroll.documentView = editorView
            scroll.autoresizingMask = []
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.setEdgeShadowsVisible(needsHScroll)
            hostParent.addSubview(scroll)
            tableEditors[editorID] = scroll

            // Live size updates while typing (row height / wrap) without waiting for commit restyle.
            if let sizeHost = editorView as? TableEditorSizeReporting {
                sizeHost.onContentSizeChange = { [weak self, weak scroll, weak editorView] newSize in
                    guard let self, let scroll, let editorView else { return }
                    var hf = scroll.frame
                    let usable = self.layoutBridge?.firstTextContainer?.size.width ?? hf.width
                    hf.size.width = min(newSize.width, usable > 0 ? usable : newSize.width)
                    // Keep reserved scroller strip if the host was taller than the grid.
                    let strip = max(0, hf.height - editorView.frame.height)
                    hf.size.height = newSize.height + strip
                    scroll.frame = hf
                    editorView.frame = NSRect(
                        origin: .zero,
                        size: CGSize(width: newSize.width, height: newSize.height)
                    )
                    scroll.superview?.setNeedsDisplay(hf.insetBy(dx: -2, dy: -2))
                }
            }

            hostParent.setNeedsDisplay(hostFrame.insetBy(dx: -2, dy: -2))
        }

        for (id, editor) in tableEditors where !seenIDs.contains(id) {
            let vacated = editor.frame
            editor.removeFromSuperview()
            tableEditors.removeValue(forKey: id)
            setNeedsDisplay(vacated.insetBy(dx: -2, dy: -2))
        }
    }

    private func applyHostFrame(
        _ host: NSView,
        hostFrame: NSRect,
        contentSize: CGSize,
        needsHScroll: Bool
    ) {
        if !host.frame.equalTo(hostFrame) {
            host.frame = hostFrame
        }
        if let scroll = host as? NSScrollView {
            scroll.horizontalScrollElasticity = .none
            scroll.verticalScrollElasticity = .none
            if let doc = scroll.documentView {
                // Prefer live document width if the host editor already grew (typing).
                let live = doc.frame.size
                let w = max(contentSize.width, live.width)
                // Document height is the grid only; host may be taller (scroller strip).
                // Keep document top-aligned and lock Y scroll to 0.
                let h = max(contentSize.height, live.height)
                let resolved = NSRect(origin: .zero, size: CGSize(width: w, height: h))
                if !doc.frame.equalTo(resolved) {
                    doc.frame = resolved
                }
                let origin = scroll.contentView.bounds.origin
                if origin.y != 0 {
                    scroll.contentView.scroll(to: NSPoint(x: origin.x, y: 0))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        }
        _ = needsHScroll
    }

    func removeAllTableEditors() {
        for (_, editor) in tableEditors {
            let parent = editor.superview
            let vacated = editor.frame
            editor.removeFromSuperview()
            parent?.setNeedsDisplay(vacated.insetBy(dx: -2, dy: -2))
        }
        tableEditors.removeAll()
    }

    /// Resolve the host editor under a text-view-local point and open a cell.
    /// Host may be a sibling (breakout reading-column parent), so convert via window.
    func forwardClickToTableEditor(at localPoint: NSPoint) {
        updateTableEditors()
        guard !tableEditors.isEmpty else { return }
        let windowPoint = convert(localPoint, to: nil)
        for host in tableEditors.values {
            let inHost = host.convert(windowPoint, from: nil)
            guard host.bounds.contains(inHost) else { continue }
            if let controlling = host as? MarkdownTableEditorControlling {
                controlling.beginEditing(at: inHost)
            } else if let scroll = host as? NSScrollView,
                      let doc = scroll.documentView {
                let inDoc = doc.convert(inHost, from: host)
                if let controlling = doc as? MarkdownTableEditorControlling {
                    controlling.beginEditing(at: inDoc)
                }
            }
            break
        }
    }
}

/// Optional hook so the host editor can push live size changes (row wrap) to the engine host.
@MainActor
public protocol TableEditorSizeReporting: AnyObject {
    var onContentSizeChange: ((CGSize) -> Void)? { get set }
}

/// Horizontal-only scroll host for custom table editors.
/// Vertical wheel/trackpad gestures are forwarded to the document scroller so
/// the table never rubber-bands or overscrolls vertically.
///
/// Owns:
/// - edge shadows on overflow sides only
/// - fixed left/right table borders (not part of the scrolling grid document)
final class TableEditorScrollView: NSScrollView {
    private let leftEdgeShadow = TableEdgeShadowView(edge: .left)
    private let rightEdgeShadow = TableEdgeShadowView(edge: .right)
    private let leftBorder = TableFixedSideBorderView()
    private let rightBorder = TableFixedSideBorderView()
    private var canScrollHorizontally = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        clipsToBounds = true
        for v in [leftBorder, rightBorder, leftEdgeShadow, rightEdgeShadow] {
            v.wantsLayer = true
            addSubview(v, positioned: .above, relativeTo: contentView)
        }
        leftEdgeShadow.isHidden = true
        rightEdgeShadow.isHidden = true
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentBoundsDidChange),
            name: NSView.boundsDidChangeNotification, object: contentView
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func setEdgeShadowsVisible(_ canScroll: Bool) {
        canScrollHorizontally = canScroll
        refreshChrome()
    }

    @objc private func contentBoundsDidChange() { refreshChrome() }

    private func refreshChrome() {
        layoutFixedBorders()
        layoutEdgeShadows()
        updateEdgeShadowVisibility()
    }

    private func layoutFixedBorders() {
        let bw: CGFloat = 1
        let b = bounds
        leftBorder.frame = NSRect(x: 0, y: 0, width: bw, height: b.height)
        rightBorder.frame = NSRect(x: max(0, b.width - bw), y: 0, width: bw, height: b.height)
    }

    private func layoutEdgeShadows() {
        let w = TableEdgeShadowView.width
        let b = bounds
        leftEdgeShadow.frame = NSRect(x: 0, y: 0, width: min(w, b.width), height: b.height)
        rightEdgeShadow.frame = NSRect(
            x: max(0, b.width - w), y: 0,
            width: min(w, b.width), height: b.height
        )
    }

    private func updateEdgeShadowVisibility() {
        guard canScrollHorizontally, let doc = documentView else {
            leftEdgeShadow.isHidden = true
            rightEdgeShadow.isHidden = true
            return
        }
        let x = contentView.bounds.origin.x
        let maxX = max(0, doc.frame.width - contentView.bounds.width)
        if maxX <= 0.5 {
            leftEdgeShadow.isHidden = true
            rightEdgeShadow.isHidden = true
            return
        }
        leftEdgeShadow.isHidden = x <= 0.5
        rightEdgeShadow.isHidden = x >= maxX - 0.5
    }

    override func layout() {
        super.layout()
        refreshChrome()
    }

    override func tile() {
        super.tile()
        let origin = contentView.bounds.origin
        if origin.y != 0 {
            contentView.scroll(to: NSPoint(x: origin.x, y: 0))
            reflectScrolledClipView(contentView)
        }
        // Re-assert chrome after AppKit rewrites scroll-view subviews.
        refreshChrome()
        // Keep chrome above clip view after tile().
        for v in [leftBorder, rightBorder, leftEdgeShadow, rightEdgeShadow] {
            addSubview(v, positioned: .above, relativeTo: contentView)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
            updateEdgeShadowVisibility()
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }
}

/// Soft vertical drop-shadow strip on the left/right edge of a horizontally scrollable table.
final class TableEdgeShadowView: NSView {
    enum Edge { case left, right }
    static let width: CGFloat = 6
    private let edge: Edge

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let colors: [CGColor]
        let locations: [CGFloat] = [0, 1]
        switch edge {
        case .left:
            colors = [
                NSColor.black.withAlphaComponent(0.07).cgColor,
                NSColor.black.withAlphaComponent(0).cgColor,
            ]
        case .right:
            colors = [
                NSColor.black.withAlphaComponent(0).cgColor,
                NSColor.black.withAlphaComponent(0.07).cgColor,
            ]
        }
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: locations
        ) else { return }
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: bounds.width, y: 0),
            options: []
        )
    }
}

/// 1pt vertical border on the table host so L/R edges stay fixed while content scrolls.
final class TableFixedSideBorderView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSBezierPath(rect: bounds).fill()
    }
}
