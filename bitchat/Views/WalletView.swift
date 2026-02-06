//
// WalletView.swift
// bitchat
//
// Clean wallet UI showing QR code, address, and balances.
// Fetches balances privately via Flashbots Protect RPC over Tor.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CoreImage.CIFilterBuiltins
import SwiftUI

/// Main wallet view showing address QR code, copyable address, and balances
struct WalletView: View {
    let wallet: EmbeddedWallet
    @EnvironmentObject var xmtpContainer: XMTPServiceContainer
    
    /// Use the balance service from the container for shared testnet mode state
    private var balanceService: EthereumBalanceService {
        xmtpContainer.balanceService
    }
    
    @State private var address: String = ""
    @State private var isLoading: Bool = true
    @State private var loadError: String?
    @State private var showCopiedToast: Bool = false
    @State private var copiedText: String = "Address copied!"
    @State private var showSendSheet: Bool = false
    @State private var showHistorySheet: Bool = false
    
    // Auto-refresh timer
    private let refreshInterval: TimeInterval = 15
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // MARK: - QR Code
                if !address.isEmpty {
                    qrCodeSection
                }
                
                // MARK: - Address
                if !address.isEmpty {
                    addressSection
                }
                
                // MARK: - XMTP Inbox ID
                if let inboxId = xmtpContainer.clientService.inboxId {
                    xmtpInboxSection(inboxId: inboxId)
                }
                
                // MARK: - Loading / Error
                if isLoading {
                    ProgressView("Loading wallet...")
                        .padding()
                } else if let error = loadError {
                    errorSection(error)
                }
                
                // MARK: - Balances
                if !address.isEmpty {
                    balancesSection
                }
                
