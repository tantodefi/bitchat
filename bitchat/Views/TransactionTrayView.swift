//
// TransactionTrayView.swift
// bitchat
//
// UI for reviewing and approving transaction requests from XMTP agents.
// Shows transaction details in a slide-up tray format.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// A slide-up tray for reviewing and approving transaction requests
struct TransactionTrayView: View {
    let request: XMTPWalletSendCalls
    let onApprove: () -> Void
    let onReject: () -> Void
    let onAllowMeshRelay: (Bool) -> Void
    
    @State private var allowMeshRelay = true
    @Environment(\.dismiss) private var dismiss
    
    // Network names for display
    private var networkName: String {
        // Parse hex chain ID
        let chainIdHex = request.chainId.hasPrefix("0x") ? String(request.chainId.dropFirst(2)) : request.chainId
        guard let chainId = UInt64(chainIdHex, radix: 16) else { return "Unknown" }
        
        switch chainId {
        case 1: return "Ethereum"
        case 11155111: return "Sepolia (Testnet)"
        case 8453: return "Base"
        case 84532: return "Base Sepolia"
        case 42161: return "Arbitrum"
        case 421614: return "Arbitrum Sepolia (Testnet)"
        default: return "Chain \(chainId)"
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Handle bar
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
            
            // Header
            HStack {
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .font(.title2)
                    .foregroundColor(.blue)
                Text("Transaction Request")
                    .font(.headline)
                Spacer()
            }
            .padding()
            
            Divider()
            
            ScrollView {
                VStack(spacing: 16) {
                    // Calls list
                    ForEach(Array(request.calls.enumerated()), id: \.offset) { index, call in
                        callCard(call, index: index)
                    }
                    
                    // Network info
                    GroupBox {
                        HStack {
                            Label("Network", systemImage: "network")
                            Spacer()
                            Text(networkName)
                                .foregroundColor(.secondary)
                        }
                        
                        Divider()
                        
                        HStack {
                            Label("From", systemImage: "creditcard")
                            Spacer()
                            Text(truncateAddress(request.from))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal)
                    
                    // Mesh relay option
                    GroupBox {
                        Toggle(isOn: $allowMeshRelay) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Allow mesh relay if offline", systemImage: "antenna.radiowaves.left.and.right")
                                Text("Transaction can be relayed through nearby peers with internet")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .onChange(of: allowMeshRelay) { newValue in
                            onAllowMeshRelay(newValue)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            
            Divider()
            
            // Action buttons
            HStack(spacing: 16) {
                Button(action: {
                    onReject()
                    dismiss()
                }) {
                    Text("Reject")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.systemGray5))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                }
                
                Button(action: {
                    onApprove()
                    dismiss()
                }) {
                    Text("Approve")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
            }
            .padding()
        }
        .background(Color(.systemBackground))
        .cornerRadius(20, corners: [.topLeft, .topRight])
    }
    
    @ViewBuilder
    private func callCard(_ call: WalletSendCall, index: Int) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Description from metadata
                if let metadata = call.metadata, let description = metadata.description {
                    Text(description)
                        .font(.headline)
                }
                
                // To address
                HStack {
                    Text("To:")
                        .foregroundColor(.secondary)
                    Text(truncateAddress(call.to))
                        .font(.system(.caption, design: .monospaced))
                }
                
                // Value
                if let value = call.value, !value.isEmpty, value != "0x0" {
                    HStack {
                        Text("Value:")
                            .foregroundColor(.secondary)
                        Text(formatWeiValue(value))
                            .fontWeight(.medium)
                    }
                }
                
                // Amount from metadata
                if let metadata = call.metadata,
                   let amount = metadata.amount,
                   let currency = metadata.currency,
                   let decimals = metadata.decimals {
                    HStack {
                        Text("Amount:")
                            .foregroundColor(.secondary)
                        Text(formatAmount(amount, decimals: decimals, currency: currency))
                            .fontWeight(.medium)
                            .foregroundColor(.blue)
                    }
                }
                
                // Transaction type badge
                if let metadata = call.metadata, let txType = metadata.transactionType {
                    HStack {
                        TransactionTypeBadge(type: txType)
                        Spacer()
                    }
                }
            }
        }
        .padding(.horizontal)
    }
    
    private func truncateAddress(_ address: String) -> String {
        guard address.count > 12 else { return address }
        return "\(address.prefix(6))…\(address.suffix(4))"
    }
    
    private func formatWeiValue(_ hexValue: String) -> String {
        let hex = hexValue.hasPrefix("0x") ? String(hexValue.dropFirst(2)) : hexValue
        guard let wei = UInt64(hex, radix: 16) else { return hexValue }
        
        let eth = Double(wei) / 1e18
        if eth >= 0.001 {
            return String(format: "%.4f ETH", eth)
        } else {
            return "\(wei) wei"
        }
    }
    
    private func formatAmount(_ amount: UInt64, decimals: UInt8, currency: String) -> String {
        let value = Double(amount) / pow(10, Double(decimals))
        if decimals <= 2 {
            return String(format: "%.2f %@", value, currency)
        } else if value >= 1 {
            return String(format: "%.4f %@", value, currency)
        } else {
            return String(format: "%.6f %@", value, currency)
        }
    }
}

// MARK: - Transaction Type Badge

struct TransactionTypeBadge: View {
    let type: String
    
