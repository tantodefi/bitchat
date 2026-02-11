//
// CrossChainSwapView.swift
// bitchat
//
// UI for EIL cross-chain swaps using EIP-7702.
// Chain selection, amount input, quote display, and swap execution.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// View for initiating and monitoring cross-chain swaps
struct CrossChainSwapView: View {
    let wallet: EmbeddedWallet
    let eilManager: EILCrossChainManager
    let balanceService: EthereumBalanceService
    
    @Environment(\.dismiss) private var dismiss
    
    // Form state
    @State private var sourceChainId: UInt64 = 1
    @State private var destinationChainId: UInt64 = 10
    @State private var amount: String = ""
    @State private var customRecipient: String = ""
    @State private var useCustomRecipient: Bool = false
    @State private var slippageTolerance: Double = 0.5 // 0.5%
    
    // Quote state
    @State private var quote: EILCrossChainManager.SwapQuote?
    @State private var isLoadingQuote: Bool = false
    @State private var quoteError: String?
    
    // Swap state
    @State private var isSwapping: Bool = false
    @State private var swapResult: EILCrossChainManager.VoucherRequest?
    @State private var swapError: String?
    
    // Available chains
    @State private var availableChains: [EILCrossChainManager.SupportedChain] = []
    
    private var sourceChain: EILCrossChainManager.SupportedChain? {
        availableChains.first { $0.id == sourceChainId }
    }
    
