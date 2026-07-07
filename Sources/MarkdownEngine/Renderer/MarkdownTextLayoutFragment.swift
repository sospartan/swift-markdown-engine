//
//  MarkdownTextLayoutFragment.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 12.04.26.
//
//  TextKit 2 replacement for CodeBlockLayoutManager.
//  Draws code-block backgrounds, LaTeX images, and task checkboxes
//  via NSTextLayoutFragment instead of NSLayoutManager glyph overrides.

import AppKit

// MARK: - Custom attribute keys for rendering overlays

extension NSAttributedString.Key {
    static let latexImage = NSAttributedString.Key("LatexRenderedImage")
    static let latexBounds = NSAttributedString.Key("LatexImageBounds")
    static let latexIsBlock = NSAttributedString.Key("LatexIsBlock")
    static let latexBlockOffsetY = NSAttributedString.Key("LatexBlockOffsetY")
    static let thematicBreak = NSAttributedString.Key("ThematicBreak")
    /// Int nesting level (1-based) of a blockquote line; the fragment
    /// paints that many vertical bars in the left gutter.
    static let blockquoteLevel = NSAttributedString.Key("BlockquoteLevel")
    /// Marks a bullet-list marker char (`-`/`*`/`+`) whose glyph is hidden so
    /// the fragment can paint a `•` in its place. Set to `true`.
    static let bulletMarker = NSAttributedString.Key("BulletListMarker")
    /// CGFloat — natural image width; presence flags block as overlay-rendered.
    static let scrollableBlockNaturalWidth = NSAttributedString.Key("ScrollableBlockNaturalWidth")
    /// Int — hash of source text; key for overlay reconcile + offset persistence.
    static let scrollableBlockSourceID = NSAttributedString.Key("ScrollableBlockSourceID")
    /// CGFloat — total reserved height (image + scroller strip) for overlay sizing.
    static let scrollableBlockTotalHeight = NSAttributedString.Key("ScrollableBlockTotalHeight")
    /// NSValue(range:) — full multi-line range of the wide-table source, used to scope width-change restyles.
    static let scrollableBlockFullRange = NSAttributedString.Key("ScrollableBlockFullRange")
    /// Consolidated callout metadata (type + title + editing flag).
    static let callout = NSAttributedString.Key("Callout")
    /// Marks the literal `[!TYPE]` marker of a callout so later regex passes
    /// (e.g. incomplete-link highlighting) leave it alone.
    static let calloutMarker = NSAttributedString.Key("CalloutMarker")
}

final class CalloutAttribute {
    let type: String
    let title: String
    let color: NSColor
    let icon: String
    var isEditing: Bool
    let id: UUID

    init(type: String, title: String, color: NSColor, icon: String, isEditing: Bool = false, id: UUID = UUID()) {
        self.type = type
        self.title = title
        self.color = color
        self.icon = icon
        self.isEditing = isEditing
        self.id = id
    }
}

final class MarkdownTextLayoutFragment: NSTextLayoutFragment {

    /// Horizontal space (points) each blockquote nesting level occupies —
    /// shared so the styler's text indent and the painted bars line up.
    static let blockquoteIndentPerLevel: CGFloat = 18
    static let blockquoteBarWidth: CGFloat = 3

    /// Strip below an overlay block for the legacy-small scroller (~11pt) + buffer.
    static let scrollableBlockScrollerStrip: CGFloat = 14

    // MARK: - FB15131180

    /// Maps to TextKit-2's private `extraLineFragmentAttributes` selector so we can pin the trailing extra-line metrics to body font; otherwise a trailing heading paragraph inflates `usageBoundsForTextContainer` by ~30pt when the caret enters it. Pattern from STTextView.
    @objc(extraLineFragmentAttributes)
    dynamic var stExtraLineFragmentAttributes: NSDictionary?

    // MARK: - Rendering surface

