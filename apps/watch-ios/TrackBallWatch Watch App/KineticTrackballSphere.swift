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

    var body: some View {
        let d = max(diameter, 1)
        // Parallax: horizontal drag → rotY, vertical → rotX — both axes must read clearly on a circle.
        let parallaxX = CGFloat(sin(rotY * .pi / 180.0)) * d * 0.10
        let parallaxY = CGFloat(sin(rotX * .pi / 180.0)) * d * 0.10

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
                // Two concentric gloss rings: independent rotY (horizontal drag) and rotX (vertical drag).
                .overlay(glossRing(d: d, rotationDegrees: rotY, lineWidthScale: 1.0))
                .overlay(glossRing(d: d, rotationDegrees: rotX, lineWidthScale: 0.78))
                .overlay(causticBlob(d: d, rotX: rotX, rotY: rotY))
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
    private func glossRing(d: CGFloat, rotationDegrees: Double, lineWidthScale: CGFloat) -> some View {
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
                lineWidth: max(2.0, d * 0.038 * lineWidthScale)
            )
            .rotationEffect(.degrees(rotationDegrees))
    }

    @ViewBuilder
    /// Soft highlight blob — kept circular; offset follows both spin axes.
    private func causticBlob(d: CGFloat, rotX: Double, rotY: Double) -> some View {
        let ox = CGFloat(sin(rotY * .pi / 180.0)) * d * 0.06
        let oy = CGFloat(sin(rotX * .pi / 180.0)) * d * 0.06
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
            .offset(x: -d * 0.08 + ox, y: -d * 0.14 + oy)
            .blur(radius: 1)
    }
}

#if DEBUG
#Preview {
    KineticTrackballSphere(
        diameter: 120,
        rotX: 35,
        rotY: -40,
        isDragging: true
    )
    .padding()
}
#endif
