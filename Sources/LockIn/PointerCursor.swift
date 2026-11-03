import SwiftUI
import AppKit

extension View {
    /// Shows the pointing-hand cursor while hovering, as long as the view is enabled.
    func pointingHandCursor() -> some View { modifier(PointingHandCursor()) }
}

private struct PointingHandCursor: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(enabled ? .link : nil)
        } else {
            // Cursor rects rather than NSCursor push/pop on hover: a button that disappears
            // mid-hover (e.g. Save closing its editor) can't leave the cursor stuck as a hand.
            content.overlay { if enabled { CursorRectView() } }
        }
    }
}

private struct CursorRectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HandView() }
    func updateNSView(_ view: NSView, context: Context) { view.window?.invalidateCursorRects(for: view) }
    private final class HandView: NSView {
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
        // Clicks go to the control underneath; only the cursor rect matters.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Wraps any button style so the button also shows the pointing-hand cursor.
/// Applied at each window root for unstyled buttons, and around every explicit style.
struct PointerButtonStyle<Base: PrimitiveButtonStyle>: PrimitiveButtonStyle {
    var base: Base
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration).buttonStyle(base).pointingHandCursor()
    }
}

extension PrimitiveButtonStyle {
    static func pointer<Base: PrimitiveButtonStyle>(_ base: Base) -> PointerButtonStyle<Base> where Self == PointerButtonStyle<Base> {
        PointerButtonStyle(base: base)
    }
}
