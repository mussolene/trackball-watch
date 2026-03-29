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
        material.emission.contents = UIImage(named: "TrackballEmission") ?? Self.generateEmissionTexture()
        material.specular.contents = UIColor(white: 0.95, alpha: 1.0)
        material.shininess = 96.0
        material.fresnelExponent = 1.8
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

        // ── Key light (upper-left, neutral cool) ──────────────────────────────
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.intensity = 1100
        keyLight.color = UIColor(red: 0.93, green: 0.97, blue: 1.0, alpha: 1.0)
        keyLight.castsShadow = false
        let keyNode = SCNNode()
        keyNode.light = keyLight
        keyNode.eulerAngles = SCNVector3(-Float.pi / 4, -Float.pi / 6, 0)
        scene.rootNode.addChildNode(keyNode)

        // ── Fill light (right side, cyan accent) ──────────────────────────────
        let fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.intensity = 420
        fillLight.color = UIColor(red: 0.38, green: 0.90, blue: 0.97, alpha: 1.0)
        fillLight.castsShadow = false
        let fillNode = SCNNode()
        fillNode.light = fillLight
        fillNode.eulerAngles = SCNVector3(Float.pi / 8, Float.pi / 2, 0)
        scene.rootNode.addChildNode(fillNode)

        // ── Ambient light ─────────────────────────────────────────────────────
        let ambLight = SCNLight()
        ambLight.type = .ambient
        ambLight.intensity = 180
        ambLight.color = UIColor(red: 0.16, green: 0.19, blue: 0.28, alpha: 1.0)
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

    /// Generate an Orbital Ball texture using Core Graphics directly.
    static func generateBallTexture(size: Int = 256) -> UIImage? {
        let sz = size
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: sz, height: sz, bitsPerComponent: 8,
            bytesPerRow: sz * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let w = CGFloat(sz)
        let graphite = CGColor(red: 0.09, green: 0.12, blue: 0.18, alpha: 1.0)
        let deep = CGColor(red: 0.05, green: 0.07, blue: 0.11, alpha: 1.0)
        let white = CGColor(red: 0.96, green: 0.98, blue: 1.0, alpha: 1.0)
        let grid = CGColor(red: 0.90, green: 0.94, blue: 1.0, alpha: 0.26)

        // Dark base
        ctx.setFillColor(deep)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: w))

        // Soft body shading
        if let body = CGGradient(
            colorsSpace: colorSpace,
            colors: [white.copy(alpha: 0.18)!, graphite, deep] as CFArray,
            locations: [0.0, 0.28, 1.0]
        ) {
            ctx.drawRadialGradient(
                body,
                startCenter: CGPoint(x: w * 0.34, y: w * 0.28),
                startRadius: 0,
                endCenter: CGPoint(x: w * 0.50, y: w * 0.52),
                endRadius: w * 0.60,
                options: [.drawsAfterEndLocation]
            )
        }

        // Longitude grid
        ctx.setStrokeColor(grid)
        ctx.setLineWidth(max(1.0, w * 0.008))
        for x in stride(from: w * 0.08, through: w * 0.92, by: w * 0.14) {
            ctx.strokeEllipse(in: CGRect(x: x - w * 0.18, y: w * 0.10, width: w * 0.36, height: w * 0.80))
        }

        // Latitude grid
        for y in stride(from: w * 0.18, through: w * 0.82, by: w * 0.16) {
            ctx.strokeEllipse(in: CGRect(x: w * 0.10, y: y - w * 0.10, width: w * 0.80, height: w * 0.20))
        }

        // Specular lobe
        ctx.setFillColor(white.copy(alpha: 0.14)!)
        ctx.fillEllipse(in: CGRect(x: w * 0.22, y: w * 0.18, width: w * 0.22, height: w * 0.15))

        guard let cgImage = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Emissive overlay for the orbital arc and glow node.
    static func generateEmissionTexture(size: Int = 256) -> UIImage? {
        let sz = size
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: sz, height: sz, bitsPerComponent: 8,
            bytesPerRow: sz * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let w = CGFloat(sz)
        let gridGlow = CGColor(red: 0.86, green: 0.92, blue: 1.0, alpha: 0.10)
        ctx.setStrokeColor(gridGlow)
        ctx.setLineWidth(max(0.8, w * 0.005))
        for x in stride(from: w * 0.08, through: w * 0.92, by: w * 0.14) {
            ctx.strokeEllipse(in: CGRect(x: x - w * 0.18, y: w * 0.10, width: w * 0.36, height: w * 0.80))
        }
        for y in stride(from: w * 0.18, through: w * 0.82, by: w * 0.16) {
            ctx.strokeEllipse(in: CGRect(x: w * 0.10, y: y - w * 0.10, width: w * 0.80, height: w * 0.20))
        }

        guard let cgImage = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
