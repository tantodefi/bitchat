//
// WalletView.swift
// bitchat
//
// Clean wallet UI showing QR code, address, and balances.
// Fetches balances privately via Flashbots Protect RPC over Tor.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - Account Mode

/// Switches between EOA (externally owned account) and PQ smart contract wallet
enum AccountMode: String, CaseIterable {
    case eoa = "EOA"
    case pqAccount = "PQ Account"
}

/// Main wallet view showing address QR code, copyable address, and balances
struct WalletView: View {
    let wallet: EmbeddedWallet
    @EnvironmentObject var xmtpContainer: XMTPServiceContainer
    
    /// Use the balance service from the container for shared testnet mode state
    private var balanceService: EthereumBalanceService {
        xmtpContainer.balanceService
    }
    
    @State private var address: String = ""
    @State private var isLoading: Bool = true
    @State private var loadError: String?
    @State private var showCopiedToast: Bool = false
    @State private var copiedText: String = "Address copied!"
    @State private var showSendSheet: Bool = false
    @State private var showHistorySheet: Bool = false
    @State private var showStealthSheet: Bool = false
    @State private var showCrossChainSheet: Bool = false
    @State private var showPQStealthSheet: Bool = false
    @State private var showPQSettingsSheet: Bool = false
    
    // Account mode toggle
    @AppStorage("active-account-mode") private var activeAccountMode: AccountMode = .eoa
    @StateObject private var pqViewModel = PQAccountViewModel()
    
    // Stealth PQ account support (lazily initialised after container is ready)
    @State private var stealthPQViewModel: StealthPQAccountViewModel?
    
    // Track the address we're fetching balances for to avoid race conditions
    @State private var currentFetchAddress: String = ""
    
    // Cancellable task for mode-switch fetches — cancelled on re-toggle
    @State private var balanceFetchTask: Task<Void, Never>?
    
    // Stealth address support
    @StateObject private var stealthStore = StealthAddressStore()
    private var stealthManager: StealthAddressManager {
        StealthAddressManager(wallet: wallet)
    }
    
    // Cross-chain support
    private var eilManager: EILCrossChainManager {
        EILCrossChainManager(wallet: wallet)
    }
    
    // ENS name support - uses App Group for persistence across reinstalls
    @AppStorage("ensSubdomain", store: UserDefaults(suiteName: BitchatApp.groupID)) private var ensSubdomain: String?
    
    // Beta warning - show once across both WalletView and WalletSettingsView
    @AppStorage("wallet-beta-warning-accepted") private var betaWarningAccepted: Bool = false
    @State private var showBetaWarning: Bool = false
    
    // Auto-refresh timer
    private let refreshInterval: TimeInterval = 15
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // MARK: - Account Mode Picker
                // Show if PQ is deployed, OR if user is already in PQ mode
                // (persisted via @AppStorage) — so they can always switch back to EOA.
                if pqViewModel.state.isDeployed || activeAccountMode == .pqAccount {
                    accountModePicker
                }
                
                // MARK: - PQ Account Badge (when in PQ mode)
                if activeAccountMode == .pqAccount && pqViewModel.state.isDeployed {
                    pqBadgeSection
                }
                
                // MARK: - QR Code
                if !displayAddress.isEmpty {
                    qrCodeSection
                }
                
                // MARK: - ENS Name (EOA only)
                if activeAccountMode == .eoa && !address.isEmpty {
                    ensNameSection
                }
                
                // MARK: - Address
                if !displayAddress.isEmpty {
                    addressSection
                }
                
