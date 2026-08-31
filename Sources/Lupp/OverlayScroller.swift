import AppKit

/// Transparent overlay scrollbars, matching Flöt's: a thin pill floating over
/// the content, no track behind it, and no layout width of its own.
///
/// The width matters as much as the look. A scrollbar that occupies layout space
/// makes a panel narrow the moment it has enough in it to scroll — content
/// shifting sideways as a side effect of there being more of it. Overlay style
/// costs nothing and never moves anything.
final class OverlayScroller: NSScroller {
    private static let thickness: CGFloat = 6
    private static let inset: CGFloat = 2

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                      scrollerStyle: NSScroller.Style) -> CGFloat {
        // The hit target, not the pill: comfortably grabbable while the drawn
        // pill stays 6pt, as in Flöt.
        11
    }

    /// No slot at all. The pill floats over whatever is underneath.
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let r = rect(for: .knob)
        guard r.width > 0, r.height > 0 else { return }

        let vertical = bounds.height >= bounds.width
        let t = OverlayScroller.thickness
        let i = OverlayScroller.inset
        let pill = vertical
            ? NSRect(x: r.midX - t / 2, y: r.minY + i, width: t, height: max(t, r.height - i * 2))
            : NSRect(x: r.minX + i, y: r.midY - t / 2, width: max(t, r.width - i * 2), height: t)

        // Brighter while being dragged, the way Flöt's pill lifts on hover.
        let alpha: CGFloat = (window?.firstResponder === self) ? 0.75 : 0.4
        NSColor.white.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: pill, xRadius: t / 2, yRadius: t / 2).fill()
    }
}
