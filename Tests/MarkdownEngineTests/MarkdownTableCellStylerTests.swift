//
//  MarkdownTableCellStylerTests.swift
//  MarkdownEngineTests
//
//  Body-text-equivalent table cell styling: source kept, markers shrink/reveal.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("MarkdownTableCellStyler")
struct MarkdownTableCellStylerTests {

    private var theme: MarkdownEditorTheme { .default }
    private var font: NSFont { NSFont.systemFont(ofSize: 14) }

    private func style(_ raw: String, caret: Int = -1, header: Bool = false) -> NSAttributedString {
        _ = NSApplication.shared
        return MarkdownTableCellStyler.attributedString(
            raw,
            baseFont: font,
            header: header,
            theme: theme,
            codeBackgroundColor: .clear,
            caretLocation: caret
        )
    }

    private func fontTraits(at index: Int, in s: NSAttributedString) -> NSFontDescriptor.SymbolicTraits {
        guard index < s.length,
              let f = s.attribute(.font, at: index, effectiveRange: nil) as? NSFont else { return [] }
        return f.fontDescriptor.symbolicTraits
    }

    private func fontSize(at index: Int, in s: NSAttributedString) -> CGFloat {
        guard index < s.length,
              let f = s.attribute(.font, at: index, effectiveRange: nil) as? NSFont else { return 0 }
        return f.pointSize
    }

    @Test func keepsSourceCharacters() {
        let s = style("a **b** c")
        #expect(s.string == "a **b** c")
    }

    @Test func plainCellHasNoEmphasis() {
        let s = style("hello")
        #expect(!fontTraits(at: 0, in: s).contains(.bold))
        #expect(!fontTraits(at: 0, in: s).contains(.italic))
    }

    @Test func boldContentWhenMarkersShrunk() {
        // "a **b** c" — b is at index 4
        let s = style("a **b** c", caret: -1)
        #expect(fontTraits(at: 4, in: s).contains(.bold))
        // Opening ** at 2–3 should be near-zero font
        #expect(fontSize(at: 2, in: s) < 1)
    }

    @Test func italicContent() {
        // "a *b* c" — b at index 3
        let s = style("a *b* c")
        #expect(fontTraits(at: 3, in: s).contains(.italic))
    }

    @Test func nestedEmphasisComposes() {
        // **a *b* c**
        let s = style("**a *b* c**")
        let aIdx = (s.string as NSString).range(of: "a").location
        let bIdx = (s.string as NSString).range(of: "b").location
        let cIdx = (s.string as NSString).range(of: "c").location
        #expect(fontTraits(at: aIdx, in: s).contains(.bold))
        #expect(!fontTraits(at: aIdx, in: s).contains(.italic))
        #expect(fontTraits(at: bIdx, in: s).contains(.bold))
        #expect(fontTraits(at: bIdx, in: s).contains(.italic))
        #expect(fontTraits(at: cIdx, in: s).contains(.bold))
    }

    @Test func caretInsideConstructRevealsMarkers() {
        let raw = "**bold**"
        // caret on 'b' (index 2)
        let s = style(raw, caret: 2)
        #expect(fontSize(at: 0, in: s) >= 10)
        #expect(fontTraits(at: 2, in: s).contains(.bold))
    }

    @Test func caretOutsideConstructShrinksMarkers() {
        let raw = "x **bold**"
        // caret on 'x' (index 0)
        let s = style(raw, caret: 0)
        #expect(fontSize(at: 2, in: s) < 1)
    }

    @Test func inlineCodeGetsCodeFont() {
        let s = style("`x`")
        #expect(s.string == "`x`")
        // content 'x' at index 1
        let f = s.attribute(.font, at: 1, effectiveRange: nil) as? NSFont
        #expect(f?.fontName.lowercased().contains("mono") == true
            || f?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true
            || (f.map { CTFontCopyPostScriptName($0 as CTFont) as String }?.lowercased().contains("mono") ?? false))
    }

    @Test func strikethroughIsApplied() {
        let s = style("~~gone~~")
        let g = (s.string as NSString).range(of: "g").location
        #expect(s.attribute(.strikethroughStyle, at: g, effectiveRange: nil) != nil)
    }

    @Test func highlightIsApplied() {
        let s = style("==note==")
        let n = (s.string as NSString).range(of: "n").location
        #expect(s.attribute(.backgroundColor, at: n, effectiveRange: nil) != nil)
    }

    @Test func headerCellStartsBold() {
        let s = style("h", header: true)
        #expect(fontTraits(at: 0, in: s).contains(.bold))
    }

    @Test func inactiveLinkHidesURLAndStylesLabel() {
        let raw = "[hi](https://example.com)"
        let s = style(raw, caret: -1)
        let h = (s.string as NSString).range(of: "h").location
        #expect(s.attribute(.link, at: h, effectiveRange: nil) != nil)
        #expect(s.attribute(.underlineStyle, at: h, effectiveRange: nil) != nil)
        // '(' of URL should be shrunk / cleared
        let paren = (s.string as NSString).range(of: "(").location
        let size = fontSize(at: paren, in: s)
        let color = s.attribute(.foregroundColor, at: paren, effectiveRange: nil) as? NSColor
        #expect(size < 1 || color?.alphaComponent == 0)
    }

    @Test func activeLinkRevealsMarkers() {
        let raw = "[hi](https://example.com)"
        // caret on 'h' of hi
        let s = style(raw, caret: 1)
        #expect(fontSize(at: 0, in: s) >= 10) // '['
        #expect(s.attribute(.link, at: 1, effectiveRange: nil) == nil)
    }
}
