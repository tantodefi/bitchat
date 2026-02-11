//
// StealthAddressListView.swift
// bitchat
//
// List view showing discovered stealth addresses with scanning controls.
// Displays address cards with labels, balances, and quick actions.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// List view for discovered stealth addresses
struct StealthAddressListView: View {
    @ObservedObject var store: StealthAddressStore
    let stealthManager: StealthAddressManager
    let balanceService: EthereumBalanceService
    
    @State private var showMetaAddressSheet: Bool = false
    @State private var metaAddress: String = ""
    @State private var selectedAddress: DiscoveredStealthAddress?
    @State private var isLoadingMetaAddress: Bool = false
    @State private var isGeneratingSelfAddress: Bool = false
    @State private var showGeneratedAddressConfirmation: Bool = false
    @State private var lastGeneratedAddress: String = ""
    
    private var activeChainId: UInt64 {
        balanceService.useTestnet ? 11155111 : 1 // Sepolia or Mainnet
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // MARK: - Header & Meta-Address
                headerSection
                
                // MARK: - Scanning Status
                if store.isScanning {
                    scanningStatusSection
                }
                
                // MARK: - Stats Overview
                if store.totalCount > 0 {
                    statsSection
                }
                
                // MARK: - Self-Generated Addresses
                selfGeneratedSection
                
                // MARK: - Discovered Address List
                addressListSection
            }
            .padding()
        }
        .navigationTitle("Stealth Addresses")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showMetaAddressSheet) {
            StealthMetaAddressSheet(metaAddress: metaAddress)
        }
        .sheet(item: $selectedAddress) { address in
            NavigationStack {
                StealthAddressDetailView(
                    address: address,
                    store: store,
                    stealthManager: stealthManager,
                    balanceService: balanceService
                )
            }
        }
        .alert("Address Generated", isPresented: $showGeneratedAddressConfirmation) {
            Button("Copy", role: .none) {
                copyToClipboard(lastGeneratedAddress)
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("New stealth address:\n\(lastGeneratedAddress.prefix(20))...\(lastGeneratedAddress.suffix(8))")
        }
        .task {
            await loadMetaAddress()
        }
    }
    
    // MARK: - Sections
    
    private var headerSection: some View {
        VStack(spacing: 16) {
            // Stealth receive button
            Button {
                showMetaAddressSheet = true
            } label: {
                HStack {
                    Image(systemName: "eye.slash.fill")
                        .font(.title2)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stealth Receive")
                            .font(.headline)
                        Text("Generate private receiving address")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    if isLoadingMetaAddress {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "qrcode")
                            .font(.title2)
                    }
                }
                .padding()
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .disabled(metaAddress.isEmpty || isLoadingMetaAddress)
            
            // Info text
            Text("Share your stealth meta-address to receive payments privately. Each sender generates a unique address that only you can detect and spend from.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }
    
    private var scanningStatusSection: some View {
        VStack(spacing: 8) {
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                
                Text("Scanning for stealth payments...")
                    .font(.subheadline)
                
                Spacer()
                
                Text("\(Int(store.scanProgress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            ProgressView(value: store.scanProgress)
                .progressViewStyle(.linear)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
    }
    
    private var statsSection: some View {
        HStack(spacing: 16) {
            statCard(
                title: "Discovered",
                value: "\(store.totalCount)",
                icon: "eye.fill",
                color: .blue
            )
            
            statCard(
                title: "With Balance",
                value: "\(store.withBalanceCount)",
                icon: "dollarsign.circle.fill",
                color: .green
            )
            
            statCard(
                title: "Swept",
                value: "\(store.sweptCount)",
                icon: "checkmark.circle.fill",
                color: .gray
            )
        }
    }
    
    private func statCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
            
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemGray).opacity(0.1))
        .cornerRadius(12)
    }
    
    // MARK: - Self-Generated Addresses Section
    
    private var selfGeneratedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your Stealth Addresses")
                    .font(.headline)
                
                Spacer()
                
                // Generate new button
                Button {
                    Task { await generateNewAddress() }
                } label: {
                    HStack(spacing: 4) {
                        if isGeneratingSelfAddress {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "plus.circle.fill")
                        }
                        Text("Generate")
                            .font(.caption)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(isGeneratingSelfAddress || metaAddress.isEmpty)
            }
            
            Text("Generate one-time addresses to share for receiving payments. Each address is derived from your stealth meta-address and can only be spent by you.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            let selfAddresses = store.selfGeneratedAddresses(for: activeChainId)
            
            if selfAddresses.isEmpty {
                selfGeneratedEmptyView
            } else {
                ForEach(selfAddresses) { address in
                    AddressCard(address: address, showDerivationIndex: true) {
                        selectedAddress = address
                    }
                }
            }
        }
    }
    
    private var selfGeneratedEmptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus.circle")
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text("No addresses generated yet")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Text("Tap \"Generate\" to create a new one-time address you can share.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color(.systemGray).opacity(0.05))
        .cornerRadius(12)
    }
    
    private var addressListSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Discovered Addresses")
                    .font(.headline)
                
                Spacer()
                
                Text("\(store.discoveredAddresses(for: activeChainId).count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.systemGray).opacity(0.2))
                    .cornerRadius(8)
            }
            
            let addresses = store.discoveredAddresses(for: activeChainId)
            
            if addresses.isEmpty {
                emptyStateView
            } else {
                ForEach(addresses) { address in
                    AddressCard(address: address) {
                        selectedAddress = address
                    }
                }
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "eye.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text("No discovered addresses yet")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text("When someone sends to your stealth meta-address, it will appear here after scanning.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(Color(.systemGray).opacity(0.05))
        .cornerRadius(12)
    }
    
    // MARK: - Actions
    
    private func loadMetaAddress() async {
        isLoadingMetaAddress = true
        defer { isLoadingMetaAddress = false }
        
        do {
            metaAddress = try await stealthManager.getStealthMetaAddress()
        } catch {
            print("Failed to load stealth meta-address: \(error)")
        }
    }
    
    private func generateNewAddress() async {
        isGeneratingSelfAddress = true
        defer { isGeneratingSelfAddress = false }
        
        do {
            let nextIndex = store.nextDerivationIndex(for: activeChainId)
            let result = try await stealthManager.generateSelfStealthAddress(derivationIndex: nextIndex)
            
            let newAddress = DiscoveredStealthAddress(
                address: result.stealthAddress,
                ephemeralPubKey: result.ephemeralPubKey,
                viewTag: result.viewTag,
                blockNumber: 0,  // Self-generated, no block
                transactionHash: "",  // Self-generated, no tx
                chainId: activeChainId,
                label: "Address #\(result.derivationIndex + 1)",
                isSelfGenerated: true,
                derivationIndex: result.derivationIndex
            )
            
            await MainActor.run {
                store.addAddress(newAddress)
                lastGeneratedAddress = result.stealthAddress
                showGeneratedAddressConfirmation = true
            }
        } catch {
            print("Failed to generate self-stealth address: \(error)")
        }
    }
    
    private func copyToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - Address Card

private struct AddressCard: View {
    let address: DiscoveredStealthAddress
    var showDerivationIndex: Bool = false
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Status indicator
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                
                VStack(alignment: .leading, spacing: 4) {
                    // Label or truncated address
                    if !address.label.isEmpty {
                        Text(address.label)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(1)
                    }
                    
                    Text(truncatedAddress)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(address.label.isEmpty ? .primary : .secondary)
                    
                    // Discovered date or derivation index
                    HStack(spacing: 4) {
                        if address.isSelfGenerated, let index = address.derivationIndex {
                            Image(systemName: "key.fill")
                                .font(.caption2)
                                .foregroundColor(.accentColor)
                            Text("Index #\(index)")
                                .font(.caption2)
                                .foregroundColor(.accentColor)
                        } else {
                            Text(address.discoveredAt, style: .relative)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                // Balance
                VStack(alignment: .trailing, spacing: 2) {
                    if let balance = address.cachedBalance, balance != "0" {
                        Text(formatBalance(balance))
                            .font(.system(.subheadline, design: .monospaced))
                            .fontWeight(.semibold)
                        Text("ETH")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else if address.isSwept {
                        Text("Swept")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if address.isSelfGenerated {
                        Text("Unused")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("—")
                            .foregroundColor(.secondary)
                    }
                }
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(address.isSelfGenerated ? Color.accentColor.opacity(0.05) : Color(.systemGray).opacity(0.1))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
    
    private var truncatedAddress: String {
        let addr = address.address
        return "\(addr.prefix(10))...\(addr.suffix(8))"
    }
    
    private var statusColor: Color {
        if address.isSwept {
            return .gray
        } else if let balance = address.cachedBalance, balance != "0" {
            return .green
        } else if address.isSelfGenerated {
            return .accentColor
        } else {
            return .orange
        }
    }
    
    private func formatBalance(_ weiString: String) -> String {
        guard let wei = Decimal(string: weiString) else { return "0" }
        let eth = wei / Decimal(pow(10.0, 18.0))
        
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
        formatter.numberStyle = .decimal
        
        return formatter.string(from: eth as NSNumber) ?? "0"
    }
}

// MARK: - Meta-Address Sheet

private struct StealthMetaAddressSheet: View {
    let metaAddress: String
    @Environment(\.dismiss) private var dismiss
    @State private var showCopiedToast: Bool = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // QR Code
                    if let qrImage = generateQRCode(from: metaAddress) {
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
                    
                    // Explanation
                    VStack(spacing: 8) {
                        Text("Stealth Meta-Address")
                            .font(.headline)
                        
                        Text("Share this address to receive private payments. Each sender creates a unique address that only you can identify.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    
                    // Address display
                    VStack(spacing: 8) {
                        Text(metaAddress)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.center)
                            .padding()
                            .background(Color(.systemGray).opacity(0.1))
                            .cornerRadius(8)
                        
                        Button {
                            copyToClipboard()
                        } label: {
                            HStack {
                                Image(systemName: "doc.on.doc")
                                Text("Copy Address")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    // Warning
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                        
                        Text("The sender must use EIP-5564 compatible software to generate a stealth address from this meta-address.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(12)
                }
                .padding()
            }
            .navigationTitle("Receive Privately")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if showCopiedToast {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Copied to clipboard")
                    }
                    .font(.subheadline)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(25)
                    .shadow(radius: 4)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut, value: showCopiedToast)
        }
    }
    
    private func copyToClipboard() {
        #if os(iOS)
        UIPasteboard.general.string = metaAddress
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(metaAddress, forType: .string)
        #endif
        
        showCopiedToast = true
        
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            showCopiedToast = false
        }
    }
    
    private func generateQRCode(from string: String) -> PlatformImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        
        guard let outputImage = filter.outputImage else { return nil }
        
        // Scale up for better quality
        let scale = 10.0
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        
        #if os(iOS)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }
}

// MARK: - Platform Compatibility

#if os(iOS)
import UIKit
private typealias PlatformImage = UIImage
#else
import AppKit
private typealias PlatformImage = NSImage
#endif

// MARK: - QR Code Generation

private func generateQRCode(from string: String) -> PlatformImage? {
    let context = CIContext()
    let filter = CIFilter.qrCodeGenerator()
    
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"
    
    guard let outputImage = filter.outputImage else { return nil }
    
    let scale = 10.0
    let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    
    guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
    
    #if os(iOS)
    return UIImage(cgImage: cgImage)
    #else
    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    #endif
}

// MARK: - Preview

#if DEBUG
struct StealthAddressListView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            Text("Preview requires wallet instance")
        }
    }
}
#endif
