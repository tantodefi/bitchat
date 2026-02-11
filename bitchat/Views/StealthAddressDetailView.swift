//
// StealthAddressDetailView.swift
// bitchat
//
// Detail view for a single discovered stealth address.
// Shows balance, label editing, sweep/send functionality.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// Detail view for a discovered stealth address
struct StealthAddressDetailView: View {
    let address: DiscoveredStealthAddress
    @ObservedObject var store: StealthAddressStore
    let stealthManager: StealthAddressManager
    let balanceService: EthereumBalanceService
    
    @Environment(\.dismiss) private var dismiss
    @State private var label: String = ""
    @State private var isRefreshing: Bool = false
    @State private var showSweepSheet: Bool = false
    @State private var showCopiedToast: Bool = false
    @State private var copiedText: String = ""
    @State private var balance: String?
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // MARK: - Status Header
                statusHeader
                
                // MARK: - Address Info
                addressSection
                
                // MARK: - Balance
                balanceSection
                
                // MARK: - Label
                labelSection
                
                // MARK: - Details
                detailsSection
                
                // MARK: - Actions
                if !address.isSwept {
                    actionsSection
                }
                
                // MARK: - Danger Zone
                dangerZone
            }
            .padding()
        }
        .navigationTitle("Stealth Address")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        .overlay(alignment: .bottom) {
            if showCopiedToast {
                copiedToastView
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: showCopiedToast)
        .onAppear {
            label = address.label
            balance = address.cachedBalance
        }
        .sheet(isPresented: $showSweepSheet) {
            SweepStealthAddressSheet(
                address: address,
                stealthManager: stealthManager,
                balanceService: balanceService,
                onComplete: {
                    store.markAsSwept(addressId: address.id)
                    dismiss()
                }
            )
        }
    }
    
    // MARK: - Sections
    
    private var statusHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.title)
                .foregroundColor(statusColor)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.headline)
                
                Text(statusDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .background(statusColor.opacity(0.1))
        .cornerRadius(12)
    }
    
    private var addressSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Address")
                .font(.headline)
            
            HStack {
                Text(address.address)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                
                Spacer()
                
                Button {
                    copyToClipboard(address.address, label: "Address")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.body)
                }
                .buttonStyle(.borderless)
            }
            .padding()
            .background(Color(.systemGray).opacity(0.1))
            .cornerRadius(8)
        }
    }
    
    private var balanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Balance")
                    .font(.headline)
                
                Spacer()
                
                if isRefreshing {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Button {
                        Task {
                            await refreshBalance()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.body)
                    }
                    .buttonStyle(.borderless)
                }
            }
            
            HStack {
                Text(formattedBalance)
                    .font(.system(.title, design: .monospaced))
                    .fontWeight(.bold)
                
                Text("ETH")
                    .font(.title3)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if let checkedAt = address.balanceCheckedAt {
                    Text("Updated \(checkedAt, style: .relative)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(.systemGray).opacity(0.1))
            .cornerRadius(8)
        }
    }
    
    private var labelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Label")
                .font(.headline)
            
            HStack {
                TextField("Add a label...", text: $label)
                    .textFieldStyle(.plain)
                
                if label != address.label {
                    Button("Save") {
                        store.updateLabel(for: address.id, label: label)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .background(Color(.systemGray).opacity(0.1))
            .cornerRadius(8)
        }
    }
    
    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details")
                .font(.headline)
            
            VStack(spacing: 0) {
                detailRow(label: "Discovered", value: address.discoveredAt.formatted())
                
                Divider()
                
                detailRow(label: "Block", value: "#\(address.blockNumber)")
                
                Divider()
                
                HStack {
                    Text("Transaction")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Button {
                        copyToClipboard(address.transactionHash, label: "Transaction hash")
                    } label: {
                        Text("\(address.transactionHash.prefix(10))...")
                            .font(.system(.caption, design: .monospaced))
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 10)
                .padding(.horizontal)
                
                Divider()
                
                detailRow(label: "View Tag", value: String(format: "0x%02X", address.viewTag))
                
                Divider()
                
                detailRow(label: "Chain ID", value: chainName(for: address.chainId))
            }
            .background(Color(.systemGray).opacity(0.1))
            .cornerRadius(8)
        }
    }
    
    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
        }
        .padding(.vertical, 10)
        .padding(.horizontal)
    }
    
    private var actionsSection: some View {
        VStack(spacing: 12) {
            Text("Actions")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            HStack(spacing: 16) {
                Button {
                    showSweepSheet = true
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                        Text("Sweep")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .disabled(balance == nil || balance == "0")
                
                Button {
                    copyToClipboard(address.address, label: "Address")
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.on.doc.fill")
                            .font(.title)
                        Text("Copy")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                
                Button {
                    openExplorer()
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "safari.fill")
                            .font(.title)
                        Text("Explorer")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.purple.opacity(0.1))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    private var dangerZone: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Danger Zone")
                .font(.headline)
                .foregroundColor(.red)
            
            Button(role: .destructive) {
                store.removeAddress(addressId: address.id)
                dismiss()
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text("Remove from list")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.red.opacity(0.1))
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            
            Text("This only removes the address from your list. If there are funds, they will remain on-chain.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var copiedToastView: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
            Text(copiedText)
        }
        .font(.subheadline)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(25)
        .shadow(radius: 4)
        .padding(.bottom, 16)
    }
    
    // MARK: - Computed Properties
    
    private var statusIcon: String {
        if address.isSwept {
            return "checkmark.circle.fill"
        } else if let bal = balance, bal != "0" {
            return "dollarsign.circle.fill"
        } else {
            return "eye.fill"
        }
    }
    
    private var statusColor: Color {
        if address.isSwept {
            return .gray
        } else if let bal = balance, bal != "0" {
            return .green
        } else {
            return .orange
        }
    }
    
    private var statusText: String {
        if address.isSwept {
            return "Swept"
        } else if let bal = balance, bal != "0" {
            return "Funds Available"
        } else {
            return "Discovered"
        }
    }
    
    private var statusDescription: String {
        if address.isSwept {
            return "Funds have been moved to your main wallet"
        } else if let bal = balance, bal != "0" {
            return "This address has funds ready to sweep"
        } else {
            return "No balance detected yet"
        }
    }
    
    private var formattedBalance: String {
        guard let bal = balance ?? address.cachedBalance else { return "0" }
        guard let wei = Decimal(string: bal) else { return "0" }
        let eth = wei / Decimal(pow(10.0, 18.0))
        
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 8
        formatter.numberStyle = .decimal
        
        return formatter.string(from: eth as NSNumber) ?? "0"
    }
    
    // MARK: - Actions
    
    private func refreshBalance() async {
        isRefreshing = true
        defer { isRefreshing = false }
        
        // Get balance from balance service
        let network: EthereumBalanceService.Network = address.chainId == 1 ? .ethereum : .sepolia
        let newBalance = await balanceService.fetchBalance(for: address.address, network: network)
        
        if let newBalance = newBalance {
            let weiString = newBalance.wei.description
            balance = weiString
            store.updateBalance(for: address.id, balance: weiString)
        }
    }
    
    private func copyToClipboard(_ text: String, label: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        
        copiedText = "\(label) copied!"
        showCopiedToast = true
        
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            showCopiedToast = false
        }
    }
    
    private func openExplorer() {
        let baseURL: String
        switch address.chainId {
        case 1:
            baseURL = "https://etherscan.io/address/"
        case 11155111:
            baseURL = "https://sepolia.etherscan.io/address/"
        case 10:
            baseURL = "https://optimistic.etherscan.io/address/"
        case 8453:
            baseURL = "https://basescan.org/address/"
        case 42161:
            baseURL = "https://arbiscan.io/address/"
        default:
            baseURL = "https://etherscan.io/address/"
        }
        
        if let url = URL(string: baseURL + address.address) {
            #if os(iOS)
            UIApplication.shared.open(url)
            #else
            NSWorkspace.shared.open(url)
            #endif
        }
    }
    
    private func chainName(for chainId: UInt64) -> String {
        switch chainId {
        case 1: return "Ethereum"
        case 11155111: return "Sepolia"
        case 10: return "Optimism"
        case 8453: return "Base"
        case 42161: return "Arbitrum One"
        default: return "Chain \(chainId)"
        }
    }
}

// MARK: - Sweep Sheet

private struct SweepStealthAddressSheet: View {
    let address: DiscoveredStealthAddress
    let stealthManager: StealthAddressManager
    let balanceService: EthereumBalanceService
    let onComplete: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var destinationAddress: String = ""
    @State private var isSweeping: Bool = false
    @State private var error: String?
    @State private var txHash: String?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Info
                VStack(spacing: 8) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.largeTitle)
                        .foregroundColor(.accentColor)
                    
                    Text("Sweep Funds")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("Transfer all funds from this stealth address to another address.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                
                // Destination
                VStack(alignment: .leading, spacing: 8) {
                    Text("Destination Address")
                        .font(.headline)
                    
                    TextField("0x...", text: $destinationAddress)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .autocapitalization(.none)
                        .keyboardType(.asciiCapable)
                        #endif
                }
                
                if let error = error {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                }
                
                if let txHash = txHash {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.green)
                        
                        Text("Sweep Submitted!")
                            .font(.headline)
                        
                        Text(txHash)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(12)
                }
                
                Spacer()
                
                // Actions
                if txHash == nil {
                    Button {
                        Task {
                            await sweep()
                        }
                    } label: {
                        if isSweeping {
                            ProgressView()
                                .progressViewStyle(.circular)
                        } else {
                            Text("Sweep All Funds")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isValidDestination ? Color.accentColor : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                    .disabled(!isValidDestination || isSweeping)
                } else {
                    Button {
                        onComplete()
                        dismiss()
                    } label: {
                        Text("Done")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
            }
            .padding()
            .navigationTitle("Sweep")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private var isValidDestination: Bool {
        destinationAddress.hasPrefix("0x") && destinationAddress.count == 42
    }
    
    private func sweep() async {
        isSweeping = true
        error = nil
        defer { isSweeping = false }
        
        do {
            // Get the private key for this stealth address
            _ = try await stealthManager.computeStealthKey(ephemeralPubKey: address.ephemeralPubKey)
            
            // TODO: Create and sign a transaction using this private key
            // For now, we show a placeholder success
            // In a full implementation, this would:
            // 1. Get nonce for the stealth address
            // 2. Estimate gas
            // 3. Build and sign EIP-1559 transaction
            // 4. Broadcast via Flashbots Protect or mesh relay
            
            // Placeholder for demo
            txHash = "0x" + String(repeating: "0", count: 64)
            
            error = "Sweep functionality not yet implemented. Private key derived successfully."
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Preview

#if DEBUG
struct StealthAddressDetailView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            Text("Preview requires wallet instance")
        }
    }
}
#endif
