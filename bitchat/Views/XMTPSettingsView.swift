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
    @ObservedObject var transactionQueue: OfflineTransactionQueue
    @ObservedObject var clientService: XMTPClientService
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
                Picker("Offline Transactions", selection: $transactionQueue.relayStrategy) {
                    ForEach(TransactionRelayStrategy.allCases, id: \.self) { strategy in
                        Text(strategy.displayName).tag(strategy)
                    }
                }
                .pickerStyle(.menu)
                
                Text(transactionQueue.relayStrategy.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Transaction Relay")
            } footer: {
                Text("Controls how pending transactions are handled when you don't have direct internet access.")
            }
            
            // MARK: - Pending Transactions
            if !transactionQueue.pendingTransactions.isEmpty {
                Section {
                    ForEach(transactionQueue.pendingTransactions) { tx in
                        PendingTransactionRow(transaction: tx)
                    }
                } header: {
                    HStack {
                        Text("Pending Transactions")
                        Spacer()
                        Text("\(transactionQueue.pendingTransactions.count)")
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // MARK: - Wallet Info
            Section {
                NavigationLink {
                    WalletView(wallet: wallet)
                } label: {
                    Label("View Wallet", systemImage: "wallet.pass")
                }
                
                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Label("Clear Pending Transactions", systemImage: "trash")
                }
                .disabled(transactionQueue.pendingTransactions.isEmpty)
            } header: {
                Text("Wallet")
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
                transactionQueue.clearAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all queued transactions. They will not be submitted to the network.")
        }
    }
}

// MARK: - Pending Transaction Row

struct PendingTransactionRow: View {
    let transaction: PendingTransaction
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(transaction.request.calls.first?.metadata?.description ?? "Transaction")
                    .font(.subheadline)
                Spacer()
                StatusBadge(status: transaction.status)
            }
            
            HStack {
                Text("To: \(transaction.recipientInboxId.prefix(12))…")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text(transaction.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            if let relayedVia = transaction.relayedVia {
                Text("Relayed via: \(relayedVia.prefix(8))…")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let status: PendingTransactionStatus
    
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

extension PendingTransactionStatus {
    var displayText: String {
        switch self {
        case .pending: return "Pending"
        case .relaying: return "Relaying"
        case .relayed: return "Relayed"
        case .submitted: return "Submitted"
        case .confirmed: return "Confirmed"
        case .failed: return "Failed"
        }
    }
    
    var color: Color {
        switch self {
        case .pending: return .orange
        case .relaying: return .blue
        case .relayed: return .purple
        case .submitted: return .cyan
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
