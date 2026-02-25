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
import Tor

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
    
    /// PQ account support: when set, sends go through the PQ smart account
    var accountMode: AccountMode = .eoa
    var pqViewModel: PQAccountViewModel? = nil
    /// The address whose balance to display (EOA or PQ smart contract wallet)
    var senderAddress: String? = nil
    
    /// Token store for ERC-20 token support
    @StateObject private var tokenStore = TokenStore.shared
    
    /// Currently selected asset (ETH or an ERC-20 token)
    @State private var selectedAsset: SelectedAsset = .eth
    @State private var showTokenPicker = false
    
    @State private var recipientAddress = ""
    @State private var amount = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var submittedTxId: String?
    @State private var showingConfirmation = false
    @State private var isOnline = true
    
    // ENS resolution
    @State private var resolvedAddress: String?
    @State private var resolvedENSName: String?
    @State private var isResolvingENS = false
    @State private var ensError: String?
    @State private var ensResolveTask: Task<Void, Never>?
    
    // Network selection
    @State private var selectedNetwork: EthereumBalanceService.Network = .sepolia
    
    // Gas settings
    @State private var selectedGasSpeed: GasSpeed = .average
    @State private var customPriorityFee: String = "1.5"
    @State private var customMaxFee: String = "30"
    @State private var showGasDetails = false
    
    /// Live gas price fetched from the network (PQ mode only)
    @State private var liveGasPriceWei: UInt64 = 0
    
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
    
    /// Check if transaction was rejected/reverted on-chain
    private var isFailed: Bool {
        guard let txId = submittedTxId else { return false }
        return meshRelay.failedTransactions.contains { $0.id == txId }
    }
    
    /// Amount in the smallest unit of the selected asset.
    /// For ETH: wei (1e18). For ERC-20: depends on token decimals.
    private var amountInWei: UInt64? {
        guard let ethAmount = Double(amount) else { return nil }
        let decimals = Double(selectedAsset.decimals)
        let smallest = ethAmount * pow(10, decimals)
        guard smallest >= 0, smallest <= Double(UInt64.max) else { return nil }
        return UInt64(smallest)
    }
    
    /// Amount as BigUInt for token transfers that may exceed UInt64.
    private var amountBigUInt: BigUInt? {
        guard let ethAmount = Double(amount) else { return nil }
        let decimals = Int(selectedAsset.decimals)
        let multiplier = BigUInt(10).power(decimals)
        // Split into whole and fractional parts for precision
        let wholePart = BigUInt(UInt64(ethAmount))
        let fracPart = ethAmount - Double(UInt64(ethAmount))
        let fracScaled = BigUInt(UInt64(fracPart * pow(10, Double(min(decimals, 18)))))
        let fracMultiplier = BigUInt(10).power(max(0, decimals - min(decimals, 18)))
        return wholePart * multiplier + fracScaled * fracMultiplier
    }
    
    private var isValidAddress: Bool {
        let addr = effectiveRecipientAddress
        return addr.hasPrefix("0x") && addr.count == 42
    }
    
    /// Whether the input looks like an ENS name
    private var isENSInput: Bool {
        ENSResolver.looksLikeENSName(recipientAddress)
    }
    
    /// The actual address to use for the transaction (resolved or raw)
    private var effectiveRecipientAddress: String {
        resolvedAddress ?? recipientAddress
    }
    
    private var canSend: Bool {
        isValidAddress && amountInWei != nil && (amountInWei ?? 0) > 0 && submittedTxId == nil && !isResolvingENS
    }
    
    /// Whether this view is sending from a PQ smart contract account
    private var isPQMode: Bool {
        accountMode == .pqAccount && pqViewModel != nil
    }
    
    /// Available networks based on current mode
    private var availableNetworks: [EthereumBalanceService.Network] {
        if balanceService.useTestnet {
            return EthereumBalanceService.Network.testnets
        } else {
            return EthereumBalanceService.Network.mainnets
        }
    }
    
    /// Get current network's balance using the user's selected network
    private var currentBalance: EthereumBalanceService.Balance? {
        return balanceService.balances[selectedNetwork]
    }
    
    /// Formatted available balance for the selected asset.
    private var availableBalanceText: String {
        if selectedAsset.isETH {
            guard let balance = currentBalance else { return "-- ETH" }
            return balance.formattedETH + " ETH"
        } else {
            if case .token(let token) = selectedAsset,
               let tokenBal = tokenStore.balance(for: token, on: selectedNetwork) {
                return tokenBal.formattedBalance + " " + token.symbol
            }
            return "-- \(selectedAsset.symbol)"
        }
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
        if isPQMode {
            // PQ UserOps: use live gas price from the network.
            // PQAccountViewModel.estimatePQGasCost uses the same maxFee formula
            // as PQTransactionSigner for consistency. The real bundler estimation
            // happens at signing time.
            let cost = PQAccountViewModel.estimatePQGasCost(liveGasPrice: liveGasPriceWei)
            return cost.toDouble() / 1e18
        }
        // EOA: 65k gas covers both simple transfers (21k) and contract receives.
        let gasLimit: UInt64 = 65000
        let maxCostWei = gasLimit * maxFeeWei
        return Double(maxCostWei) / 1e18
    }
    
    /// Check if amount + gas exceeds balance.
    /// For token transfers: checks token balance for the amount and ETH balance for gas.
    private var exceedsBalance: Bool {
        guard let sendWei = amountInWei else { return false }
        
        if !selectedAsset.isETH {
            // Token transfer: check token balance for the amount
            if case .token(let token) = selectedAsset,
               let tokenBal = tokenStore.balance(for: token, on: selectedNetwork) {
                return !(tokenBal.rawBalance >= BigUInt(sendWei))
            }
            return false // Can't determine — don't block
        }
        
        guard let balance = currentBalance else { return false }
        if isPQMode {
            let gasCostWei = PQAccountViewModel.estimatePQGasCost(liveGasPrice: liveGasPriceWei)
            let totalWei = BigUInt(sendWei) + gasCostWei
            return !(balance.wei >= totalWei)
        }
        // EOA: conservative 65k gas covers both simple transfers and contract receives
        let gasLimit: UInt64 = 65000
        let maxCostWei = gasLimit * maxFeeWei
        let totalWei = BigUInt(sendWei) + BigUInt(maxCostWei)
        return !(balance.wei >= totalWei)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Asset Selector
                Section {
                    Button {
                        showTokenPicker = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedAsset.iconName)
                                .font(.title2)
                                .foregroundColor(selectedAsset.isETH ? .blue : .orange)
                                .frame(width: 36, height: 36)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(selectedAsset.symbol)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text(selectedAsset.isETH ? "Native Ether" : "ERC-20 Token")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Text(availableBalanceText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Asset")
                }
                
                Section {
                    TextField("Address (0x...) or name.dstealth.eth", text: $recipientAddress)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: recipientAddress) { newValue in
                            resolveENSIfNeeded(newValue)
                        }
                    
                    if isResolvingENS {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Resolving \(recipientAddress)…")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else if let resolved = resolvedAddress, let ensName = resolvedENSName {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                            Text("\(ensName) → \(resolved.prefix(6))…\(resolved.suffix(4))")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    } else if let ensErr = ensError {
                        Text(ensErr)
                            .font(.caption)
                            .foregroundColor(.red)
                    } else if !recipientAddress.isEmpty && !isValidAddress && !isENSInput {
                        Text("Invalid address format")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                } header: {
                    Text("To")
                }
                
                // MARK: - Network Selector
                Section {
                    Picker("Network", selection: $selectedNetwork) {
                        ForEach(availableNetworks, id: \.self) { network in
                            Text(network.rawValue).tag(network)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    if selectedAsset.isETH {
                        if let balance = currentBalance {
                            HStack {
                                Text("ETH Balance on \(selectedNetwork.rawValue)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(balance.formattedETH) ETH")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                        } else {
                            HStack {
                                Text("ETH Balance on \(selectedNetwork.rawValue)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("-- ETH")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else if case .token(let token) = selectedAsset {
                        HStack {
                            Text("\(token.symbol) Balance on \(selectedNetwork.rawValue)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            if let tokenBal = tokenStore.balance(for: token, on: selectedNetwork) {
                                Text("\(tokenBal.formattedBalance) \(token.symbol)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            } else if tokenStore.isLoadingBalances {
                                ProgressView().scaleEffect(0.6)
                            } else {
                                Text("-- \(token.symbol)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Network")
                } footer: {
                    if isPQMode {
                        HStack(spacing: 4) {
                            Image(systemName: "shield.checkered")
                                .foregroundColor(.green)
                            Text("Sending from PQ smart account via ERC-4337 UserOperation")
                                .foregroundColor(.green)
                        }
                        .font(.caption)
                    }
                }
                
                Section {
                    HStack {
                        TextField("0.0", text: $amount)
                            .keyboardType(.decimalPad)
                            .font(.system(.title2, design: .monospaced))
                        
                        Text(selectedAsset.symbol)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        if let wei = amountInWei {
                            Text(selectedAsset.isETH ? "\(wei) wei" : "\(wei) units")
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
                        Text(selectedAsset.isETH ? "Amount + gas exceeds available balance" : "Amount exceeds \(selectedAsset.symbol) balance")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                } header: {
                    Text("Amount")
                }
                
                // Gas settings — only for EOA mode.
                // PQ account gas is estimated by the Pimlico bundler.
                if !isPQMode {
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
                } // end if !isPQMode (gas settings)
                
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
                            if isFailed {
                                // Transaction was broadcast but REVERTED on-chain
                                if let failed = meshRelay.failedTransactions.first(where: { $0.id == txId }) {
                                    Label("Transaction Failed", systemImage: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                    Text(failed.reason)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("The transaction was accepted by the network but reverted on-chain. This can happen when sending to a smart contract wallet with insufficient gas.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else {
                                    Label("Transaction Failed", systemImage: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                }
                            } else if isConfirmed {
                                // Transaction was broadcast and confirmed on-chain
                                if let confirmed = meshRelay.confirmedTransactions.first(where: { $0.id == txId }) {
                                    Label("Transaction Confirmed", systemImage: "checkmark.circle.fill")
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
                                    Label("Verifying on-chain...", systemImage: "hourglass")
                                        .foregroundColor(.blue)
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("Checking transaction receipt...")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
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
                            if isPQMode {
                                Text(isLoading ? "Submitting UserOp..." : "Send \(selectedAsset.symbol) via PQ")
                                    .fontWeight(.semibold)
                            } else {
                                Text(isLoading ? "Signing..." : (isOnline ? "Sign & Send \(selectedAsset.symbol)" : "Sign & Queue"))
                                    .fontWeight(.semibold)
                            }
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
            .navigationTitle(isPQMode ? "Send \(selectedAsset.symbol) (PQ)" : "Send \(selectedAsset.symbol)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                // Set initial network based on testnet mode
                selectedNetwork = balanceService.useTestnet ? .sepolia : .ethereum
                await checkConnectivity()
            }
            .task {
                // Refresh balances for the sender address when the sheet opens
                if let addr = senderAddress, !addr.isEmpty {
                    await balanceService.fetchBalances(for: addr)
                }
            }
            .task(id: selectedNetwork) {
                // Fetch live gas price from the network for PQ mode estimation
                if isPQMode, let pqVM = pqViewModel {
                    let chain: PQAccountDeployer.Chain = selectedNetwork == .arbitrumSepolia ? .arbitrumSepolia : .sepolia
                    liveGasPriceWei = await pqVM.fetchLiveGasPrice(chain: chain)
                }
                // Fetch token balances for the selected network
                if let addr = senderAddress, !addr.isEmpty {
                    await tokenStore.fetchTokenBalances(for: addr, network: selectedNetwork)
                }
            }
            .sheet(isPresented: $showTokenPicker) {
                TokenPickerView(
                    network: selectedNetwork,
                    ethBalance: currentBalance,
                    tokenStore: tokenStore,
                    balanceService: balanceService,
                    walletAddress: senderAddress ?? "",
                    selectedAsset: $selectedAsset
                )
            }
            .confirmationDialog("Confirm Transaction", isPresented: $showingConfirmation) {
                Button(isOnline ? "Sign & Send" : "Sign & Queue") {
                    Task { await signAndSend() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                let displayRecipient = resolvedENSName ?? String(effectiveRecipientAddress.prefix(10)) + "..."
                if isOnline {
                    Text("Send \(amount) \(selectedAsset.symbol) to \(displayRecipient)?\n\nThis will sign and broadcast the transaction immediately.")
                } else {
                    Text("Send \(amount) \(selectedAsset.symbol) to \(displayRecipient)?\n\nThis will sign the transaction locally and queue it for mesh relay when connectivity is available.")
                }
            }
        }
    }
    
    private func signAndSend() async {
        guard let wei = amountInWei else { return }
        
        isLoading = true
        errorMessage = nil
        
        do {
            // Determine if this is a token transfer or native ETH transfer
            let isTokenTransfer = !selectedAsset.isETH
            let tokenContractAddress = selectedAsset.contractAddress(on: selectedNetwork)
            
            if isPQMode, let pqVM = pqViewModel {
                // PQ mode: send via ERC-4337 UserOperation through the smart account
                let pqChain: PQAccountDeployer.Chain = selectedNetwork == .arbitrumSepolia ? .arbitrumSepolia : .sepolia
                let myAddress = try await wallet.getAddress()
                
                if isTokenTransfer, let contractAddr = tokenContractAddress {
                    // ERC-20 token transfer: execute(tokenContract, 0, transfer(to, amount))
                    let transferData = ABIEncoder.encodeTransfer(
                        to: effectiveRecipientAddress,
                        amount: ABIEncoder.encodeUInt256(UInt64(wei))
                    )
                    let txHash = await pqVM.executeTransaction(
                        to: contractAddr,
                        value: 0,
                        data: transferData,
                        chain: pqChain,
                        meshRelay: meshRelay,
                        replyToPeerId: myAddress
                    )
                    if let hash = txHash {
                        submittedTxId = hash
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            onSuccess?()
                            dismiss()
                        }
                    } else {
                        errorMessage = pqVM.lastError ?? "PQ token transfer failed"
                    }
                } else {
                    // Native ETH transfer
                    let txHash = await pqVM.executeTransaction(
                        to: effectiveRecipientAddress,
                        value: wei,
                        chain: pqChain,
                        meshRelay: meshRelay,
                        replyToPeerId: myAddress
                    )
                    if let hash = txHash {
                        submittedTxId = hash
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            onSuccess?()
                            dismiss()
                        }
                    } else {
                        errorMessage = pqVM.lastError ?? "PQ transaction failed"
                    }
                }
            } else {
                // EOA mode: sign raw transaction and queue for mesh relay
                let signer = TransactionSigner(
                    wallet: wallet,
                    meshRelay: meshRelay,
                    balanceService: balanceService
                )
                
                let myAddress = try await wallet.getAddress()
                
                if isTokenTransfer, let contractAddr = tokenContractAddress {
                    // ERC-20 token transfer: send 0 ETH to token contract with transfer() calldata
                    let transferData = ABIEncoder.encodeTransfer(
                        to: effectiveRecipientAddress,
                        amount: ABIEncoder.encodeUInt256(UInt64(wei))
                    )
                    let requestId = try await signer.signAndQueueTransfer(
                        to: contractAddr,
                        amountWei: 0,
                        data: transferData,
                        maxPriorityFeePerGas: priorityFeeWei,
                        maxFeePerGas: maxFeeWei,
                        replyToPeerId: myAddress,
                        description: "Send \(amount) \(selectedAsset.symbol)",
                        selectedNetwork: selectedNetwork
                    )
                    submittedTxId = requestId
                } else {
                    // Native ETH transfer
                    let requestId = try await signer.signAndQueueTransfer(
                        to: effectiveRecipientAddress,
                        amountWei: wei,
                        maxPriorityFeePerGas: priorityFeeWei,
                        maxFeePerGas: maxFeeWei,
                        replyToPeerId: myAddress,
                        description: "Send \(amount) ETH",
                        selectedNetwork: selectedNetwork
                    )
                    submittedTxId = requestId
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
    
    /// Set amount to max (balance minus estimated gas for ETH, or full token balance)
    private func setMaxAmount() {
        // For token transfers, use the full token balance
        if !selectedAsset.isETH {
            if case .token(let token) = selectedAsset,
               let tokenBal = tokenStore.balance(for: token, on: selectedNetwork) {
                amount = tokenBal.formattedBalance
            }
            return
        }
        guard let balance = currentBalance else { return }
        
        if isPQMode {
            // PQ mode (no paymaster): the smart account pays gas from its own balance
            // during validateUserOp. Reserve estimated gas cost so the EntryPoint's
            // _payPrefund doesn't revert (which surfaces as AA24 "signature error").
            // Uses live network gas price for accuracy.
            let gasCostWei = PQAccountViewModel.estimatePQGasCost(liveGasPrice: liveGasPriceWei)
            // Apply 1.5x safety margin on the gas reserve for the Max button
            let safeGasCost = gasCostWei * BigUInt(15) / BigUInt(10)
            
            guard !(safeGasCost >= balance.wei) else {
                amount = "0"
                return
            }
            
            let maxSendWei = balance.wei - safeGasCost
            let maxSendEth = maxSendWei.toDouble() / 1e18
            amount = String(format: "%.6f", max(0, maxSendEth))
            return
        }
        
        // Conservative gas estimate: covers both EOA (21k) and contract wallets (PQ accounts)
        let gasLimit: UInt64 = 65000
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
        // Quick connectivity check — try direct URLSession first (faster),
        // then Tor session as fallback. Avoids false-negative when Tor isn't bootstrapped.
        let url = selectedNetwork.rpcURL
        
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
        
        // Try direct session first (works even if Tor isn't bootstrapped)
        for session in [URLSession.shared, TorURLSession.shared.session] {
            do {
                let (_, response) = try await session.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    isOnline = true
                    return
                }
            } catch {
                continue
            }
        }
        isOnline = false
    }
    
    // MARK: - ENS Resolution
    
    /// Resolve an ENS name to an address with debounce
    private func resolveENSIfNeeded(_ input: String) {
        // Cancel any in-flight resolution
        ensResolveTask?.cancel()
        resolvedAddress = nil
        resolvedENSName = nil
        ensError = nil
        
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Only resolve if it looks like an ENS name
        guard ENSResolver.looksLikeENSName(trimmed) else {
            isResolvingENS = false
            return
        }
        
        // Debounce: wait 500ms after the user stops typing
        isResolvingENS = true
        ensResolveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            
            do {
                let resolution = try await ENSResolver.shared.resolve(trimmed)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    resolvedAddress = resolution.address
                    resolvedENSName = trimmed
                    isResolvingENS = false
                    ensError = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    resolvedAddress = nil
                    resolvedENSName = nil
                    isResolvingENS = false
                    ensError = "Could not resolve \(trimmed)"
                }
            }
        }
    }
}

#Preview {
    SendTransactionView(
        wallet: EmbeddedWallet(keychain: PreviewKeychainManager()),
        balanceService: EthereumBalanceService(),
        meshRelay: MeshTransactionRelay(keychain: PreviewKeychainManager()),
        senderAddress: "0x0000000000000000000000000000000000000001"
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
