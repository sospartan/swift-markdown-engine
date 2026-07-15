//
//  MarkdownTableCellStyler.swift
//  MarkdownEngine
//
//  Body-text-equivalent inline styling for a single table-cell source string.
//  Markers stay in storage and shrink when the caret is outside their construct
//  (same MarkerStyle / isActive rules as the document styler).
//

import AppKit
import Foundation

/// Styles a table cell's **source** markdown into an `NSAttributedString`.
///
/// Unlike the engine's internal strip-based image path, this keeps every source
/// character so caret ranges, selection, and typing stay trivially correct —
/// matching body-text inline behavior.
public enum MarkdownTableCellStyler {

    /// Style `raw` cell source. Pass `caretLocation = -1` (default) to shrink
    /// every inactive marker (inactive image / non-editing cell). While editing,
    /// pass the cell-local caret so constructs under the caret reveal markers.
    public static func attributedString(
        _ raw: String,
        baseFont: NSFont,
        header: Bool,
        theme: MarkdownEditorTheme,
        codeBackgroundColor: NSColor,
        markers: MarkerStyle = .default,
        linkStyle: LinkStyle = .default,
        caretLocation: Int = -1,
        textColor: NSColor? = nil,
        alignment: NSTextAlignment = .left,
        paragraphStyle: NSParagraphStyle? = nil
    ) -> NSAttributedString {
        let pointSize = baseFont.pointSize
        let descriptor = baseFont.fontDescriptor
        let startFont: NSFont = header
            ? (NSFont(descriptor: descriptor.withSymbolicTraits(.bold), size: pointSize) ?? baseFont)
            : baseFont
        let color = textColor ?? theme.bodyText
        let codeFont = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        let markerFont = NSFont(descriptor: startFont.fontDescriptor, size: markers.hiddenMarkerFontSize)
            ?? NSFont.systemFont(ofSize: markers.hiddenMarkerFontSize)

        let para: NSParagraphStyle = {
            if let paragraphStyle { return paragraphStyle }
            let p = NSMutableParagraphStyle()
            p.alignment = alignment
            p.lineBreakMode = .byWordWrapping
            p.lineSpacing = 0
            p.paragraphSpacing = 0
            p.paragraphSpacingBefore = 0
            p.lineHeightMultiple = 1
            return p
        }()

        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: startFont,
            .foregroundColor: color,
            .paragraphStyle: para,
        ]
        let out = NSMutableAttributedString(string: raw, attributes: baseAttrs)
        guard !raw.isEmpty else { return out }

        let ns = raw as NSString
        let caret = caretLocation
        let nodes = InlineParser.parse(raw)

        let ctx = CellStyleContext(
            ns: ns,
            baseDescriptor: descriptor,
            pointSize: pointSize,
            codeFont: codeFont,
            codeBackground: codeBackgroundColor,
            markerFont: markerFont,
            markerAlpha: markers.inlineCodeMarkerAlpha,
            theme: theme,
            linkStyle: linkStyle,
            caret: caret,
            bodyColor: color
        )

        applyInlines(nodes, font: startFont, ctx: ctx, into: out)
        shrinkInlineMarkers(nodes, ctx: ctx, forceReveal: false, into: out)

