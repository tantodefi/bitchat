//
// TransactionHistoryView.swift
// bitchat
//
// Transaction history view showing pending, confirmed, and failed transactions.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct TransactionHistoryView: View {
    @ObservedObject var meshRelay: MeshTransactionRelay
    let balanceService: EthereumBalanceService
    
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTransaction: TransactionItem?
    
    private var allTransactions: [TransactionItem] {
        var items: [TransactionItem] = []
        
        // Add pending transactions (queued for mesh relay due to network issues)
        for relay in meshRelay.pendingRelays {
            items.append(TransactionItem(
                id: relay.id,
                status: mapStatus(relay.status),
                toAddress: relay.payload.toAddress,
                amount: relay.payload.amount,
                currency: relay.payload.currency ?? "ETH",
                chainId: relay.payload.chainId,
                txHash: nil,
                timestamp: relay.createdAt,
                description: relay.payload.description
            ))
        }
        
        // Add confirmed transactions
        for confirmed in meshRelay.confirmedTransactions {
            items.append(TransactionItem(
                id: confirmed.id,
                status: .confirmed,
                toAddress: confirmed.toAddress,
                amount: confirmed.amount,
                currency: confirmed.currency ?? "ETH",
                chainId: confirmed.chainId,
                txHash: confirmed.txHash,
                timestamp: confirmed.confirmedAt,
                description: nil
            ))
        }
        
        // Add failed transactions (rejected by network)
        for failed in meshRelay.failedTransactions {
            items.append(TransactionItem(
                id: failed.id,
                status: .failed,
                toAddress: failed.toAddress,
                amount: failed.amount,
                currency: failed.currency ?? "ETH",
                chainId: failed.chainId,
                txHash: nil,
                timestamp: failed.failedAt,
                description: nil,
                failureReason: failed.reason
            ))
        }
        
        // Sort by timestamp, newest first
        return items.sorted { $0.timestamp > $1.timestamp }
    }
    
    var body: some View {
        NavigationStack {
            Group {
                if allTransactions.isEmpty {
                    emptyState
                } else {
                    transactionList
                }
            }
            .navigationTitle("Transaction History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.left.arrow.right.circle")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("No Transactions")
                .font(.headline)
            
            Text("Your transaction history will appear here after you send ETH.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var transactionList: some View {
        List {
            ForEach(allTransactions) { tx in
                TransactionRowView(transaction: tx, balanceService: balanceService)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedTransaction = tx
                    }
            }
        }
        .listStyle(.insetGrouped)
        .sheet(item: $selectedTransaction) { tx in
            TransactionDetailView(transaction: tx, balanceService: balanceService)
        }
    }
    
    private func mapStatus(_ relayStatus: MeshTransactionRelay.RelayStatus) -> TransactionStatus {
        switch relayStatus {
        case .queued: return .queued
        case .relaying: return .pending
        case .awaitingConfirmation: return .pending
        case .confirmed: return .confirmed
        case .failed: return .failed
        }
    }
}

// MARK: - Transaction Item Model

struct TransactionItem: Identifiable {
    let id: String
    let status: TransactionStatus
    let toAddress: String
    let amount: UInt64?
    let currency: String
    let chainId: UInt64
    let txHash: String?
    let timestamp: Date
    let description: String?
    let failureReason: String?
    
    init(id: String, status: TransactionStatus, toAddress: String, amount: UInt64?, currency: String, chainId: UInt64, txHash: String?, timestamp: Date, description: String?, failureReason: String? = nil) {
        self.id = id
        self.status = status
        self.toAddress = toAddress
        self.amount = amount
        self.currency = currency
        self.chainId = chainId
        self.txHash = txHash
        self.timestamp = timestamp
        self.description = description
        self.failureReason = failureReason
    }
}

enum TransactionStatus: String {
    case queued = "Queued"
    case pending = "Pending"
    case confirmed = "Confirmed"
    case failed = "Failed"
    
    var icon: String {
        switch self {
        case .queued: return "clock.fill"
        case .pending: return "arrow.triangle.2.circlepath"
        case .confirmed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .queued: return .orange
        case .pending: return .blue
        case .confirmed: return .green
        case .failed: return .red
        }
    }
}

// MARK: - Transaction Row View

struct TransactionRowView: View {
    let transaction: TransactionItem
    let balanceService: EthereumBalanceService
    
    private var networkName: String {
        switch transaction.chainId {
        case 1: return "Ethereum"
        case 11155111: return "Sepolia"
        case 8453: return "Base"
        default: return "Chain \(transaction.chainId)"
        }
    }
    
