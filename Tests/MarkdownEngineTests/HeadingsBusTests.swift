//
//  HeadingsBusTests.swift
//  MarkdownEngineTests
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Heading extraction")
struct HeadingsBusTests {

    @Test func extractsNestedHeadings() {
        let text = "# One\n\n## Two\n\n### Three\n"
        let headings = HeadingExtractor.extract(from: text)
        #expect(headings.count == 3)
        #expect(headings[0].level == 1)
        #expect(headings[0].title == "One")
        #expect(headings[1].level == 2)
        #expect(headings[1].title == "Two")
        #expect(headings[2].level == 3)
        #expect(headings[2].title == "Three")
    }

    @Test func extractsBoldTitleText() {
        let text = "# **Bold** title\n"
        let headings = HeadingExtractor.extract(from: text)
        #expect(headings.count == 1)
        #expect(headings[0].title == "Bold title")
    }

    @Test func ignoresHeadingInsideCodeBlock() {
        let text = "```\n# Not a heading\n```\n\n# Real\n"
        let headings = HeadingExtractor.extract(from: text)
        #expect(headings.count == 1)
        #expect(headings[0].title == "Real")
    }

    @Test func headingRangeCoversLine() {
        let text = "## Hello\n"
        let headings = HeadingExtractor.extract(from: text)
        #expect(headings.count == 1)
        let ns = text as NSString
        #expect(ns.substring(with: headings[0].range).hasPrefix("##"))
    }
}
