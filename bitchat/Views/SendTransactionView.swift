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

struct SendTransactionView: View {
    @Environment(\.dismiss) private var dismiss
    
    let wallet: EmbeddedWallet
    let balanceService: EthereumBalanceService
    @ObservedObject var meshRelay: MeshTransactionRelay
    
    @State private var recipientAddress = ""
    @State private var amount = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var submittedTxId: String?
    @State private var showingConfirmation = false
    @State private var isOnline = true
    
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
                    
                    if let wei = amountInWei {
                        Text("\(wei) wei")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Gas Limit")
                            Spacer()
                            Text("21,000")
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text("Max Fee")
                            Spacer()
                            Text("~50 gwei")
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text("Priority Fee")
                            Spacer()
                            Text("1.5 gwei")
                                .foregroundColor(.secondary)
                        }
                    }
                    .font(.caption)
                } header: {
                    Text("Gas Settings (EIP-1559)")
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