        // Re-assert paragraph style over the whole run (inline passes may not touch it).
        if out.length > 0 {
            out.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: out.length))
        }
        return out
    }

    // MARK: - Context

    private struct CellStyleContext {
        let ns: NSString
        let baseDescriptor: NSFontDescriptor
        let pointSize: CGFloat
        let codeFont: NSFont
        let codeBackground: NSColor
        let markerFont: NSFont
        let markerAlpha: CGFloat
        let theme: MarkdownEditorTheme
        let linkStyle: LinkStyle
        let caret: Int
        let bodyColor: NSColor

        func isActive(_ range: NSRange) -> Bool {
            if NSLocationInRange(caret, range) { return true }
            guard range.length > 0, caret == NSMaxRange(range) else { return false }
            let last = ns.character(at: caret - 1)
            return last != 0x0A && last != 0x0D
        }
    }

    // MARK: - Content styling

    private static func applyInlines(
        _ nodes: [InlineNode],
        font: NSFont,
        ctx: CellStyleContext,
        into out: NSMutableAttributedString
    ) {
        for node in nodes {
            switch node {
            case .text:
                break

            case .emphasis(let kind, _, let markers, let children):
                let composed = composeEmphasis(font, kind, ctx: ctx)
                let contentRange = content(of: markers)
                if contentRange.length > 0 {
                    out.addAttribute(.font, value: composed, range: contentRange)
                }
                if ctx.isActive(nodeRange(node)) {
                    for marker in markers {
                        out.addAttribute(.foregroundColor, value: ctx.theme.mutedText, range: marker)
                    }
                }
                applyInlines(children, font: composed, ctx: ctx, into: out)

            case .strikethrough(_, let markers, let children):
                let contentRange = content(of: markers)
                if contentRange.length > 0 {
                    out.addAttributes([
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .strikethroughColor: ctx.theme.strikethroughColor,
                    ], range: contentRange)
                }
                if ctx.isActive(nodeRange(node)) {
                    for marker in markers {
                        out.addAttribute(.foregroundColor, value: ctx.theme.mutedText, range: marker)
                    }
                }
                applyInlines(children, font: font, ctx: ctx, into: out)

            case .highlight(_, let markers, let children):
                let contentRange = content(of: markers)
                if contentRange.length > 0 {
                    out.addAttribute(.backgroundColor, value: ctx.theme.highlightColor, range: contentRange)
                }
                if ctx.isActive(nodeRange(node)) {
                    for marker in markers {
                        out.addAttribute(.foregroundColor, value: ctx.theme.mutedText, range: marker)
                    }
                }
                applyInlines(children, font: font, ctx: ctx, into: out)

            case .code(let range, let contentRange):
                if contentRange.length > 0 {
                    out.addAttributes([
                        .font: ctx.codeFont,
                        .backgroundColor: ctx.codeBackground,
                        .foregroundColor: ctx.bodyColor,
                        .spellingState: 0,
                    ], range: contentRange)
                }
                out.addAttribute(.spellingState, value: 0, range: range)
                let markerAttrs: [NSAttributedString.Key: Any] = ctx.isActive(range)
                    ? [.foregroundColor: ctx.theme.mutedText, .font: ctx.codeFont]
                    : [
                        .foregroundColor: ctx.theme.mutedText.withAlphaComponent(ctx.markerAlpha),
                        .font: ctx.markerFont,
                    ]
                for marker in codeMarkers(of: range, content: contentRange) {
                    out.addAttributes(markerAttrs, range: marker)
                }

            case .link(let range, let textRange, let urlRange, let markers, let children):
                out.addAttribute(.spellingState, value: 0, range: range)
                var urlString = ctx.ns.substring(with: urlRange)
                if !urlString.contains("://") { urlString = "https://\(urlString)" }
                let active = ctx.isActive(range)
                if let url = URL(string: urlString) {
                    if active {
                        if textRange.length > 0 {
                            out.addAttribute(
                                .foregroundColor,
                                value: ctx.theme.link.withAlphaComponent(ctx.linkStyle.activeLinkAlpha),
                                range: textRange
                            )
                        }
                    } else if textRange.length > 0 {
                        out.addAttributes([
                            .link: url,
                            .underlineStyle: NSUnderlineStyle.single.rawValue,
                            .foregroundColor: ctx.theme.link,
                        ], range: textRange)
                    }
                }
                for marker in markers {
                    out.addAttribute(.foregroundColor, value: ctx.theme.mutedText, range: marker)
                }
                applyInlines(children, font: font, ctx: ctx, into: out)

            case .escape, .image, .wikiLink, .imageEmbed, .inlineLatex:
                // Keep raw source; no special cell rendering (no LaTeX attachments).
                break
            }
        }
    }

    // MARK: - Marker shrinking

    private static func shrinkInlineMarkers(
        _ nodes: [InlineNode],
        ctx: CellStyleContext,
        forceReveal: Bool,
        into out: NSMutableAttributedString
    ) {
        for node in nodes {
            switch node {
            case .emphasis(_, let range, let markers, let children):
                let active = forceReveal || ctx.isActive(range)
                if !active { shrink(markers, ctx: ctx, into: out) }
                shrinkInlineMarkers(children, ctx: ctx, forceReveal: active, into: out)

            case .strikethrough(let range, let markers, let children):
                let active = forceReveal || ctx.isActive(range)
                if !active { shrink(markers, ctx: ctx, into: out) }
                shrinkInlineMarkers(children, ctx: ctx, forceReveal: active, into: out)

            case .highlight(let range, let markers, let children):
                let active = forceReveal || ctx.isActive(range)
                if !active { shrink(markers, ctx: ctx, into: out) }
                shrinkInlineMarkers(children, ctx: ctx, forceReveal: active, into: out)

            case .link(let range, _, _, let markers, let children):
                let active = forceReveal || ctx.isActive(range)
                if !active {
                    shrink(markers, ctx: ctx, into: out)
                    if markers.count >= 4 {
                        let hide = NSRange(
                            location: markers[2].location,
                            length: NSMaxRange(markers[3]) - markers[2].location
                        )
                        if hide.length > 0 {
                            out.addAttributes([
                                .font: ctx.markerFont,
                                .foregroundColor: NSColor.clear,
                            ], range: hide)
                        }
                    }
                }
                shrinkInlineMarkers(children, ctx: ctx, forceReveal: active, into: out)

            case .wikiLink(let range, _, _, let markers):
                if !(forceReveal || ctx.isActive(range)) { shrink(markers, ctx: ctx, into: out) }

            case .image(let range, _, _, let markers):
                if !(forceReveal || ctx.isActive(range)) { shrink(markers, ctx: ctx, into: out) }

            case .escape(let range, _, let marker):
                if !(forceReveal || ctx.isActive(range)) { shrink([marker], ctx: ctx, into: out) }

            case .text, .code, .imageEmbed, .inlineLatex:
                break
            }
        }
    }

    private static func shrink(
        _ markers: [NSRange],
        ctx: CellStyleContext,
        into out: NSMutableAttributedString
    ) {
        for marker in markers where marker.length > 0 {
            out.addAttributes([
                .font: ctx.markerFont,
                .kern: -ctx.markerFont.pointSize,
            ], range: marker)
        }
    }

    // MARK: - Helpers

    private static func composeEmphasis(
        _ current: NSFont,
        _ kind: EmphasisKind,
        ctx: CellStyleContext
    ) -> NSFont {
        var traits = current.fontDescriptor.symbolicTraits.intersection([.bold, .italic])
        switch kind {
        case .bold: traits.insert(.bold)
        case .italic: traits.insert(.italic)
        case .boldItalic: traits.formUnion([.bold, .italic])
        }
        return NSFont(descriptor: ctx.baseDescriptor.withSymbolicTraits(traits), size: ctx.pointSize)
            ?? current
    }

    private static func content(of markers: [NSRange]) -> NSRange {
        guard markers.count >= 2 else { return NSRange(location: 0, length: 0) }
        let start = NSMaxRange(markers[0])
        return NSRange(location: start, length: max(0, markers[1].location - start))
    }

    private static func codeMarkers(of range: NSRange, content: NSRange) -> [NSRange] {
        [
            NSRange(location: range.location, length: max(0, content.location - range.location)),
            NSRange(
                location: NSMaxRange(content),
                length: max(0, NSMaxRange(range) - NSMaxRange(content))
            ),
        ]
    }

    private static func nodeRange(_ node: InlineNode) -> NSRange {
        switch node {
        case .text(let r): return r
        case .code(let range, _): return range
        case .emphasis(_, let range, _, _): return range
        case .link(let range, _, _, _, _): return range
        case .image(let range, _, _, _): return range
        case .wikiLink(let range, _, _, _): return range
        case .imageEmbed(let range, _, _): return range
        case .strikethrough(let range, _, _): return range
        case .highlight(let range, _, _): return range
        case .inlineLatex(let range, _, _): return range
        case .escape(let range, _, _): return range
        }
    }
}