    private var destinationChain: EILCrossChainManager.SupportedChain? {
        availableChains.first { $0.id == destinationChainId }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // MARK: - Chain Selection
                    chainSelectionSection
                    
                    // MARK: - Amount Input
                    amountSection
                    
                    // MARK: - Recipient
                    if useCustomRecipient {
                        recipientSection
                    }
                    
                    // MARK: - Quote
                    if let quote = quote {
                        quoteSection(quote)
                    } else if isLoadingQuote {
                        ProgressView("Getting quote...")
                            .padding()
                    } else if let error = quoteError {
                        errorView(error)
                    }
                    
                    // MARK: - Slippage
                    slippageSection
                    
                    // MARK: - Swap Button
                    swapButton
                    
                    // MARK: - Result
                    if let result = swapResult {
                        swapResultSection(result)
                    }
                    
                    // MARK: - Info
                    infoSection
                }
                .padding()
            }
            .navigationTitle("Cross-Chain Swap")
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
            .task {
                await loadChains()
            }
            .onChange(of: amount) { _ in
                refreshQuote()
            }
            .onChange(of: sourceChainId) { _ in
                refreshQuote()
            }
            .onChange(of: destinationChainId) { _ in
                refreshQuote()
            }
        }
    }
    
    // MARK: - Sections
    
    private var chainSelectionSection: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Swap Route")
                    .font(.headline)
                Spacer()
            }
            
            HStack(spacing: 12) {
                // Source chain
                VStack(alignment: .leading, spacing: 4) {
                    Text("From")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Picker("Source", selection: $sourceChainId) {
                        ForEach(availableChains) { chain in
                            Text(chain.name).tag(chain.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemGray).opacity(0.1))
                    .cornerRadius(12)
                }
                
                // Swap direction button
                Button {
                    withAnimation {
                        let temp = sourceChainId
                        sourceChainId = destinationChainId
                        destinationChainId = temp
                    }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                }
                .padding(.top, 20)
                
                // Destination chain
                VStack(alignment: .leading, spacing: 4) {
                    Text("To")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Picker("Destination", selection: $destinationChainId) {
                        ForEach(availableChains.filter { $0.id != sourceChainId }) { chain in
                            Text(chain.name).tag(chain.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemGray).opacity(0.1))
                    .cornerRadius(12)
                }
            }
        }
    }
    
    private var amountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Amount")
                    .font(.headline)
                
                Spacer()
                
                if sourceChain != nil {
                    Button("Max") {
                        // Set max balance
                    }
                    .font(.caption)
                    .foregroundColor(.accentColor)
                }
            }
            
            HStack {
                TextField("0.0", text: $amount)
                    .font(.system(.title2, design: .monospaced))
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.plain)
                
                Text(sourceChain?.symbol ?? "ETH")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(.systemGray).opacity(0.1))
            .cornerRadius(12)
            
            // Balance display
            if let sourceChain = sourceChain {
                HStack {
                    Text("Balance:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("— \(sourceChain.symbol)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    private var recipientSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recipient")
                .font(.headline)
            
            TextField("0x...", text: $customRecipient)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.plain)
                .padding()
                .background(Color(.systemGray).opacity(0.1))
                .cornerRadius(12)
                #if os(iOS)
                .autocapitalization(.none)
                #endif
        }
    }
    
    private func quoteSection(_ quote: EILCrossChainManager.SwapQuote) -> some View {
        VStack(spacing: 12) {
            HStack {
                Text("Quote")
                    .font(.headline)
                
                Spacer()
                
                Button {
                    refreshQuote()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            
            VStack(spacing: 8) {
                quoteRow(label: "You send", value: formatAmount(quote.sourceAmount), suffix: sourceChain?.symbol ?? "ETH")
                
                Divider()
                
                quoteRow(label: "You receive (est.)", value: formatAmount(quote.destinationAmount), suffix: destinationChain?.symbol ?? "ETH")
                
                Divider()
                
                quoteRow(label: "Fee", value: formatAmount(quote.fee), suffix: sourceChain?.symbol ?? "ETH")
                
                Divider()
                
                quoteRow(label: "Est. time", value: formatTime(quote.estimatedTime), suffix: "")
                
                if quote.priceImpact > 0.1 {
                    Divider()
                    
                    HStack {
                        Text("Price impact")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Text(String(format: "%.2f%%", quote.priceImpact))
                            .font(.subheadline)
                            .foregroundColor(quote.priceImpact > 1 ? .orange : .primary)
                    }
                }
            }
            .padding()
            .background(Color(.systemGray).opacity(0.1))
            .cornerRadius(12)
        }
    }
    
    private func quoteRow(label: String, value: String, suffix: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
            
            if !suffix.isEmpty {
                Text(suffix)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var slippageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Slippage Tolerance")
                    .font(.subheadline)
                
                Spacer()
                
                Text(String(format: "%.1f%%", slippageTolerance))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            HStack(spacing: 8) {
                ForEach([0.1, 0.5, 1.0], id: \.self) { value in
                    Button {
                        slippageTolerance = value
                    } label: {
                        Text(String(format: "%.1f%%", value))
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(slippageTolerance == value ? Color.accentColor : Color(.systemGray).opacity(0.2))
                            .foregroundColor(slippageTolerance == value ? .white : .primary)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
                
                Spacer()
                
                Toggle("Custom recipient", isOn: $useCustomRecipient)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .scaleEffect(0.8)
            }
        }
    }
    
    private var swapButton: some View {
        Button {
            Task {
                await executeSwap()
            }
        } label: {
            HStack {
                if isSwapping {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.left.arrow.right")
                    Text("Swap")
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(canSwap ? Color.accentColor : Color.gray)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .disabled(!canSwap || isSwapping)
    }
    
    private func swapResultSection(_ result: EILCrossChainManager.VoucherRequest) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: statusIcon(for: result.status))
                    .font(.title)
                    .foregroundColor(statusColor(for: result.status))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle(for: result.status))
                        .font(.headline)
                    
                    Text(statusDescription(for: result.status))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding()
            .background(statusColor(for: result.status).opacity(0.1))
            .cornerRadius(12)
            
            if let txHash = result.sourceTxHash {
                HStack {
                    Text("Source TX:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("\(txHash.prefix(10))...")
                        .font(.system(.caption, design: .monospaced))
                }
            }
            
            if let error = result.error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
            }
        }
    }
    
    private func errorView(_ error: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            
            Text(error)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
    }
    
    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.blue)
                
                Text("Cross-chain swaps use EIP-7702 to enable your wallet to interact with the Ethereum Interop Layer. Swaps are secured by atomic vouchers from XLP liquidity providers.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color.blue.opacity(0.1))
            .cornerRadius(12)
        }
    }
    
    // MARK: - Computed Properties
    
    private var canSwap: Bool {
        guard let amountValue = Double(amount), amountValue > 0 else { return false }
        guard quote != nil else { return false }
        guard sourceChainId != destinationChainId else { return false }
        
        if useCustomRecipient {
            guard customRecipient.hasPrefix("0x") && customRecipient.count == 42 else { return false }
        }
        
        return true
    }
    
    // MARK: - Actions
    
    private func loadChains() async {
        availableChains = await eilManager.getAvailableChains(includeTestnets: balanceService.useTestnet)
        
        // Set default chains
        if let first = availableChains.first {
            sourceChainId = first.id
        }
        if let second = availableChains.dropFirst().first {
            destinationChainId = second.id
        }
    }
    
    private func refreshQuote() {
        guard let amountValue = Double(amount), amountValue > 0 else {
            quote = nil
            return
        }
        
        // Convert to wei
        let weiAmount = String(format: "%.0f", amountValue * pow(10, 18))
        
        isLoadingQuote = true
        quoteError = nil
        
        Task {
            do {
                let newQuote = try await eilManager.getQuote(
                    sourceChainId: sourceChainId,
                    destinationChainId: destinationChainId,
                    amount: weiAmount
                )
                quote = newQuote
            } catch {
                quoteError = error.localizedDescription
            }
            isLoadingQuote = false
        }
    }
    
    private func executeSwap() async {
        guard let quote = quote else { return }
        
        isSwapping = true
        swapError = nil
        
        do {
            // Calculate minimum receive with slippage
            let destinationAmount = Decimal(string: quote.destinationAmount) ?? 0
            let slippage = Decimal(slippageTolerance / 100)
            let minReceive = destinationAmount * (1 - slippage)
            
            let recipient = useCustomRecipient ? customRecipient : nil
            
            let result = try await eilManager.initiateSwap(
                sourceChainId: sourceChainId,
                destinationChainId: destinationChainId,
                amount: quote.sourceAmount,
                minReceive: minReceive.description,
                recipient: recipient
            )
            
            swapResult = result
        } catch {
            swapError = error.localizedDescription
        }
        
        isSwapping = false
    }
    
    // MARK: - Helpers
    
    private func formatAmount(_ weiString: String) -> String {
        guard let wei = Decimal(string: weiString) else { return "0" }
        let eth = wei / Decimal(pow(10.0, 18.0))
        
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
        formatter.numberStyle = .decimal
        
        return formatter.string(from: eth as NSNumber) ?? "0"
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s"
        } else if seconds < 3600 {
            return "\(Int(seconds / 60))m"
        } else {
            return "\(Int(seconds / 3600))h"
        }
    }
    
    private func statusIcon(for status: EILCrossChainManager.VoucherStatus) -> String {
        switch status {
        case .pending, .sourcing:
            return "clock.fill"
        case .matched, .submitted, .confirming:
            return "arrow.right.circle.fill"
        case .bridging:
            return "link.circle.fill"
        case .completing:
            return "checkmark.circle"
        case .completed:
            return "checkmark.circle.fill"
        case .failed, .expired:
            return "xmark.circle.fill"
        }
    }
    
    private func statusColor(for status: EILCrossChainManager.VoucherStatus) -> Color {
        switch status {
        case .pending, .sourcing:
            return .orange
        case .matched, .submitted, .confirming, .bridging, .completing:
            return .blue
        case .completed:
            return .green
        case .failed, .expired:
            return .red
        }
    }
    
    private func statusTitle(for status: EILCrossChainManager.VoucherStatus) -> String {
        switch status {
        case .pending:
            return "Pending"
        case .sourcing:
            return "Finding Liquidity"
        case .matched:
            return "Liquidity Found"
        case .submitted:
            return "Submitted"
        case .confirming:
            return "Confirming"
        case .bridging:
            return "Bridging"
        case .completing:
            return "Completing"
        case .completed:
            return "Completed!"
        case .failed:
            return "Failed"
        case .expired:
            return "Expired"
        }
    }
    
    private func statusDescription(for status: EILCrossChainManager.VoucherStatus) -> String {
        switch status {
        case .pending:
            return "Preparing swap..."
        case .sourcing:
            return "Looking for XLP liquidity providers..."
        case .matched:
            return "XLP matched, preparing transaction..."
        case .submitted:
            return "Transaction submitted to source chain"
        case .confirming:
            return "Waiting for confirmations..."
        case .bridging:
            return "Cross-chain message in flight"
        case .completing:
            return "Executing on destination chain..."
        case .completed:
            return "Swap completed successfully"
        case .failed:
            return "Something went wrong"
        case .expired:
            return "Deadline passed"
        }
    }
}

// MARK: - Preview

#if DEBUG
struct CrossChainSwapView_Previews: PreviewProvider {
    static var previews: some View {
        Text("Preview requires wallet instance")
    }
}
#endif
