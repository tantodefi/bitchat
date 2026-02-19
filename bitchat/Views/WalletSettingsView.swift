//
// WalletSettingsView.swift
// bitchat
//
// Settings UI for wallet configuration including transaction relay,
// stealth addresses, and cross-chain features.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// Settings view for wallet and transaction configuration
struct WalletSettingsView: View {
    @ObservedObject var meshTransactionRelay: MeshTransactionRelay
    @ObservedObject var balanceService: EthereumBalanceService
    let wallet: EmbeddedWallet
    
    @State private var showingClearConfirmation = false
    @State private var showingExportConfirmation = false
    @State private var exportedPrivateKey: IdentifiableString?
    
    // Stealth and EIL settings
    @AppStorage("enableStealthScanning") private var enableStealthScanning = true
    @AppStorage("enableEILSwaps") private var enableEILSwaps = true
    @AppStorage("stealthScanInterval") private var stealthScanInterval: Double = 60 // seconds
    
    // ENS settings - uses App Group for persistence across reinstalls
    @AppStorage("ensSubdomain", store: UserDefaults(suiteName: BitchatApp.groupID)) private var ensSubdomain: String?
    @State private var walletAddress: String = ""
    @State private var xmtpInboxId: String?
    
    // Beta warning - show once across both WalletView and WalletSettingsView
    @AppStorage("wallet-beta-warning-accepted") private var betaWarningAccepted: Bool = false
    @State private var showBetaWarning: Bool = false
    
    // PQ Account
    @StateObject private var pqViewModel = PQAccountViewModel()
    @State private var exportedPQSeed: IdentifiableString?
    
    // Helios
    @State private var isStartingHelios = false
    
