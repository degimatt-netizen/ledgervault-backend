import SwiftUI

// MARK: - Brand Palette ──────────────────────────────────────────────────────

enum LVBrand {
    /// Deep navy — primary brand background
    static let navy      = Color(hex: "0D1529")
    /// Mid navy — card / gradient step
    static let navyMid   = Color(hex: "152040")
    /// Accent green (positive / action)
    static let green     = Color(red: 0.15, green: 0.78, blue: 0.38)
}

// MARK: - Shield Outline ─────────────────────────────────────────────────────

/// Classic heraldic shield with concave centre-top notch, matching the anymark logo.
private struct ShieldPath: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        return Path { p in
            let r = w * 0.09          // corner radius

            // ── Top edge with centre notch ───────────────────────────────
            p.move(to: .init(x: w * 0.10 + r, y: h * 0.04))
            p.addLine(to: .init(x: w * 0.41, y: h * 0.04))
            // concave notch (curves downward in the centre)
            p.addQuadCurve(to: .init(x: w * 0.59, y: h * 0.04),
                           control: .init(x: w * 0.50, y: h * 0.155))
            p.addLine(to: .init(x: w * 0.90 - r, y: h * 0.04))

            // top-right corner
            p.addQuadCurve(to: .init(x: w * 0.90, y: h * 0.04 + r),
                           control: .init(x: w * 0.90, y: h * 0.04))

            // ── Right side ──────────────────────────────────────────────
            p.addLine(to: .init(x: w * 0.90, y: h * 0.56))
            p.addCurve(to: .init(x: w * 0.50, y: h * 0.965),
                       control1: .init(x: w * 0.90, y: h * 0.835),
                       control2: .init(x: w * 0.72, y: h * 0.965))

            // ── Left side ───────────────────────────────────────────────
            p.addCurve(to: .init(x: w * 0.10, y: h * 0.56),
                       control1: .init(x: w * 0.28, y: h * 0.965),
                       control2: .init(x: w * 0.10, y: h * 0.835))
            p.addLine(to: .init(x: w * 0.10, y: h * 0.04 + r))

            // top-left corner
            p.addQuadCurve(to: .init(x: w * 0.10 + r, y: h * 0.04),
                           control: .init(x: w * 0.10, y: h * 0.04))
            p.closeSubpath()
        }
    }
}

// MARK: - Inner 2 × 2 Reticle Mark ──────────────────────────────────────────

/// Four rounded squares in a 2 × 2 grid — top-left fully opaque,
/// the others progressively lighter, creating the crosshair / scope reticle.
private struct ReticleMark: View {
    let size: CGFloat
    var tint: Color = .white

    var body: some View {
        let sq  = size * 0.155
        let gap = size * 0.038
        let off = sq / 2 + gap / 2

        ZStack {
            square(tint, 1.00, x: -off, y: -off, sq: sq)   // top-left (solid)
            square(tint, 0.60, x:  off, y: -off, sq: sq)   // top-right
            square(tint, 0.60, x: -off, y:  off, sq: sq)   // bottom-left
            square(tint, 0.30, x:  off, y:  off, sq: sq)   // bottom-right
        }
    }

    @ViewBuilder
    private func square(_ color: Color, _ opacity: Double,
                        x: CGFloat, y: CGFloat, sq: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: sq * 0.22)
            .fill(color.opacity(opacity))
            .frame(width: sq, height: sq)
            .offset(x: x, y: y)
    }
}

// MARK: - LVMonogram (shield mark only) ─────────────────────────────────────

struct LVMonogram: View {
    var size: CGFloat = 90

    var body: some View {
        ZStack {
            // Navy gradient fill
            ShieldPath()
                .fill(LinearGradient(
                    colors: [LVBrand.navyMid, LVBrand.navy],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            // Subtle top-highlight for depth
            ShieldPath()
                .fill(LinearGradient(
                    colors: [Color.white.opacity(0.10), Color.clear],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.45)
                ))

            // 2×2 reticle, nudged slightly upward inside the shield
            ReticleMark(size: size)
                .offset(y: -size * 0.02)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - LVWordmark (shield + logotype side-by-side) ────────────────────────

/// Horizontal lockup matching the anymark brand guide.
struct LVWordmark: View {
    /// Height of the shield; text scales proportionally.
    var shieldSize: CGFloat = 44
    var textColor: Color = .white

    var body: some View {
        HStack(spacing: shieldSize * 0.22) {
            LVMonogram(size: shieldSize)
            Text("LedgerVault")
                .font(.system(size: shieldSize * 0.43, weight: .bold, design: .default))
                .foregroundStyle(textColor)
                .tracking(-0.4)
        }
    }
}

// MARK: - Preview ─────────────────────────────────────────────────────────────

#Preview {
    ZStack {
        Color(hex: "0A1020").ignoresSafeArea()
        VStack(spacing: 40) {
            // Shield only — various sizes
            HStack(spacing: 24) {
                LVMonogram(size: 120)
                LVMonogram(size: 72)
                LVMonogram(size: 44)
                LVMonogram(size: 28)
            }

            Divider().background(Color.white.opacity(0.12))

            // Horizontal wordmark
            LVWordmark(shieldSize: 48)

            // Smaller wordmark
            LVWordmark(shieldSize: 32)

            Divider().background(Color.white.opacity(0.12))

            // On a white card (dark text)
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white)
                .frame(height: 80)
                .overlay(LVWordmark(shieldSize: 36, textColor: LVBrand.navy))
                .padding(.horizontal, 32)
        }
        .padding(32)
    }
}
