import SwiftUI
import AVFoundation

struct MainView: View {
    @StateObject private var relay = WatchRelayService.shared
    @StateObject private var pairing = PairingService.shared
    @StateObject private var bonjour = BonjourBrowser()
    @State private var showingScanner = false
    @State private var showingManualEntry = false

    var body: some View {
        NavigationStack {
            List {
                // Relay status
                Section {
                    StatusRow(relay: relay, pairing: pairing)
                }

                // Saved connections
                if !pairing.connections.isEmpty {
                    Section("My Desktops") {
                        ForEach(pairing.connections) { config in
                            SavedConnectionRow(
                                config: config,
                                isActive: config.deviceId == pairing.activeId,
                                onActivate: { pairing.activate(config) }
                            )
                        }
                        .onDelete { indexSet in
                            indexSet.forEach { pairing.delete(pairing.connections[$0]) }
                        }
                    }
                }

                // Bonjour discovery
                Section {
                    if bonjour.isSearching && bonjour.discovered.isEmpty {
                        Label("Searching for nearby desktops…", systemImage: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                    ForEach(bonjour.discovered) { desktop in
                        DiscoveredRow(desktop: desktop, pairing: pairing)
                    }
                } header: {
                    HStack {
                        Text("Nearby Desktops")
                        Spacer()
                        if bonjour.isSearching {
                            ProgressView().scaleEffect(0.7)
                        }
                    }
                }

                // Other pairing options
                Section("Pair Manually") {
                    Button {
                        showingScanner = true
                    } label: {
                        Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    }
                    Button {
                        showingManualEntry = true
                    } label: {
                        Label("Enter IP Address", systemImage: "network")
                    }
                }

                Section("Additional Input") {
                    NavigationLink {
                        TrackballDebugView()
                    } label: {
                        Label("Trackball Remote", systemImage: "dot.squareshape.split.2x2")
                    }
                }

                // Stats
                if relay.isRunning && relay.packetsRelayed > 0 {
                    Section {
                        Label("Packets relayed: \(relay.packetsRelayed)", systemImage: "arrow.up.arrow.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("TrackBall Watch")
            .onAppear { bonjour.start() }
            .onDisappear { bonjour.stop() }
            .sheet(isPresented: $showingScanner) {
                QRScannerView { code in
                    showingScanner = false
                    if let config = pairing.parsePairingURL(code) {
                        Task { await pairing.pair(with: config) }
                    } else {
                        pairing.pairingError = "Invalid QR code"
                    }
                }
            }
            .sheet(isPresented: $showingManualEntry) {
                ManualEntryView(pairing: pairing, isPresented: $showingManualEntry)
            }
            .sheet(isPresented: $pairing.showPINEntry) {
                PINEntryView(pairing: pairing)
            }
            .alert("Error", isPresented: Binding(
                get: { pairing.pairingError != nil },
                set: { if !$0 { pairing.pairingError = nil } }
            )) {
                Button("OK") { pairing.pairingError = nil }
            } message: {
                Text(pairing.pairingError ?? "")
            }
        }
    }
}

// MARK: - Status row

struct StatusRow: View {
    @ObservedObject var relay: WatchRelayService
    @ObservedObject var pairing: PairingService

    private var statusColor: Color {
        switch relay.desktopLinkState {
        case .connected: return .green
        case .connecting, .waiting: return .yellow
        case .failed: return .red
        case .idle: return relay.isRunning ? .yellow : .red
        }
    }

    private var statusText: String {
        switch relay.desktopLinkState {
        case .connected:
            return "Desktop connected"
        case .connecting:
            return "Connecting to desktop…"
        case .waiting:
            return "Desktop unavailable (waiting network)"
        case .failed:
            return "Desktop connection failed"
        case .idle:
            return relay.isRunning ? "Relay running (no desktop selected)" : "Relay stopped"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusText)
                Spacer()
                Button(relay.isRunning ? "Stop" : "Start") {
                    if relay.isRunning { relay.stop() } else { relay.start() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let active = pairing.activeConnection {
                Text("Selected desktop: \(active.host):\(active.port)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("No desktop selected. Choose one in 'My Desktops' or 'Nearby Desktops'.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Saved connection row

struct SavedConnectionRow: View {
    let config: DesktopConfig
    let isActive: Bool
    let onActivate: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isActive ? "desktopcomputer.fill" : "desktopcomputer")
                .foregroundStyle(isActive ? .blue : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name.isEmpty ? config.host : config.name)
                    .font(.subheadline)
                    .fontWeight(isActive ? .semibold : .regular)
                Text("\(config.host):\(config.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Connect") { onActivate() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Discovered desktop row

struct DiscoveredRow: View {
    let desktop: DiscoveredDesktop
    @ObservedObject var pairing: PairingService

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(desktop.name)
                    .font(.subheadline)
                Text("\(desktop.host):\(desktop.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Connect") {
                pairing.startPairing(with: desktop, requirePIN: false)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }
}

// MARK: - PIN entry sheet

struct PINEntryView: View {
    @ObservedObject var pairing: PairingService

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let desktop = pairing.pendingDesktop {
                    VStack(spacing: 8) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 48))
                            .foregroundStyle(.blue)
                        Text("Connect to")
                            .foregroundStyle(.secondary)
                        Text(desktop.name)
                            .font(.title2.bold())
                        Text(PairingService.pin(for: desktop))
                            .font(.system(size: 36, design: .monospaced).bold())
                            .foregroundStyle(.primary)
                            .padding(.top, 8)
                        Text("This code should match what's shown on your desktop.\nLeave blank to skip verification.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                TextField("PIN (optional)", text: $pairing.enteredPIN)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .frame(maxWidth: 200)

                Button("Connect") {
                    pairing.confirmPIN()
                }
                .buttonStyle(.borderedProminent)

                Spacer()
            }
            .padding()
            .navigationTitle("Confirm Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { pairing.cancelPIN() }
                }
            }
        }
    }
}

// MARK: - Manual IP entry

struct ManualEntryView: View {
    @ObservedObject var pairing: PairingService
    @Binding var isPresented: Bool
    @State private var host = ""
    @State private var port = "47474"
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Desktop Address") {
                    TextField("Name (optional)", text: $name)
                    TextField("IP Address (e.g. 192.168.1.5)", text: $host)
                        .keyboardType(.decimalPad)
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                }
            }
            .navigationTitle("Manual Pairing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        guard let portVal = UInt16(port), !host.isEmpty else { return }
                        let displayName = name.isEmpty ? host : name
                        let config = DesktopConfig(host: host, port: portVal,
                                                   deviceId: UUID().uuidString, name: displayName)
                        Task {
                            await pairing.pair(with: config)
                            isPresented = false
                        }
                    }
                    .disabled(host.isEmpty || UInt16(port) == nil)
                }
            }
        }
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
