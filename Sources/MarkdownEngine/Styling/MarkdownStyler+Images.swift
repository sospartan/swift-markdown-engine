//
//  MarkdownStyler+Images.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Image embed (`![[...]]`) styling and layout.
//

import AppKit
import Foundation

extension MarkdownStyler {

    // MARK: Markdown Image Links ![alt](url)

    /// Style `![alt](url)` images by routing the URL through the embedder's
    /// `EmbeddedImageProvider` (URL goes into the request's `name` field —
    /// providers that don't speak URLs simply return `nil`, at which point we
    /// fall back to dimming the markdown source).
    ///
    /// Standalone paragraphs collapse into a block image (source hidden);
    /// images amid other text render inline at the baseline, following the
    /// same collapse pattern as inline LaTeX. Linked images
    /// `[![alt](img)](link)` additionally carry a `.link` attribute on the
    /// anchor so clicks open the destination URL.
    static func styleImageLinks(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        // Tables own their cell visuals; rendering an inline image from the
        // source text would double-draw under the collapsed table image.
        let tableRanges = ctx.tokens.filter { $0.kind == .table }.map(\.range)
        for (idx, token) in ctx.tokens.enumerated() where token.kind == .imageLink {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }
            if tableRanges.contains(where: { tableRange in
                token.range.location >= tableRange.location
                    && NSMaxRange(token.range) <= NSMaxRange(tableRange)
            }) { continue }

            // The URL lives between markerRanges[2] ('(') and markerRanges[3] (')').
            guard token.markerRanges.count >= 4 else {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                continue
            }
            let openParen = token.markerRanges[2]
            let closeParen = token.markerRanges[3]
            let urlStart = NSMaxRange(openParen)
            let urlLength = closeParen.location - urlStart
            guard urlLength > 0 else {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                continue
            }
            let urlRange = NSRange(location: urlStart, length: urlLength)
            let url = ctx.nsText.substring(with: urlRange)
            let isActive = ctx.activeTokenIndices.contains(idx)
            let wrappingLink = ctx.tokens.first {
                $0.kind == .link
                    && $0.contentRange.location == token.range.location
                    && $0.contentRange.length == token.range.length
            }
            let linkURL: URL? = {
                guard let wrappingLink, wrappingLink.markerRanges.count >= 4 else { return nil }
                let open = wrappingLink.markerRanges[2]
                let close = wrappingLink.markerRanges[3]
                let start = NSMaxRange(open)
                let length = close.location - start
                guard length > 0 else { return nil }
                var s = ctx.nsText.substring(with: NSRange(location: start, length: length))
                if !s.contains("://") { s = "https://\(s)" }
                return URL(string: s)
            }()
            let linkHideRanges: [NSRange] = {
                guard let wrappingLink, wrappingLink.markerRanges.count >= 4 else { return [] }
                var ranges = wrappingLink.markerRanges
                let open = wrappingLink.markerRanges[2]
                let close = wrappingLink.markerRanges[3]
                let start = NSMaxRange(open)
                let length = close.location - start
                if length > 0 {
                    ranges.append(NSRange(location: start, length: length))
                }
                return ranges
            }()

            let request = EmbeddedImageRequest(name: url)
            guard let image = ctx.services.images.image(for: request) else {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                // When nested in a link with no image, collapse the image URL run so
                // inactive source doesn't read as "altimg" next to the alt text.
                if wrappingLink != nil {
                    let urlText = ctx.nsText.substring(with: urlRange)
                    attrs.append((urlRange, [
                        .foregroundColor: NSColor.clear,
                        .font: ctx.latexMarkerFont,
                        .kern: -HeadingHelpers.textWidth(urlText, font: ctx.latexMarkerFont)
                    ]))
                }
                continue
            }

            let imageEmbedConfig = ctx.configuration.imageEmbed
            let maxWidth: CGFloat = {
                if let tc = ctx.layoutBridge?.firstTextContainer {
                    let w = tc.containerSize.width - tc.lineFragmentPadding * 2
                    if w > 0 && w < imageEmbedConfig.unreasonableMaxWidth { return w }
                }
                return imageEmbedConfig.fallbackMaxWidth
            }()

            // Natural size; only shrink when wider than the text column.
            // Height follows from the aspect ratio, then the block is centered.
            let imageSize = image.size
            let targetWidth = min(imageSize.width, maxWidth)
            let scale = imageSize.width > 0 ? targetWidth / imageSize.width : 1
            let displayWidth = imageSize.width * scale
            let displayHeight = imageSize.height * scale
            let imageBounds = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)

