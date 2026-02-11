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
    @State private var exportedPrivateKey: String?
    @State private var showingPrivateKey = false
    
    // Stealth and EIL settings
    @AppStorage("enableStealthScanning") private var enableStealthScanning = true
    @AppStorage("enableEILSwaps") private var enableEILSwaps = true
    @AppStorage("stealthScanInterval") private var stealthScanInterval: Double = 60 // seconds
    
    // ENS settings
    @AppStorage("ensSubdomain") private var ensSubdomain: String?
    @State private var walletAddress: String = ""
    @State private var xmtpInboxId: String?
    
    // Beta warning - show once across both WalletView and WalletSettingsView
    @AppStorage("wallet-beta-warning-accepted") private var betaWarningAccepted: Bool = false
    @State private var showBetaWarning: Bool = false
    
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
                            Text(balanceService.useTestnet ? "Using Sepolia testnet" : "Using Ethereum & Base mainnet")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: balanceService.useTestnet ? "testtube.2" : "network")
                    }
                }
                .tint(.orange)
                
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
        .sheet(isPresented: $showingPrivateKey) {
            PrivateKeyExportSheet(privateKey: exportedPrivateKey ?? "", onDismiss: {
                exportedPrivateKey = nil
                showingPrivateKey = false
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
    }
    
    private func exportPrivateKey() async {
        do {
            let privateKey = try await wallet.getOrCreatePrivateKey()
            exportedPrivateKey = "0x" + privateKey.map { String(format: "%02x", $0) }.joined()
            showingPrivateKey = true
        } catch {
            // Handle error silently - user can retry
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
