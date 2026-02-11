//
// WalletQRScannerView.swift
// bitchat
//
// QR scanner for wallet addresses to start XMTP DMs.
// This is free and unencumbered software released into the public domain.
//

import SwiftUI
#if os(iOS)
import AVFoundation
#endif
import XMTP
import BitLogger

/// Sheet view for scanning wallet address QR codes to start XMTP chats
struct WalletQRScannerSheet: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Binding var isPresented: Bool
    @Environment(\.colorScheme) var colorScheme
    
    @State private var scanStatus: ScanStatus = .scanning
    @State private var lastScannedCode: String?
    
    enum ScanStatus: Equatable {
        case scanning
        case processing(String)
        case success(String)
        case error(String)
    }
    
    private var backgroundColor: Color { colorScheme == .dark ? Color.black : Color.white }
    private var accentColor: Color { Color.orange }
    private var boxColor: Color { Color.gray.opacity(0.1) }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Scan Wallet QR")
                    .font(.bitchatSystem(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(accentColor)
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark")
                        .font(.bitchatSystem(size: 14, weight: .semibold))
                        .foregroundColor(accentColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            
            Divider()
            
            VStack(spacing: 16) {
                // Status message
                statusView
                    .padding(.top, 12)
                
                #if os(iOS)
                // Camera scanner
                WalletCameraScannerView(isActive: scanStatus == .scanning) { code in
                    handleScannedCode(code)
                }
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(accentColor.opacity(0.3), lineWidth: 2)
                )
                #else
                // macOS: manual input
                macOSInputView
                #endif
                
                // Instructions
                Text("Scan a wallet QR to start an XMTP chat")
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)
                
                Spacer()
            }
            .padding()
        }
        .background(backgroundColor)
    }
    
    @ViewBuilder
    private var statusView: some View {
        switch scanStatus {
        case .scanning:
            HStack(spacing: 8) {
                Image(systemName: "viewfinder")
                    .foregroundColor(accentColor)
                Text("Point camera at wallet QR code")
                    .font(.bitchatSystem(size: 14, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        case .processing(let address):
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Looking up \(address.prefix(10))…")
                    .font(.bitchatSystem(size: 14, design: .monospaced))
                    .foregroundColor(accentColor)
            }
        case .success(let message):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text(message)
                    .font(.bitchatSystem(size: 14, design: .monospaced))
                    .foregroundColor(.green)
            }
        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(message)
                    .font(.bitchatSystem(size: 14, design: .monospaced))
                    .foregroundColor(.red)
            }
            .onAppear {
                // Reset to scanning after showing error
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if case .error = scanStatus {
                        scanStatus = .scanning
                        lastScannedCode = nil
                    }
                }
            }
        }
    }
    
    #if os(macOS)
    @State private var manualInput: String = ""
    
    private var macOSInputView: some View {
        VStack(spacing: 12) {
            TextField("Paste wallet address (0x...)", text: $manualInput)
                .textFieldStyle(.roundedBorder)
                .font(.bitchatSystem(size: 14, design: .monospaced))
            
            Button("Look Up") {
                handleScannedCode(manualInput)
            }
            .buttonStyle(.borderedProminent)
            .tint(accentColor)
            .disabled(manualInput.isEmpty)
        }
        .padding()
    }
    #endif
    
    private func handleScannedCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Deduplicate
        guard trimmed != lastScannedCode else { return }
        lastScannedCode = trimmed
        
        // Extract wallet address from various QR formats
        let walletAddress = extractWalletAddress(from: trimmed)
        
        guard let address = walletAddress else {
            scanStatus = .error("Not a valid wallet address")
            return
        }
        
        guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
            scanStatus = .error("XMTP not connected")
            return
        }
        
        scanStatus = .processing(address)
        
        Task {
            await resolveAndOpenChat(walletAddress: address)
        }
    }
    
    private func extractWalletAddress(from code: String) -> String? {
        // Direct wallet address
        if code.hasPrefix("0x") && code.count == 42 && code.dropFirst(2).allSatisfy({ $0.isHexDigit }) {
            return code
        }
        
        // ethereum: URI format (e.g., ethereum:0x1234...)
        if code.lowercased().hasPrefix("ethereum:") {
            let potential = String(code.dropFirst(9))
            // Handle ethereum:0x... or ethereum:pay-0x... formats
            let address = potential.split(separator: "@").first.map(String.init) ?? potential
            let cleanAddress = address.hasPrefix("pay-") ? String(address.dropFirst(4)) : address
            if cleanAddress.hasPrefix("0x") && cleanAddress.count == 42 {
                return cleanAddress
            }
        }
        
        // Look for 0x address anywhere in the string
        if let range = code.range(of: "0x[a-fA-F0-9]{40}", options: .regularExpression) {
            return String(code[range])
        }
        
        return nil
    }
    
    @MainActor
    private func resolveAndOpenChat(walletAddress: String) async {
        do {
            let identity = PublicIdentity(kind: .ethereum, identifier: walletAddress.lowercased())
            if let inboxId = try await XMTPServiceContainer.shared.clientService.getInboxIdFromIdentity(identity: identity) {
                scanStatus = .success("Opening chat…")
                
                // Short delay to show success, then close and open chat
                try? await Task.sleep(nanoseconds: 500_000_000)
                
                isPresented = false
                await viewModel.startXMTPChat(with: inboxId)
            } else {
                scanStatus = .error("No XMTP identity for this wallet")
            }
        } catch {
            SecureLogger.error("Wallet lookup failed: \(error)", category: .session)
            scanStatus = .error("Lookup failed")
        }
    }
}

