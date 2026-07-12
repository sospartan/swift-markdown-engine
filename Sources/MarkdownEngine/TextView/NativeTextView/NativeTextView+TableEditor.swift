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

            let actualAnchorRect = bridge.boundingRect(
                forCharacterRange: NSRange(location: al, length: 1), in: container
            )
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
            let hostFrame = NSRect(
                x: textContainerOrigin.x + actualAnchorRect.minX,
                y: textContainerOrigin.y + actualAnchorRect.minY,
                width: hostWidth,
                height: contentSize.height
            )

            if let existing = tableEditors[editorID] {
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
            // Document height must equal host height so AppKit never creates a vertical range.
            editorView.frame = NSRect(
                origin: .zero,
                size: CGSize(width: contentSize.width, height: hostFrame.height)
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
            addSubview(scroll)
            tableEditors[editorID] = scroll

            // Live size updates while typing (row height / wrap) without waiting for commit restyle.
            if let sizeHost = editorView as? TableEditorSizeReporting {
                sizeHost.onContentSizeChange = { [weak self, weak scroll, weak editorView] newSize in
                    guard let self, let scroll, let editorView else { return }
                    var hf = scroll.frame
                    let usable = self.layoutBridge?.firstTextContainer?.size.width ?? hf.width
                    hf.size.width = min(newSize.width, usable > 0 ? usable : newSize.width)
                    hf.size.height = newSize.height
                    scroll.frame = hf
                    // Keep document height locked to host height (no vertical overscroll).
                    editorView.frame = NSRect(
                        origin: .zero,
                        size: CGSize(width: newSize.width, height: hf.height)
                    )
                    self.setNeedsDisplay(hf.insetBy(dx: -2, dy: -2))
                }
            }

            setNeedsDisplay(hostFrame.insetBy(dx: -2, dy: -2))
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
                // Prefer live document size if the host editor already grew (typing).
                let live = doc.frame.size
                let w = max(contentSize.width, live.width)
                // Keep document height exactly equal to host height so AppKit never
                // creates a vertical scrollable range / overscroll rubber-band.
                let h = hostFrame.height
                let resolved = NSRect(origin: .zero, size: CGSize(width: w, height: h))
                if !doc.frame.equalTo(resolved) {
                    doc.frame = resolved
                }
            }
        }
    }

    func removeAllTableEditors() {
        for (_, editor) in tableEditors {
            editor.removeFromSuperview()
        }
        tableEditors.removeAll()
    }

    /// Resolve the host editor under a text-view-local point and open a cell.
    func forwardClickToTableEditor(at localPoint: NSPoint) {
        updateTableEditors()
        guard !tableEditors.isEmpty else { return }
        for host in tableEditors.values {
            let inHost = host.convert(localPoint, from: self)
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