                // MARK: - Actions
                if !address.isEmpty && !isLoading {
                    actionsSection
                }
            }
            .padding()
        }
        .navigationTitle("Wallet")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await loadWallet()
        }
        .task {
            // Auto-refresh balances periodically
            await autoRefreshBalances()
        }
        .overlay(alignment: .bottom) {
            if showCopiedToast {
                copiedToast
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: showCopiedToast)
        .sheet(isPresented: $showSendSheet) {
            SendTransactionView(
                wallet: wallet,
                balanceService: balanceService,
                meshRelay: xmtpContainer.meshTransactionRelay
            )
        }
        .sheet(isPresented: $showHistorySheet) {
            TransactionHistoryView(
                meshRelay: xmtpContainer.meshTransactionRelay,
                balanceService: balanceService
            )
        }
    }
    
    // MARK: - Sections
    
    private var qrCodeSection: some View {
        VStack(spacing: 16) {
            if let qrImage = generateQRCode(from: address) {
                #if os(iOS)
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .padding(16)
                    .background(Color.white)
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
                #else
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .padding(16)
                    .background(Color.white)
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
                #endif
            }
            
            Text("Scan to receive")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var addressSection: some View {
        VStack(spacing: 12) {
            Text("Your Address")
                .font(.headline)
            
            HStack {
                Text(truncatedAddress)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.primary)
                
                Spacer()
                
                Button {
                    copyAddress()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .help("Copy address")
            }
            .padding()
            .background(Color(.systemGray).opacity(0.15))
            .cornerRadius(8)
            
            Text(address)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
    }
    
    private var balancesSection: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Balances")
                    .font(.headline)
                
                Spacer()
                
                if balanceService.isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Button {
                        Task {
                            await balanceService.fetchBalances(for: address)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.body)
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh balances")
                }
            }
            
            if let error = balanceService.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            // Show active networks based on mainnet/testnet mode
            let networks = balanceService.useTestnet ? EthereumBalanceService.Network.testnets : EthereumBalanceService.Network.mainnets
            ForEach(networks, id: \.self) { network in
                balanceRow(for: network)
            }
            
            HStack {
                Image(systemName: balanceService.useTestnet ? "testtube.2" : "shield.checkered")
                    .foregroundColor(balanceService.useTestnet ? .orange : .green)
                Text(balanceService.useTestnet ? "Testnet Mode" : "Mainnet")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var actionsSection: some View {
        VStack(spacing: 12) {
            Text("Actions")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            HStack(spacing: 16) {
                Button {
                    showSendSheet = true
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                        Text("Send")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                
                Button {
                    copyAddress()
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title)
                        Text("Receive")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                
                Button {
                    showHistorySheet = true
                } label: {
                    VStack(spacing: 8) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.title)
                            
                            // Badge for pending transactions
                            let pendingCount = xmtpContainer.meshTransactionRelay.pendingRelays.count
                            if pendingCount > 0 {
                                Text("\(pendingCount)")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                                    .padding(4)
                                    .background(Color.orange)
                                    .clipShape(Circle())
                                    .offset(x: 8, y: -4)
                            }
                        }
                        Text("History")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.purple.opacity(0.1))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
            }
            
            // Pending transactions indicator
            let txCount = xmtpContainer.meshTransactionRelay.pendingRelays.count + xmtpContainer.meshTransactionRelay.confirmedTransactions.count
            if txCount > 0 {
                Button {
                    showHistorySheet = true
                } label: {
                    HStack {
                        if xmtpContainer.meshTransactionRelay.pendingRelays.isEmpty {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("\(xmtpContainer.meshTransactionRelay.confirmedTransactions.count) confirmed transaction(s)")
                        } else {
                            Image(systemName: "clock.badge.fill")
                                .foregroundColor(.orange)
                            Text("\(xmtpContainer.meshTransactionRelay.pendingRelays.count) pending transaction(s)")
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    private func balanceRow(for network: EthereumBalanceService.Network) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(network.rawValue)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                if let balance = balanceService.balances[network] {
                    Text(formatLastUpdated(balance.lastUpdated))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            if let balance = balanceService.balances[network] {
                Text("\(balance.formattedETH) ETH")
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
            } else {
                Text("—")
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.systemGray).opacity(0.1))
        .cornerRadius(8)
    }
    
    private func errorSection(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)
            
            Text(error)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button("Retry") {
                Task { await loadWallet() }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
    
    private var copiedToast: some View {
        Text(copiedText)
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.8))
            .cornerRadius(20)
            .padding(.bottom, 32)
    }
    
    private func xmtpInboxSection(inboxId: String) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .foregroundColor(.blue)
                Text("XMTP Inbox ID")
                    .font(.headline)
            }
            
            HStack {
                Text(truncateInboxId(inboxId))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.primary)
                
                Spacer()
                
                Button {
                    copyInboxId(inboxId)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .help("Copy XMTP inbox ID")
            }
            .padding()
            .background(Color.blue.opacity(0.1))
            .cornerRadius(8)
            
            Text("Share this ID for secure wallet messaging")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private func truncateInboxId(_ id: String) -> String {
        guard id.count > 24 else { return id }
        return String(id.prefix(12)) + "…" + String(id.suffix(8))
    }
    
    private func copyInboxId(_ id: String) {
        #if os(iOS)
        UIPasteboard.general.string = id
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
        #endif
        
        copiedText = "Inbox ID copied!"
        showCopiedToast = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCopiedToast = false
        }
    }
    
    private var truncatedAddress: String {
        guard address.count > 16 else { return address }
        return String(address.prefix(8)) + "…" + String(address.suffix(6))
    }
    
    // MARK: - Actions
    
    private func loadWallet() async {
        isLoading = true
        loadError = nil
        
        do {
            let addr = try await wallet.getAddress()
            address = addr
            await balanceService.fetchBalances(for: addr)
        } catch {
            loadError = error.localizedDescription
        }
        
        isLoading = false
    }
    
    private func autoRefreshBalances() async {
        // Keep refreshing while view is active
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(refreshInterval))
            
            guard !Task.isCancelled, !address.isEmpty else { break }
            
            // Silently refresh balances in background
            await balanceService.fetchBalances(for: address)
        }
    }
    
    private func copyAddress() {
        #if os(iOS)
        UIPasteboard.general.string = address
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        #endif
        
        copiedText = "Address copied!"
        showCopiedToast = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCopiedToast = false
        }
    }
    
    private func formatLastUpdated(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    
    // MARK: - QR Code Generation
    
    #if os(iOS)
    private func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        
        guard let outputImage = filter.outputImage else { return nil }
        
        // Scale up for crisp rendering
        let scale = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = outputImage.transformed(by: scale)
        
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }
        
        return UIImage(cgImage: cgImage)
    }
    #else
    private func generateQRCode(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        
        guard let outputImage = filter.outputImage else { return nil }
        
        // Scale up for crisp rendering
        let scale = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = outputImage.transformed(by: scale)
        
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }
        
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
    #endif
}

// MARK: - Preview

#if DEBUG
struct WalletView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            WalletView(wallet: EmbeddedWallet(keychain: PreviewKeychainManager()))
                .environmentObject(XMTPServiceContainer.configure(keychain: PreviewKeychainManager()))
        }
    }
}
#endif
