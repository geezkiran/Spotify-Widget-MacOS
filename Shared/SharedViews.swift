import SwiftUI

/// Text that, when its string changes, slides into place: from the right after skipping forward,
/// from the left after skipping back. The old string slides out the same way first.
///
/// Transitions only run on the outermost view being inserted, and a removal transition keeps the direction from when it was
/// last rendered. So the strings live in two slots that stay in the tree and swap on each change: the old string stays put
/// and animates out under the current direction, and the new string is inserted with its own transition.
struct SlidingText: View {
    let text: String
    var previous: String?
    /// How many times the string has changed, which picks the slot it's shown in.
    var changes = 0
    var direction: SkipDirection? = .forward
    var delay: Double = 0
    /// Fades out a string that doesn't fit instead of truncating it with an ellipsis, and scrolls it by `marquee`.
    var fadesOverflow = false
    /// How far through one scroll loop an overflowing string is, from 0 to 1. Only used with `fadesOverflow`.
    var marquee: Double = 0

    var body: some View {
        // A hidden one-line Text sets the size, so a long string can't widen the layout and push out the margins.
        // The visible text lives in an overlay, which never affects layout.
        Text(text)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                // A ZStack so the outgoing and incoming strings share one slot instead of stacking.
                ZStack(alignment: .leading) {
                    ForEach(0..<2, id: \.self) { slot in
                        let current = slot == changes % 2
                        SlidingLine(
                            text: current ? text : previous ?? "",
                            gone: !current,
                            direction: direction,
                            // Wait for the old string to clear before the new one comes in.
                            delay: delay + (current && previous != nil ? SlidingLine.exitDuration : 0),
                            marquee: fadesOverflow ? (current ? marquee : 0) : nil
                        )
                    }
                }
            }
            .clipped()
            .mask {
                if fadesOverflow {
                    // Short strings end before the fade, so only overflowing text is affected.
                    HStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 20)
                    }
                } else {
                    Color.black
                }
            }
    }
}

private struct SlidingLine: View {
    let text: String
    /// Set once a newer string replaces this one.
    let gone: Bool
    let direction: SkipDirection?
    let delay: Double
    /// When set, lays the string out at its full width and scrolls it this far through a loop, leaving the parent
    /// to clip it, rather than truncating.
    var marquee: Double?

    static let exitDuration = 0.2

    var body: some View {
        // Positive when text travels left: entering from the right, leaving to the left.
        let travel: CGFloat = direction == .backward ? -24 : 24
        let exit = Animation.easeIn(duration: Self.exitDuration).delay(delay)
        let entrance = Animation.spring(duration: 0.3, bounce: 0.15).delay(delay)
        ZStack(alignment: .leading) {
            // Keyed by the string, so a new string is inserted fresh and gets the insertion transition.
            ForEach([text], id: \.self) { text in
                Group {
                    if let marquee {
                        MarqueeLayout(progress: marquee) {
                            Text(text).lineLimit(1)
                            Text(text).lineLimit(1)
                        }
                        // Each step glides on from the last; the return to 0 is a jump, which the copy makes invisible.
                        .animation(marquee == 0 ? nil : .linear(duration: Marquee.stepDuration), value: marquee)
                    } else {
                        Text(text)
                            .lineLimit(1)
                    }
                }
                .offset(x: gone ? -travel : 0)
                .opacity(gone ? 0 : 1)
                .animation(gone ? exit : entrance, value: gone)
                // A gone string is already invisible when it's finally dropped, so it needs no removal animation.
                .transition(.asymmetric(insertion: .offset(x: travel).combined(with: .opacity), removal: .identity).animation(entrance))
            }
        }
    }
}

/// Timing for scrolling a string that doesn't fit. Widgets can't run open-ended animations, so the timeline moves the
/// string one short step per entry, each animating no longer than WidgetKit allows.
enum Marquee {
    /// Space between the string and the copy that follows it in.
    static let gap: CGFloat = 28
    /// Points per second.
    static let speed: CGFloat = 30
    static let stepDuration: TimeInterval = 2
    /// How long the string rests at the start before each loop.
    static let pause: TimeInterval = 2.5

    /// How many steps one loop of a string this wide takes.
    static func steps(forWidth width: CGFloat) -> Int {
        max(1, Int(((width + gap) / (speed * stepDuration)).rounded(.up)))
    }
}

/// Places a string at its full width and, when it overflows, a copy one gap after it, then shifts both left by `progress`
/// of the string plus gap. At progress 1 the copy sits exactly where the string started, so the loop restarts seamlessly.
private struct MarqueeLayout: Layout {
    var progress: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let size = subviews[0].sizeThatFits(.unspecified)
        let overflows = size.width > bounds.width
        let x = bounds.minX - (overflows ? progress * (size.width + Marquee.gap) : 0)
        subviews[0].place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(size))
        // A string that fits doesn't scroll, so its copy is parked past the clipped edge.
        let copyX = overflows ? x + size.width + Marquee.gap : bounds.maxX + Marquee.gap
        subviews[1].place(at: CGPoint(x: copyX, y: bounds.minY), proposal: ProposedViewSize(size))
    }
}

/// The custom like icon, from 24×24 SVG paths: a circle with a plus, or a check once liked.
struct LikeIconShape: Shape {
    let liked: Bool

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + (x - 12) * scale, y: rect.midY + (y - 12) * scale)
        }
        var path = Path()
        if liked {
            path.move(to: p(7.5, 12))
            path.addLine(to: p(10.5, 15))
            path.addLine(to: p(16.5, 9))
        } else {
            path.move(to: p(12, 8))
            path.addLine(to: p(12, 16))
            path.move(to: p(8, 12))
            path.addLine(to: p(16, 12))
        }
        path.addEllipse(in: CGRect(origin: p(2, 2), size: CGSize(width: 20 * scale, height: 20 * scale)))
        return path
    }
}
