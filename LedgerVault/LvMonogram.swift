import SwiftUI

// ── LV Shield Logo ────────────────────────────────────────────────────────────
struct LVMonogram: View {
    var size: CGFloat = 90

    private func shieldPath(in rect: CGSize) -> Path {
        Path { p in
            let w = rect.width
            let h = rect.height
            let topY    = h * 0.06
            let sideBot = h * 0.60
            let tipY    = h * 0.95
            let r       = w * 0.10

            p.move(to: CGPoint(x: w * 0.10 + r, y: topY))
            p.addLine(to: CGPoint(x: w * 0.90 - r, y: topY))
            p.addQuadCurve(to:    CGPoint(x: w * 0.90, y: topY + r),
                           control: CGPoint(x: w * 0.90, y: topY))
            p.addLine(to: CGPoint(x: w * 0.90, y: sideBot))
            p.addQuadCurve(to:    CGPoint(x: w * 0.50, y: tipY),
                           control: CGPoint(x: w * 0.90, y: h * 0.90))
            p.addQuadCurve(to:    CGPoint(x: w * 0.10, y: sideBot),
                           control: CGPoint(x: w * 0.10, y: h * 0.90))
            p.addLine(to: CGPoint(x: w * 0.10, y: topY + r))
            p.addQuadCurve(to:    CGPoint(x: w * 0.10 + r, y: topY),
                           control: CGPoint(x: w * 0.10, y: topY))
            p.closeSubpath()
        }
    }

    var body: some View {
        ZStack {
            GeometryReader { geo in
                let sz = CGSize(width: geo.size.width, height: geo.size.height)
                let path = shieldPath(in: sz)

                // Black fill
                path.fill(Color.black)

                // Subtle inner depth gradient
                path.fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.07), Color.clear],
                        startPoint: .top,
                        endPoint: UnitPoint(x: 0.5, y: 0.5)
                    )
                )

                // Dark gold border
                path.stroke(
                    LinearGradient(
                        colors: [Color(hex: "C9A227"), Color(hex: "7A5C00")],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: sz.width * 0.032
                )
            }

            // LV text in dark gold
            Text("LV")
                .font(.system(size: size * 0.36, weight: .black, design: .serif))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(hex: "E8C040"), Color(hex: "A87800")],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: Color(hex: "C9A227").opacity(0.5), radius: 4, x: 0, y: 0)
                .offset(y: -size * 0.05)
        }
        .frame(width: size, height: size)
        .shadow(color: Color(hex: "C9A227").opacity(0.3), radius: size * 0.12, x: 0, y: size * 0.04)
    }
}

// ── Preview ───────────────────────────────────────────────────────────────────
#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        VStack(spacing: 28) {
            LVMonogram(size: 120)
            LVMonogram(size: 80)
            LVMonogram(size: 44)
        }
    }
}
