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
                            delay: delay + (current && previous != nil ? SlidingLine.exitDuration : 0)
                        )
                    }
                }
            }
            .clipped()
    }
}

private struct SlidingLine: View {
    let text: String
    /// Set once a newer string replaces this one.
    let gone: Bool
    let direction: SkipDirection?
    let delay: Double

    static let exitDuration = 0.2

    var body: some View {
        // Positive when text travels left: entering from the right, leaving to the left.
        let travel: CGFloat = direction == .backward ? -24 : 24
        let exit = Animation.easeIn(duration: Self.exitDuration).delay(delay)
        let entrance = Animation.spring(duration: 0.3, bounce: 0.15).delay(delay)
        ZStack(alignment: .leading) {
            // Keyed by the string, so a new string is inserted fresh and gets the insertion transition.
            ForEach([text], id: \.self) { text in
                Text(text)
                    .lineLimit(1)
                    .offset(x: gone ? -travel : 0)
                    .opacity(gone ? 0 : 1)
                    .animation(gone ? exit : entrance, value: gone)
                    // A gone string is already invisible when it's finally dropped, so it needs no removal animation.
                    .transition(.asymmetric(insertion: .offset(x: travel).combined(with: .opacity), removal: .identity).animation(entrance))
            }
        }
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
