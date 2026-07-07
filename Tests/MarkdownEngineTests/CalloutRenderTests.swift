//
//  CalloutRenderTests.swift
//  MarkdownEngineTests
//
//  Tests for callout attribute emission.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Callout rendering")
struct CalloutRenderTests {

    private let base: CGFloat = 14
    private var fontName: String { NSFont.systemFont(ofSize: 14).fontName }

    private static let calloutConfig = CalloutConfiguration(types: [
        "info": CalloutConfiguration.CalloutStyle(color: .systemBlue, icon: "info.circle"),
        "note": CalloutConfiguration.CalloutStyle(color: .systemBlue, icon: "note.text"),
        "warning": CalloutConfiguration.CalloutStyle(color: .systemOrange, icon: "exclamationmark.triangle"),
    ])

    @MainActor
    @Test("Callout attribute is emitted for > [!info] blocks")
    func calloutAttributeEmitted() throws {
        _ = NSApplication.shared
        let text = "> [!info] Important note\n> First body line\n> Another line"

        var config = MarkdownEditorConfiguration.default
        config.callout = Self.calloutConfig
        BlockParser.calloutTypes = config.callout.activeTypes
        defer { BlockParser.calloutTypes = nil }

        let attrs = MarkdownASTStyler.styleAttributes(
            text: text,
            fontName: fontName,
            fontSize: base,
            caretLocation: -1,
            configuration: config
        )

        let calloutRanges = attrs.filter { $0.attributes[.callout] is CalloutAttribute }
        #expect(!calloutRanges.isEmpty, "expected callout attribute to be emitted for > [!info] block")

        let calloutAttr = calloutRanges.first?.attributes[.callout] as? CalloutAttribute
        #expect(calloutAttr?.type == "info", "expected type 'info', got '\(calloutAttr?.type ?? "nil")'")
        #expect(calloutAttr?.title == "Important note", "expected title 'Important note', got '\(calloutAttr?.title ?? "nil")'")
    }

    @MainActor
    @Test("Block without callout config stays as blockquote")
    func noCalloutConfigFallsBackToBlockquote() throws {
        _ = NSApplication.shared
        let text = "> [!info] No config"

        var config = MarkdownEditorConfiguration.default
        config.callout = .none
        BlockParser.calloutTypes = nil

        let attrs = MarkdownASTStyler.styleAttributes(
            text: text,
            fontName: fontName,
            fontSize: base,
            caretLocation: -1,
            configuration: config
        )

        let calloutRanges = attrs.filter { $0.attributes[.callout] is CalloutAttribute }
        #expect(calloutRanges.isEmpty, "expected no callout attribute when config is empty")
    }
}
