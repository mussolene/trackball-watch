import SwiftUI

/// Production-style red sphere: light falloff, specular, rotating gloss ring.
/// Stays a true circle: no stacked `rotation3DEffect` on the whole view (large angles squash the disk into an ellipse on watchOS).
/// Pure visuals — interaction and TBP live in `TrackballView`.
struct KineticTrackballSphere: View {
    let diameter: CGFloat
    /// Host trackball spin (degrees) — used for gloss rotation and 2D parallax only.
    var rotX: Double
    var rotY: Double
    var isDragging: Bool

    private var spinRing: Double { rotY }

    var body: some View {
        let d = max(diameter, 1)
        // Tiny 2D parallax for “round” depth without 3D projection flattening the ball.
        let parallaxX = CGFloat(sin(rotY * .pi / 180.0)) * d * 0.03
        let parallaxY = CGFloat(sin(rotX * .pi / 180.0)) * d * 0.025

        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            Color.white.opacity(0.92),
                            Color(red: 1.0, green: 0.22, blue: 0.18),
                            Color(red: 0.72, green: 0.05, blue: 0.02),
                            Color(red: 0.15, green: 0.02, blue: 0.02),
                        ]),
                        center: UnitPoint(x: 0.28, y: 0.22),
                        startRadius: d * 0.02,
                        endRadius: d * 0.55
                    )
                )
                .overlay(specularHighlight(d: d, parallaxX: parallaxX, parallaxY: parallaxY))
                .overlay(glossRing(d: d))
                .overlay(causticBlob(d: d))
                .shadow(color: .black.opacity(isDragging ? 0.72 : 0.58), radius: isDragging ? 12 : 10, x: 2, y: isDragging ? 12 : 10)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private func specularHighlight(d: CGFloat, parallaxX: CGFloat, parallaxY: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(colors: [
                        Color.white.opacity(0.55),
                        Color.white.opacity(0.08),
                        Color.clear,
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: d * 0.2
                )
            )
            .frame(width: d * 0.28, height: d * 0.28)
            .blur(radius: 1.2)
            .offset(x: -d * 0.18 + parallaxX, y: -d * 0.2 + parallaxY)
    }

    @ViewBuilder
    private func glossRing(d: CGFloat) -> some View {
        Circle()
            .stroke(
                AngularGradient(
                    gradient: Gradient(colors: [
                        Color.clear,
                        Color.white.opacity(0.45),
                        Color.clear,
                        Color.black.opacity(0.25),
                        Color.clear,
                        Color.white.opacity(0.28),
                        Color.clear,
                    ]),
                    center: .center
                ),
                lineWidth: max(2.5, d * 0.038)
            )
            .rotationEffect(.degrees(spinRing))
    }

    @ViewBuilder
    /// Soft highlight blob — kept circular so it never reads as a squashed “pancake”.
    private func causticBlob(d: CGFloat) -> some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.16),
                        Color.clear,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: d * 0.22, height: d * 0.22)
            .offset(x: -d * 0.08, y: -d * 0.14)
            .blur(radius: 1)
    }
}

#if DEBUG
#Preview {
    KineticTrackballSphere(
        diameter: 120,
        rotX: 12,
        rotY: -20,
        isDragging: true
    )
    .padding()
}
#endif