    var color: Color {
        switch type.lowercased() {
        case "transfer", "send": return .blue
        case "swap": return .purple
        case "lend", "deposit": return .green
        case "borrow": return .orange
        case "mint", "nft": return .pink
        case "approve": return .yellow
        default: return .gray
        }
    }
    
    var icon: String {
        switch type.lowercased() {
        case "transfer", "send": return "arrow.up.right"
        case "swap": return "arrow.triangle.2.circlepath"
        case "lend", "deposit": return "arrow.down.to.line"
        case "borrow": return "arrow.up.to.line"
        case "mint", "nft": return "sparkles"
        case "approve": return "checkmark.seal"
        default: return "questionmark.circle"
        }
    }
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(type.capitalized)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15))
        .foregroundColor(color)
        .cornerRadius(6)
    }
}

// MARK: - Transaction Status Card (for in-chat display)

struct TransactionStatusCard: View {
    let txHash: String
    let status: TxStatus
    let chainId: UInt64
    let toAddress: String
    let amount: UInt64?
    let currency: String?
    let decimals: UInt8?
    let timestamp: Date
    
    private var networkName: String {
        switch chainId {
        case 1: return "Ethereum"
        case 11155111: return "Sepolia"
        case 8453: return "Base"
        default: return "Chain \(chainId)"
        }
    }
    
    private var explorerURL: URL? {
        let baseURL: String
        switch chainId {
        case 1: baseURL = "https://etherscan.io/tx/"
        case 11155111: baseURL = "https://sepolia.etherscan.io/tx/"
        case 8453: baseURL = "https://basescan.org/tx/"
        default: return nil
        }
        return URL(string: baseURL + txHash)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status header
            HStack {
                statusIcon
                Text(statusText)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text(timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            // Amount
            if let amount = amount, let currency = currency {
                let value = Double(amount) / pow(10, Double(decimals ?? 18))
                Text(String(format: "%.4f %@", value, currency))
                    .font(.headline)
            }
            
            // To address
            HStack {
                Text("To:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(toAddress.prefix(8))…\(toAddress.suffix(6))")
                    .font(.system(.caption, design: .monospaced))
            }
            
            // Tx hash with link
            if let url = explorerURL {
                Link(destination: url) {
                    HStack {
                        Text("Tx: \(txHash.prefix(12))…")
                            .font(.system(.caption2, design: .monospaced))
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption2)
                    }
                    .foregroundColor(.blue)
                }
            } else {
                Text("Tx: \(txHash.prefix(12))…")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            
            // Network badge
            HStack {
                Image(systemName: "network")
                    .font(.caption2)
                Text(networkName)
                    .font(.caption2)
            }
            .foregroundColor(.secondary)
        }
        .padding()
        .background(statusBackgroundColor)
        .cornerRadius(12)
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .pending:
            Image(systemName: "clock.fill")
                .foregroundColor(.orange)
        case .confirmed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        }
    }
    
    private var statusText: String {
        switch status {
        case .pending: return "Transaction Pending"
        case .confirmed: return "Transaction Confirmed"
        case .failed: return "Transaction Failed"
        }
    }
    
    private var statusBackgroundColor: Color {
        switch status {
        case .pending: return Color.orange.opacity(0.1)
        case .confirmed: return Color.green.opacity(0.1)
        case .failed: return Color.red.opacity(0.1)
        }
    }
}

// MARK: - Corner Radius Extension

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

// MARK: - Preview

#Preview {
    TransactionTrayView(
        request: XMTPWalletSendCalls(
            chainId: 1,
            from: "0x1234567890abcdef1234567890abcdef12345678",
            calls: [
                WalletSendCall(
                    to: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
                    data: nil,
                    value: "0x5AF3107A4000",
                    gas: nil,
                    metadata: WalletSendCallMetadata(
                        description: "Send 0.0001 ETH to vitalik.eth",
                        transactionType: "transfer",
                        currency: "ETH",
                        amount: 100000000000000,
                        decimals: 18,
                        toAddress: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
                        platform: nil,
                        apy: nil
                    )
                )
            ]
        ),
        onApprove: { print("Approved") },
        onReject: { print("Rejected") },
        onAllowMeshRelay: { print("Mesh relay: \($0)") }
    )
}
