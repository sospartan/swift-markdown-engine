//
//  LinkedImageRenderTests.swift
//  MarkdownEngineTests
//
//  Linked images `[![alt](img)](url)`: parse, active-token coupling, and
//  collapsed-render path (anchor carries `.link` + image).
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

private struct StubImageProvider: EmbeddedImageProvider {
    let image: NSImage
    func image(for reference: EmbeddedImageRequest) -> NSImage? {
        reference.name.isEmpty ? nil : image
    }
    func fingerprint() -> AnyHashable { "stub" }
}

@Suite("Linked image render")
struct LinkedImageRenderTests {

    private func makeStubImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 40, height: 20))
        img.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 20).fill()
        img.unlockFocus()
        return img
    }

    @Test("caret in outer link URL activates nested imageLink")
    func activeTokenCoupling() {
        let text = "[![alt](img.png)](https://example.com)" as NSString
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text as String)
        let link = tokens.first { $0.kind == .link }!
        // Caret inside the link destination URL.
        let caretInURL = link.markerRanges[2].location + 1
        let active = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: NSRange(location: caretInURL, length: 0),
            tokens: tokens,
            in: text
        )
        let imageIdx = tokens.firstIndex { $0.kind == .imageLink }
        let linkIdx = tokens.firstIndex { $0.kind == .link }
        #expect(imageIdx != nil)
        #expect(linkIdx != nil)
        #expect(active.contains(linkIdx!))
        #expect(active.contains(imageIdx!))
    }

    @Test("collapsed linked image anchor carries .link and .latexImage")
    func collapsedAnchorHasLink() {
        let text = "[![alt](img.png)](https://example.com)"
        let stub = makeStubImage()
        var config = MarkdownEditorConfiguration.default
        config.services = MarkdownEditorServices(images: StubImageProvider(image: stub))
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let attrs = MarkdownStyler.styleAttributes(
            text: text,
            fontName: "Helvetica",
            fontSize: 14,
            caretLocation: -1,
            activeTokenIndices: [],
            precomputedTokens: tokens,
            configuration: config
        )
        let hasLatexImage = attrs.contains { $0.attributes[.latexImage] != nil }
        let hasLink = attrs.contains {
            guard let url = $0.attributes[.link] as? URL else { return false }
            return url.absoluteString.contains("example.com")
        }
        #expect(hasLatexImage)
        #expect(hasLink)
    }

    @Test("plain standalone image still collapses with provider")
    func plainImageStillRenders() {
        let text = "![alt](img.png)"
        let stub = makeStubImage()
        var config = MarkdownEditorConfiguration.default
        config.services = MarkdownEditorServices(images: StubImageProvider(image: stub))
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let attrs = MarkdownStyler.styleAttributes(
            text: text,
            fontName: "Helvetica",
            fontSize: 14,
            caretLocation: -1,
            activeTokenIndices: [],
            precomputedTokens: tokens,
            configuration: config
        )
        #expect(attrs.contains { $0.attributes[.latexImage] != nil })
    }

    @Test("inline image amid text renders (GFM inline)")
    func inlineImageAmidText() {
        let text = "Hello ![alt](img.png) world"
        let stub = makeStubImage()
        var config = MarkdownEditorConfiguration.default
        config.services = MarkdownEditorServices(images: StubImageProvider(image: stub))
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let attrs = MarkdownStyler.styleAttributes(
            text: text,
            fontName: "Helvetica",
            fontSize: 14,
            caretLocation: -1,
            activeTokenIndices: [],
            precomputedTokens: tokens,
            configuration: config
        )
        // Anchor carries the image, drawn inline (not block).
        let anchor = attrs.first { $0.attributes[.latexImage] != nil }
        #expect(anchor != nil)
        #expect((anchor?.attributes[.latexIsBlock] as? Bool) != true)
        // Image URL run is collapsed (clear + negative kern), not left visible.
        let imageToken = tokens.first { $0.kind == .imageLink }!
        let urlRun = NSRange(
            location: NSMaxRange(imageToken.markerRanges[2]),
            length: imageToken.markerRanges[3].location - NSMaxRange(imageToken.markerRanges[2])
        )
        #expect(attrs.contains {
            $0.range == urlRun && ($0.attributes[.foregroundColor] as? NSColor) == .clear
        })
    }

    @Test("inline linked image anchor carries .link")
    func inlineLinkedImage() {
        let text = "See [![a](i.png)](https://example.com) end"
        let stub = makeStubImage()
        var config = MarkdownEditorConfiguration.default
        config.services = MarkdownEditorServices(images: StubImageProvider(image: stub))
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let attrs = MarkdownStyler.styleAttributes(
            text: text,
            fontName: "Helvetica",
            fontSize: 14,
            caretLocation: -1,
            activeTokenIndices: [],
            precomputedTokens: tokens,
            configuration: config
        )
        let anchor = attrs.first { $0.attributes[.latexImage] != nil }
        #expect(anchor != nil)
        let url = anchor?.attributes[.link] as? URL
        #expect(url?.absoluteString.contains("example.com") == true)
    }

    @Test("active inline image reveals source (no image attr)")
    func activeInlineImageRevealsSource() {
        let text = "Hello ![alt](img.png) world"
        let stub = makeStubImage()
        var config = MarkdownEditorConfiguration.default
        config.services = MarkdownEditorServices(images: StubImageProvider(image: stub))
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let imageIdx = tokens.firstIndex { $0.kind == .imageLink }!
        let attrs = MarkdownStyler.styleAttributes(
            text: text,
            fontName: "Helvetica",
            fontSize: 14,
            caretLocation: 8,
            activeTokenIndices: [imageIdx],
            precomputedTokens: tokens,
            configuration: config
        )
        #expect(!attrs.contains { $0.attributes[.latexImage] != nil })
    }
}
