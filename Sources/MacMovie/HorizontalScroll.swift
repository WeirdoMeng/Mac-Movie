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

// Keep scrollability visible without bringing back system scrollbars.
struct HorizontalChoices<Content: View>: View {
    var fadeColor = Theme.surface
    @ViewBuilder let content: () -> Content
    var body: some View {
        CategoryScroll { content().padding(.trailing, 20) }
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.left.chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 18, height: 28)
                    .background(LinearGradient(colors: [fadeColor.opacity(0), fadeColor], startPoint: .leading, endPoint: .trailing))
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .help("左右滚动查看更多；支持鼠标滚轮和触摸板")
    }
}

// Grouped macOS Forms own an internal NSScrollView; hide its indicators directly
// while retaining the native grouped controls and scroll behavior.
struct HiddenScrollIndicators: NSViewRepresentable {
    final class Marker: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hideIndicators() }
        func hideIndicators() {
            DispatchQueue.main.async { [weak self] in
                guard let root = self?.window?.contentView else { return }
                func hide(in view: NSView) {
                    if let scroll = view as? NSScrollView {
                        scroll.hasVerticalScroller = false
                        scroll.hasHorizontalScroller = false
                    }
                    view.subviews.forEach { hide(in: $0) }
                }
                hide(in: root)
            }
        }
    }
    func makeNSView(context: Context) -> Marker { Marker(frame: .zero) }
    func updateNSView(_ view: Marker, context: Context) { view.hideIndicators() }
}