// MARK: - Camera Scanner View (iOS only)

#if os(iOS)
struct WalletCameraScannerView: UIViewRepresentable {
    typealias UIViewType = WalletPreviewView
    var isActive: Bool
    var onCode: (String) -> Void
    
    func makeUIView(context: Context) -> WalletPreviewView {
        let view = WalletPreviewView()
        context.coordinator.setup(sessionOwner: view, onCode: onCode)
        context.coordinator.setActive(isActive)
        return view
    }
    
    func updateUIView(_ uiView: WalletPreviewView, context: Context) {
        context.coordinator.setActive(isActive)
    }
    
    func makeCoordinator() -> Coordinator { Coordinator() }
    
    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private var onCode: ((String) -> Void)?
        private weak var owner: WalletPreviewView?
        private let session = AVCaptureSession()
        private var isRunning = false
        private var permissionGranted = false
        private var desiredActive = false
        
        func setup(sessionOwner: WalletPreviewView, onCode: @escaping (String) -> Void) {
            self.owner = sessionOwner
            self.onCode = onCode
            session.beginConfiguration()
            session.sessionPreset = .high
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            if output.availableMetadataObjectTypes.contains(.qr) {
                output.metadataObjectTypes = [.qr]
            }
            session.commitConfiguration()
            sessionOwner.videoPreviewLayer.session = session
            
            AVCaptureDevice.requestAccess(for: .video) { granted in
                self.permissionGranted = granted
                if granted && self.desiredActive && !self.isRunning {
                    self.setActive(true)
                }
            }
        }
        
        func setActive(_ active: Bool) {
            desiredActive = active
            guard permissionGranted else { return }
            if active && !isRunning {
                isRunning = true
                DispatchQueue.global(qos: .userInitiated).async {
                    if !self.session.isRunning { self.session.startRunning() }
                }
            } else if !active && isRunning {
                isRunning = false
                DispatchQueue.global(qos: .userInitiated).async {
                    if self.session.isRunning { self.session.stopRunning() }
                }
            }
        }
        
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            for obj in metadataObjects {
                guard let m = obj as? AVMetadataMachineReadableCodeObject,
                      m.type == .qr,
                      let str = m.stringValue else { continue }
                onCode?(str)
            }
        }
    }
    
    final class WalletPreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override init(frame: CGRect) {
            super.init(frame: frame)
            videoPreviewLayer.videoGravity = .resizeAspectFill
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
#endif

// MARK: - Preview

// Preview disabled - requires ChatViewModel which has complex initialization
// For manual testing, present via showWalletQRScanner state in ContentView
