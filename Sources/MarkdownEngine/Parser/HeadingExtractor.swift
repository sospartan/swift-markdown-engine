//
//  HeadingExtractor.swift
//  MarkdownEngine
//
//  Extracts table-of-contents entries from the document AST.
//

import Foundation

enum HeadingExtractor {

    static func extract(from text: String) -> [DocumentHeading] {
        let ns = text as NSString
        return DocumentAST.parse(text).compactMap { block in
            guard case .heading(let level, let range, _, let inlines) = block else { return nil }
            let title = plainText(from: inlines, in: ns).trimmingCharacters(in: .whitespacesAndNewlines)
            return DocumentHeading(
                level: level,
                title: title,
                rangeLocation: range.location,
                rangeLength: range.length
            )
        }
    }

    private static func plainText(from nodes: [InlineNode], in ns: NSString) -> String {
        var parts: [String] = []
        for node in nodes {
            appendPlainText(node, to: &parts, in: ns)
        }
        return parts.joined()
    }

    private static func appendPlainText(_ node: InlineNode, to parts: inout [String], in ns: NSString) {
        switch node {
        case .text(let range):
            parts.append(ns.substring(with: range))
        case .code(_, let content):
            parts.append(ns.substring(with: content))
        case .emphasis(_, _, _, let children),
             .strikethrough(_, _, let children),
             .highlight(_, _, let children):
            for child in children { appendPlainText(child, to: &parts, in: ns) }
        case .link(_, let textRange, _, _, let children):
            if children.isEmpty {
                parts.append(ns.substring(with: textRange))
            } else {
                for child in children { appendPlainText(child, to: &parts, in: ns) }
            }
        case .image(_, let alt, _, _):
            parts.append(ns.substring(with: alt))
        case .wikiLink(_, let name, _, _):
            parts.append(ns.substring(with: name))
        case .imageEmbed(_, let target, _):
            parts.append(ns.substring(with: target))
        case .inlineLatex(_, let content, _):
            parts.append(ns.substring(with: content))
        case .escape(_, let character, _):
            parts.append(ns.substring(with: character))
        }
    }
}
