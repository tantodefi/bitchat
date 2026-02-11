//
// SendTransactionView.swift
// bitchat
//
// UI for sending ETH or token transfers.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// Gas speed presets for transaction fee selection
enum GasSpeed: String, CaseIterable, Identifiable {
    case slow = "Slow"
    case average = "Average"
    case fast = "Fast"
    case custom = "Custom"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .slow: return "tortoise"
        case .average: return "hare"
        case .fast: return "bolt"
        case .custom: return "slider.horizontal.3"
        }
    }
    
    /// Priority fee (tip to validator) in gwei
    var priorityFeeGwei: Double {
        switch self {
        case .slow: return 0.5
        case .average: return 1.5
        case .fast: return 3.0
        case .custom: return 1.5 // Default for custom
        }
    }
    
    /// Max fee per gas in gwei
    var maxFeeGwei: Double {
        switch self {
        case .slow: return 15
        case .average: return 30
        case .fast: return 60
        case .custom: return 30 // Default for custom
        }
    }
    
    var description: String {
        switch self {
        case .slow: return "~5+ min"
        case .average: return "~1-3 min"
        case .fast: return "~15 sec"
        case .custom: return "Manual"
        }
    }
}

struct SendTransactionView: View {
    @Environment(\.dismiss) private var dismiss
    
    let wallet: EmbeddedWallet
    let balanceService: EthereumBalanceService
    @ObservedObject var meshRelay: MeshTransactionRelay
    var onSuccess: (() -> Void)? = nil
    
    @State private var recipientAddress = ""
    @State private var amount = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var submittedTxId: String?
    @State private var showingConfirmation = false
    @State private var isOnline = true
    
    // Gas settings
    @State private var selectedGasSpeed: GasSpeed = .average
    @State private var customPriorityFee: String = "1.5"
    @State private var customMaxFee: String = "30"
    @State private var showGasDetails = false
    
    /// Get the current status of the submitted transaction
    private var txStatus: MeshTransactionRelay.RelayStatus? {
        guard let txId = submittedTxId else { return nil }
        return meshRelay.pendingRelays.first { $0.id == txId }?.status
    }
    
    /// Check if transaction was confirmed (removed from pending, added to confirmed)
    private var isConfirmed: Bool {
        guard let txId = submittedTxId else { return false }
        return meshRelay.confirmedTransactions.contains { $0.id == txId }
    }
    
    private var amountInWei: UInt64? {
        guard let ethAmount = Double(amount) else { return nil }
        return UInt64(ethAmount * 1_000_000_000_000_000_000) // 1e18
    }
    
    private var isValidAddress: Bool {
        recipientAddress.hasPrefix("0x") && recipientAddress.count == 42
    }
    
    private var canSend: Bool {
        isValidAddress && amountInWei != nil && (amountInWei ?? 0) > 0 && submittedTxId == nil
    }
    
    /// Get current network's balance
    private var currentBalance: EthereumBalanceService.Balance? {
        let network = balanceService.useTestnet ? EthereumBalanceService.Network.sepolia : EthereumBalanceService.Network.ethereum
        return balanceService.balances[network]
    }
    
    /// Formatted available balance
    private var availableBalanceText: String {
        guard let balance = currentBalance else { return "-- ETH" }
        return balance.formattedETH + " ETH"
    }
    
    /// Current priority fee in wei
    private var priorityFeeWei: UInt64 {
        if selectedGasSpeed == .custom {
            let gwei = Double(customPriorityFee) ?? 1.5
            return UInt64(gwei * 1_000_000_000)
        }
        return UInt64(selectedGasSpeed.priorityFeeGwei * 1_000_000_000)
    }
    
    /// Current max fee in wei
    private var maxFeeWei: UInt64 {
        if selectedGasSpeed == .custom {
            let gwei = Double(customMaxFee) ?? 30
            return UInt64(gwei * 1_000_000_000)
        }
        return UInt64(selectedGasSpeed.maxFeeGwei * 1_000_000_000)
    }
    
    /// Estimated transaction cost in ETH
    private var estimatedCostEth: Double {
        let gasLimit: UInt64 = 21000
        let maxCostWei = gasLimit * maxFeeWei
        return Double(maxCostWei) / 1e18
    }
    
