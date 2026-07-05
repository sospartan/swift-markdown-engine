import Foundation

/// Per-editor object that bridges scroll-to-range requests from the embedder
/// to the engine coordinator without NotificationCenter or SwiftUI bindings.
/// The embedder creates one instance and passes it to the wrapper; the
/// wrapper fills in the handler during `makeNSView`.
public final class ScrollHandler: NSObject {
    public var scroll: ((NSRange) -> Void)?
}
