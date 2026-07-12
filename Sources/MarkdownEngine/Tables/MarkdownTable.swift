//
//  MarkdownTable.swift
//  MarkdownEngine
//
//  Public model, parser, and serializer for GFM pipe tables.
//

import Foundation

/// Column alignment of a GFM table.
public enum MarkdownTableAlignment: Sendable, Equatable {
    case left
    case center
    case right
}

/// A parsed GFM table, independent of its source text location.
public struct MarkdownTable: Sendable, Equatable {
    public let header: [String]
    public let alignments: [MarkdownTableAlignment]
    public let rows: [[String]]

    public init(header: [String], alignments: [MarkdownTableAlignment], rows: [[String]]) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }
}

/// Parses a GFM pipe table from its Markdown source.
public enum MarkdownTableParser {

    public static func parse(_ source: String) -> MarkdownTable? {
        let rawLines = source.components(separatedBy: CharacterSet.newlines)
        let lines = rawLines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return nil }

        let header = parseRow(lines[0])
        let alignments = parseAlignments(lines[1])
        guard !header.isEmpty, !alignments.isEmpty else { return nil }

        let columnCount = max(header.count, alignments.count)
        let bodyLines = Array(lines.dropFirst(2))

        let paddedHeader = pad(header, to: columnCount, with: "")
        let paddedAlign = pad(alignments, to: columnCount, with: .left)
        let rows = bodyLines.map { pad(parseRow($0), to: columnCount, with: "") }

        return MarkdownTable(header: paddedHeader, alignments: paddedAlign, rows: rows)
    }

    private static func parseRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    private static func parseAlignments(_ line: String) -> [MarkdownTableAlignment] {
        let cells = parseRow(line)
        return cells.map { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            let leading = trimmed.hasPrefix(":")
            let trailing = trimmed.hasSuffix(":")
            switch (leading, trailing) {
            case (true, true): return .center
            case (false, true): return .right
            default: return .left
            }
        }
    }

    private static func pad<T>(_ array: [T], to count: Int, with fill: T) -> [T] {
        if array.count == count { return array }
        if array.count > count { return Array(array.prefix(count)) }
        return array + Array(repeating: fill, count: count - array.count)
    }
}

/// Serializes a ``MarkdownTable`` back into GFM pipe-table source text.
public enum MarkdownTableSerializer {

    public static func serialize(_ table: MarkdownTable) -> String {
        let columnCount = max(table.header.count, table.alignments.count)
        let header = pad(table.header, to: columnCount, with: "")
        let alignments = pad(table.alignments, to: columnCount, with: .left)
        let rows = table.rows.map { pad($0, to: columnCount, with: "") }

        var lines: [String] = []
        lines.append("| " + header.joined(separator: " | ") + " |")
        lines.append("| " + alignments.map(alignmentMarker).joined(separator: " | ") + " |")
        for row in rows {
            lines.append("| " + row.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    private static func alignmentMarker(_ alignment: MarkdownTableAlignment) -> String {
        switch alignment {
        case .left:   return "---"
        case .center: return ":---:"
        case .right:  return "---:"
        }
    }

    private static func pad<T>(_ array: [T], to count: Int, with fill: T) -> [T] {
        if array.count == count { return array }
        if array.count > count { return Array(array.prefix(count)) }
        return array + Array(repeating: fill, count: count - array.count)
    }
}
