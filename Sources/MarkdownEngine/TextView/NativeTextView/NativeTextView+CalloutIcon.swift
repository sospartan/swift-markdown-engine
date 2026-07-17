//
//  NativeTextView+CalloutIcon.swift
//  MarkdownEngine
//
//  Hit-test for the rendered callout icon (the SF Symbol drawn at the first
//  line of a `> [!TYPE]` block in render mode). On hit, place the caret on the
//  callout's first line and hand the icon rect + current type to the embedder
//  via `onCalloutIconClick`, so it can present a type-switch menu.
//

import AppKit

extension NativeTextView {

    /// The drawn callout icon under `containerPoint`, if any. Only the first
    /// line of a callout block carries an icon, and only in render mode
    /// (`CalloutAttribute.isEditing == false`). `containerPoint` is in the
    /// text-container coordinate space (view-local minus `textContainerOrigin`).
    func calloutIconHit(at containerPoint: CGPoint) -> (firstLineRange: NSRange, iconRect: CGRect, type: String)? {
        guard let textContainer = textContainer,
              let bridge = layoutBridge,
              let storage = textStorage, storage.length > 0 else { return nil }
        let baseFont = self.baseFont
        let iconHeight = ceil(baseFont.ascender - baseFont.descender)
        let iconWidth = iconHeight + 4
        let nsText = storage.string as NSString

        var hit: (firstLineRange: NSRange, iconRect: CGRect, type: String)?
        storage.enumerateAttribute(.callout, in: NSRange(location: 0, length: storage.length), options: []) { value, attrRange, stop in
            guard let ca = value as? CalloutAttribute, !ca.isEditing else { return }
            // Only the first line of the block carries the icon: the previous
            // non-newline character must not share the same callout id.
            if !isFirstCalloutLine(at: attrRange.location, nsText: nsText, storage: storage, current: ca) { return }
            // First visual line only — a wrapped continuation indents at
            // `headIndent` (no icon reservation) and would skew the X math.
            let firstLine = bridge.firstSegmentRect(forCharacterRange: attrRange, in: textContainer)
            guard firstLine != .zero else { return }
            // The styler indents the first render line by `textIndent + iconWidth`
            // (MarkdownASTStyler.styleCallout), so the icon sits immediately to
            // the left of the text: `iconX = firstLine.minX - iconWidth`. The
            // text starts at `firstLine.minX`, so the icon column never overlaps
            // content clicks.
            let iconX = firstLine.minX - iconWidth
            // Vertically span the whole first visual line — the icon is drawn
            // centered on the cap-height, but reconstructing the exact baseline
            // from a segment rect is fragile across `extraLineHeight`/leading.
            // The full-line height is forgiving and stays within the icon's X
            // column, so it won't catch clicks on the title or body.
            let iconRect = CGRect(x: iconX, y: firstLine.minY, width: iconWidth, height: firstLine.height)
            if iconRect.contains(containerPoint) {
                let firstLineRange = nsText.lineRange(for: NSRange(location: attrRange.location, length: 0))
                hit = (firstLineRange, iconRect, ca.type)
                stop.pointee = true
            }
        }
        return hit
    }

    /// True when no preceding non-newline character carries a `.callout`
    /// attribute with the same `id` — i.e. this is the first line of its
    /// callout block. Mirrors `MarkdownTextLayoutFragment.isFirstCalloutFragment`.
    private func isFirstCalloutLine(
        at index: Int, nsText: NSString, storage: NSTextStorage, current: CalloutAttribute
    ) -> Bool {
        var idx = index - 1
        while idx >= 0 {
            let ch = nsText.character(at: idx)
            if ch == 0x0A || ch == 0x0D { idx -= 1; continue }
            break
        }
        if idx < 0 { return true }
        guard let prev = storage.attribute(.callout, at: idx, effectiveRange: nil) as? CalloutAttribute
        else { return true }
        return prev.id != current.id
    }

    /// On icon hit, select the callout's first line (so the existing
    /// `didMarkdownCallout` replaces `[!OLD]` while keeping the title) and
    /// invoke the embedder hook to present a type-switch menu. Returns `true`
    /// when the click was consumed.
    @discardableResult
    func handleCalloutIconClickIfHit(event: NSEvent) -> Bool {
        guard let storage = textStorage, storage.length > 0, isEditable else { return false }
        let localPoint = convert(event.locationInWindow, from: nil)
        let containerPoint = CGPoint(
            x: localPoint.x - textContainerOrigin.x,
            y: localPoint.y - textContainerOrigin.y
        )
        guard let result = calloutIconHit(at: containerPoint) else { return false }
        // Place the caret on the callout's first line so `didMarkdownCallout`
        // (which operates on the selected line) replaces the type in place.
        setSelectedRange(NSRange(location: result.firstLineRange.location, length: 0))
        if let coord = delegate as? NativeTextViewCoordinator {
            // Icon rect in text-view-local coords (container + containerOrigin),
            // ready for `NSMenu.popUp(..., in: textView)`.
            let viewRect = CGRect(
                x: result.iconRect.origin.x + textContainerOrigin.x,
                y: result.iconRect.origin.y + textContainerOrigin.y,
                width: result.iconRect.width,
                height: result.iconRect.height
            )
            coord.onCalloutIconClick?(self, viewRect, result.type)
        }
        return true
    }
}