    private var formattedAmount: String {
        guard let amount = transaction.amount else { return "—" }
        let eth = Double(amount) / 1_000_000_000_000_000_000
        if eth < 0.0001 {
            return String(format: "%.8f", eth)
        } else if eth < 1 {
            return String(format: "%.6f", eth)
        } else {
            return String(format: "%.4f", eth)
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            Image(systemName: transaction.status.icon)
                .font(.title2)
                .foregroundColor(transaction.status.color)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 4) {
                // To address
                HStack {
                    Text("To:")
                        .foregroundColor(.secondary)
                    Text(truncatedAddress(transaction.toAddress))
                        .font(.system(.body, design: .monospaced))
                }
                .font(.subheadline)
                
                // Status and network
                HStack {
                    Text(transaction.status.rawValue)
                        .font(.caption)
                        .foregroundColor(transaction.status.color)
                    
                    Text("•")
                        .foregroundColor(.secondary)
                    
                    Text(networkName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("•")
                        .foregroundColor(.secondary)
                    
                    Text(formatTimestamp(transaction.timestamp))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // Failure reason (if present)
                if let reason = transaction.failureReason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundColor(.red.opacity(0.8))
                        .lineLimit(2)
                }
            }
            
            Spacer()
            
            // Amount
            VStack(alignment: .trailing) {
                Text("-\(formattedAmount)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.primary)
                Text(transaction.currency)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func truncatedAddress(_ address: String) -> String {
        guard address.count > 12 else { return address }
        return String(address.prefix(6)) + "…" + String(address.suffix(4))
    }
    
    private func formatTimestamp(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Transaction Detail View

struct TransactionDetailView: View {
    let transaction: TransactionItem
    let balanceService: EthereumBalanceService
    
    @Environment(\.dismiss) private var dismiss
    
    private var networkName: String {
        switch transaction.chainId {
        case 1: return "Ethereum Mainnet"
        case 11155111: return "Sepolia Testnet"
        case 8453: return "Base"
        case 42161: return "Arbitrum"
        case 421614: return "Arbitrum Sepolia Testnet"
        default: return "Chain \(transaction.chainId)"
        }
    }
    
    private var explorerURL: URL? {
        guard let hash = transaction.txHash else { return nil }
        switch transaction.chainId {
        case 1:
            return URL(string: "https://etherscan.io/tx/\(hash)")
        case 11155111:
            return URL(string: "https://sepolia.etherscan.io/tx/\(hash)")
        case 8453:
            return URL(string: "https://basescan.org/tx/\(hash)")
        case 42161:
            return URL(string: "https://arbiscan.io/tx/\(hash)")
        case 421614:
            return URL(string: "https://sepolia.arbiscan.io/tx/\(hash)")
        default:
            return nil
        }
    }
    
    private var formattedAmount: String {
        guard let amount = transaction.amount else { return "—" }
        let eth = Double(amount) / 1_000_000_000_000_000_000
        return String(format: "%.8f", eth)
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Status
                    HStack {
                        Label("Status", systemImage: transaction.status.icon)
                        Spacer()
                        Text(transaction.status.rawValue)
                            .foregroundColor(transaction.status.color)
                    }
                    
                    // Network
                    HStack {
                        Label("Network", systemImage: "network")
                        Spacer()
                        Text(networkName)
                            .foregroundColor(.secondary)
                    }
                    
                    // Timestamp
                    HStack {
                        Label("Time", systemImage: "clock")
                        Spacer()
                        Text(transaction.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .foregroundColor(.secondary)
                    }
                }
                
                Section("Transaction") {
                    // Amount
                    HStack {
                        Label("Amount", systemImage: "dollarsign.circle")
                        Spacer()
                        Text("\(formattedAmount) \(transaction.currency)")
                            .font(.system(.body, design: .monospaced))
                    }
                    
                    // To Address
                    VStack(alignment: .leading, spacing: 4) {
                        Label("To Address", systemImage: "arrow.right.circle")
                        Text(transaction.toAddress)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                    
                    // TX Hash (if available)
                    if let hash = transaction.txHash {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Transaction Hash", systemImage: "number")
                            Text(hash)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    
                    // Request ID
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Request ID", systemImage: "tag")
                        Text(transaction.id)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
                
                if let description = transaction.description {
                    Section("Description") {
                        Text(description)
                            .foregroundColor(.secondary)
                    }
                }
                
                if let reason = transaction.failureReason {
                    Section("Failure Reason") {
                        Text(reason)
                            .foregroundColor(.red)
                    }
                }
                
                if let url = explorerURL {
                    Section {
                        Link(destination: url) {
                            HStack {
                                Label("View on Block Explorer", systemImage: "safari")
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Transaction Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    TransactionHistoryView(
        meshRelay: MeshTransactionRelay(keychain: PreviewKeychainManager()),
        balanceService: EthereumBalanceService()
    )
}
