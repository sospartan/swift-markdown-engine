//
//  NativeTextViewCoordinator+SlashTrigger.swift
//  MarkdownEngine
//
//  Created by Acta on 17.07.26.
//
//  Detects a `/` typed at a position eligible to open an insert-command
//  palette (line start or after whitespace, editable, degenerate selection,
//  not inside a code block, not inside an active table cell) and notifies
//  the embedder via ``onSlashTrigger``. Fires synchronously inside
//  `textDidChange`, the same pattern used by `onCalloutIconClick`; the
//  embedder's `NSMenu.popUp` runs its modal tracking loop there.
//

import AppKit

extension NativeTextViewCoordinator {

    /// True when the caret sits immediately after a `/` that was just typed at
    /// an eligible position (line start or just after whitespace) and the
    /// surrounding context allows an insert-command palette.
    ///
    /// Conditions (all must hold):
    /// - view is editable
    /// - selection is degenerate (length == 0)
    /// - caret location > 0 and the character immediately before it is `/`
    /// - the character before the `/` is either a line start (or the slash is
    ///   at location 0) or whitespace (space / tab)
    /// - the caret is not inside a fenced or indented code block
    /// - `rawSourceMode` is off
    /// - view is not `hasMarkedText()` (IME composition)
    /// - caret is not inside an active table cell editor
    /// - the character before the `/` is NOT another `/` (so `//`, `///` or
    ///   `https://` do not trigger); only the first slash after whitespace/
    ///   line-start qualifies
    func slashTriggerState(in tv: NSTextView) -> SlashTriggerState? {
        guard tv.isEditable else { return nil }
        guard !configuration.rawSourceMode else { return nil }
        guard !tv.hasMarkedText() else { return nil }
        let sel = tv.selectedRange()
        guard sel.length == 0 else { return nil }
        let ns = tv.string as NSString
        let length = ns.length
        let loc = sel.location
        guard loc > 0, loc <= length else { return nil }
        let slashIndex = loc - 1
        let slashChar = ns.character(at: slashIndex)
        guard slashChar == 0x002F else { return nil } // '/'

        // Reject multiple slashes: the char before the slash must not be another
        // '/'. This prevents `//`, `///`, `https://` from triggering.
        if slashIndex > 0, ns.character(at: slashIndex - 1) == 0x002F { return nil }

        // Pre-slash position must be line-start or whitespace.
        if slashIndex == 0 {
            // line start
        } else {
            let prevChar = ns.character(at: slashIndex - 1)
            // 0x000A = LF, 0x000D = CR, 0x0009 = TAB, 0x0020 = SPACE
            let isLineStart = (prevChar == 0x000A || prevChar == 0x000D)
            let isWhitespace = (prevChar == 0x0009 || prevChar == 0x0020)
            if !isLineStart && !isWhitespace { return nil }
        }

        // Code-block exclusion.
        let slashRange = NSRange(location: slashIndex, length: 1)
        let parsed = parsedDocument(for: tv.string)
        if MarkdownDetection.isInsideCodeBlock(range: slashRange, codeTokens: parsed.codeTokens) {
            return nil
        }

        // Table exclusion: caret falls inside a table source token.
        if isInsideTableToken(range: slashRange, parsed: parsed) {
            return nil
        }

// Use text-view-local glyph bounds (no scroll/document conversion) so
        // embedder `NSMenu.popUp(..., in: textView)` anchors at the caret.
        let caretRect = textViewLocalRect(for: slashRange, in: tv)
            ?? textViewLocalRect(for: sel, in: tv)
            ?? .zero
        return SlashTriggerState(triggerRange: slashRange, caretRect: caretRect)
    }

    /// Glyph bounding rect in the text view's own coordinate system.
    private func textViewLocalRect(for range: NSRange, in tv: NSTextView) -> CGRect? {
        guard range.location != NSNotFound,
              let bridge = layoutBridge,
              let textContainer = tv.textContainer else { return nil }
        var boundingRect = bridge.boundingRect(forCharacterRange: range, in: textContainer)
        let origin = tv.textContainerOrigin
        boundingRect.origin.x += origin.x
        boundingRect.origin.y += origin.y
        return boundingRect
    }

    /// True when the range falls within a table source token (slash palette is
    /// for body text, not pipe-table rows).
    private func isInsideTableToken(range: NSRange, parsed: ParsedDocument) -> Bool {
        for token in parsed.tokens where token.kind == .table {
            if NSIntersectionRange(token.range, range).length > 0 { return true }
        }
        return false
    }

    func dispatchSlashTriggerIfNeeded(in tv: NSTextView) {
        guard let handler = onSlashTrigger else { return }
        guard let state = slashTriggerState(in: tv) else { return }
        handler(tv, state)
    }
}