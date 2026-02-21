//
// StealthPQAccountListView.swift
// bitchat
//
// SwiftUI view for managing stealth PQ Account addresses.
// Shows derived stealth PQ accounts, balances, and sweep controls.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// View for managing stealth PQ Account addresses (pq.dstealth.eth)
struct StealthPQAccountListView: View {
    @ObservedObject var viewModel: StealthPQAccountViewModel
    
    @State private var showCurrentAddressSheet = false
    @State private var sweepInProgress: UInt32?
    @State private var showSweepConfirmation = false
    @State private var accountToSweep: StealthPQAccount?
    @State private var errorMessage: String?
    @State private var showError = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // MARK: - Header
                headerSection
                
                // MARK: - Generate Section
                generateSection
                
                // MARK: - Latest Address Card
                if let current = viewModel.currentAccount {
                    latestAddressSection(current)
                }
                
                // MARK: - Scanning Status
                if viewModel.isScanning {
                    scanningStatusSection
                }
                
                // MARK: - Stats
                if !viewModel.accounts.isEmpty {
                    statsSection
                }
                
                // MARK: - Funded Accounts
                if !viewModel.fundedAccounts.isEmpty {
                    fundedAccountsSection
                }
                
                // MARK: - All Accounts
                allAccountsSection
            }
            .padding()
        }
        .navigationTitle("Stealth PQ Accounts")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showCurrentAddressSheet) {
            if let current = viewModel.currentAccount {
                StealthPQAddressSheet(account: current, ensName: viewModel.pqENSName)
            }
        }
        .alert("Sweep Confirmation", isPresented: $showSweepConfirmation) {
            Button("Sweep", role: .destructive) {
                if let account = accountToSweep {
                    Task { await viewModel.sweep(account: account) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let account = accountToSweep {
                Text("Sweep \(String(format: "%.6f", account.balanceETH)) ETH from stealth account #\(account.index) to your main PQ account?")
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .task {
            // Load persisted accounts first, then scan existing ones for balance updates
            await viewModel.loadAccounts()
            await viewModel.scanBalances()
        }
        .refreshable {
            await viewModel.scanBalances()
        }
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                .font(.system(size: 40))
                .foregroundColor(.purple)
            
            Text("Post-Quantum Stealth Addresses")
                .font(.headline)
            
            Text("Each payment uses a unique PQ Account address derived from your stealth keys. Funds are swept to your main account after receiving.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            // Network badge
            networkBadge
        }
        .padding()
    }
    
    /// Arbitrum Sepolia network indicator — PQ accounts use L2 due to high deploy gas (~5-15M).
    private var networkBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "diamond.fill")
                .font(.system(size: 10))
                .foregroundColor(.cyan)
            
            Text("Arbitrum Sepolia")
                .font(.caption2)
                .fontWeight(.medium)
            
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
            
            Text("Testnet")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.cyan.opacity(0.1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.cyan.opacity(0.3), lineWidth: 0.5)
        )
    }
    
    // MARK: - Generate Section
    
    private var generateSection: some View {
        VStack(spacing: 12) {
            Button {
                Task { await viewModel.generateNextAccount() }
            } label: {
                HStack {
                    if viewModel.isGenerating {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Generate Stealth PQ Account")
                            .font(.headline)
                        
                        Text("Derive a new unique receive address")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "arrow.right")
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.purple.opacity(0.1))
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isGenerating)
        }
    }
    
    // MARK: - Latest Address
    
    private func latestAddressSection(_ account: StealthPQAccount) -> some View {
        Button {
            showCurrentAddressSheet = true
        } label: {
            HStack {
                Image(systemName: "qrcode")
                    .font(.title2)
                    .foregroundColor(.purple)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Latest Receive Address")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Text(truncateAddress(account.pqAccountAddress))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    
                    if let name = viewModel.pqENSName {
                        Text(name)
                            .font(.caption2)
                            .foregroundColor(.purple)
                    }
                }
                
                Spacer()
                
                Text("#\(account.index)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.2))
                    .cornerRadius(4)
                
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(.systemGray).opacity(0.08))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Scanning Status
    
    private var scanningStatusSection: some View {
        HStack {
            ProgressView()
                .scaleEffect(0.8)
            
            Text("Scanning stealth PQ accounts...")
                .font(.subheadline)
            
            Spacer()
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
    }
    
    // MARK: - Stats
    
    private var statsSection: some View {
        HStack(spacing: 16) {
            statCard(
                title: "Total",
                value: "\(viewModel.accounts.count)",
                icon: "number",
                color: .blue
            )
            
            statCard(
                title: "Funded",
                value: "\(viewModel.fundedAccounts.count)",
                icon: "dollarsign.circle.fill",
                color: .green
            )
            
            statCard(
                title: "Sweepable",
                value: "\(viewModel.sweepableAccounts.count)",
                icon: "arrow.right.circle.fill",
                color: .orange
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
    
    // MARK: - Funded Accounts
    
    private var fundedAccountsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Funded Accounts")
                    .font(.headline)
                
                Spacer()
                
                if viewModel.sweepableAccounts.count > 1 {
                    Button("Sweep All") {
                        Task { await viewModel.sweepAll() }
                    }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }
            
            ForEach(viewModel.fundedAccounts) { account in
                accountCard(account, isFunded: true)
            }
        }
    }
    
    // MARK: - All Accounts
    
    private var allAccountsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("All Stealth PQ Accounts")
                .font(.headline)
            
            if viewModel.accounts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.6))
                    
                    Text("No addresses generated yet")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    
                    Text("Tap \"Generate\" above to derive your first quantum-resistant stealth address. Each address is unique for receiver privacy.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ForEach(viewModel.accounts) { account in
                    accountCard(account, isFunded: account.isFunded)
                }
            }
        }
    }
    
    // MARK: - Account Card
    
    private func accountCard(_ account: StealthPQAccount, isFunded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Index badge
                Text("#\(account.index)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.2))
                    .cornerRadius(4)
                
                // Address
                Text(truncateAddress(account.pqAccountAddress))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                Spacer()
                
                // Verification badge
                verificationBadge(account.verificationLevel)
            }
            
            HStack {
                // Balance
                if isFunded {
                    Text(String(format: "%.6f ETH", account.balanceETH))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.green)
                } else {
                    Text("0 ETH")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Deploy status
                if account.isDeployed {
                    Label("Deployed", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundColor(.green)
                } else {
                    Label("Counterfactual", systemImage: "circle.dashed")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            // Sweep button
            if account.canSweep(minimumWei: StealthPQAccountManager.minimumSweepBalanceWei) {
                Button {
                    accountToSweep = account
                    showSweepConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.right.circle.fill")
                        Text("Sweep to Main Account")
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(sweepInProgress == account.index)
                .overlay {
                    if sweepInProgress == account.index {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
            }
        }
        .padding()
        .background(isFunded ? Color.green.opacity(0.05) : Color(.systemGray).opacity(0.05))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isFunded ? Color.green.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }
    
    // MARK: - Verification Badge
    
    private func verificationBadge(_ level: EthereumBalanceService.VerificationLevel) -> some View {
        HStack(spacing: 4) {
            switch level {
            case .heliosVerified:
                Image(systemName: "shield.checkmark.fill")
                    .foregroundColor(.green)
                Text("Helios")
                    .foregroundColor(.green)
            case .proofConsistent:
                Image(systemName: "checkmark.seal")
                    .foregroundColor(.blue)
                Text("Proof")
                    .foregroundColor(.blue)
            case .unverified:
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                Text("RPC")
                    .foregroundColor(.orange)
            case .pending:
                Image(systemName: "clock")
                    .foregroundColor(.secondary)
                Text("Pending")
                    .foregroundColor(.secondary)
            }
        }
        .font(.caption2)
    }
    
    // MARK: - Helpers
    
    private func truncateAddress(_ address: String) -> String {
        guard address.count > 16 else { return address }
        return "\(address.prefix(8))...\(address.suffix(6))"
    }
}

// MARK: - Address Sheet

/// Sheet showing the current stealth PQ account address + QR code
struct StealthPQAddressSheet: View {
    let account: StealthPQAccount
    let ensName: String?
    @Environment(\.dismiss) private var dismiss
    @State private var showCopiedToast = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // QR Code
                    if let qrImage = generateQRCode(from: account.pqAccountAddress) {
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
                    
                    if let name = ensName {
                        Text(name)
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.purple)
                    }
                    
                    Text("Stealth PQ Account #\(account.index)")
                        .font(.headline)
                    
                    // PQ Account address
                    VStack(spacing: 4) {
                        Text("PQ Account Address")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text(account.pqAccountAddress)
                            .font(.system(.caption, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .padding()
                            .background(Color(.systemGray).opacity(0.1))
                            .cornerRadius(8)
                    }
                    
                    // Signer EOA
                    VStack(spacing: 4) {
                        Text("Stealth Signer (EOA)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text(account.stealthSignerAddress)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    
                    // Action buttons
                    HStack(spacing: 12) {
                        Button {
                            #if os(iOS)
                            UIPasteboard.general.string = account.pqAccountAddress
                            #elseif os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(account.pqAccountAddress, forType: .string)
                            #endif
                            withAnimation { showCopiedToast = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation { showCopiedToast = false }
                            }
                        } label: {
                            Label(showCopiedToast ? "Copied!" : "Copy Address", systemImage: showCopiedToast ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(showCopiedToast ? .green : .purple)
                        
                        #if os(iOS)
                        ShareLink(item: account.pqAccountAddress) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .tint(.purple)
                        #endif
                    }
                    
                    // Security info
                    VStack(spacing: 8) {
                        Label("Quantum-resistant (ML-DSA-44 + ECDSA)", systemImage: "lock.shield.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Label("Counterfactual — deploys on first sweep", systemImage: "circle.dashed")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Label("Unique address per payment for privacy", systemImage: "eye.slash")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        HStack(spacing: 4) {
                            Image(systemName: "diamond.fill")
                                .font(.system(size: 8))
                                .foregroundColor(.cyan)
                            Text("Arbitrum Sepolia (L2)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .background(Color(.systemGray).opacity(0.05))
                    .cornerRadius(8)
                }
                .padding()
            }
            .navigationTitle("Receive (PQ)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
    
    // MARK: - QR Code Generation
    
    #if os(iOS)
    private func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    #else
    private func generateQRCode(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
    #endif
}

// MARK: - ViewModel

/// ViewModel bridging StealthPQAccountManager to SwiftUI
@MainActor
class StealthPQAccountViewModel: ObservableObject {
    @Published var accounts: [StealthPQAccount] = []
    @Published var currentAccount: StealthPQAccount?
    @Published var isScanning = false
    @Published var isGenerating = false
    @Published var pqENSName: String?
    @Published var sweepResults: [UInt32: String] = [:] // index → userOpHash
    
    let manager: StealthPQAccountManager
    private let signer: PQTransactionSigner
    let namestoneService: NamestoneService
    private let ensUsername: String?
    
    /// The bare label (e.g. "alice") extracted from whatever format ensUsername was in.
    var ensLabel: String? {
        guard let raw = ensUsername else { return nil }
        // Strip any trailing .dstealth.eth or .pq.dstealth.eth suffix
        let label = raw
            .replacingOccurrences(of: ".pq.dstealth.eth", with: "")
            .replacingOccurrences(of: ".dstealth.eth", with: "")
        return label.isEmpty ? nil : label
    }
    
    var fundedAccounts: [StealthPQAccount] {
        accounts.filter { $0.isFunded }
    }
    
    var sweepableAccounts: [StealthPQAccount] {
        accounts.filter { $0.canSweep(minimumWei: StealthPQAccountManager.minimumSweepBalanceWei) }
    }
    
    init(
        manager: StealthPQAccountManager,
        signer: PQTransactionSigner,
        namestoneService: NamestoneService = .shared,
        ensUsername: String? = nil
    ) {
        self.manager = manager
        self.signer = signer
        self.namestoneService = namestoneService
        self.ensUsername = ensUsername
        
        // Build full PQ ENS name from bare label
        let label = ensUsername?
            .replacingOccurrences(of: ".pq.dstealth.eth", with: "")
            .replacingOccurrences(of: ".dstealth.eth", with: "")
        if let label, !label.isEmpty {
            self.pqENSName = "\(label).pq.dstealth.eth"
        }
    }
    
    /// Update the PQ ENS name after the user edits it.
    func updatePQENSName(_ newLabel: String) {
        self.pqENSName = "\(newLabel.lowercased()).pq.dstealth.eth"
    }
    
    /// Load already-persisted accounts from disk (no network calls).
    func loadAccounts() async {
        await manager.loadPersistedAccounts()
        self.accounts = await manager.allAccounts
        self.currentAccount = await manager.latestAccount
    }
    
    /// Generate the next stealth PQ account explicitly.
    /// Mirrors the EOA "Generate" button pattern.
    func generateNextAccount() async {
        isGenerating = true
        defer { isGenerating = false }
        
        do {
            let account = try await manager.generateNextAccount()
            self.accounts = await manager.allAccounts
            self.currentAccount = account
        } catch {
            print("Failed to generate stealth PQ account: \(error)")
        }
    }
    
    /// Scan **already-generated** stealth PQ accounts for balances.
    /// Does NOT create any new accounts.
    func scanBalances() async {
        guard !accounts.isEmpty else { return }
        
        isScanning = true
        defer { isScanning = false }
        
        do {
            let scanned = try await manager.scanBalances()
            self.accounts = scanned
            self.currentAccount = await manager.latestAccount
        } catch {
            print("Stealth PQ scan failed: \(error)")
        }
    }
    
    /// Sweep a single stealth account to the main PQ account.
    /// The sweep amount is auto-computed: balance - actual gas cost.
    /// No hardcoded gas reserve — uses live bundler gas estimation.
    func sweep(account: StealthPQAccount) async {
        do {
            let mainAccountAddress = try await signer.getAccountAddress()
            let stealthKey = try await manager.getStealthPrivateKey(at: account.index)
            
            let result = try await signer.sweepStealthAccount(
                stealthAccount: account,
                stealthPrivateKey: stealthKey,
                destinationAddress: mainAccountAddress
            )
            
            sweepResults[account.index] = result.userOpHash
            
            print("Swept \(String(format: "%.6f", result.sweepAmountETH)) ETH from stealth #\(account.index) (gas: \(String(format: "%.6f", result.gasCostETH)) ETH)")
            
            // After sweep, advance the index and rotate ENS
            let newIndex = await manager.advanceIndex()
            await rotateENS(toIndex: newIndex)
            
            // Rescan balances
            await scanBalances()
        } catch {
            print("Sweep failed for account #\(account.index): \(error)")
        }
    }
    
    /// Sweep all sweepable accounts sequentially
    func sweepAll() async {
        for account in sweepableAccounts {
            await sweep(account: account)
        }
    }
    
    /// Register or rotate the pq.dstealth.eth ENS name
    func registerENS() async {
        guard let label = ensLabel else { return }
        
        do {
            // Only register if the user has explicitly generated at least one account
            guard let latest = await manager.latestAccount else { return }
            let index = await manager.currentDerivationIndex
            
            _ = try await namestoneService.setStealthPQAccountName(
                name: label,
                pqAccountAddress: latest.pqAccountAddress,
                stealthIndex: index
            )
            
            self.pqENSName = "\(label).pq.dstealth.eth"
        } catch {
            print("Failed to register pq.dstealth.eth: \(error)")
        }
    }
    
    /// Rotate ENS to point at a new stealth index
    private func rotateENS(toIndex index: UInt32) async {
        guard let label = ensLabel else { return }
        
        do {
            let account = try await manager.getStealthPQAccount(at: index)
            _ = try await namestoneService.rotateStealthPQAddress(
                name: label,
                newPQAccountAddress: account.pqAccountAddress,
                newStealthIndex: index
            )
        } catch {
            print("Failed to rotate pq.dstealth.eth: \(error)")
        }
    }
}