    /// Check if amount + gas exceeds balance
    private var exceedsBalance: Bool {
        guard let balance = currentBalance,
              let sendWei = amountInWei else { return false }
        let gasLimit: UInt64 = 21000
        let maxCostWei = gasLimit * maxFeeWei
        let totalWei = BigUInt(sendWei) + BigUInt(maxCostWei)
        // Use >= with NOT: totalWei > balance.wei  ≡  !(balance.wei >= totalWei)
        return !(balance.wei >= totalWei)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Recipient Address (0x...)", text: $recipientAddress)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    
                    if !recipientAddress.isEmpty && !isValidAddress {
                        Text("Invalid address format")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                } header: {
                    Text("To")
                }
                
                Section {
                    HStack {
                        TextField("0.0", text: $amount)
                            .keyboardType(.decimalPad)
                            .font(.system(.title2, design: .monospaced))
                        
                        Text("ETH")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        if let wei = amountInWei {
                            Text("\(wei) wei")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        // Available balance with Max button
                        HStack(spacing: 4) {
                            Text("Available:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(availableBalanceText)
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(exceedsBalance ? .red : .primary)
                            
                            Button("Max") {
                                setMaxAmount()
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                    
                    if exceedsBalance {
                        Text("Amount + gas exceeds available balance")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                } header: {
                    Text("Amount")
                } footer: {
                    HStack {
                        Text("Network:")
                        Text(balanceService.useTestnet ? "Sepolia Testnet" : "Ethereum Mainnet")
                            .foregroundColor(balanceService.useTestnet ? .orange : .primary)
                    }
                    .font(.caption)
                }
                
                Section {
                    // Gas speed picker
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Transaction Speed")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        HStack(spacing: 8) {
                            ForEach(GasSpeed.allCases) { speed in
                                GasSpeedButton(
                                    speed: speed,
                                    isSelected: selectedGasSpeed == speed
                                ) {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        selectedGasSpeed = speed
                                        if speed != .custom {
                                            customPriorityFee = String(format: "%.1f", speed.priorityFeeGwei)
                                            customMaxFee = String(format: "%.0f", speed.maxFeeGwei)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    
                    // Custom gas inputs (shown when custom is selected)
                    if selectedGasSpeed == .custom {
                        VStack(spacing: 12) {
                            HStack {
                                Text("Priority Fee")
                                    .font(.subheadline)
                                Spacer()
                                HStack(spacing: 4) {
                                    TextField("1.5", text: $customPriorityFee)
                                        .keyboardType(.decimalPad)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 60)
                                        .textFieldStyle(.roundedBorder)
                                    Text("gwei")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            HStack {
                                Text("Max Fee")
                                    .font(.subheadline)
                                Spacer()
                                HStack(spacing: 4) {
                                    TextField("30", text: $customMaxFee)
                                        .keyboardType(.decimalPad)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 60)
                                        .textFieldStyle(.roundedBorder)
                                    Text("gwei")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    
                    // Gas details disclosure
                    DisclosureGroup("Details", isExpanded: $showGasDetails) {
                        VStack(alignment: .leading, spacing: 8) {
                            gasDetailRow(label: "Gas Limit", value: "21,000")
                            gasDetailRow(label: "Priority Fee", value: String(format: "%.2f gwei", selectedGasSpeed == .custom ? (Double(customPriorityFee) ?? 1.5) : selectedGasSpeed.priorityFeeGwei))
                            gasDetailRow(label: "Max Fee", value: String(format: "%.0f gwei", selectedGasSpeed == .custom ? (Double(customMaxFee) ?? 30) : selectedGasSpeed.maxFeeGwei))
                            Divider()
                            gasDetailRow(label: "Max Cost", value: String(format: "%.6f ETH", estimatedCostEth), highlight: true)
                        }
                        .font(.caption)
                        .padding(.top, 8)
                    }
                    .font(.subheadline)
                } header: {
                    Text("Gas Settings (EIP-1559)")
                } footer: {
                    Text("Max cost is the worst-case fee. Actual cost is usually lower.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                    }
                }
                
                // Show transaction status based on actual relay state
                if let txId = submittedTxId {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            if isConfirmed {
                                // Transaction was broadcast successfully
                                if let confirmed = meshRelay.confirmedTransactions.first(where: { $0.id == txId }) {
                                    Label("Transaction Broadcast", systemImage: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    
                                    Text("TX Hash: \(confirmed.txHash.prefix(20))...")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    
                                    Text("Closing in 2 seconds...")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .onAppear {
                                            // Auto-dismiss after showing success
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                                onSuccess?()
                                                dismiss()
                                            }
                                        }
                                }
                            } else if let status = txStatus {
                                switch status {
                                case .queued:
                                    Label("Queued", systemImage: "clock.fill")
                                        .foregroundColor(.orange)
                                    Text("Waiting to broadcast...")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                case .relaying:
                                    Label("Broadcasting...", systemImage: "arrow.up.circle.fill")
                                        .foregroundColor(.blue)
                                    ProgressView()
                                        .scaleEffect(0.8)
                                case .awaitingConfirmation:
                                    Label("Awaiting Confirmation", systemImage: "hourglass")
                                        .foregroundColor(.blue)
                                case .confirmed:
                                    Label("Confirmed", systemImage: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                case .failed:
                                    Label("Transaction Failed", systemImage: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                    Text("The transaction was rejected by the network. Check your balance and try again.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                // Transaction not in pending or confirmed - might have been cleared
                                Label("Status Unknown", systemImage: "questionmark.circle")
                                    .foregroundColor(.secondary)
                            }
                            
                            Text("Request ID: \(txId.prefix(16))...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Section {
                    Button {
                        showingConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            if isLoading {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text(isLoading ? "Signing..." : (isOnline ? "Sign & Send" : "Sign & Queue"))
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(!canSend || isLoading)
                    
                    if !isOnline {
                        Text("Offline mode: Transaction will be queued and broadcast when connectivity is available.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }
            .navigationTitle("Send ETH")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                await checkConnectivity()
            }
            .confirmationDialog("Confirm Transaction", isPresented: $showingConfirmation) {
                Button(isOnline ? "Sign & Send" : "Sign & Queue") {
                    Task { await signAndSend() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if isOnline {
                    Text("Send \(amount) ETH to \(recipientAddress.prefix(10))...?\n\nThis will sign and broadcast the transaction immediately.")
                } else {
                    Text("Send \(amount) ETH to \(recipientAddress.prefix(10))...?\n\nThis will sign the transaction locally and queue it for mesh relay when connectivity is available.")
                }
            }
        }
    }
    
    private func signAndSend() async {
        guard let wei = amountInWei else { return }
        
        isLoading = true
        errorMessage = nil
        
        do {
            // Create a TransactionSigner instance
            let signer = TransactionSigner(
                wallet: wallet,
                meshRelay: meshRelay,
                balanceService: balanceService
            )
            
            // For testing, we use our own address as reply-to
            let myAddress = try await wallet.getAddress()
            
            let requestId = try await signer.signAndQueueTransfer(
                to: recipientAddress,
                amountWei: wei,
                maxPriorityFeePerGas: priorityFeeWei,
                maxFeePerGas: maxFeeWei,
                replyToPeerId: myAddress, // Self for testing
                description: "Send \(amount) ETH"
            )
            
            submittedTxId = requestId
            // Note: Actual broadcast status will be tracked via meshRelay.pendingRelays observation
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
    
    /// Set amount to max (balance minus estimated gas)
    private func setMaxAmount() {
        guard let balance = currentBalance else { return }
        let gasLimit: UInt64 = 21000
        let maxGasCostWei = BigUInt(gasLimit) * BigUInt(maxFeeWei)
        
        // Subtract gas from balance, ensure non-negative
        // Check: balance.wei > maxGasCostWei  ≡  !(maxGasCostWei >= balance.wei)
        guard !(maxGasCostWei >= balance.wei) else {
            amount = "0"
            return
        }
        
        let maxSendWei = balance.wei - maxGasCostWei
        let maxSendEth = maxSendWei.toDouble() / 1e18
        
        // Format with enough precision
        amount = String(format: "%.6f", maxSendEth)
    }
    
    /// Helper view for gas detail rows
    private func gasDetailRow(label: String, value: String, highlight: Bool = false) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .foregroundColor(highlight ? .primary : .secondary)
                .fontWeight(highlight ? .medium : .regular)
        }
    }
    
    private func checkConnectivity() async {
        // Quick connectivity check
        guard let url = URL(string: "https://sepolia.drpc.org") else {
            isOnline = false
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_chainId",
            "params": []
        ])
        request.timeoutInterval = 5
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                isOnline = httpResponse.statusCode == 200
            } else {
                isOnline = false
            }
        } catch {
            isOnline = false
        }
    }
}

#Preview {
    SendTransactionView(
        wallet: EmbeddedWallet(keychain: PreviewKeychainManager()),
        balanceService: EthereumBalanceService(),
        meshRelay: MeshTransactionRelay(keychain: PreviewKeychainManager())
    )
}

// MARK: - Gas Speed Button

struct GasSpeedButton: View {
    let speed: GasSpeed
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: speed.icon)
                    .font(.system(size: 16))
                Text(speed.rawValue)
                    .font(.caption2)
                    .fontWeight(.medium)
                if speed != .custom {
                    Text(speed.description)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? .accentColor : .primary)
    }
}
