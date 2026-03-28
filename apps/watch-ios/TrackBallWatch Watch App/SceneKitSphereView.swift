import SwiftUI
import WatchKit
import SceneKit
import simd

/// 3D trackball sphere rendered with SceneKit.
/// Uses WKInterfaceObjectRepresentable to embed WKInterfaceSCNScene in SwiftUI.
struct SceneKitSphereView: WKInterfaceObjectRepresentable {
    let diameter: CGFloat
    let orientation: simd_quatd
    let isDragging: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeWKInterfaceObject(context: WKInterfaceObjectRepresentableContext<SceneKitSphereView>) -> WKInterfaceSCNScene {
        let scnScene = WKInterfaceSCNScene()
        let scene = SCNScene()

        // ── Sphere geometry ────────────────────────────────────────────────────
        let sphere = SCNSphere(radius: 1.0)
        sphere.segmentCount = 36

        let material = SCNMaterial()
        // Try to load a custom asset texture first; fall back to generated one
        let texture = UIImage(named: "TrackballTexture") ?? Self.generateBallTexture()
        material.diffuse.contents = texture
        material.specular.contents = UIColor.white
        material.shininess = 80.0
        material.lightingModel = .phong
        sphere.materials = [material]

        let sphereNode = SCNNode(geometry: sphere)
        scene.rootNode.addChildNode(sphereNode)

        // ── Camera (orthographic — no perspective distortion) ──────────────────
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 1.15
        camera.zNear = 0.1
        camera.zFar = 10.0
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 3)
        scene.rootNode.addChildNode(cameraNode)

        // ── Key light (upper-left, warm white) ────────────────────────────────
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.intensity = 1000
        keyLight.castsShadow = false
        let keyNode = SCNNode()
        keyNode.light = keyLight
        keyNode.eulerAngles = SCNVector3(-Float.pi / 4, -Float.pi / 6, 0)
        scene.rootNode.addChildNode(keyNode)

        // ── Fill light (right side, cool blue tint) ───────────────────────────
        let fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.intensity = 350
        fillLight.color = UIColor(red: 0.8, green: 0.9, blue: 1.0, alpha: 1.0)
        fillLight.castsShadow = false
        let fillNode = SCNNode()
        fillNode.light = fillLight
        fillNode.eulerAngles = SCNVector3(Float.pi / 8, Float.pi / 2, 0)
        scene.rootNode.addChildNode(fillNode)

        // ── Ambient light ─────────────────────────────────────────────────────
        let ambLight = SCNLight()
        ambLight.type = .ambient
        ambLight.intensity = 100
        let ambNode = SCNNode()
        ambNode.light = ambLight
        scene.rootNode.addChildNode(ambNode)

        scnScene.scene = scene
        // Render at 60 fps when available; Apple Watch will cap to its max
        scnScene.preferredFramesPerSecond = 60

        context.coordinator.sphereNode = sphereNode
        return scnScene
    }

    func updateWKInterfaceObject(_ object: WKInterfaceSCNScene, context: WKInterfaceObjectRepresentableContext<SceneKitSphereView>) {
        guard let node = context.coordinator.sphereNode else { return }
        // Apply quaternion orientation directly to the sphere node
        let q = orientation
        node.orientation = SCNVector4(
            Float(q.imag.x),
            Float(q.imag.y),
            Float(q.imag.z),
            Float(q.real)
        )
    }

    // MARK: - Coordinator

    final class Coordinator {
        var sphereNode: SCNNode?
    }

    // MARK: - Procedural Texture

    /// Generate a billiard-ball style texture using Core Graphics directly
    /// (UIGraphicsImageRenderer is not available in watchOS).
    /// Red background + white equatorial band + white meridian → all 3 rotation axes visible.
    static func generateBallTexture(size: Int = 256) -> UIImage? {
        let sz = size
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: sz, height: sz, bitsPerComponent: 8,
            bytesPerRow: sz * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let w = CGFloat(sz)
        let red   = CGColor(red: 0.82, green: 0.10, blue: 0.06, alpha: 1)
        let white = CGColor(red: 1,    green: 1,    blue: 1,    alpha: 1)

        // Red background
        ctx.setFillColor(red)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: w))

        // White equatorial band
        ctx.setFillColor(white)
        let bandH = w * 0.14
        ctx.fill(CGRect(x: 0, y: w / 2 - bandH / 2, width: w, height: bandH))

        // White meridian line
        let meridW = w * 0.08
        ctx.fill(CGRect(x: w / 2 - meridW / 2, y: 0, width: meridW, height: w))

        // Red center dot at intersection
        ctx.setFillColor(red)
        let dotR = w * 0.07
        ctx.fillEllipse(in: CGRect(x: w / 2 - dotR, y: w / 2 - dotR,
                                   width: dotR * 2, height: dotR * 2))

        // White pole dots for depth reference
        ctx.setFillColor(white)
        let pR = w * 0.04
        ctx.fillEllipse(in: CGRect(x: w / 2 - pR, y: w * 0.06 - pR, width: pR * 2, height: pR * 2))
        ctx.fillEllipse(in: CGRect(x: w / 2 - pR, y: w * 0.94 - pR, width: pR * 2, height: pR * 2))

        guard let cgImage = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
