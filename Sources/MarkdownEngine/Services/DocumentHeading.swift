//
//  DocumentHeading.swift
//  MarkdownEngine
//
//  Public heading entry for embedder table-of-contents UIs.
//

import Foundation

/// One ATX heading in the document, extracted from the engine's AST parse.
public struct DocumentHeading: Sendable, Equatable {
    public let level: Int
    public let title: String
    public let rangeLocation: Int
    public let rangeLength: Int

    public init(level: Int, title: String, rangeLocation: Int, rangeLength: Int) {
        self.level = level
        self.title = title
        self.rangeLocation = rangeLocation
        self.rangeLength = rangeLength
    }

    public var range: NSRange {
        NSRange(location: rangeLocation, length: rangeLength)
    }
}
