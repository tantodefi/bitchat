//
// CustomTokenSettingsView.swift
// bitchat
//
// UI for managing custom ERC-20 tokens: view defaults, add new tokens,
// remove custom entries.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// Settings view for managing custom ERC-20 tokens.
struct CustomTokenSettingsView: View {
    @ObservedObject var tokenStore: TokenStore
    @ObservedObject var balanceService: EthereumBalanceService

    @State private var showAddSheet = false
    @State private var selectedTab: TokenTab = .known

    private enum TokenTab: String, CaseIterable {
        case known = "Known Tokens"
        case custom = "Custom"
    }

    /// Active networks based on testnet mode.
    private var activeNetworks: [EthereumBalanceService.Network] {
        balanceService.useTestnet
            ? EthereumBalanceService.Network.testnets
            : EthereumBalanceService.Network.mainnets
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Tab", selection: $selectedTab) {
                ForEach(TokenTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            List {
                switch selectedTab {
                case .known:
                    // MARK: - Default Tokens
                    Section {
                        ForEach(tokenStore.mergedDefaultTokens, id: \.symbol) { token in
                            DefaultTokenRow(
                                token: token,
                                allNetworks: EthereumBalanceService.Network.allCases,
                                isEnabled: tokenStore.isTokenEnabled(token.symbol),
                                onToggle: { enabled in
                                    tokenStore.setTokenEnabled(token.symbol, enabled: enabled)
                                }
                            )
                        }
                    } header: {
                        HStack {
                            Text("\(tokenStore.mergedDefaultTokens.count) tokens")
                            Spacer()
                            if tokenStore.isRemoteLoaded {
                                Text("incl. Uniswap list")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } footer: {
                        Text("Toggle tokens on or off. Disabled tokens won't appear in the send picker or balance views.")
                    }

                case .custom:
                    // MARK: - Custom Tokens
                    Section {
                        Button {
                            showAddSheet = true
                        } label: {
                            Label("Add Custom Token", systemImage: "plus.circle.fill")
                        }
                    }

                    if customTokensForActiveNetworks.isEmpty {
                        Section {
                            HStack {
                                Spacer()
                                VStack(spacing: 8) {
                                    Image(systemName: "plus.circle.dashed")
                                        .font(.title2)
                                        .foregroundColor(.secondary)
                                    Text("No custom tokens yet")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("Add any ERC-20 token by contract address")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 8)
                        }
                    } else {
                        Section {
                            ForEach(customTokensForActiveNetworks) { entry in
                                CustomTokenRow(entry: entry) {
                                    tokenStore.removeCustomToken(id: entry.id)
                                }
                            }
                        } header: {
                            Text("\(customTokensForActiveNetworks.count) custom token\(customTokensForActiveNetworks.count == 1 ? "" : "s")")
                        } footer: {
                            Text("Add any ERC-20 token by its contract address. The app will try to auto-detect the token name and decimals.")
                        }
                    }
                }
            }
        }
        .navigationTitle("Manage Tokens")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showAddSheet) {
            AddCustomTokenView(
                tokenStore: tokenStore,
                balanceService: balanceService
            )
        }
    }

    /// Custom tokens on active networks.
    private var customTokensForActiveNetworks: [CustomTokenEntry] {
        let chainIds = Set(activeNetworks.map { $0.chainId })
        return tokenStore.customTokens.filter { chainIds.contains($0.chainId) }
    }
}

// MARK: - Default Token Row

private struct DefaultTokenRow: View {
    let token: TokenMetadata
    let allNetworks: [EthereumBalanceService.Network]
    let isEnabled: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            TokenIconView(token: token, size: 28)
                .frame(width: 36, height: 36)
                .opacity(isEnabled ? 1.0 : 0.4)

            VStack(alignment: .leading, spacing: 2) {
                Text(token.symbol)
                    .font(.headline)
                    .foregroundColor(isEnabled ? .primary : .secondary)

                Text(token.name)
                    .font(.caption)
                    .foregroundColor(.secondary)

                let chainNames = allNetworks
                    .filter { token.address(onNetwork: $0) != nil }
                    .map { $0.rawValue }
                if !chainNames.isEmpty {
                    Text(chainNames.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Custom Token Row

private struct CustomTokenRow: View {
    let entry: CustomTokenEntry
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.fill")
                .font(.title2)
                .foregroundColor(.orange)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.symbol)
                    .font(.headline)

                Text(entry.name)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(truncatedAddress(entry.contractAddress))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(chainName(for: entry.chainId))
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private func truncatedAddress(_ address: String) -> String {
        guard address.count > 14 else { return address }
        return String(address.prefix(8)) + "…" + String(address.suffix(4))
    }

    private func chainName(for chainId: Int) -> String {
        switch chainId {
        case 1: return "Ethereum"
        case 42161: return "Arbitrum"
        case 8453: return "Base"
        case 11155111: return "Sepolia"
        case 421614: return "Arb Sepolia"
        default: return "Chain \(chainId)"
        }
    }
}

// MARK: - Add Custom Token View

struct AddCustomTokenView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var tokenStore: TokenStore
    @ObservedObject var balanceService: EthereumBalanceService

    @State private var contractAddress = ""
    @State private var selectedChainId: Int = 11155111
    @State private var tokenSymbol = ""
    @State private var tokenName = ""
    @State private var tokenDecimals = "18"
    @State private var isDiscovering = false
    @State private var discoveryError: String?
    @State private var discoverySuccess = false

    private var activeNetworks: [EthereumBalanceService.Network] {
        balanceService.useTestnet
            ? EthereumBalanceService.Network.testnets
            : EthereumBalanceService.Network.mainnets
    }

    private var isValidAddress: Bool {
        contractAddress.hasPrefix("0x") && contractAddress.count == 42
    }

    private var canSave: Bool {
        isValidAddress && !tokenSymbol.isEmpty && (UInt8(tokenDecimals) != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Network
                Section {
                    Picker("Network", selection: $selectedChainId) {
                        ForEach(activeNetworks, id: \.chainId) { network in
                            Text(network.rawValue).tag(network.chainId)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Chain")
                }

                // MARK: - Contract Address
                Section {
                    TextField("0x...", text: $contractAddress)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if !contractAddress.isEmpty && !isValidAddress {
                        Text("Invalid contract address")
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    if isValidAddress {
                        if tokenStore.isKnownToken(address: contractAddress, chainId: selectedChainId) {
                            HStack(spacing: 4) {
                                Image(systemName: "info.circle")
                                    .foregroundColor(.blue)
                                Text("This token is already in your list")
                                    .foregroundColor(.blue)
                            }
                            .font(.caption)
                        } else {
                            Button {
                                Task { await discoverToken() }
                            } label: {
                                HStack {
                                    if isDiscovering {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                            .padding(.trailing, 4)
                                    }
                                    Text(isDiscovering ? "Detecting..." : "Auto-detect Token Info")
                                }
                            }
                            .disabled(isDiscovering)
                        }
                    }

                    if let error = discoveryError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    if discoverySuccess {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Token detected!")
                        }
                        .font(.caption)
                        .foregroundColor(.green)
                    }
                } header: {
                    Text("Contract Address")
                }

                // MARK: - Token Details
                Section {
                    HStack {
                        Text("Symbol")
                        Spacer()
                        TextField("USDC", text: $tokenSymbol)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.characters)
                            .frame(maxWidth: 120)
                    }

                    HStack {
                        Text("Name")
                        Spacer()
                        TextField("USD Coin", text: $tokenName)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 200)
                    }

                    HStack {
                        Text("Decimals")
                        Spacer()
                        TextField("18", text: $tokenDecimals)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 60)
                    }
                } header: {
                    Text("Token Details")
                } footer: {
                    Text("If auto-detect doesn't work, enter the token symbol, name, and decimals manually.")
                }

                // MARK: - Save
                Section {
                    Button {
                        saveToken()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Add Token")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(!canSave)
                }
            }
            .navigationTitle("Add Custom Token")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                // Default to first active network
                if let first = activeNetworks.first {
                    selectedChainId = first.chainId
                }
            }
        }
    }

    private func discoverToken() async {
        guard isValidAddress else { return }
        isDiscovering = true
        discoveryError = nil
        discoverySuccess = false

        guard let network = activeNetworks.first(where: { $0.chainId == selectedChainId }) else {
            discoveryError = "Unknown network"
            isDiscovering = false
            return
        }

        if let result = await tokenStore.discoverTokenMetadata(
            contractAddress: contractAddress,
            network: network
        ) {
            tokenSymbol = result.symbol
            tokenDecimals = String(result.decimals)
            if tokenName.isEmpty {
                tokenName = result.symbol
            }
            discoverySuccess = true
        } else {
            discoveryError = "Could not detect token info. Enter details manually."
        }

        isDiscovering = false
    }

    private func saveToken() {
        guard canSave, let decimals = UInt8(tokenDecimals) else { return }

        let entry = CustomTokenEntry(
            contractAddress: contractAddress,
            chainId: selectedChainId,
            symbol: tokenSymbol.uppercased(),
            name: tokenName.isEmpty ? tokenSymbol : tokenName,
            decimals: decimals
        )

        tokenStore.addCustomToken(entry)
        dismiss()
    }
}

// MARK: - Preview

#if DEBUG
struct CustomTokenSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            CustomTokenSettingsView(
                tokenStore: TokenStore(),
                balanceService: EthereumBalanceService()
            )
        }
    }
}
#endif
