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

// MARK: - Shield Shape ───────────────────────────────────────────────────────

/// Geometric shield — modern squircle top, straight sides tapering to a sharp point.
/// Matches the app icon exactly (tall proportions, 22% corner radius, waist at 52%).
private struct ShieldPath: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        return Path { p in
            let r     = w * 0.22           // large top corner radius (squircle feel)
            let left  = CGFloat(0)
            let right = w
            let top   = CGFloat(0)
            let waist = h * 0.52           // straight sides end here
            let tipY  = h * 0.97
            let tipX  = w * 0.50

            // ── Top-left corner ──────────────────────────────────────
            p.move(to: .init(x: left, y: top + r))
            p.addQuadCurve(to: .init(x: left + r, y: top),
                           control: .init(x: left, y: top))

            // ── Top edge ──────────────────────────────────────────────
            p.addLine(to: .init(x: right - r, y: top))

            // ── Top-right corner ──────────────────────────────────────
            p.addQuadCurve(to: .init(x: right, y: top + r),
                           control: .init(x: right, y: top))

            // ── Right side straight ───────────────────────────────────
            p.addLine(to: .init(x: right, y: waist))

            // ── Right shoulder → tip ──────────────────────────────────
            p.addCurve(to: .init(x: tipX, y: tipY),
                       control1: .init(x: right, y: waist + (tipY - waist) * 0.45),
                       control2: .init(x: tipX + w * 0.10, y: tipY - h * 0.02))

            // ── Tip → left shoulder ───────────────────────────────────
            p.addCurve(to: .init(x: left, y: waist),
                       control1: .init(x: tipX - w * 0.10, y: tipY - h * 0.02),
                       control2: .init(x: left, y: waist + (tipY - waist) * 0.45))

            // ── Left side up ──────────────────────────────────────────
            p.addLine(to: .init(x: left, y: top + r))
            p.closeSubpath()
        }
    }
}

// MARK: - Inner Window Mark ──────────────────────────────────────────────────

/// Four small rounded squares in a 2×2 grid — the "vault windows" at the heart of the shield.
/// Proportions match the app icon: sq = 15.8% of shield size, gap = 4.4%, corner = 26%.
private struct WindowMark: View {
    let size: CGFloat
    var tint: Color = .white

    var body: some View {
        let sq  = size * 0.158
        let gap = size * 0.044
        let cr  = sq * 0.26
        VStack(spacing: gap) {
            HStack(spacing: gap) {
                RoundedRectangle(cornerRadius: cr).fill(tint).frame(width: sq, height: sq)
                RoundedRectangle(cornerRadius: cr).fill(tint).frame(width: sq, height: sq)
            }
            HStack(spacing: gap) {
                RoundedRectangle(cornerRadius: cr).fill(tint).frame(width: sq, height: sq)
                RoundedRectangle(cornerRadius: cr).fill(tint).frame(width: sq, height: sq)
            }
        }
        .offset(y: -size * 0.10)   // shift grid into upper portion of shield
    }
}

// MARK: - LVMonogram (shield mark only) ─────────────────────────────────────

struct LVMonogram: View {
    var size: CGFloat = 90
    var tint: Color = .white
    /// Override the inner window colour. When nil, navy is used for white shields,
    /// white for all others (navy, .primary, custom colours).
    var windowTint: Color? = nil

    var body: some View {
        ZStack {
            ShieldPath()
                .fill(tint)

            WindowMark(size: size, tint: windowTint ?? (tint == LVBrand.navy ? .white : LVBrand.navy))
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
        HStack(spacing: shieldSize * 0.24) {
            LVMonogram(size: shieldSize, tint: textColor)
            Text("LedgerVault")
                .font(.system(size: shieldSize * 0.48, weight: .semibold, design: .default))
                .foregroundStyle(textColor)
                .tracking(-0.3)
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
