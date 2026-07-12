//
//  MarkdownTableDelegate.swift
//  MarkdownEngine
//
//  Host-delegate that lets the embedder take over table rendering and editing.
//

import AppKit
import Foundation

/// Host-delegate for GFM tables.
///
/// The engine renders tables using the default image renderer unless the delegate
/// provides a custom image. When ``shouldUseCustomEditing(for:range:)`` returns
/// `true`, the engine never falls back to pipe-source mode while the caret is
/// inside the table. When the caret is inside a table with custom editing enabled,
/// the engine creates a host-provided editor view, positions it at the table's
/// bounding rect, and keeps it in sync with scroll and resize.
public protocol MarkdownTableDelegate: Sendable {
    /// Return `true` if the host wants to take over editing for this table.
    func shouldUseCustomEditing(for table: MarkdownTable, range: NSRange) -> Bool

    /// Return a custom rendered image for the table, or `nil` to use the engine's
    /// default image renderer. `maxWidth` is the available container width; the
    /// returned image should not exceed it (the engine falls back to scrollable
    /// wide-table mode if it does).
    func renderImage(
        for table: MarkdownTable,
        baseFont: NSFont,
        theme: MarkdownEditorTheme,
        codeBackgroundColor: NSColor,
        latex: any LatexRenderer,
        appearance: NSAppearance,
        maxWidth: CGFloat
    ) -> NSImage?

    /// Create an editor view for the table. The engine adds the returned view as
    /// a subview of the text view, positions it at the table's bounding rect, and
    /// keeps the frame in sync during scroll and resize.
    ///
    /// Call `commit` with the serialized Markdown source whenever the user makes
    /// structural (row/column add/delete) or cell-text changes. The engine
    /// replaces the table source range and triggers a restyle.
    ///
    /// Return `nil` if the host does not want to show an editor for this table
    /// (the engine falls back to image-only display).
    func makeEditorView(
        for table: MarkdownTable,
        range: NSRange,
        textView: NSTextView,
        baseFont: NSFont,
        commit: @escaping (String) -> Void
    ) -> NSView?
}

public extension MarkdownTableDelegate {
    func shouldUseCustomEditing(for table: MarkdownTable, range: NSRange) -> Bool { false }
    func renderImage(
        for table: MarkdownTable,
        baseFont: NSFont,
        theme: MarkdownEditorTheme,
        codeBackgroundColor: NSColor,
        latex: any LatexRenderer,
        appearance: NSAppearance,
        maxWidth: CGFloat
    ) -> NSImage? { nil }
    func makeEditorView(
        for table: MarkdownTable,
        range: NSRange,
        textView: NSTextView,
        baseFont: NSFont,
        commit: @escaping (String) -> Void
    ) -> NSView? { nil }
}

/// Default delegate that keeps the historical engine behavior.
public struct DefaultMarkdownTableDelegate: MarkdownTableDelegate {
    public init() {}
}

/// Optional protocol for host table editor views.
///
/// When the caret first enters a custom table, the engine creates the editor
/// after the mouse-down tracking loop has already chosen its hit target.
/// Implementing this lets the engine forward that click into the newly created
/// editor so the first click both activates the table and opens a cell.
@MainActor
public protocol MarkdownTableEditorControlling: AnyObject {
    /// Begin editing the cell under `point` (coordinates in the editor view).
    func beginEditing(at pointInView: NSPoint)
}