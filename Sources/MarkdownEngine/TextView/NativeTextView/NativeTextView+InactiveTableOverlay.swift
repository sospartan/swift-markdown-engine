//
//  NativeTextView+InactiveTableOverlay.swift
//  MarkdownEngine
//
//  Host-provided overlay views for inactive custom tables (e.g. hover 3-dots menu).
//

import AppKit

extension NativeTextView {

    /// Coalesce inactive overlay updates to one per runloop tick.
    func updateInactiveTableOverlays() {
        if inactiveTableOverlays.isEmpty {
            performInactiveTableOverlayUpdate()
            return
        }
        if pendingInactiveTableOverlayUpdate { return }
        pendingInactiveTableOverlayUpdate = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingInactiveTableOverlayUpdate = false
            self.performInactiveTableOverlayUpdate()
        }
    }

    /// Force a synchronous reconcile so overlay creation can keep up with restyles.
    func updateInactiveTableOverlaysNow() {
        pendingInactiveTableOverlayUpdate = false
        performInactiveTableOverlayUpdate()
    }

    /// Walk storage; create / position / destroy inactive table overlay views.
    func performInactiveTableOverlayUpdate() {
        guard let storage = textStorage,
              let bridge = layoutBridge,
              let container = bridge.firstTextContainer,
              let tlm = textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage else {
            removeAllInactiveTableOverlays()
            return
        }

        let delegate = configuration.services.tableDelegate
        let fullRange = NSRange(location: 0, length: storage.length)
        let containerWidth = container.size.width

        var hasAny = false
        storage.enumerateAttribute(.inactiveTableOverlayAnchor, in: fullRange, options: []) { value, _, stop in
            if value is Int { hasAny = true; stop.pointee = true }
        }
        guard hasAny else {
            removeAllInactiveTableOverlays()
            return
        }

        tlm.ensureLayout(for: tlm.documentRange)

        var seenIDs: Set<Int> = []
        let breakout = configuration.readingWidth != nil
        let hostParent: NSView = breakout ? (superview ?? self) : self

        storage.enumerateAttribute(.inactiveTableOverlayAnchor, in: fullRange, options: []) { value, attrRange, _ in
            guard let overlayID = value as? Int else { return }

            if storage.attribute(.customTableEditorAnchor, at: attrRange.location, effectiveRange: nil) != nil {
                return
            }

            if storage.attribute(.scrollableBlockSourceID, at: attrRange.location, effectiveRange: nil) != nil {
                return
            }

            seenIDs.insert(overlayID)

            if let start = tcs.location(tcs.documentRange.location, offsetBy: attrRange.location),
               let end = tcs.location(start, offsetBy: attrRange.length),
               let textRange = NSTextRange(location: start, end: end) {
                tlm.ensureLayout(for: textRange)
            }

            let anchorRect = bridge.boundingRect(forCharacterRange: attrRange, in: container)
            guard !anchorRect.isEmpty else { return }

            guard let sourceText = storage.attribute(.inactiveTableSourceText, at: attrRange.location, effectiveRange: nil) as? String,
                  let parsed = MarkdownTableParser.parse(sourceText) else { return }

            var image: NSImage?
            storage.enumerateAttribute(.latexImage, in: attrRange, options: []) { value, _, stop in
                if let img = value as? NSImage {
                    image = img
                    stop.pointee = true
                }
            }
            guard let image else { return }

            let imageBoundsVal = storage.attribute(
                .customTableEditorImageBounds, at: attrRange.location, effectiveRange: nil
            ) as? NSValue
            let imageBounds = imageBoundsVal?.rectValue ?? CGRect(origin: .zero, size: image.size)
            let hostWidth = min(imageBounds.width, containerWidth)
            let hostHeight = imageBounds.height

            let columnLeft = (breakout ? frame.origin.x : 0) + textContainerOrigin.x + anchorRect.minX
            let top = (breakout ? frame.origin.y : 0) + textContainerOrigin.y + anchorRect.minY
            var hostFrame = NSRect(
                x: columnLeft,
                y: top,
                width: hostWidth,
                height: hostHeight
            )
            hostFrame = hostParent.backingAlignedRect(hostFrame, options: [.alignAllEdgesNearest])

            let sourceID = storage.attribute(
                .scrollableBlockSourceID, at: attrRange.location, effectiveRange: nil
            ) as? Int ?? overlayID

            let activate: () -> Void = { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
                self.setSelectedRange(NSRange(location: attrRange.location, length: 0))
            }
            let commit: (String) -> Void = { [weak self] replacement in
                guard let self, let handler = self.tableEditorCommitHandler else { return }
                handler(attrRange, replacement)
            }

            if let existing = inactiveTableOverlays[overlayID] {
                if existing.superview !== hostParent {
                    existing.removeFromSuperview()
                    hostParent.addSubview(existing)
                }
                if !existing.frame.equalTo(hostFrame) {
                    hostParent.setNeedsDisplay(existing.frame)
                    existing.frame = hostFrame
                    hostParent.setNeedsDisplay(hostFrame)
                }
                return
            }

            guard let overlayView = delegate.makeInactiveOverlayView(
                for: parsed,
                range: attrRange,
                textView: self,
                image: image,
                sourceID: sourceID,
                activate: activate,
                commit: commit
            ) else { return }

            overlayView.frame = hostFrame
            overlayView.autoresizingMask = []
            hostParent.addSubview(overlayView)
            inactiveTableOverlays[overlayID] = overlayView
            hostParent.setNeedsDisplay(hostFrame)
        }

        for (id, overlay) in inactiveTableOverlays where !seenIDs.contains(id) {
            let vacated = overlay.frame
            overlay.removeFromSuperview()
            inactiveTableOverlays.removeValue(forKey: id)
            hostParent.setNeedsDisplay(vacated.insetBy(dx: -2, dy: -2))
        }
    }

    /// Drop one inactive overlay synchronously when its table becomes active.
    func removeInactiveTableOverlay(overlayID: Int) {
        guard let overlay = inactiveTableOverlays.removeValue(forKey: overlayID) else { return }
        let parent = overlay.superview
        let vacated = overlay.frame
        overlay.removeFromSuperview()
        parent?.setNeedsDisplay(vacated.insetBy(dx: -2, dy: -2))
    }

    /// Drop all inactive overlays synchronously (file switch path).
    func removeAllInactiveTableOverlays() {
        pendingInactiveTableOverlayUpdate = false
        for (_, overlay) in inactiveTableOverlays {
            let parent = overlay.superview
            let vacated = overlay.frame
            overlay.removeFromSuperview()
            parent?.setNeedsDisplay(vacated.insetBy(dx: -2, dy: -2))
        }
        inactiveTableOverlays.removeAll()
    }
}
