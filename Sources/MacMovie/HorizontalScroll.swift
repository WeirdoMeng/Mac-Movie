import AppKit
import SwiftUI

final class MouseWheelScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        // Ordinary mouse wheels emit vertical line deltas. Preserve native
        // horizontal/precise events, including trackpad momentum and gestures.
        guard !event.hasPreciseScrollingDeltas,
              abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
              let documentView else {
            super.scrollWheel(with: event)
            return
        }
        let limit = max(0, documentView.frame.width - contentView.bounds.width)
        var point = contentView.bounds.origin
        point.x = min(limit, max(0, point.x - event.scrollingDeltaY * 12))
        contentView.scroll(to: point)
        reflectScrolledClipView(contentView)
    }
}

struct CategoryScroll<Content: View>: NSViewRepresentable {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    func makeNSView(context: Context) -> MouseWheelScrollView {
        let scroll = MouseWheelScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.documentView = NSHostingView(rootView: AnyView(content.fixedSize()))
        return scroll
    }

    func updateNSView(_ scroll: MouseWheelScrollView, context: Context) {
        guard let host = scroll.documentView as? NSHostingView<AnyView> else { return }
        host.rootView = AnyView(content.fixedSize())
        host.frame.size = host.fittingSize
    }
}
