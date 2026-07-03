//
//  CalloutRenderTests.swift
//  MarkdownEngineTests
//
//  Temporary visual regression test for callout rendering.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Callout rendering")
struct CalloutRenderTests {

    private let base: CGFloat = 14
    private var fontName: String { NSFont.systemFont(ofSize: 14).fontName }

    @MainActor
    @Test("Callout title is visibly rendered in render mode")
    func calloutTitleIsVisible() throws {
        _ = NSApplication.shared
        let text = "> [!info] Important note\n> First body line\n> Another line"

        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let baseFont = NSFont.systemFont(ofSize: base)
        textView.baseFont = baseFont
        textView.font = baseFont
        textView.string = text
        let layoutDelegate = MarkdownLayoutManagerDelegate()
        textView.textLayoutManager?.delegate = layoutDelegate

        let attrs = MarkdownASTStyler.styleAttributes(
            text: text,
            fontName: fontName,
            fontSize: base,
            caretLocation: -1
        )
        textView.textStorage?.beginEditing()
        for (range, a) in attrs {
            textView.textStorage?.addAttributes(a, range: range)
        }
        textView.textStorage?.endEditing()

        textView.layout()
        textView.display()

        guard let bitmap = textView.bitmapImageRepForCachingDisplay(in: textView.bounds) else {
            Issue.record("failed to create bitmap rep")
            return
        }
        textView.cacheDisplay(in: textView.bounds, to: bitmap)

        // Sample a point on the rendered title line where the title text
        // (not the blue background) should appear.
        let sampleX = 80
        let sampleY = 5
        let color = bitmap.colorAt(x: sampleX, y: sampleY)
        let background = MarkdownTextLayoutFragment.calloutStyle(for: "info").color.withAlphaComponent(0.1)
        #expect(color != background, "expected visible title pixel, got background color")
        #expect(color?.alphaComponent != 0, "expected non-transparent title pixel")
    }
}