    /// Extend rendering bounds for code-block backgrounds (full container width)
    /// and block images drawn below text via paragraphSpacing.
    private static let calloutBottomPadding: CGFloat = 15

    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        if hasCodeBlockBackground || hasThematicBreak || hasBlockquote {
            let containerWidth = textLayoutManager?.textContainer?.size.width ?? bounds.width
            bounds.origin.x = -layoutFragmentFrame.origin.x
            bounds.size.width = containerWidth + layoutFragmentFrame.origin.x
        }
        // Extend vertical bounds for callout bottom padding on the last fragment.
        if hasCalloutInFragment,
           let ts = textStorage, let range = fragmentNSRange,
           isLastCalloutFragment(in: range, textStorage: ts) {
            bounds.size.height += Self.calloutBottomPadding
        }
        // Extend bounds to cover block images that render below the text line
        // (visibleSource mode uses paragraphSpacing to create space for the image).
        for rect in blockImageRects(at: .zero) {
            bounds = bounds.union(rect)
        }
        return bounds
    }

    private var hasCalloutInFragment: Bool {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return false }
        return hasCallout(in: range, textStorage: ts)
    }

    // MARK: - Drawing

    override func draw(at point: CGPoint, in context: CGContext) {
        // 1. Code-block backgrounds (behind text)
        drawCodeBlockBackground(at: point, in: context)

        // 2. LaTeX images (behind text — hidden markers are invisible anyway)
        drawLatexImages(at: point, in: context)

        // 3. Callout backgrounds/bars (behind text)
        drawCalloutBackgrounds(at: point, in: context)

        // 4. Normal text
        super.draw(at: point, in: context)

        // 5. Callout icons/titles (on top of hidden source text)
        drawCalloutOverlays(at: point, in: context)

        // 6. Task checkboxes (on top of hidden [ ]/[x] markers)
        drawTaskCheckboxes(at: point, in: context)

        // 5b. Bullet glyphs (on top of hidden -/*/+ markers)
        drawBulletMarkers(at: point, in: context)

        // 6. Thematic breaks (full-width line, painted last so it doesn't
        //    fight with anything that already drew at the line's center)
        drawThematicBreaks(at: point, in: context)

        // 7. Blockquote bars (left gutter, behind nothing — text is indented)
        drawBlockquoteBars(at: point, in: context)
    }

    // MARK: - Helpers

    /// NSRange in the document for this fragment's content.
    private var fragmentNSRange: NSRange? {
        guard let tcs = textLayoutManager?.textContentManager as? NSTextContentStorage else { return nil }
        return Self.nsRange(for: self, in: tcs)
    }

    private static func nsRange(for fragment: NSTextLayoutFragment, in tcs: NSTextContentStorage) -> NSRange? {
        let start = tcs.offset(from: tcs.documentRange.location, to: fragment.rangeInElement.location)
        let end = tcs.offset(from: tcs.documentRange.location, to: fragment.rangeInElement.endLocation)
        guard start != NSNotFound, end != NSNotFound, end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private var textStorage: NSTextStorage? {
        (textLayoutManager?.textContentManager as? NSTextContentStorage)?.textStorage
    }

    /// Returns the drawing position for a character at `docIndex` (document-level NSRange location).
    /// `point` is the draw origin passed to `draw(at:in:)`.
    private func drawPosition(forDocumentCharAt docIndex: Int, point: CGPoint) -> (x: CGFloat, baselineY: CGFloat, lineHeight: CGFloat)? {
        guard let fragRange = fragmentNSRange else { return nil }
        let localIndex = docIndex - fragRange.location
        guard localIndex >= 0 else { return nil }

        // NSTextLineFragment.typographicBounds.origin.y is already relative to the
        // parent layout fragment, so we use it directly — accumulating per-line
        // heights would double-count the inter-line offset on wrapped lines.
        for lineFragment in textLineFragments {
            let lr = lineFragment.characterRange
            if localIndex >= lr.location && localIndex < lr.location + lr.length {
                let charPos = lineFragment.locationForCharacter(at: localIndex)
                let tb = lineFragment.typographicBounds
                return (
                    x: point.x + tb.origin.x + charPos.x,
                    baselineY: point.y + tb.origin.y + charPos.y,
                    lineHeight: tb.height
                )
            }
        }
        return nil
    }

    /// Typographic bounds of the line fragment containing `localIndex`
    /// (index relative to the fragment, not the document).
    private func lineBounds(forLocalIndex localIndex: Int, point: CGPoint) -> CGRect? {
        for lineFragment in textLineFragments {
            let lr = lineFragment.characterRange
            if localIndex >= lr.location && localIndex < lr.location + lr.length {
                let tb = lineFragment.typographicBounds
                return CGRect(x: point.x + lineFragment.glyphOrigin.x + tb.origin.x,
                              y: point.y + tb.origin.y,
                              width: tb.width,
                              height: tb.height)
            }
        }
        return nil
    }

    // MARK: - Code Block Background

    private var hasCodeBlockBackground: Bool {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return false }
        let bgColor = ts.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? NSColor
        guard let bgColor else { return false }
        return isCodeBlockBackgroundColor(bgColor)
    }

    private var hasThematicBreak: Bool {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return false }
        var found = false
        ts.enumerateAttribute(.thematicBreak, in: range, options: []) { value, _, stop in
            if value as? Bool == true {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private var hasBlockquote: Bool {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return false }
        var found = false
        ts.enumerateAttribute(.blockquoteLevel, in: range, options: []) { value, _, stop in
            if value is Int {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private func drawCodeBlockBackground(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return }

        // Only fenced code-block fragments get the full-width fill (first char must carry the code background).
        guard let color = ts.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? NSColor,
              isCodeBlockBackgroundColor(color) else { return }

        let containerWidth = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width

        var effectiveHeight = layoutFragmentFrame.height
        if textLineFragments.count > 1,
           let lastLF = textLineFragments.last,
           lastLF.characterRange.length == 0 {
            effectiveHeight -= lastLF.typographicBounds.height
        }

        let scale = textLayoutManager?.textContainer?.textView?.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let rawY = point.y
        let rawMaxY = point.y + effectiveHeight
        let snappedY = floor(rawY * scale) / scale
        let snappedMaxY = ceil(rawMaxY * scale) / scale

        // Draw full-width background, clipping out any active selection rects
        // so the system's blue selection highlight remains visible inside code blocks.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = nsContext

        let bgRect = CGRect(
            x: point.x - layoutFragmentFrame.origin.x,
            y: snappedY,
            width: containerWidth,
            height: snappedMaxY - snappedY
        )

        let selectionRects = selectionRectsInDrawCoordinates(drawPoint: point, snappedY: snappedY, snappedMaxY: snappedMaxY)
        color.setFill()
        if selectionRects.isEmpty {
            NSBezierPath(rect: bgRect).fill()
        } else {
            let path = NSBezierPath()
            path.windingRule = .evenOdd
            path.appendRect(bgRect)
            for r in selectionRects {
                path.appendRect(r.intersection(bgRect))
            }
            path.fill()
        }
    }

    /// Returns active text-selection rectangles intersecting this fragment, in
    /// the same draw-relative coordinate system used by `drawCodeBlockBackground`.
    private func selectionRectsInDrawCoordinates(drawPoint: CGPoint, snappedY: CGFloat, snappedMaxY: CGFloat) -> [CGRect] {
        guard let tlm = textLayoutManager else { return [] }
        var rects: [CGRect] = []

        let dx = drawPoint.x - layoutFragmentFrame.origin.x
        let myRange = self.rangeInElement

        for selection in tlm.textSelections {
            for textRange in selection.textRanges {
                let interStart = textRange.location.compare(myRange.location) == .orderedAscending
                    ? myRange.location : textRange.location
                let interEnd = textRange.endLocation.compare(myRange.endLocation) == .orderedDescending
                    ? myRange.endLocation : textRange.endLocation
                guard interStart.compare(interEnd) == .orderedAscending,
                      let intersection = NSTextRange(location: interStart, end: interEnd) else { continue }

                tlm.enumerateTextSegments(in: intersection, type: .selection, options: []) { _, segFrame, _, _ in
                    // Expand vertically to match the bgRect's snapped span so the
                    // even-odd cut-out is geometrically congruent with the fill.
                    let drawRect = CGRect(
                        x: segFrame.origin.x + dx,
                        y: snappedY,
                        width: segFrame.width,
                        height: snappedMaxY - snappedY
                    )
                    rects.append(drawRect)
                    return true
                }
            }
        }
        return rects
    }

    private func isCodeBlockBackgroundColor(_ color: NSColor) -> Bool {
        let highlighter = (textLayoutManager?.textContainer?.textView as? NativeTextView)?
            .configuration.services.syntaxHighlighter
            ?? PlainTextSyntaxHighlighter()
        let currentBg = highlighter.backgroundColor()
        guard let colorRGB = color.usingColorSpace(.deviceRGB),
              let currentBgRGB = currentBg.usingColorSpace(.deviceRGB) else { return false }
        let tolerance: CGFloat = 0.03
        return abs(colorRGB.redComponent - currentBgRGB.redComponent) < tolerance &&
               abs(colorRGB.greenComponent - currentBgRGB.greenComponent) < tolerance &&
               abs(colorRGB.blueComponent - currentBgRGB.blueComponent) < tolerance
    }

    // MARK: - LaTeX / Block Image Helpers

    /// Compute the draw rect for a block image at `attrRange` using `point` as
    /// the draw origin.  Shared by `drawLatexImages` and `blockImageRects` so
    /// bounds and rendering stay in sync.
    private func blockImageDrawRect(
        attrRange: NSRange,
        imageBounds: CGRect,
        blockOffsetY: CGFloat?,
        point: CGPoint
    ) -> CGRect? {
        guard let pos = drawPosition(forDocumentCharAt: attrRange.location, point: point) else { return nil }
        let fragLocation = fragmentNSRange?.location ?? 0
        let localStart = attrRange.location - fragLocation
        let localLast = max(localStart, localStart + attrRange.length - 1)
        let firstLb = lineBounds(forLocalIndex: localStart, point: point)
        // For a wrapped source span (e.g. a long `![alt](url)` that wraps in
        // a narrow window), anchor to the LAST line's maxY so the image
        // doesn't paint over subsequent wrapped lines of its own source.
        let lastLb = lineBounds(forLocalIndex: localLast, point: point) ?? firstLb
        let lineHeight = firstLb?.height ?? pos.lineHeight
        let firstLineMinY = firstLb?.origin.y ?? (pos.baselineY - lineHeight)
        let lastLineMaxY = (lastLb?.origin.y ?? firstLineMinY) + (lastLb?.height ?? lineHeight)

        let yPosition: CGFloat
        if let blockOffsetY {
            // Backward-compatible interpretation: `blockOffsetY` is the gap
            // from the FIRST line's top to the image's top (= baseLineHeight
            // + imageGap on a single-line source). Re-anchor to the last
            // line by subtracting one line height, leaving the same single-
            // line geometry intact while pushing the image down by one
            // extra line per wrap.
            yPosition = lastLineMaxY + blockOffsetY - lineHeight
        } else {
            yPosition = firstLineMinY + (lineHeight - imageBounds.height) / 2
        }
        return CGRect(x: pos.x, y: yPosition,
                       width: imageBounds.width, height: imageBounds.height)
    }

    /// Returns the rects of all block images in this fragment, relative to
    /// `point`.  Used by `renderingSurfaceBounds` (with `.zero`) to extend
    /// the surface so images drawn in paragraphSpacing aren't clipped.
    private func blockImageRects(at point: CGPoint) -> [CGRect] {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return [] }
        var rects: [CGRect] = []
        ts.enumerateAttribute(.latexImage, in: range, options: []) { value, attrRange, _ in
            guard value is NSImage else { return }
            let isBlock = ts.attribute(.latexIsBlock, at: attrRange.location, effectiveRange: nil) as? Bool ?? false
            guard isBlock else { return }
            // Skip overlay blocks; surface bounds must stay within container.
            if ts.attribute(.scrollableBlockNaturalWidth, at: attrRange.location, effectiveRange: nil) != nil {
                return
            }
            let boundsVal = ts.attribute(.latexBounds, at: attrRange.location, effectiveRange: nil) as? NSValue
            let imageBounds = boundsVal?.rectValue ?? .zero
            let blockOffsetY = ts.attribute(.latexBlockOffsetY, at: attrRange.location, effectiveRange: nil) as? CGFloat
            if let rect = blockImageDrawRect(attrRange: attrRange, imageBounds: imageBounds, blockOffsetY: blockOffsetY, point: point) {
                rects.append(rect)
            }
        }
        return rects
    }

    // MARK: - LaTeX Images

    private func drawLatexImages(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = nsContext

        ts.enumerateAttribute(.latexImage, in: range, options: []) { [weak self] value, attrRange, _ in
            guard let self, let image = value as? NSImage else { return }

            // Skip overlay-rendered blocks; WideTableOverlay owns the visual.
            if ts.attribute(.scrollableBlockNaturalWidth, at: attrRange.location, effectiveRange: nil) != nil {
                return
            }

            let boundsVal = ts.attribute(.latexBounds, at: attrRange.location, effectiveRange: nil) as? NSValue
            let imageBounds = boundsVal?.rectValue ?? CGRect(origin: .zero, size: image.size)
            let isBlock = ts.attribute(.latexIsBlock, at: attrRange.location, effectiveRange: nil) as? Bool ?? false
            let blockOffsetY = ts.attribute(.latexBlockOffsetY, at: attrRange.location, effectiveRange: nil) as? CGFloat

            guard let pos = drawPosition(forDocumentCharAt: attrRange.location, point: point) else { return }

            let drawRect: CGRect
            if isBlock {
                guard let rect = blockImageDrawRect(attrRange: attrRange, imageBounds: imageBounds, blockOffsetY: blockOffsetY, point: point) else { return }
                drawRect = rect
            } else {
                let descent = imageBounds.origin.y
                drawRect = CGRect(x: pos.x,
                                  y: pos.baselineY + descent - imageBounds.height,
                                  width: imageBounds.width, height: imageBounds.height)
            }
            image.draw(in: drawRect)
        }
    }

    // MARK: - Thematic Breaks (---, ***, ___)

    /// Draw a 1pt horizontal rule across the full container width for any
    /// line fragment whose backing text carries the `.thematicBreak`
    /// attribute. This decouples HR rendering from the source-text length,
    /// so a 3-char `---` looks the same as a 80-char auto-expanded line.
    private func drawThematicBreaks(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return }
        var hasThematic = false
        ts.enumerateAttribute(.thematicBreak, in: range, options: []) { value, _, stop in
            if value as? Bool == true {
                hasThematic = true
                stop.pointee = true
            }
        }
        guard hasThematic else { return }

        let containerWidth = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
        let theme = (textLayoutManager?.textContainer?.textView as? NativeTextView)?
            .configuration.theme ?? .default

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = nsContext

        let strokeColor = theme.strikethroughColor.withAlphaComponent(0.4)
        strokeColor.setFill()

        // Walk each line fragment in this layout fragment and paint a
        // band on those whose first character carries the marker. (HR
        // tokens are always single-line, but the loop is robust if a
        // future caller ever stacks several rules in one paragraph.)
        let fragLocation = fragmentNSRange?.location ?? 0
        for lineFragment in textLineFragments {
            let lr = lineFragment.characterRange
            let docStart = fragLocation + lr.location
            // TextKit 2 appends a synthetic trailing empty line fragment whose
            // characterRange lands at exactly `tsLen` — `attribute(at:)` needs
            // a strictly in-bounds index, so skip the sentinel.
            guard docStart < ts.length else { continue }
            let isHR = ts.attribute(.thematicBreak, at: docStart, effectiveRange: nil) as? Bool == true
            let tb = lineFragment.typographicBounds
            if isHR {
                // tb.origin.y is already relative to this layout fragment.
                let centerY = point.y + tb.origin.y + tb.height / 2
                let bandRect = CGRect(
                    x: point.x - layoutFragmentFrame.origin.x,
                    y: centerY - 0.5,
                    width: containerWidth,
                    height: 1
                )
                NSBezierPath(rect: bandRect).fill()
            }
        }
    }

    // MARK: - Blockquote Bars

    /// Paint `level` vertical bars in the left gutter of every line that
    /// carries `.blockquoteLevel`. Each line paints its own segment, so a
    /// run of quote lines reads as one continuous bar.
    private func drawBlockquoteBars(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return }
        guard !hasCallout(in: range, textStorage: ts) else { return }
        var anyLevel = false
        ts.enumerateAttribute(.blockquoteLevel, in: range, options: []) { value, _, stop in
            if value is Int { anyLevel = true; stop.pointee = true }
        }
        guard anyLevel else { return }

        let textView = textLayoutManager?.textContainer?.textView
        let baseFont = (textView as? NativeTextView)?.baseFont
            ?? (textView?.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize))
        let theme = (textView as? NativeTextView)?.configuration.theme ?? .default
        let indentPerLevel = Self.blockquoteIndentPerLevel
        let barWidth = Self.blockquoteBarWidth

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = nsContext
        theme.mutedText.withAlphaComponent(0.5).setFill()

        let fragLocation = fragmentNSRange?.location ?? 0
        let leftEdge = point.x - layoutFragmentFrame.origin.x
        let isLastFragment = isLastBlockquoteFragment(in: range, textStorage: ts)
        let lastRealLine = textLineFragments.last { fragLocation + $0.characterRange.location < ts.length }

        for lineFragment in textLineFragments {
            let lr = lineFragment.characterRange
            let docStart = fragLocation + lr.location
            // TextKit 2 appends a synthetic trailing empty line fragment whose
            // characterRange lands at exactly `tsLen` — `attribute(at:)` needs
            // a strictly in-bounds index, so skip the sentinel.
            guard docStart < ts.length else { continue }
            let tb = lineFragment.typographicBounds
            if let level = ts.attribute(.blockquoteLevel, at: docStart, effectiveRange: nil) as? Int {
                // tb.origin.y is already relative to this layout fragment.
                let barY = point.y + tb.origin.y
                let extend = isLastFragment && lineFragment === lastRealLine
                let fontHeight = baseFont.ascender - baseFont.descender
                let bottomPadding = max(0, tb.height - fontHeight)
                let barHeight = tb.height + (extend ? bottomPadding : 0)
                for i in 0..<level {
                    let barX = leftEdge + CGFloat(i) * indentPerLevel + indentPerLevel * 0.25
                    NSBezierPath(rect: CGRect(
                        x: barX, y: barY, width: barWidth, height: barHeight
                    )).fill()
                }
            }
        }
    }

    // MARK: - Callouts

    /// Draw a callout background + left accent bar behind text. The icon/title
    /// overlay is drawn afterward in `drawCalloutOverlays` so it renders on top
    /// of the hidden source text.
    private func drawCalloutBackgrounds(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return }
        guard let ca = calloutAttribute(in: range, textStorage: ts) else { return }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = nsContext

        let calloutColor = ca.color
        let containerWidth = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
        let leftEdge = point.x - layoutFragmentFrame.origin.x
        let level = calloutLevel(in: range, textStorage: ts) ?? 1

        // Vertical span of the whole callout block.
        var firstY: CGFloat?
        var lastMaxY: CGFloat?
        for lineFragment in textLineFragments {
            let tb = lineFragment.typographicBounds
            let y = point.y + tb.origin.y
            let maxY = y + tb.height
            if firstY == nil { firstY = y }
            lastMaxY = max(lastMaxY ?? y, maxY)
        }
        guard let firstY = firstY, var lastMaxY = lastMaxY else { return }

        // Background fill. Middle fragments are plain rectangles; only the first
        // fragment rounds its top corners and the last fragment rounds its bottom
        // corners, so adjacent fragments merge into one continuous rounded box.
        let isFirst = isFirstCalloutFragment(in: range, textStorage: ts)
        let isLast = isLastCalloutFragment(in: range, textStorage: ts)
        if isLast { lastMaxY += Self.calloutBottomPadding }
        let bgRect = CGRect(x: leftEdge, y: firstY, width: containerWidth, height: lastMaxY - firstY)
        let bgPath = Self.roundedRectPath(
            rect: bgRect,
            topLeft: isFirst ? 6 : 0,
            topRight: isFirst ? 6 : 0,
            bottomLeft: isLast ? 6 : 0,
            bottomRight: isLast ? 6 : 0
        )
        calloutColor.withAlphaComponent(0.1).setFill()
        bgPath.fill()

        // Left accent bar, aligned with the innermost blockquote bar for this level.
        let barX = leftEdge + CGFloat(level - 1) * Self.blockquoteIndentPerLevel + Self.blockquoteIndentPerLevel * 0.25
        let barRect = CGRect(x: barX, y: firstY, width: Self.blockquoteBarWidth, height: lastMaxY - firstY)
        calloutColor.setFill()
        NSBezierPath(rect: barRect).fill()
    }

    /// Draw the SF Symbol icon and rendered title for a callout. Called after
    /// `super.draw` so the replacement text appears on top of the hidden source.
    private func drawCalloutOverlays(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return }
        guard let ca = calloutAttribute(in: range, textStorage: ts) else { return }

        // In edit mode the raw Markdown is visible, so skip the rendered icon.
        guard !ca.isEditing else { return }

        // Icon only on the first fragment of the callout block.
        guard isFirstCalloutFragment(in: range, textStorage: ts),
              let firstLine = textLineFragments.first else { return }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = nsContext

        let calloutColor = ca.color
        let calloutIcon = ca.icon
        let leftEdge = point.x - layoutFragmentFrame.origin.x
        let level = calloutLevel(in: range, textStorage: ts) ?? 1
        let indent = CGFloat(level) * Self.blockquoteIndentPerLevel

        let tb = firstLine.typographicBounds
        let lineY = point.y + tb.origin.y

        let textView = textLayoutManager?.textContainer?.textView
        let baseFont = (textView as? NativeTextView)?.baseFont
            ?? (textView?.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize))

        let iconHeight = ceil(baseFont.ascender - baseFont.descender)
        let iconWidth = iconHeight + 4
        let iconX = leftEdge + indent + Self.blockquoteIndentPerLevel * 0.5
        let firstCharPos = firstLine.locationForCharacter(at: firstLine.characterRange.location)
        let baselineY = lineY + firstCharPos.y
        let iconCenterY = baselineY - baseFont.capHeight / 2
        let iconY = iconCenterY - iconHeight / 2

        if let baseSymbol = NSImage(systemSymbolName: calloutIcon, accessibilityDescription: nil) {
            let colorConfig = NSImage.SymbolConfiguration(hierarchicalColor: calloutColor)
            let refConfig = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            let refSymbol = baseSymbol.withSymbolConfiguration(refConfig.applying(colorConfig)) ?? baseSymbol
            let refSize = refSymbol.size
            let scale = iconHeight / refSize.height
            let drawWidth = refSize.width * scale
            let drawX = iconX + (iconWidth - drawWidth) / 2
            refSymbol.draw(in: CGRect(x: drawX, y: iconY, width: drawWidth, height: iconHeight))
        }
    }

    private func isFirstCalloutFragment(in range: NSRange, textStorage: NSTextStorage) -> Bool {
        let currentCallout = calloutAttribute(in: range, textStorage: textStorage)
        guard let tlm = textLayoutManager,
              let tcm = tlm.textContentManager as? NSTextContentStorage else { return true }
        guard let prevLocation = tcm.location(rangeInElement.location, offsetBy: -1),
              let prevFragment = tlm.textLayoutFragment(for: prevLocation),
              let prevRange = Self.nsRange(for: prevFragment, in: tcm) else { return true }
        guard let prevCallout = calloutAttribute(in: prevRange, textStorage: textStorage) else { return true }
        return prevCallout.id != currentCallout?.id
    }

    private func isLastCalloutFragment(in range: NSRange, textStorage: NSTextStorage) -> Bool {
        let currentCallout = calloutAttribute(in: range, textStorage: textStorage)
        var nextIndex = NSMaxRange(range)
        let nsText = textStorage.string as NSString
        while nextIndex < textStorage.length {
            let ch = nsText.character(at: nextIndex)
            if ch == 0x0A || ch == 0x0D {
                nextIndex += 1
                continue
            }
            break
        }
        guard nextIndex < textStorage.length else { return true }
        guard let nextCallout = textStorage.attribute(.callout, at: nextIndex, effectiveRange: nil) as? CalloutAttribute
        else { return true }
        // Adjacent callout blocks have distinct UUIDs; same id → continuation
        // of the same callout, different id → this is the last fragment of its own.
        return nextCallout.id != currentCallout?.id
    }

    private func isLastBlockquoteFragment(in range: NSRange, textStorage: NSTextStorage) -> Bool {
        guard let tlm = textLayoutManager,
              let tcm = tlm.textContentManager as? NSTextContentStorage else { return true }
        guard let nextLocation = tcm.location(rangeInElement.endLocation, offsetBy: 1),
              let nextFragment = tlm.textLayoutFragment(for: nextLocation),
              let nextRange = Self.nsRange(for: nextFragment, in: tcm) else { return true }
        var nextHasBlockquote = false
        var nextHasCallout = false
        textStorage.enumerateAttribute(.blockquoteLevel, in: nextRange, options: []) { value, _, stop in
            if value is Int { nextHasBlockquote = true; stop.pointee = true }
        }
        textStorage.enumerateAttribute(.callout, in: nextRange, options: []) { value, _, stop in
            if value is CalloutAttribute { nextHasCallout = true; stop.pointee = true }
        }
        // A plain blockquote bar ends when the next fragment is not a blockquote,
        // or when it becomes a callout (callouts draw their own accent bar).
        return !nextHasBlockquote || nextHasCallout
    }

    private func calloutAttribute(in range: NSRange, textStorage: NSTextStorage) -> CalloutAttribute? {
        var result: CalloutAttribute?
        textStorage.enumerateAttribute(.callout, in: range, options: []) { value, _, stop in
            if let ca = value as? CalloutAttribute {
                result = ca
                stop.pointee = true
            }
        }
        return result
    }

    private func hasCallout(in range: NSRange, textStorage: NSTextStorage) -> Bool {
        calloutAttribute(in: range, textStorage: textStorage) != nil
    }

    private func calloutLevel(in range: NSRange, textStorage: NSTextStorage) -> Int? {
        var result: Int?
        textStorage.enumerateAttribute(.blockquoteLevel, in: range, options: []) { value, _, stop in
            if let level = value as? Int {
                result = level
                stop.pointee = true
            }
        }
        return result
    }

    /// Build a rectangle path with independent corner radii. A radius of 0
    /// produces a sharp corner for that quadrant.
    private static func roundedRectPath(
        rect: CGRect,
        topLeft: CGFloat,
        topRight: CGFloat,
        bottomLeft: CGFloat,
        bottomRight: CGFloat
    ) -> NSBezierPath {
        let path = NSBezierPath()
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY

        path.move(to: CGPoint(x: minX + topLeft, y: minY))
        path.line(to: CGPoint(x: maxX - topRight, y: minY))
        if topRight > 0 {
            path.appendArc(
                withCenter: CGPoint(x: maxX - topRight, y: minY + topRight),
                radius: topRight,
                startAngle: 270,
                endAngle: 360,
                clockwise: false
            )
        }
        path.line(to: CGPoint(x: maxX, y: maxY - bottomRight))
        if bottomRight > 0 {
            path.appendArc(
                withCenter: CGPoint(x: maxX - bottomRight, y: maxY - bottomRight),
                radius: bottomRight,
                startAngle: 0,
                endAngle: 90,
                clockwise: false
            )
        }
        path.line(to: CGPoint(x: minX + bottomLeft, y: maxY))
        if bottomLeft > 0 {
            path.appendArc(
                withCenter: CGPoint(x: minX + bottomLeft, y: maxY - bottomLeft),
                radius: bottomLeft,
                startAngle: 90,
                endAngle: 180,
                clockwise: false
            )
        }
        path.line(to: CGPoint(x: minX, y: minY + topLeft))
        if topLeft > 0 {
            path.appendArc(
                withCenter: CGPoint(x: minX + topLeft, y: minY + topLeft),
                radius: topLeft,
                startAngle: 180,
                endAngle: 270,
                clockwise: false
            )
        }
        path.close()
        return path
    }

    // MARK: - Bullet Markers

    /// Paint a `•` over every hidden bullet marker (`.bulletMarker`). The
    /// glyph is drawn in the same font as the source so its baseline matches
    /// the surrounding text, and centered within the original marker char's
    /// advance so a `•` of a different width still sits where `-`/`*`/`+` was.
    private func drawBulletMarkers(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return }
        let selectionRanges: [NSRange] = {
            guard let tv = textLayoutManager?.textContainer?.textView else { return [] }
            return tv.selectedRanges.map { $0.rangeValue }.filter { $0.length > 0 }
        }()

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = nsContext

        let theme = (textLayoutManager?.textContainer?.textView as? NativeTextView)?
            .configuration.theme ?? .default
        let storageString = ts.string as NSString

        ts.enumerateAttribute(.bulletMarker, in: range, options: []) { [weak self] value, attrRange, _ in
            guard let self, (value as? Bool) == true else { return }
            // Leave a selected marker alone so the highlighted raw char shows.
            if selectionRanges.contains(where: { NSIntersectionRange($0, attrRange).length > 0 }) { return }
            guard let pos = self.drawPosition(forDocumentCharAt: attrRange.location, point: point) else { return }

            let font = (ts.attribute(.font, at: attrRange.location, effectiveRange: nil) as? NSFont)
                ?? (self.textLayoutManager?.textContainer?.textView?.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize))
            let bulletAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.bodyText]
            let bullet = "•" as NSString

            let markerWidth = storageString.substring(with: attrRange).size(withAttributes: [.font: font]).width
            let bulletWidth = bullet.size(withAttributes: bulletAttrs).width
            let xOffset = max(0, (markerWidth - bulletWidth) / 2)
            // Flipped context: text origin is its top edge, baseline sits one
            // ascent below — so top = baseline − ascent aligns the glyph.
            let topY = pos.baselineY - font.ascender
            bullet.draw(at: CGPoint(x: pos.x + xOffset, y: topY), withAttributes: bulletAttrs)
        }
    }

    // MARK: - Task List Checkboxes

    private func drawTaskCheckboxes(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return }
        let selectionRanges: [NSRange] = {
            guard let tv = textLayoutManager?.textContainer?.textView else { return [] }
            return tv.selectedRanges.map { $0.rangeValue }.filter { $0.length > 0 }
        }()

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = nsContext

        ts.enumerateAttribute(.taskCheckbox, in: range, options: []) { [weak self] value, attrRange, _ in
            guard let self, value != nil else { return }
            if selectionRanges.contains(where: { NSIntersectionRange($0, attrRange).length > 0 }) { return }

            let isChecked = (value as? Bool) ?? false
            guard let pos = drawPosition(forDocumentCharAt: attrRange.location, point: point) else { return }

            let font = (ts.attribute(.font, at: attrRange.location, effectiveRange: nil) as? NSFont)
                ?? (textLayoutManager?.textContainer?.textView?.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize))
            let ascent = max(0, font.ascender)
            let descent = max(0, -font.descender)
            let fontHeight = max(1, ceil(ascent + descent))
            let markerWidth = ("[ ]" as NSString).size(withAttributes: [.font: font]).width
            let size = max(1.0, min(floor(fontHeight * 1.2), floor(markerWidth * 1.2)))
            let boxX = pos.x + max(0, (markerWidth - size) / 2)
            let centerY = pos.baselineY + (descent - ascent) / 2
            let boxY = centerY - size / 2

            let scale = textLayoutManager?.textContainer?.textView?.window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor ?? 2.0
            func alignToPixel(_ value: CGFloat) -> CGFloat {
                (value * scale).rounded(.toNearestOrAwayFromZero) / scale
            }
            let boxRect = CGRect(x: alignToPixel(boxX), y: alignToPixel(boxY), width: size, height: size)
            guard !boxRect.isEmpty, !boxRect.isNull else { return }

            let iconInset = max(0.0, size * 0.01)
            let iconRect = boxRect.insetBy(dx: iconInset, dy: iconInset)
            let symbolName = isChecked ? "checkmark.square.fill" : "square"
            if let baseSymbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
                let sizeConfig = NSImage.SymbolConfiguration(pointSize: iconRect.height, weight: .regular)
                let theme = (textLayoutManager?.textContainer?.textView as? NativeTextView)?.configuration.theme ?? .default
                let tint = isChecked ? theme.bodyText : theme.mutedText
                let colorConfig = NSImage.SymbolConfiguration(hierarchicalColor: tint)
                let symbolConfig = sizeConfig.applying(colorConfig)
                let symbol = baseSymbol.withSymbolConfiguration(symbolConfig) ?? baseSymbol
                symbol.draw(in: iconRect)
            }
        }
    }
}

// MARK: - Layout Manager Delegate

final class MarkdownLayoutManagerDelegate: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let fragment = MarkdownTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        // Seed body font + paragraphStyle so the trailing fragment doesn't inherit heading metrics (FB15131180).
        if let textView = textLayoutManager.textContainer?.textView as? NativeTextView {
            let baseFont = textView.baseFont
            let para = NSMutableParagraphStyle()
            let lineHeight = layoutBridgeDefaultLineHeight(for: baseFont, using: textView.layoutBridge)
            para.minimumLineHeight = ceil(lineHeight) + textView.configuration.paragraph.lineHeightExtraSpacing
            para.paragraphSpacing = ceil(lineHeight * textView.configuration.paragraph.spacingFactor)
            para.paragraphSpacingBefore = 0
            fragment.stExtraLineFragmentAttributes = NSDictionary(dictionary: [
                NSAttributedString.Key.font: baseFont,
                NSAttributedString.Key.foregroundColor: textView.configuration.theme.bodyText,
                NSAttributedString.Key.paragraphStyle: para
            ])
        }
        return fragment
    }
}
