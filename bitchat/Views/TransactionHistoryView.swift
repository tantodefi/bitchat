//
// TransactionHistoryView.swift
// bitchat
//
// Full transaction history: sends, receives, contract interactions, token transfers.
// All data fetched via Helios light client over Tor for privacy + trustless verification.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct TransactionHistoryView: View {
    @ObservedObject var meshRelay: MeshTransactionRelay
    let balanceService: EthereumBalanceService
    /// The address to filter transactions for (EOA or PQ account address).
    let filterAddress: String
    /// Optional PQ smart account address for scanning ERC-4337 UserOp events.
    var pqAddress: String? = nil

    @Environment(\.dismiss) private var dismiss
    @StateObject private var historyService = TransactionHistoryService()
    @State private var selectedTransaction: OnChainTransaction?
    @State private var filterType: TxFilterType = .all

    enum TxFilterType: String, CaseIterable {
        case all = "All"
        case sends = "Sends"
        case receives = "Receives"
        case contracts = "Contracts"
        case tokens = "Tokens"
    }

    private var filteredTransactions: [OnChainTransaction] {
        switch filterType {
        case .all:
            return historyService.transactions
        case .sends:
            return historyService.transactions.filter { $0.txType == .send }
        case .receives:
            return historyService.transactions.filter { $0.txType == .receive }
        case .contracts:
            return historyService.transactions.filter {
                $0.txType == .contractCall || $0.txType == .contractDeploy
            }
        case .tokens:
            return historyService.transactions.filter {
                $0.txType == .tokenTransfer || $0.txType == .tokenReceive || $0.txType == .approval
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Verification banner
                verificationBanner

                // Filter picker
                filterPicker

                // Content
                if historyService.isLoading && historyService.transactions.isEmpty {
                    loadingState
                } else if filteredTransactions.isEmpty {
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
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await refreshHistory() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(historyService.isLoading)
                }
            }
            .task {
                await refreshHistory()
            }
            .sheet(item: $selectedTransaction) { tx in
                OnChainTransactionDetailView(transaction: tx)
            }
        }
    }

    // MARK: - Subviews

    private var verificationBanner: some View {
        Group {
            switch historyService.verificationLevel {
            case .heliosVerified:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundColor(.green)
                    Text("Verified via Helios light client")
                        .font(.caption)
                        .foregroundColor(.green)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.1))
            case .proofConsistent:
                HStack(spacing: 6) {
                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundColor(.blue)
                    Text("Proof-verified via Tor")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.1))
            case .unverified:
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.shield")
                        .foregroundColor(.orange)
                    Text("Unverified — Helios not synced")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
            }
        }
    }

    private var filterPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TxFilterType.allCases, id: \.self) { type in
                    let count = countForFilter(type)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            filterType = type
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(type.rawValue)
                            if count > 0 {
                                Text("\(count)")
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(filterType == type ? Color.white.opacity(0.3) : Color.secondary.opacity(0.2))
                                    .clipShape(Capsule())
                            }
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(filterType == type ? .white : .primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(filterType == type ? Color.accentColor : Color(.systemGray5))
                        .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Fetching transaction history…")
                .font(.subheadline)
                .foregroundColor(.secondary)
            if !historyService.discoveryProgress.isEmpty {
                Text(historyService.discoveryProgress)
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.7))
                    .transition(.opacity)
            } else {
                Text("Scanning blocks via Helios over Tor")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: iconForEmptyFilter)
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text(filterType == .all ? "No Transactions" : "No \(filterType.rawValue)")
                .font(.headline)

            Text(emptyDescription)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if let error = historyService.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transactionList: some View {
        List {
            if historyService.isLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Updating…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            ForEach(filteredTransactions) { tx in
                OnChainTransactionRowView(
                    transaction: tx,
                    userAddress: filterAddress.lowercased()
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedTransaction = tx
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Helpers

    private func refreshHistory() async {
        // Use the correct chain and testnet flag based on balance service settings.
        let useTestnet = balanceService.useTestnet
        let chainId: UInt64 = useTestnet ? 11155111 : 1  // Sepolia or Ethereum mainnet
        await historyService.fetchHistory(
            for: filterAddress,
            meshRelay: meshRelay,
            chainId: chainId,
            useTestnet: useTestnet,
            pqAddress: pqAddress
        )
    }

    private func countForFilter(_ type: TxFilterType) -> Int {
        switch type {
        case .all:
            return historyService.transactions.count
        case .sends:
            return historyService.transactions.filter { $0.txType == .send }.count
        case .receives:
            return historyService.transactions.filter { $0.txType == .receive }.count
        case .contracts:
            return historyService.transactions.filter {
                $0.txType == .contractCall || $0.txType == .contractDeploy
            }.count
        case .tokens:
            return historyService.transactions.filter {
                $0.txType == .tokenTransfer || $0.txType == .tokenReceive || $0.txType == .approval
            }.count
        }
    }

    private var iconForEmptyFilter: String {
        switch filterType {
        case .all: return "arrow.left.arrow.right.circle"
        case .sends: return "arrow.up.right.circle"
        case .receives: return "arrow.down.left.circle"
        case .contracts: return "gearshape.circle"
        case .tokens: return "circlebadge.2"
        }
    }

    private var emptyDescription: String {
        switch filterType {
        case .all:
            return "Your transaction history will appear here. Fetched trustlessly via Helios."
        case .sends:
            return "No outgoing ETH transfers found in the scan range."
        case .receives:
            return "No incoming ETH transfers found in the scan range."
        case .contracts:
            return "No contract interactions found in the scan range."
        case .tokens:
            return "No ERC-20 token transfers found in the scan range."
        }
    }
}

// MARK: - Transaction Row View (On-Chain)

struct OnChainTransactionRowView: View {
    let transaction: OnChainTransaction
    let userAddress: String

    private var networkName: String {
        "Ethereum" // All on-chain history is mainnet for now
    }

    private var isSend: Bool {
        transaction.txType == .send || transaction.txType == .tokenTransfer
    }

    private var amountText: String {
        // ERC-20 token amount
        if let tokenAmount = transaction.tokenAmount, let symbol = transaction.tokenSymbol {
            let decimals = tokenDecimals(for: transaction.contractAddress)
            let divisor = pow(10.0, Double(decimals))
            let amount = tokenAmount.toDouble() / divisor
            let prefix = isSend ? "-" : "+"
            if amount < 0.01 {
                return "\(prefix)\(String(format: "%.6f", amount)) \(symbol)"
            }
            return "\(prefix)\(String(format: "%.4f", amount)) \(symbol)"
        }

        // Native ETH
        let weiDouble = transaction.value.toDouble()
        if weiDouble == 0 && (transaction.txType == .contractCall || transaction.txType == .approval) {
            return "—"
        }
        let eth = weiDouble / 1_000_000_000_000_000_000
        let prefix = isSend ? "-" : "+"
        if eth < 0.0001 && eth > 0 {
            return "\(prefix)\(String(format: "%.8f", eth)) ETH"
        } else if eth < 1 {
            return "\(prefix)\(String(format: "%.6f", eth)) ETH"
        } else {
            return "\(prefix)\(String(format: "%.4f", eth)) ETH"
        }
    }

    private var statusColor: Color {
        switch transaction.status {
        case .queued: return .orange
        case .pending: return .blue
        case .confirmed: return .green
        case .failed, .reverted: return .red
        }
    }

    private var typeColor: Color {
        switch transaction.txType {
        case .send, .tokenTransfer: return .red
        case .receive, .tokenReceive: return .green
        case .contractCall, .contractDeploy: return .purple
        case .approval: return .blue
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Transaction type icon
            ZStack {
                Circle()
                    .fill(typeColor.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: transaction.txType.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(typeColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                // Transaction type + counterparty
                HStack(spacing: 4) {
                    Text(transaction.txType.rawValue)
                        .font(.subheadline.weight(.medium))

                    if transaction.verificationLevel == .heliosVerified {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }

                // Counterparty address
                HStack(spacing: 4) {
                    Text(isSend ? "To:" : "From:")
                        .foregroundColor(.secondary)
                    Text(truncatedAddress(isSend ? transaction.to : transaction.from))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .font(.caption)

                // Status + timestamp
                HStack(spacing: 4) {
                    Image(systemName: transaction.status.icon)
                        .font(.caption2)
                        .foregroundColor(statusColor)
                    Text(transaction.status.rawValue)
                        .font(.caption2)
                        .foregroundColor(statusColor)

                    Text("•")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text(formatTimestamp(transaction.timestamp))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // Failure reason
                if let reason = transaction.failureReason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundColor(.red.opacity(0.8))
                        .lineLimit(1)
                }
            }

            Spacer()

            // Amount
            VStack(alignment: .trailing, spacing: 2) {
                Text(amountText)
                    .font(.system(.subheadline, design: .monospaced, weight: .medium))
                    .foregroundColor(isSend ? .primary : .green)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if let blockNum = transaction.blockNumber {
                    Text("#\(blockNum)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func truncatedAddress(_ address: String) -> String {
        guard address.count > 12 else { return address.isEmpty ? "—" : address }
        return String(address.prefix(6)) + "…" + String(address.suffix(4))
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func tokenDecimals(for contractAddress: String?) -> UInt8 {
        guard let addr = contractAddress?.lowercased() else { return 18 }
        let known: [String: UInt8] = [
            "0xdac17f958d2ee523a2206206994597c13d831ec7": 6,   // USDT
            "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48": 6,   // USDC
            "0x6b175474e89094c44da98b954eedeac495271d0f": 18,  // DAI
            "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2": 18,  // WETH
            "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599": 8,   // WBTC
        ]
        return known[addr] ?? 18
    }
}

// MARK: - Transaction Detail View (On-Chain)

struct OnChainTransactionDetailView: View {
    let transaction: OnChainTransaction

    @Environment(\.dismiss) private var dismiss

    private var networkName: String {
        "Ethereum Mainnet"
    }

    private var explorerURL: URL? {
        guard let hash = transaction.txHash else { return nil }
        return URL(string: "https://etherscan.io/tx/\(hash)")
    }

    private var formattedETH: String {
        let eth = transaction.value.toDouble() / 1_000_000_000_000_000_000
        return String(format: "%.8f", eth)
    }

    private var typeColor: Color {
        switch transaction.txType {
        case .send, .tokenTransfer: return .red
        case .receive, .tokenReceive: return .green
        case .contractCall, .contractDeploy: return .purple
        case .approval: return .blue
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Type + Status header
                Section {
                    HStack {
                        ZStack {
                            Circle()
                                .fill(typeColor.opacity(0.15))
                                .frame(width: 44, height: 44)
                            Image(systemName: transaction.txType.icon)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(typeColor)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(transaction.txType.rawValue)
                                .font(.headline)
                            HStack(spacing: 4) {
                                Image(systemName: transaction.status.icon)
                                    .foregroundColor(statusColor)
                                Text(transaction.status.rawValue)
                                    .foregroundColor(statusColor)
                            }
                            .font(.subheadline)
                        }

                        Spacer()

                        // Verification badge
                        verificationBadge
                    }
                }

                Section("Details") {
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

                    // Block number
                    if let block = transaction.blockNumber {
                        HStack {
                            Label("Block", systemImage: "number.square")
                            Spacer()
                            Text("#\(block)")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }

                    // ETH value
                    HStack {
                        Label("ETH Value", systemImage: "dollarsign.circle")
                        Spacer()
                        Text("\(formattedETH) ETH")
                            .font(.system(.body, design: .monospaced))
                    }

                    // Token amount (if ERC-20)
                    if let tokenAmount = transaction.tokenAmount,
                       let symbol = transaction.tokenSymbol {
                        HStack {
                            Label("Token Amount", systemImage: "circlebadge.2")
                            Spacer()
                            Text("\(tokenAmount.description) \(symbol)")
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }

                Section("Addresses") {
                    // From
                    VStack(alignment: .leading, spacing: 4) {
                        Label("From", systemImage: "arrow.up.circle")
                        Text(transaction.from)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }

                    // To
                    VStack(alignment: .leading, spacing: 4) {
                        Label("To", systemImage: "arrow.down.circle")
                        Text(transaction.to.isEmpty ? "Contract Creation" : transaction.to)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }

                    // Contract address (for interactions)
                    if let contract = transaction.contractAddress {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Contract", systemImage: "gearshape")
                            Text(contract)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                // Calldata (for contract interactions)
                if let input = transaction.input, input.count > 4 {
                    Section("Calldata") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Function: \(String(input.prefix(10)))")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.primary)
                            if input.count > 10 {
                                Text(input)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(4)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                // TX Hash
                if let hash = transaction.txHash {
                    Section("Transaction Hash") {
                        Text(hash)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }

                // Gas info
                if transaction.gasUsed != nil || transaction.gasPrice != nil {
                    Section("Gas") {
                        if let gasUsed = transaction.gasUsed {
                            HStack {
                                Label("Gas Used", systemImage: "flame")
                                Spacer()
                                Text("\(gasUsed)")
                                    .foregroundColor(.secondary)
                            }
                        }
                        if let gasPrice = transaction.gasPrice {
                            HStack {
                                Label("Gas Price", systemImage: "gauge")
                                Spacer()
                                let gwei = Double(gasPrice) / 1_000_000_000
                                Text(String(format: "%.2f Gwei", gwei))
                                    .foregroundColor(.secondary)
                            }
                        }
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
                                Label("View on Etherscan", systemImage: "safari")
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

    @ViewBuilder
    private var verificationBadge: some View {
        switch transaction.verificationLevel {
        case .heliosVerified:
            VStack(spacing: 2) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundColor(.green)
                    .font(.title3)
                Text("Verified")
                    .font(.caption2)
                    .foregroundColor(.green)
            }
        case .proofConsistent:
            VStack(spacing: 2) {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundColor(.blue)
                    .font(.title3)
                Text("Proof")
                    .font(.caption2)
                    .foregroundColor(.blue)
            }
        case .unverified:
            VStack(spacing: 2) {
                Image(systemName: "exclamationmark.shield")
                    .foregroundColor(.orange)
                    .font(.title3)
                Text("Unverified")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
    }

    private var statusColor: Color {
        switch transaction.status {
        case .queued: return .orange
        case .pending: return .blue
        case .confirmed: return .green
        case .failed, .reverted: return .red
        }
    }
}

#Preview {
    TransactionHistoryView(
        meshRelay: MeshTransactionRelay(keychain: PreviewKeychainManager()),
        balanceService: EthereumBalanceService(),
        filterAddress: "0x0000000000000000000000000000000000000000"
    )
}