                // MARK: - XMTP Inbox ID
                if let inboxId = xmtpContainer.clientService.inboxId {
                    xmtpInboxSection(inboxId: inboxId)
                    
                    if activeAccountMode == .pqAccount {
                        Text("This Inbox ID belongs to your EOA signing key. Your PQ smart account shares it because XMTP identity is tied to the signer, not the contract address.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                    }
                }
                
                // MARK: - Loading / Error
                if isLoading && displayAddress.isEmpty {
                    ProgressView("Loading wallet...")
                        .padding()
                }
                if let error = loadError {
                    errorSection(error)
                }
                
                // MARK: - Balances
                if !displayAddress.isEmpty {
                    balancesSection
                }
                
                // MARK: - Actions
                if !displayAddress.isEmpty {
                    actionsSection
                }
                
                // MARK: - Stealth Addresses (EOA only)
                if activeAccountMode == .eoa && !address.isEmpty {
                    stealthSection
                }
                
                // MARK: - Stealth PQ Accounts (PQ mode)
                if activeAccountMode == .pqAccount && pqViewModel.state.isDeployed {
                    pqStealthSection
                }
                
                // MARK: - PQ Account Settings (PQ mode)
                if activeAccountMode == .pqAccount {
                    pqSettingsSection
                }
                
                // MARK: - Cross-Chain Swaps (EOA only)
                if activeAccountMode == .eoa && !address.isEmpty {
                    crossChainSection
                }
            }
            .padding()
        }
        .navigationTitle(activeAccountMode == .pqAccount ? "PQ Wallet" : "Wallet")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            // Coordinated startup flow — designed to show cached data
            // immediately so the wallet is usable offline:
            // 1. Load EOA address (local keychain, instant)
            // 2. Restore PQ cached state (local, instant)
            // 3. Load cached balances and stop blocking the UI
            // 4. Run PQ network init + balance fetches in background
            await loadWallet()
            
            // Configure PQ view model and restore cached state immediately
            // (before initializeKeys, which may need network)
            if XMTPServiceContainer.isConfigured {
                let container = XMTPServiceContainer.shared
                pqViewModel.configure(
                    pqKeyManager: container.pqKeyManager,
                    chainServiceSets: Array(container.pqChainServices.values)
                )
                // Restore cached PQ address so displayAddress works immediately
                // for users in PQ mode even before initializeKeys completes.
                pqViewModel.restoreCachedAddressIfNeeded()
            }
            
            // Load cached balances immediately so the UI isn't empty
            let earlyAddress = displayAddress
            if !earlyAddress.isEmpty {
                currentFetchAddress = earlyAddress
                balanceService.loadCachedBalances(for: earlyAddress)
            }
            
            // ── UI is now unblocked — address + cached balances are available ──
            isLoading = false
            
            // ── Background: Kick Helios if it failed to auto-start ──
            HeliosManager.shared.restartIfNeeded()
            
            // ── Background: PQ network initialization ──
            if XMTPServiceContainer.isConfigured {
                await pqViewModel.initializeKeys(from: wallet)
                
                // After PQ init the displayAddress may change (e.g. PQ address
                // computed for first time). Re-sync if needed.
                let postPQAddress = displayAddress
                if !postPQAddress.isEmpty && postPQAddress != currentFetchAddress {
                    currentFetchAddress = postPQAddress
                    balanceService.clearBalances()
                    balanceService.loadCachedBalances(for: postPQAddress)
                }
            }
            
            // ── Background: Stealth PQ view model ──
            if stealthPQViewModel == nil, XMTPServiceContainer.isConfigured {
                let container = XMTPServiceContainer.shared
                let arbSepolia = StealthPQAccountManager.defaultChain.chainId
                if let chainSet = container.pqChainServices[arbSepolia] {
                    let manager = StealthPQAccountManager(
                        wallet: wallet,
                        stealthAddressManager: stealthManager,
                        pqKeyManager: container.pqKeyManager,
                        deployer: chainSet.deployer,
                        balanceService: balanceService
                    )
                    stealthPQViewModel = StealthPQAccountViewModel(
                        manager: manager,
                        signer: chainSet.signer,
                        ensUsername: ensSubdomain
                    )
                }
            }
            
            // ── Background: Fetch fresh balances from network ──
            let targetAddress = displayAddress
            guard !targetAddress.isEmpty else { return }
            currentFetchAddress = targetAddress
            await balanceService.fetchBalances(for: targetAddress)
            
