import SwiftUI
import AVFoundation

struct MainView: View {
    @StateObject private var relay = WatchRelayService.shared
    @StateObject private var pairing = PairingService.shared
    @State private var showingPairing = false
    @State private var showingScanner = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Status card
                StatusCard(relay: relay)

                // Pairing section
                if pairing.isPaired {
                    PairedView(pairing: pairing)
                } else {
                    PairButton(showingScanner: $showingScanner)
                }

                Spacer()

                // Stats
                if relay.isRunning {
                    Text("Packets relayed: \(relay.packetsRelayed)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle("TrackBall Watch")
            .sheet(isPresented: $showingScanner) {
                QRScannerView { code in
                    showingScanner = false
                    if let config = pairing.parsePairingURL(code) {
                        Task {
                            await pairing.pair(with: config)
                        }
                    } else {
                        pairing.pairingError = "Invalid QR code"
                    }
                }
            }
        }
    }
}

// MARK: - Subviews

struct StatusCard: View {
    @ObservedObject var relay: WatchRelayService

    var body: some View {
        HStack {
            Circle()
                .fill(relay.isRunning ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text(relay.isRunning ? "Relay active" : "Relay stopped")
                .font(.subheadline)
            Spacer()
            Button(relay.isRunning ? "Stop" : "Start") {
                if relay.isRunning { relay.stop() } else { relay.start() }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PairedView: View {
    @ObservedObject var pairing: PairingService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Desktop paired", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Button("Unpair") {
                pairing.unpair()
            }
            .foregroundStyle(.red)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PairButton: View {
    @Binding var showingScanner: Bool

    var body: some View {
        VStack(spacing: 12) {
            Text("No desktop paired")
                .foregroundStyle(.secondary)
            Button(action: { showingScanner = true }) {
                Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - QR Scanner

struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onScan = onScan
        return vc
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    private var captureSession: AVCaptureSession?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
    }

    private func setupCamera() {
        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
        captureSession = session
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        if let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
           let string = object.stringValue {
            captureSession?.stopRunning()
            onScan?(string)
        }
    }
}