    var body: some View {
        List {
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
                            Text(balanceService.useTestnet ? "Using Sepolia & Arbitrum Sepolia testnets" : "Using Ethereum, Base & Arbitrum mainnet")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: balanceService.useTestnet ? "testtube.2" : "network")
                    }
                }
                .tint(.orange)
                
                // Proof verification toggle (Phase 1 — proof-consistent, not fully trustless)
                Toggle(isOn: $balanceService.proofVerificationEnabled) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Merkle Proof Checking")
                            Text(balanceService.proofVerificationEnabled
                                 ? "Proofs checked via eth_getProof (state root still from RPC)"
                                 : "Trusting RPC responses (unverified)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if balanceService.proofStats.totalQueries > 0 {
                                let stats = balanceService.proofStats
                                Text("✓ \(stats.proofVerified)/\(stats.totalQueries) proof-consistent" +
                                     (stats.mismatchDetected > 0 ? " • ⚠️ \(stats.mismatchDetected) mismatches!" : ""))
                                    .font(.caption2)
                                    .foregroundColor(stats.mismatchDetected > 0 ? .red : .green)
                            }
                        }
                    } icon: {
                        Image(systemName: balanceService.proofVerificationEnabled ? "shield.lefthalf.filled" : "shield.slash")
                    }
                }
                .tint(.yellow)
                
                // Helios Light Client status
                heliosStatusRow
                
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
                
                Button {
                    showingExportConfirmation = true
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Export Private Key")
                            Text("Backup your wallet key securely")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "key.fill")
                    }
                }
            } header: {
                Text("Wallet")
            } footer: {
                Text("Testnet mode uses Sepolia for testing without real funds.")
            }
            
            // MARK: - Post-Quantum Account
            Section {
                // PQ Key Status
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ML-DSA-44 Keys")
                            Text(pqViewModel.state.displayStatus)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: pqViewModel.state.isDeployed ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                            .foregroundColor(pqViewModel.state.isDeployed ? .green : .orange)
                    }
                    
                    Spacer()
                    
                    if case .notInitialized = pqViewModel.state {
                        Button("Initialize") {
                            Task {
                                await pqViewModel.initializeKeys(from: wallet)
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    } else if case .initializing = pqViewModel.state {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else if case .error = pqViewModel.state {
                        Button("Retry") {
                            Task {
                                await pqViewModel.initializeKeys(from: wallet)
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
                
                // PQ Account Address
                if let address = pqViewModel.accountAddress {
                    HStack {
                        Text("Account")
                        Spacer()
                        Text(address.prefix(8) + "..." + address.suffix(4))
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }
                }
                
                // PQ Public Key (truncated)
                if let pkHex = pqViewModel.pqPublicKeyHex {
                    HStack {
                        Text("Public Key")
                        Spacer()
                        Text(pkHex)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }
                }
                
                // Chain selector + deploy (shown when keys are ready)
                if case .keysReady = pqViewModel.state {
                    // Chain target picker
                    Picker("Deploy Target", selection: $pqViewModel.deployTarget) {
                        ForEach(PQDeployTarget.allCases) { target in
                            Text(target.rawValue).tag(target)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    if pqViewModel.canDeploy {
                        // Per-chain status rows
                        ForEach(pqViewModel.chainStatuses.filter { status in
                            pqViewModel.deployTarget.chains.contains(where: { $0.chainId == status.chain.chainId })
                        }) { status in
                            HStack(spacing: 8) {
                                Image(systemName: status.statusIcon)
                                    .foregroundColor(pqChainStatusColor(status))
                                    .font(.caption)
                                Text(status.displayName)
                                    .font(.caption)
                                Spacer()
                                if status.isDeployed {
                                    Text("Deployed")
                                        .font(.caption2)
                                        .foregroundColor(.green)
                                } else if status.isDeploying {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                } else {
                                    let (sufficient, balance) = pqViewModel.checkDeploymentBalance(
                                        chain: status.chain,
                                        balanceService: balanceService
                                    )
                                    if sufficient {
                                        Text(String(format: "%.4f ETH", balance))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    } else {
                                        Text(String(format: "%.4f ETH ⚠️", balance))
                                            .font(.caption2)
                                            .foregroundColor(.orange)
                                    }
                                }
                            }
                        }
                        
                        // Insufficient gas warning
                        let lowChains = pqViewModel.insufficientBalanceChains(balanceService: balanceService)
                        if !lowChains.isEmpty {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Insufficient gas for deployment")
                                        .font(.caption)
                                    Text("Need ≥ \(String(format: "%.3f", PQAccountViewModel.minimumDeploymentGasETH)) ETH on \(lowChains.map(\.chain.name).joined(separator: " & ")). Use a testnet faucet.")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                            }
                        }
                        
                        // Deploy button
                        if !pqViewModel.allTargetChainsDeployed {
                            Button {
                                Task { await pqViewModel.deployToTarget() }
                            } label: {
                                HStack {
                                    Image(systemName: "arrow.up.circle.fill")
                                    Text("Deploy on \(pqViewModel.deployTarget.rawValue)")
                                }
                                .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .tint(.orange)
                            .disabled(pqViewModel.isAnyTargetDeploying || !lowChains.isEmpty)
                        }
                    } else {
                        // No Pimlico API key — show guidance
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Bundler API key required")
                                    .font(.caption)
                                Text("Add PIMLICO_API_KEY to Secrets.xcconfig to enable on-chain deployment.")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "key.fill")
                                .foregroundColor(.orange)
                        }
                    }
                } else if case .deploying = pqViewModel.state {
                    // Deploying — show per-chain progress
                    ForEach(pqViewModel.chainStatuses.filter { $0.isDeploying || $0.isDeployed }) { status in
                        HStack(spacing: 8) {
                            if status.isDeploying {
                                ProgressView().scaleEffect(0.6)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                            }
                            Text(status.displayName)
                                .font(.caption)
                            Spacer()
                            if status.isDeployed {
                                Text("✓").foregroundColor(.green).font(.caption)
                            } else if let err = status.error {
                                Text(err).font(.caption2).foregroundColor(.red).lineLimit(1)
                            }
                        }
                    }
                } else if case .deployed = pqViewModel.state {
                    // Show per-chain deployment status (deployed + undeployed)
                    ForEach(pqViewModel.chainStatuses) { status in
                        HStack(spacing: 8) {
                            Image(systemName: status.isDeployed ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundColor(status.isDeployed ? .green : .secondary)
                                .font(.caption)
                            Text(status.displayName)
                                .font(.caption)
                            Spacer()
                            if status.isDeployed {
                                Text("Deployed")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                            } else if status.isDeploying {
                                ProgressView().scaleEffect(0.6)
                            } else {
                                Text("Not deployed")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    // Deploy on remaining chains button
                    if pqViewModel.hasUndeployedChains && !pqViewModel.isAnyTargetDeploying {
                        let undeployed = pqViewModel.undeployedChains
                        let names = undeployed.map(\.name).joined(separator: " & ")
                        
                        // Check gas on undeployed chains
                        let lowChains = undeployed.filter { chain in
                            let (sufficient, _) = pqViewModel.checkDeploymentBalance(
                                chain: chain,
                                balanceService: balanceService
                            )
                            return !sufficient
                        }
                        
                        if !lowChains.isEmpty {
                            Label {
                                Text("Need ≥ \(String(format: "%.3f", PQAccountViewModel.minimumDeploymentGasETH)) ETH on \(lowChains.map(\.name).joined(separator: " & "))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                            }
                        }
                        
                        Button {
                            Task { await pqViewModel.deployOnRemainingChains() }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.up.circle.fill")
                                Text("Deploy on \(names)")
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                        .disabled(!lowChains.isEmpty)
                        
                        Text("Same address via CREATE2 — deploy the same Safe on multiple networks.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                // Error display
                if let error = pqViewModel.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                // Export PQ Seed
                if pqViewModel.state != .notInitialized {
                    Button {
                        Task {
                            if let seed = await pqViewModel.exportSeed() {
                                exportedPQSeed = IdentifiableString(value: seed)
                            }
                        }
                    } label: {
                        Label("Export PQ Seed", systemImage: "square.and.arrow.up")
                            .foregroundColor(.orange)
                    }
                }
            } header: {
                Label("Post-Quantum Security", systemImage: "shield.checkered")
            } footer: {
                Text("Hybrid ECDSA + ML-DSA-44 smart account (ERC-4337). Deploy on Sepolia, Arbitrum Sepolia, or both — same address via CREATE2.")
            }
            
            // MARK: - Stealth Addresses
            Section {
                Toggle(isOn: $enableStealthScanning) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Stealth Scanning")
                            Text(enableStealthScanning ? "Scanning for private payments" : "Not scanning")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "eye.slash.fill")
                    }
                }
                
                if enableStealthScanning {
                    HStack {
                        Text("Scan Interval")
                        Spacer()
                        Picker("", selection: $stealthScanInterval) {
                            Text("30 sec").tag(30.0)
                            Text("1 min").tag(60.0)
                            Text("5 min").tag(300.0)
                            Text("15 min").tag(900.0)
                        }
                        .pickerStyle(.menu)
                    }
                }
            } header: {
                Text("Stealth Addresses (EIP-5564)")
            } footer: {
                Text("Stealth addresses let you receive payments privately. Each sender generates a unique address only you can identify.")
            }
            
            // MARK: - ENS Identity
            Section {
                if let ensName = ensSubdomain {
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Current Name")
                                Text(ensName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "globe")
                        }
                        
                        Spacer()
                        
                        NavigationLink {
                            ENSSettingsView(
                                currentName: ensName,
                                walletAddress: walletAddress,
                                xmtpInboxId: xmtpInboxId,
                                onNameChanged: { newName in
                                    ensSubdomain = newName
                                }
                            )
                        } label: {
                            Image(systemName: "pencil")
                                .foregroundColor(.accentColor)
                        }
                    }
                } else {
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("No ENS Name")
                                Text("Name will be registered on first launch")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "globe")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } header: {
                Text("ENS Identity")
            } footer: {
                Text("Your .dstealth.eth name lets others find your wallet and message you easily.")
            }
            
            // MARK: - Cross-Chain Swaps
            Section {
                Toggle(isOn: $enableEILSwaps) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cross-Chain Swaps")
                            Text(enableEILSwaps ? "EIP-7702 + EIL enabled" : "Disabled")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "arrow.left.arrow.right.circle.fill")
                    }
                }
                .tint(.purple)
            } header: {
                Text("Ethereum Interop Layer")
            } footer: {
                Text("Uses EIP-7702 account abstraction to enable trustless cross-chain swaps through XLP liquidity providers.")
            }
        }
        .navigationTitle("Wallet Settings")
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
        .confirmationDialog(
            "Export Private Key?",
            isPresented: $showingExportConfirmation,
            titleVisibility: .visible
        ) {
            Button("Export", role: .destructive) {
                Task {
                    await exportPrivateKey()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your private key controls all funds in your wallet. Never share it with anyone. Store it securely offline.")
        }
        .sheet(item: $exportedPrivateKey) { item in
            PrivateKeyExportSheet(privateKey: item.value, onDismiss: {
                exportedPrivateKey = nil
            })
        }
        .task {
            // Load wallet address for ENS settings
            do {
                walletAddress = try await wallet.getAddress()
            } catch {
                // Silently handle - address not critical for all settings
            }
            
            // Load XMTP inbox ID if available
            if XMTPServiceContainer.isConfigured {
                xmtpInboxId = XMTPServiceContainer.shared.clientService.inboxId
                
                // Configure PQ VM with container services
                let container = XMTPServiceContainer.shared
                pqViewModel.configure(
                    pqKeyManager: container.pqKeyManager,
                    chainServiceSets: Array(container.pqChainServices.values)
                )
                
                // Auto-initialize keys so deployed state is restored on revisit
                await pqViewModel.initializeKeys(from: wallet)
            }
        }
        .sheet(item: $exportedPQSeed) { item in
            PQSeedExportSheet(seed: item.value, onDismiss: {
                exportedPQSeed = nil
            })
        }
        .onAppear {
            // Show beta warning once
            if !betaWarningAccepted {
                showBetaWarning = true
            }
        }
        .alert("⚠️ Beta Wallet", isPresented: $showBetaWarning) {
            Button("Accept") {
                betaWarningAccepted = true
            }
        } message: {
            Text("This wallet is still in beta and under active development.\n\nRecommended: Only use testnet funds for now.\n\nIf you use mainnet funds, make sure to export your private key from Wallet Settings.\n\nThe developer is not responsible for loss of funds. Please be safe.")
        }
    }
    
    private func exportPrivateKey() async {
        do {
            let privateKey = try await wallet.getOrCreatePrivateKey()
            let hex = "0x" + privateKey.map { String(format: "%02x", $0) }.joined()
            exportedPrivateKey = IdentifiableString(value: hex)
        } catch {
            // Handle error silently - user can retry
        }
    }
    
    private func pqChainStatusColor(_ status: PQChainDeploymentStatus) -> Color {
        if status.isDeploying { return .orange }
        if status.isDeployed { return .green }
        if status.error != nil { return .red }
        return .secondary
    }
    
    // MARK: - Helios Status Row
    
    @ViewBuilder
    private var heliosStatusRow: some View {
        let helios = HeliosManager.shared
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Helios Light Client")
                    .font(.body)
                
                if helios.isRunning {
                    switch helios.syncStatus {
                    case .synced(let block):
                        Text("Synced to block \(block)")
                            .font(.caption)
                            .foregroundColor(.green)
                    case .syncing(let progress):
                        Text("Syncing... \(Int(progress * 100))%")
                            .font(.caption)
                            .foregroundColor(.orange)
                    default:
                        Text("Running")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                } else if helios.isFFIAvailable {
                    if isStartingHelios {
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.6)
                            Text("Starting...")
                        }
                        .font(.caption)
                        .foregroundColor(.orange)
                    } else {
                        Text("Available — tap to start")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                } else {
                    Text("Not built — run build-ios.sh in localPackages/HeliosBridge/")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // Show Helios stats from balance service
                let stats = balanceService.proofStats
                if stats.heliosVerified > 0 {
                    Text("✓✓ \(stats.heliosVerified) Helios-verified queries")
                        .font(.caption2)
                        .foregroundColor(.green)
                }
            }
        } icon: {
            Image(systemName: helios.isRunning ? "checkmark.shield.fill" : "shield.righthalf.inset.filled")
                .foregroundColor(helios.isRunning ? .green : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard helios.isFFIAvailable && !helios.isRunning && !isStartingHelios else { return }
            isStartingHelios = true
            let network: HeliosManager.EthereumNetwork = balanceService.useTestnet ? .sepolia : .mainnet
            Task {
                do {
                    // Let HeliosManager auto-detect Tor readiness
                    // (uses Tor if available, direct connection otherwise)
                    try await helios.start(network: network)
                } catch {
                    let torStatus = TorManager.shared.isReady ? "Tor ready" : "Tor not ready"
                    SecureLogger.error("HeliosManager: Manual start failed (\(torStatus)): \(error)", category: .network)
                }
                await MainActor.run { isStartingHelios = false }
            }
        }
    }
}

// MARK: - Identifiable String Wrapper

/// Simple wrapper to make a String usable with .sheet(item:)
struct IdentifiableString: Identifiable {
    let id = UUID()
    let value: String
}

// MARK: - PQ Seed Export Sheet

struct PQSeedExportSheet: View {
    let seed: String
    let onDismiss: () -> Void

    @State private var showKey = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Warning header
                VStack(spacing: 12) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)

                    Text("PQ Secret Key")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("This is your ML-DSA-44 secret key. Anyone with this key can sign as your post-quantum identity. Never share it.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()

                // Key display
                VStack(spacing: 12) {
                    if showKey {
                        ScrollView {
                            Text(seed)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding()
                        }
                        .frame(maxHeight: 200)
                        .background(Color(.systemGray).opacity(0.1))
                        .cornerRadius(8)
                    } else {
                        Button {
                            showKey = true
                        } label: {
                            HStack {
                                Image(systemName: "eye.slash.fill")
                                Text("Tap to reveal")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(.systemGray).opacity(0.1))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }

                    if showKey {
                        Button {
                            #if os(iOS)
                            UIPasteboard.general.string = seed
                            #else
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(seed, forType: .string)
                            #endif
                            copied = true

                            // Clear clipboard after 60 seconds for security
                            Task {
                                try? await Task.sleep(nanoseconds: 60_000_000_000)
                                #if os(iOS)
                                if UIPasteboard.general.string == seed {
                                    UIPasteboard.general.string = ""
                                }
                                #endif
                            }
                        } label: {
                            HStack {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                Text(copied ? "Copied! (clears in 60s)" : "Copy to Clipboard")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)

                // Security tips
                VStack(alignment: .leading, spacing: 8) {
                    Label("Write it down on paper", systemImage: "pencil")
                    Label("Store in a password manager", systemImage: "lock.fill")
                    Label("Never screenshot or email", systemImage: "xmark.circle")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(12)
                .padding(.horizontal)

                Spacer()
            }
            .navigationTitle("PQ Seed Export")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct WalletSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            // Preview placeholder - actual implementation needs real objects
            Text("Wallet Settings Preview")
        }
    }
}
#endif