            // Auto-refresh balances periodically
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(refreshInterval))
                guard !Task.isCancelled else { break }
                let addr = displayAddress
                // Skip if address changed (user switched modes)
                guard addr == currentFetchAddress && !addr.isEmpty else { continue }
                await balanceService.fetchBalances(for: addr)
                // Re-verify after fetch: if the user toggled during the await,
                // clearBalances()+fetchGeneration already discarded stale results,
                // but double-check we don't leave isLoading in a bad state.
                guard addr == currentFetchAddress else { continue }
            }
        }
        .onChange(of: activeAccountMode) { _ in
            // Cancel any in-flight fetch from a previous toggle
            balanceFetchTask?.cancel()
            balanceFetchTask = nil
            
            let newAddress = displayAddress
            guard !newAddress.isEmpty else { return }
            currentFetchAddress = newAddress
            // clearBalances() also bumps the fetch generation, which makes
            // any still-running fetchBalances() discard its remaining results.
            balanceService.clearBalances()
            // Immediately load cached balances for the new address so the UI
            // doesn't flash empty while the network fetch runs.
            balanceService.loadCachedBalances(for: newAddress)
            balanceFetchTask = Task {
                // Re-check after potential suspension
                guard !Task.isCancelled, displayAddress == newAddress else { return }
                await balanceService.fetchBalances(for: newAddress)
            }
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
        .overlay(alignment: .bottom) {
            if showCopiedToast {
                copiedToast
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: showCopiedToast)
        .sheet(isPresented: $showSendSheet) {
            SendTransactionView(
                wallet: wallet,
                balanceService: balanceService,
                meshRelay: xmtpContainer.meshTransactionRelay,
                onSuccess: {
                    // Refresh balances after successful send
                    Task {
                        await balanceService.fetchBalances(for: displayAddress)
                    }
                },
                accountMode: activeAccountMode,
                pqViewModel: activeAccountMode == .pqAccount ? pqViewModel : nil,
                senderAddress: displayAddress
            )
        }
        .sheet(isPresented: $showHistorySheet) {
            TransactionHistoryView(
                meshRelay: xmtpContainer.meshTransactionRelay,
                balanceService: balanceService,
                filterAddress: displayAddress,
                pqAddress: activeAccountMode == .pqAccount ? pqViewModel.accountAddress : nil
            )
        }
        .sheet(isPresented: $showStealthSheet) {
            NavigationStack {
                StealthAddressListView(
                    store: stealthStore,
                    stealthManager: stealthManager,
                    balanceService: balanceService
                )
            }
        }
        .sheet(isPresented: $showCrossChainSheet) {
            CrossChainSwapView(
                wallet: wallet,
                eilManager: eilManager,
                balanceService: balanceService
            )
        }
        .sheet(isPresented: $showPQStealthSheet) {
            NavigationStack {
                if let vm = stealthPQViewModel {
                    StealthPQAccountListView(viewModel: vm)
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text("PQ services not available")
                            .font(.headline)
                        Text("Ensure a Pimlico API key is configured and the PQ account is deployed.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .navigationTitle("Stealth PQ Accounts")
                }
            }
        }
        .sheet(isPresented: $showPQSettingsSheet) {
            NavigationStack {
                WalletSettingsView(
                    meshTransactionRelay: xmtpContainer.meshTransactionRelay,
                    balanceService: balanceService,
                    wallet: wallet
                )
            }
        }
    }
    
    // MARK: - Computed Properties
    
    /// The address to display based on active account mode
    private var displayAddress: String {
        if activeAccountMode == .pqAccount, let pqAddr = pqViewModel.accountAddress {
            return pqAddr
        }
        return address
    }
    
    // MARK: - Sections
    
    private var accountModePicker: some View {
        Picker("Account", selection: $activeAccountMode) {
            Text("EOA").tag(AccountMode.eoa)
            Text("🛡 PQ Account").tag(AccountMode.pqAccount)
        }
        .pickerStyle(.segmented)
    }
    
    private var pqBadgeSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "shield.checkered")
                .font(.title3)
                .foregroundColor(.green)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Quantum-Resistant Account")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                Text("Hybrid ECDSA + ML-DSA-44 · ERC-4337")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Show deployed chains
            let deployedChains = pqViewModel.chainStatuses.filter(\.isDeployed)
            if !deployedChains.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(deployedChains) { chain in
                        Text(chain.displayName)
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }
            }
        }
        .padding()
        .background(Color.green.opacity(0.1))
        .cornerRadius(12)
    }
    
    private var qrCodeSection: some View {
        VStack(spacing: 16) {
            if let qrImage = generateQRCode(from: displayAddress) {
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
            
            Text("Scan to receive")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var ensNameSection: some View {
        Group {
            if let ensName = ensSubdomain {
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        // ENS name display
                        HStack(spacing: 8) {
                            Image(systemName: "globe")
                                .font(.body)
                                .foregroundColor(.accentColor)
                            
                            Text(ensName)
                                .font(.system(.headline, design: .rounded))
                                .foregroundColor(.primary)
                        }
                        
                        Spacer()
                        
                        // Copy button
                        Button {
                            copyENSName(ensName)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Copy ENS name")
                        
                        // Edit button - navigate to ENS settings
                        NavigationLink {
                            ENSSettingsView(
                                currentName: ensName,
                                walletAddress: address,
                                xmtpInboxId: xmtpContainer.clientService.inboxId,
                                onNameChanged: { newName in
                                    ensSubdomain = newName
                                }
                            )
                        } label: {
                            Image(systemName: "pencil.circle.fill")
                                .font(.title3)
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.borderless)
                        .help("Edit ENS name")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(10)
                }
            }
        }
    }
    
    private func copyENSName(_ name: String) {
        #if os(iOS)
        UIPasteboard.general.string = name
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)
        #endif
        
        copiedText = "ENS name copied!"
        showCopiedToast = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCopiedToast = false
        }
    }
    
    private var addressSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text(activeAccountMode == .pqAccount ? "PQ Account Address" : "Your Address")
                    .font(.headline)
                
                if activeAccountMode == .pqAccount {
                    Image(systemName: "shield.checkered")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            
            HStack {
                Text(truncatedDisplayAddress)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.primary)
                
                Spacer()
                
                Button {
                    copyDisplayAddress()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .help("Copy address")
            }
            .padding()
            .background(Color(.systemGray).opacity(0.15))
            .cornerRadius(8)
            
            Text(displayAddress)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
    }
    
    private var balancesSection: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Balances")
                    .font(.headline)
                
                Spacer()
                
                if balanceService.isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Button {
                        Task {
                            await balanceService.fetchBalances(for: displayAddress)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.body)
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh balances")
                }
            }
            
            if let error = balanceService.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            // Show active networks based on mainnet/testnet mode
            // For PQ accounts, only show chains where the account is deployed
            let allNetworks = balanceService.useTestnet ? EthereumBalanceService.Network.testnets : EthereumBalanceService.Network.mainnets
            let networks: [EthereumBalanceService.Network] = {
                if activeAccountMode == .pqAccount {
                    let deployedChainIds = Set(pqViewModel.chainStatuses.filter(\.isDeployed).map { $0.chain.chainId })
                    return allNetworks.filter { deployedChainIds.contains(UInt64($0.chainId)) }
                }
                return allNetworks
            }()
            ForEach(networks, id: \.self) { network in
                balanceRow(for: network)
            }
            
            HStack {
                Image(systemName: balanceService.useTestnet ? "testtube.2" : "shield.checkered")
                    .foregroundColor(balanceService.useTestnet ? .orange : .green)
                Text(balanceService.useTestnet ? "Testnet Mode" : "Mainnet")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            // Offline / stale cache indicator
            if balanceService.isShowingCachedBalances {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.slash")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    Text("Showing cached balances (offline)")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }
        }
    }
    
    private var actionsSection: some View {
        VStack(spacing: 12) {
            Text("Actions")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            HStack(spacing: 16) {
                Button {
                    showSendSheet = true
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                        Text("Send")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                
                Button {
                    copyDisplayAddress()
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title)
                        Text("Receive")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                
                Button {
                    showHistorySheet = true
                } label: {
                    VStack(spacing: 8) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.title)
                            
                            // Badge for pending transactions
                            let pendingCount = xmtpContainer.meshTransactionRelay.pendingRelays.count
                            if pendingCount > 0 {
                                Text("\(pendingCount)")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                                    .padding(4)
                                    .background(Color.orange)
                                    .clipShape(Circle())
                                    .offset(x: 8, y: -4)
                            }
                        }
                        Text("History")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.purple.opacity(0.1))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
            }
            
            // Pending transactions indicator
            let currentAddr = displayAddress.lowercased()
            let filteredConfirmed = xmtpContainer.meshTransactionRelay.confirmedTransactions.filter { tx in
                let from = tx.fromAddress?.lowercased() ?? currentAddr
                return from == currentAddr || tx.toAddress.lowercased() == currentAddr
            }
            let txCount = xmtpContainer.meshTransactionRelay.pendingRelays.count + filteredConfirmed.count
            if txCount > 0 {
                Button {
                    showHistorySheet = true
                } label:{
                    HStack {
                        if xmtpContainer.meshTransactionRelay.pendingRelays.isEmpty {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("\(filteredConfirmed.count) confirmed transaction(s)")
                        } else {
                            Image(systemName: "clock.badge.fill")
                                .foregroundColor(.orange)
                            Text("\(xmtpContainer.meshTransactionRelay.pendingRelays.count) pending transaction(s)")
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    private var stealthSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Private Receiving")
                    .font(.headline)
                
                Spacer()
                
                if stealthStore.withBalanceCount > 0 {
                    Text("\(stealthStore.withBalanceCount) with balance")
                        .font(.caption)
                        .foregroundColor(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.15))
                        .cornerRadius(8)
                }
            }
            
            Button {
                showStealthSheet = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "eye.slash.fill")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stealth Addresses")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Text("EIP-5564 privacy receiving")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    HStack(spacing: 4) {
                        if stealthStore.totalCount > 0 {
                            Text("\(stealthStore.totalCount)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(Color(.systemGray).opacity(0.1))
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            
            Text("Receive payments to unique addresses that only you can identify and spend from.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - PQ Stealth Section
    
    private var pqStealthSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Private Receiving (PQ)")
                    .font(.headline)
                
                Spacer()
                
                if let vm = stealthPQViewModel, !vm.fundedAccounts.isEmpty {
                    Text("\(vm.fundedAccounts.count) funded")
                        .font(.caption)
                        .foregroundColor(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.15))
                        .cornerRadius(8)
                }
            }
            
            Button {
                showPQStealthSheet = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                        .font(.title2)
                        .foregroundColor(.purple)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stealth PQ Accounts")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        HStack(spacing: 4) {
                            Image(systemName: "diamond.fill")
                                .font(.system(size: 8))
                                .foregroundColor(.cyan)
                            Text("Arbitrum Sepolia")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    HStack(spacing: 4) {
                        if let vm = stealthPQViewModel, !vm.accounts.isEmpty {
                            Text("\(vm.accounts.count)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(Color.purple.opacity(0.1))
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            
            Text("Each payment uses a unique PQ Account address derived from your stealth keys. Funds are swept to your main account.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                Text("L2 only — PQ account deployment requires ~5-15M gas, viable only on Arbitrum.")
                    .font(.caption2)
            }
            .foregroundColor(.secondary.opacity(0.8))
        }
    }
    
    // MARK: - PQ Account Settings Section
    
    private var pqSettingsSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("PQ Account Settings")
                    .font(.headline)
                
                Spacer()
            }
            
            // Deployment status row
            Button {
                showPQSettingsSheet = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape.fill")
                        .font(.title2)
                        .foregroundColor(.orange)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Deployment & Keys")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        if pqViewModel.state.isDeployed {
                            let deployedCount = pqViewModel.chainStatuses.filter(\.isDeployed).count
                            let totalCount = pqViewModel.chainStatuses.count
                            Text("Deployed on \(deployedCount)/\(totalCount) chains")
                                .font(.caption)
                                .foregroundColor(.green)
                        } else {
                            Text(pqViewModel.state.displayStatus)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            
            // ENS name row (if configured)
            if let ensName = ensSubdomain {
                let ensLabel = ensName
                    .replacingOccurrences(of: ".pq.dstealth.eth", with: "")
                    .replacingOccurrences(of: ".dstealth.eth", with: "")
                
                VStack(spacing: 8) {
                    // EOA ENS identity row
                    HStack(spacing: 12) {
                        Image(systemName: "globe")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("EOA Identity")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            
                            Text("\(ensLabel).dstealth.eth")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        NavigationLink {
                            ENSSettingsView(
                                currentName: "\(ensLabel).dstealth.eth",
                                walletAddress: address,
                                xmtpInboxId: xmtpContainer.clientService.inboxId,
                                onNameChanged: { newName in
                                    ensSubdomain = newName
                                }
                            )
                        } label: {
                            Image(systemName: "pencil.circle.fill")
                                .font(.title3)
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding()
                    .background(Color.accentColor.opacity(0.08))
                    .cornerRadius(12)
                    
                    // PQ ENS identity row
                    if let pqName = stealthPQViewModel?.pqENSName {
                        HStack(spacing: 12) {
                            Image(systemName: "shield.lefthalf.filled")
                                .font(.title2)
                                .foregroundColor(.purple)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("PQ Stealth Identity")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                
                                Text(pqName)
                                    .font(.caption)
                                    .foregroundColor(.purple)
                            }
                            
                            Spacer()
                            
                            if let vm = stealthPQViewModel {
                                NavigationLink {
                                    PQENSSettingsView(
                                        currentPQName: pqName,
                                        pqAccountAddress: vm.currentAccount?.pqAccountAddress ?? address,
                                        stealthIndex: UInt32(vm.accounts.count),
                                        viewModel: vm
                                    )
                                } label: {
                                    Image(systemName: "pencil.circle.fill")
                                        .font(.title3)
                                        .foregroundColor(.purple)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding()
                        .background(Color.purple.opacity(0.08))
                        .cornerRadius(12)
                    }
                }
            }
            
            // Seed export shortcut
            if pqViewModel.state != .notInitialized {
                HStack(spacing: 12) {
                    Image(systemName: "key.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PQ Seed Backup")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Text("Export ML-DSA-44 seed phrase")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.systemGray).opacity(0.1))
                .cornerRadius(12)
                .onTapGesture {
                    showPQSettingsSheet = true
                }
            }
        }
    }
    
    private var crossChainSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Cross-Chain")
                    .font(.headline)
                
                Spacer()
            }
            
            Button {
                showCrossChainSheet = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.left.arrow.right.circle.fill")
                        .font(.title2)
                        .foregroundColor(.purple)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cross-Chain Swap")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Text("EIP-7702 + EIL atomic swaps")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.systemGray).opacity(0.1))
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            
            Text("Swap assets between chains using EIL's trustless liquidity network.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private func balanceRow(for network: EthereumBalanceService.Network) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(network.rawValue)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                if let balance = balanceService.balances[network] {
                    HStack(spacing: 4) {
                        Text(formatLastUpdated(balance.lastUpdated))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        // Verification level badge
                        switch balance.verificationLevel {
                        case .heliosVerified:
                            Image(systemName: "checkmark.shield.fill")
                                .font(.caption2)
                                .foregroundColor(.green)
                                .help("Trustlessly verified via Helios light client")
                        case .proofConsistent:
                            Image(systemName: "shield.lefthalf.filled")
                                .font(.caption2)
                                .foregroundColor(.yellow)
                                .help("Proof-consistent (state root from RPC, not independently verified)")
                        case .unverified:
                            Image(systemName: "shield.slash")
                                .font(.caption2)
                                .foregroundColor(.orange)
                                .help("Unverified — RPC trusted")
                        case .pending:
                            ProgressView()
                                .scaleEffect(0.6)
                                .help("Balance fetch in progress")
                        }
                    }
                }
            }
            
            Spacer()
            
            if let balance = balanceService.balances[network] {
                Text("\(balance.formattedETH) ETH")
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
            } else {
                Text("—")
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.systemGray).opacity(0.1))
        .cornerRadius(8)
    }
    
    private func errorSection(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)
            
            Text(error)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button("Retry") {
                Task { await loadWallet() }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
    
    private var copiedToast: some View {
        Text(copiedText)
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.8))
            .cornerRadius(20)
            .padding(.bottom, 32)
    }
    
    private func xmtpInboxSection(inboxId: String) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .foregroundColor(.blue)
                Text("XMTP Inbox ID")
                    .font(.headline)
            }
            
            HStack {
                Text(truncateInboxId(inboxId))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.primary)
                
                Spacer()
                
                Button {
                    copyInboxId(inboxId)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .help("Copy XMTP inbox ID")
            }
            .padding()
            .background(Color.blue.opacity(0.1))
            .cornerRadius(8)
            
            Text("Share this ID for secure wallet messaging")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private func truncateInboxId(_ id: String) -> String {
        guard id.count > 24 else { return id }
        return String(id.prefix(12)) + "…" + String(id.suffix(8))
    }
    
    private func copyInboxId(_ id: String) {
        #if os(iOS)
        UIPasteboard.general.string = id
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
        #endif
        
        copiedText = "Inbox ID copied!"
        showCopiedToast = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCopiedToast = false
        }
    }
    
    private var truncatedAddress: String {
        guard address.count > 16 else { return address }
        return String(address.prefix(8)) + "…" + String(address.suffix(6))
    }
    
    private var truncatedDisplayAddress: String {
        let addr = displayAddress
        guard addr.count > 16 else { return addr }
        return String(addr.prefix(8)) + "…" + String(addr.suffix(6))
    }
    
    // MARK: - Actions
    
    private func loadWallet() async {
        isLoading = true
        loadError = nil
        
        do {
            let addr = try await wallet.getAddress()
            address = addr
        } catch {
            loadError = error.localizedDescription
        }
        
        // isLoading is cleared by the caller after balance fetch completes
    }
    
    private func copyDisplayAddress() {
        let addr = displayAddress
        #if os(iOS)
        UIPasteboard.general.string = addr
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(addr, forType: .string)
        #endif
        
        copiedText = activeAccountMode == .pqAccount ? "PQ address copied!" : "Address copied!"
        showCopiedToast = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCopiedToast = false
        }
    }
    
    private func formatLastUpdated(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    
    // MARK: - QR Code Generation
    
    #if os(iOS)
    private func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        
        guard let outputImage = filter.outputImage else { return nil }
        
        // Scale up for crisp rendering
        let scale = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = outputImage.transformed(by: scale)
        
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }
        
        return UIImage(cgImage: cgImage)
    }
    #else
    private func generateQRCode(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        
        guard let outputImage = filter.outputImage else { return nil }
        
        // Scale up for crisp rendering
        let scale = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = outputImage.transformed(by: scale)
        
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }
        
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
    #endif
}

// MARK: - Preview

#if DEBUG
struct WalletView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            WalletView(wallet: EmbeddedWallet(keychain: PreviewKeychainManager()))
                .environmentObject(XMTPServiceContainer.configure(keychain: PreviewKeychainManager()))
        }
    }
}
#endif