            // Anchor on the image alt; for linked images hide outer link syntax too.
            let renderToken: MarkdownToken
            if let wrappingLink {
                renderToken = MarkdownToken(
                    kind: .imageLink,
                    range: wrappingLink.range,
                    contentRange: token.contentRange,
                    markerRanges: token.markerRanges + wrappingLink.markerRanges
                )
            } else {
                renderToken = token
            }
            let rawContent = ctx.nsText.substring(with: renderToken.range)
            let gateToken = wrappingLink ?? token
            let isStandalone = gateToken.standaloneParagraphRange(in: ctx.nsText) != nil
            if isStandalone {
                let rendered: Bool
                if isActive {
                    rendered = appendRenderedStandaloneBlock(
                        for: renderToken,
                        rawContent: rawContent,
                        image: image,
                        imageBounds: imageBounds,
                        paragraphSpacingBefore: imageEmbedConfig.paragraphSpacing,
                        paragraphSpacing: imageEmbedConfig.paragraphSpacing,
                        alignment: .center,
                        mode: .visibleSource(imageGap: imageEmbedConfig.imageGap),
                        ctx: ctx,
                        attrs: &attrs,
                        standaloneToken: gateToken
                    )
                } else {
                    rendered = appendRenderedStandaloneBlock(
                        for: renderToken,
                        rawContent: rawContent,
                        image: image,
                        imageBounds: imageBounds,
                        paragraphSpacingBefore: imageEmbedConfig.paragraphSpacing,
                        paragraphSpacing: imageEmbedConfig.paragraphSpacing,
                        alignment: .center,
                        mode: .collapsedSource(markerTexts: ["![", "]", "(", ")"]),
                        ctx: ctx,
                        attrs: &attrs,
                        standaloneToken: gateToken,
                        anchorLink: linkURL,
                        extraHideRanges: [urlRange] + linkHideRanges
                    )
                }
                if !rendered {
                    appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                }
            } else {
                appendInlineImage(
                    token: token,
                    image: image,
                    urlRange: urlRange,
                    linkURL: linkURL,
                    isActive: isActive,
                    ctx: ctx,
                    attrs: &attrs
                )
            }
        }
        return attrs
    }

    /// Inline `![alt](url)` amid other text: collapse the source onto a single
    /// anchor glyph (same pattern as inline LaTeX) and draw the image at the
    /// baseline. Height is capped so tall images don't wreck the line.
    private static func appendInlineImage(
        token: MarkdownToken,
        image: NSImage,
        urlRange: NSRange,
        linkURL: URL?,
        isActive: Bool,
        ctx: StylingContext,
        attrs: inout [StyledRange]
    ) {
        if isActive {
            // Caret inside — reveal raw source, keep markers muted.
            for markerRange in token.markerRanges {
                attrs.append((markerRange, [.foregroundColor: ctx.configuration.theme.mutedText]))
            }
            return
        }

        let baseLineHeight = layoutBridgeDefaultLineHeight(for: ctx.baseFont, using: ctx.layoutBridge)
        let maxHeight = baseLineHeight * 5
        let imageEmbedConfig = ctx.configuration.imageEmbed
        let maxWidth: CGFloat = {
            if let tc = ctx.layoutBridge?.firstTextContainer {
                let w = tc.containerSize.width - tc.lineFragmentPadding * 2
                if w > 0 && w < imageEmbedConfig.unreasonableMaxWidth { return w }
            }
            return imageEmbedConfig.fallbackMaxWidth
        }()

        let size = image.size
        guard size.width > 0, size.height > 0 else {
            appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
            return
        }
        let scale = min(1, maxHeight / size.height, maxWidth / size.width)
        let displayWidth = size.width * scale
        let displayHeight = size.height * scale
        // Small descent so the image sits on the text baseline.
        let imageBounds = CGRect(x: 0, y: displayHeight * 0.15, width: displayWidth, height: displayHeight)

        // Anchor on the first alt char; fall back to the '!' of the opening
        // marker when the alt text is empty (`![](url)`).
        let anchorLocation = token.contentRange.length > 0
            ? token.contentRange.location
            : token.range.location
        let anchorRange = NSRange(location: anchorLocation, length: 1)
        let anchorChar = ctx.nsText.substring(with: anchorRange)
        var anchorAttrs: [NSAttributedString.Key: Any] = [
            .latexImage: image,
            .latexBounds: NSValue(rect: imageBounds),
            .foregroundColor: NSColor.clear,
            .font: ctx.latexMarkerFont,
            .underlineStyle: 0,
            .kern: displayWidth - HeadingHelpers.textWidth(anchorChar, font: ctx.latexMarkerFont)
        ]
        if let linkURL { anchorAttrs[.link] = linkURL }
        attrs.append((anchorRange, anchorAttrs))

        // Hide everything else in the token: markers, the URL run, and the
        // remaining alt text. (The AST styler already shrinks markers when
        // inactive; appending here too keeps this path self-contained.)
        var hideRanges: [NSRange] = []
        for marker in token.markerRanges where !NSLocationInRange(anchorLocation, marker) {
            hideRanges.append(marker)
        }
        hideRanges.append(urlRange)
        let contentEnd = NSMaxRange(token.contentRange)
        if anchorLocation > token.contentRange.location {
            hideRanges.append(NSRange(
                location: token.contentRange.location,
                length: anchorLocation - token.contentRange.location
            ))
        }
        if anchorLocation + 1 < contentEnd {
            hideRanges.append(NSRange(
                location: anchorLocation + 1,
                length: contentEnd - anchorLocation - 1
            ))
        }
        for range in hideRanges where range.length > 0 {
            let text = ctx.nsText.substring(with: range)
            attrs.append((range, [
                .foregroundColor: NSColor.clear,
                .font: ctx.latexMarkerFont,
                .kern: -HeadingHelpers.textWidth(text, font: ctx.latexMarkerFont)
            ]))
        }
    }

    // MARK: Image Embeds ![[Name]]

    static func styleImageEmbeds(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for (idx, token) in ctx.tokens.enumerated() where token.kind == .imageEmbed {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }

            let isActive = ctx.activeTokenIndices.contains(idx)
            let rawContent = ctx.nsText.substring(with: token.contentRange)  // = display name (no suffix)
            // The uuid|width suffix lives in the `.wikiLinkID` side-channel (same as node links).
            let suffix = ctx.wikiLinkIDProvider(token.range)
            // Re-apply the attribute every restyle so makeStorageState can recover the suffix on
            // save — even on the image-not-found path (mirrors styleWikiLink). Load-bearing.
            if let suffix, !suffix.isEmpty {
                attrs.append((token.contentRange, [.wikiLinkID: suffix]))
            }
            let referenceContent = (suffix?.isEmpty == false) ? "\(rawContent)|\(suffix!)" : rawContent
            guard let reference = ImageEmbedReference(content: referenceContent) else {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                continue
            }

            if let image = EmbeddedImageCache.shared.image(for: reference, services: ctx.services) {
                let imageEmbedConfig = ctx.configuration.imageEmbed
                // Determine max width from text container
                let maxWidth: CGFloat = {
                    if let tc = ctx.layoutBridge?.firstTextContainer {
                        let w = tc.containerSize.width - tc.lineFragmentPadding * 2
                        if w > 0 && w < imageEmbedConfig.unreasonableMaxWidth { return w }
                    }
                    return imageEmbedConfig.fallbackMaxWidth
                }()

                let minWidth = imageEmbedConfig.minimumWidth
                let imageSize = image.size
                let targetWidth: CGFloat
                if let rw = reference.requestedWidth, rw > 0 {
                    targetWidth = min(max(rw, minWidth), maxWidth)
                } else {
                    targetWidth = min(imageSize.width, maxWidth)
                }
                let scale = targetWidth / imageSize.width
                let displayWidth = imageSize.width * scale
                let displayHeight = imageSize.height * scale
                let imageBounds = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)
                let rendered: Bool
                if isActive {
                    rendered = appendRenderedStandaloneBlock(
                        for: token,
                        rawContent: rawContent,
                        image: image,
                        imageBounds: imageBounds,
                        paragraphSpacingBefore: imageEmbedConfig.paragraphSpacing,
                        paragraphSpacing: imageEmbedConfig.paragraphSpacing,
                        alignment: .left,
                        mode: .visibleSource(imageGap: imageEmbedConfig.imageGap),
                        ctx: ctx,
                        attrs: &attrs
                    )
                } else {
                    rendered = appendRenderedStandaloneBlock(
                        for: token,
                        rawContent: rawContent,
                        image: image,
                        imageBounds: imageBounds,
                        paragraphSpacingBefore: imageEmbedConfig.paragraphSpacing,
                        paragraphSpacing: imageEmbedConfig.paragraphSpacing,
                        alignment: .left,
                        mode: .collapsedSource(markerTexts: ["![[", "]]"]),
                        ctx: ctx,
                        attrs: &attrs
                    )
                }
                if !rendered {
                    appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                }
            } else {
                // Image not found — show syntax with marker coloring (like broken link)
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
            }
        }
        return attrs
    }
}
