//
//  NativeTextViewCoordinator+Headings.swift
//  MarkdownEngine
//
//  Sidebar TOC integration: extracts headings from the document and
//  scrolls to a caller-supplied source-coordinate range on demand.
//

import AppKit
import Foundation

extension NativeTextViewCoordinator {

    func postHeadingsDidChange(for text: String) {
        let headings = HeadingExtractor.extract(from: text)
        guard headings != lastPostedHeadings else { return }
        lastPostedHeadings = headings
        onHeadingsDidChange?(headings)
    }

    /// Scrolls `range` into view without changing selection or adding find highlights.
    func scrollRangeIntoView(_ range: NSRange, in tv: NSTextView) {
        let fullLength = (tv.string as NSString).length
        guard range.location < fullLength else { return }

        guard let tlm = tv.textLayoutManager,
              let scrollView = tv.enclosingScrollView,
              let matchStart = tlm.textContentManager?.location(
                tlm.documentRange.location, offsetBy: range.location)
        else {
            tv.scrollRangeToVisible(range)
            return
        }

        tlm.ensureLayout(for: tlm.documentRange)
        tlm.enumerateTextLayoutFragments(from: matchStart, options: [.ensuresLayout]) { fragment in
            let cv = scrollView.contentView
            let insetsTop = scrollView.contentInsets.top
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: tv.frame.origin.y)
            let visibleTop = cv.bounds.origin.y + insetsTop
            let visibleBottom = cv.bounds.origin.y + cv.bounds.height
            if frame.minY < visibleTop || frame.maxY > visibleBottom {
                let targetY = frame.minY - insetsTop - cv.bounds.height * 0.2
                cv.scroll(to: NSPoint(x: cv.bounds.origin.x, y: targetY))
                scrollView.reflectScrolledClipView(cv)
                (scrollView as? ClampedScrollView)?.clampToInsets()
            }
            return false
        }
    }
}
