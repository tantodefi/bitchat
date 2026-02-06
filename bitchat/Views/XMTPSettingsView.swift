//
// XMTPSettingsView.swift
// bitchat
//
// Settings UI for XMTP configuration including transaction relay preferences.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// Settings view for XMTP and transaction relay configuration
struct XMTPSettingsView: View {
    @ObservedObject var meshTransactionRelay: MeshTransactionRelay
    @ObservedObject var clientService: XMTPClientService
    @ObservedObject var balanceService: EthereumBalanceService
    let wallet: EmbeddedWallet
    
    @State private var showingWalletInfo = false
    @State private var showingClearConfirmation = false
    
    var body: some View {
        List {
            // MARK: - Connection Status
            Section {
                HStack {
                    Label("XMTP Status", systemImage: clientService.isConnected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(clientService.isConnected ? .green : .secondary)
                    Spacer()
                    Text(clientService.isConnected ? "Connected" : "Disconnected")
                        .foregroundColor(.secondary)
                }
                
                if let inboxId = clientService.inboxId {
                    HStack {
                        Text("Inbox ID")
                        Spacer()
                        Text(String(inboxId.prefix(16)) + "…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if !clientService.isConnected && clientService.bootstrapProgress > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connecting…")
                            .font(.caption)
                        ProgressView(value: clientService.bootstrapProgress)
                    }
                }
            } header: {
                Text("XMTP Connection")
            }
            
            // MARK: - Transaction Relay Settings
            Section {
                Toggle(isOn: $meshTransactionRelay.allowMeshRelay) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mesh Relay")
                            Text(meshTransactionRelay.allowMeshRelay ? "Transactions can relay through nearby peers" : "Transactions only broadcast when online")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                }
            } header: {
                Text("Transaction Relay")
            } footer: {
                Text("When enabled, signed transactions can be relayed through nearby Bluetooth peers who have internet. Peers see transaction data but cannot modify it.")
            }
            
            // MARK: - Pending Transactions
            if !meshTransactionRelay.pendingRelays.isEmpty {
                Section {
                    ForEach(meshTransactionRelay.pendingRelays, id: \.id) { relay in
                        MeshRelayRow(relay: relay)
                    }
                } header: {
                    HStack {
                        Text("Pending Transactions")
                        Spacer()
                        Text("\(meshTransactionRelay.pendingRelays.count)")
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // MARK: - Wallet Info
            Section {
                // Network mode toggle
                Toggle(isOn: $balanceService.useTestnet) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Testnet Mode")
                            Text(balanceService.useTestnet ? "Using Sepolia testnet" : "Using Ethereum & Base mainnet")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: balanceService.useTestnet ? "testtube.2" : "network")
                    }
                }
                .tint(.orange)
                
                NavigationLink {
                    WalletView(wallet: wallet)
                } label: {
                    Label("View Wallet", systemImage: "creditcard.fill")
                }
                
                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Label("Clear Pending Transactions", systemImage: "trash")
                }
                .disabled(meshTransactionRelay.pendingRelays.isEmpty)
            } header: {
                Text("Wallet")
            } footer: {
                Text("Testnet mode uses Sepolia for testing without real funds.")
            }
            
            // MARK: - Privacy Info
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("End-to-End Encrypted", systemImage: "lock.shield.fill")
                        .font(.subheadline)
                    
                    Text("All XMTP messages use MLS encryption. Transaction requests relayed through the mesh are visible to relay peers but cannot be modified.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Privacy")
            }
        }
        .navigationTitle("XMTP Settings")
        .confirmationDialog(
            "Clear all pending transactions?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                meshTransactionRelay.clearAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all queued transactions. They will not be submitted to the network.")
        }
    }
}

// MARK: - Mesh Relay Row

struct MeshRelayRow: View {
    let relay: MeshTransactionRelay.PendingRelay
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(relay.payload.description ?? "Transaction")
                    .font(.subheadline)
                Spacer()
                MeshStatusBadge(status: relay.status)
            }
            
            HStack {
                let chainName = relay.payload.chainId == 1 ? "ETH" : (relay.payload.chainId == 11155111 ? "Sepolia" : "Chain \(relay.payload.chainId)")
                Text("To: \(relay.payload.toAddress.prefix(10))… • \(chainName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text(relay.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            if let relayedVia = relay.relayedVia {
                Text("Relayed via: \(relayedVia.prefix(8))…")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Mesh Status Badge

struct MeshStatusBadge: View {
    let status: MeshTransactionRelay.RelayStatus
    
    var body: some View {
        Text(status.displayText)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(status.color.opacity(0.2))
            .foregroundColor(status.color)
            .clipShape(Capsule())
    }
}

extension MeshTransactionRelay.RelayStatus {
    var displayText: String {
        switch self {
        case .queued: return "Queued"
        case .relaying: return "Relaying"
        case .awaitingConfirmation: return "Awaiting"
        case .confirmed: return "Confirmed"
        case .failed: return "Failed"
        }
    }
    
    var color: Color {
        switch self {
        case .queued: return .orange
        case .relaying: return .blue
        case .awaitingConfirmation: return .purple
        case .confirmed: return .green
        case .failed: return .red
        }
    }
}

// MARK: - Preview

#if DEBUG
struct XMTPSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            // Preview placeholder - actual implementation needs real objects
            Text("XMTP Settings Preview")
        }
    }
}
#endif
