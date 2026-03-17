import SwiftUI

// ── LV Monogram Logo ──────────────────────────────────────────────────────────
// The "L" and "V" share a central vertical stroke — they interlock
// into a single unified glyph, not two separate letters.
struct LVMonogram: View {
    var size: CGFloat = 90

    var body: some View {
        ZStack {
            // Outer ring
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "1a2a4a"), Color(hex: "0d1b35")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
                .shadow(color: .blue.opacity(0.4), radius: 12, x: 0, y: 4)

            // Subtle ring border
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.blue.opacity(0.6), Color.cyan.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: size * 0.025
                )
                .frame(width: size, height: size)

            // LV monogram drawn as a single interlocked path
            Canvas { ctx, _ in
                let s  = size * 0.52          // scale factor
                let cx = size / 2             // center x
                let cy = size / 2             // center y

                // ── L stroke ──────────────────────────────────────
                // Vertical bar of L
                let lPath = Path { p in
                    let lx = cx - s * 0.30    // left edge of L vertical bar
                    let rx = cx - s * 0.08    // right edge of L vertical bar
                    let ty = cy - s * 0.42    // top of L
                    let by = cy + s * 0.42    // bottom of L
                    let fw = s * 0.48         // foot width of L

                    p.move(to:    CGPoint(x: lx, y: ty))
                    p.addLine(to: CGPoint(x: rx, y: ty))
                    p.addLine(to: CGPoint(x: rx, y: by - s * 0.04))
                    // L foot
                    p.addLine(to: CGPoint(x: lx + fw, y: by - s * 0.04))
                    p.addLine(to: CGPoint(x: lx + fw, y: by))
                    p.addLine(to: CGPoint(x: lx,      y: by))
                    p.closeSubpath()
                }

                // ── V stroke ──────────────────────────────────────
                // V shares the right edge of L's vertical bar as its left leg
                let vPath = Path { p in
                    let vLx  = cx - s * 0.08   // left leg of V  (same as L right edge → interlock)
                    let vRx  = cx + s * 0.36   // right leg of V outer edge
                    let thick = s * 0.18       // leg thickness
                    let ty   = cy - s * 0.42   // top
                    let by   = cy + s * 0.42   // bottom tip y

                    // Left leg of V (descends right)
                    p.move(to:    CGPoint(x: vLx,         y: ty))
                    p.addLine(to: CGPoint(x: vLx + thick, y: ty))
                    p.addLine(to: CGPoint(x: cx + s * 0.06, y: by))  // tip inner
                    p.addLine(to: CGPoint(x: cx - s * 0.06, y: by))  // tip outer
                    p.closeSubpath()

                    // Right leg of V (descends left)
                    p.move(to:    CGPoint(x: vRx,          y: ty))
                    p.addLine(to: CGPoint(x: vRx - thick,  y: ty))
                    p.addLine(to: CGPoint(x: cx + s * 0.06, y: by))  // tip inner
                    p.addLine(to: CGPoint(x: cx + s * 0.24, y: by + s * 0.02)) // outer tip
                    p.closeSubpath()
                }

                // Draw L with gradient fill
                ctx.fill(
                    lPath,
                    with: .linearGradient(
                        Gradient(colors: [Color(hex: "4A9EFF"), Color(hex: "0066FF")]),
                        startPoint: CGPoint(x: size * 0.2, y: size * 0.1),
                        endPoint:   CGPoint(x: size * 0.2, y: size * 0.9)
                    )
                )

                // Draw V with gradient fill (slightly lighter to distinguish)
                ctx.fill(
                    vPath,
                    with: .linearGradient(
                        Gradient(colors: [Color(hex: "7BBEFF"), Color(hex: "2288FF")]),
                        startPoint: CGPoint(x: size * 0.6, y: size * 0.1),
                        endPoint:   CGPoint(x: size * 0.6, y: size * 0.9)
                    )
                )
            }
            .frame(width: size, height: size)
        }
    }
}

// ── Preview ───────────────────────────────────────────────────────────────────
#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        VStack(spacing: 24) {
            LVMonogram(size: 100)
            LVMonogram(size: 60)
            LVMonogram(size: 36)
        }
    }
}
