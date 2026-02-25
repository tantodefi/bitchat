//
// TokenPickerView.swift
// bitchat
//
// Token selection sheet used in the Send flow to pick which asset to send.
// Shows ETH + all ERC-20 tokens on the selected network with their balances.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// Represents the selected asset: native ETH or an ERC-20 token.
enum SelectedAsset: Equatable {
    case eth
    case token(TokenMetadata)

    var symbol: String {
        switch self {
        case .eth: return "ETH"
        case .token(let t): return t.symbol
        }
    }

    var decimals: UInt8 {
        switch self {
        case .eth: return 18
        case .token(let t): return t.decimals
        }
    }

    var iconName: String {
        switch self {
        case .eth: return "diamond.fill"
        case .token(let t): return t.iconName
        }
    }

    var logoURI: String? {
        switch self {
        case .eth: return nil
        case .token(let t): return t.logoURI
        }
    }

    var isETH: Bool {
        if case .eth = self { return true }
        return false
    }

    /// Get the contract address for a given network (nil for native ETH).
    func contractAddress(on network: EthereumBalanceService.Network) -> String? {
        switch self {
        case .eth: return nil
        case .token(let t): return t.address(onNetwork: network)
        }
    }
}

/// Sheet for selecting which token to send.
struct TokenPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let network: EthereumBalanceService.Network
    let ethBalance: EthereumBalanceService.Balance?
    @ObservedObject var tokenStore: TokenStore
    @ObservedObject var balanceService: EthereumBalanceService
    let walletAddress: String
    @Binding var selectedAsset: SelectedAsset

    @State private var showAddToken = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Native ETH
                Section {
                    Button {
                        selectedAsset = .eth
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            ETHIconView(size: 28)
                                .frame(width: 36, height: 36)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("ETH")
                                    .font(.headline)
                                    .foregroundColor(.primary)

                                Text("Native Ether")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            if let bal = ethBalance {
                                Text("\(bal.formattedETH) ETH")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(.primary)
                            } else {
                                Text("--")
                                    .foregroundColor(.secondary)
                            }

                            if selectedAsset.isETH {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Native")
                }

                // MARK: - ERC-20 Tokens
                Section {
                    let tokens = tokenStore.tokens(for: network)
                    if tokens.isEmpty {
                        HStack {
                            Spacer()
                            Text("No tokens on \(network.rawValue)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    } else {
                        ForEach(tokens, id: \.symbol) { token in
                            let isSelected: Bool = {
                                if case .token(let t) = selectedAsset {
                                    return t.symbol == token.symbol
                                }
                                return false
                            }()

                            Button {
                                selectedAsset = .token(token)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    TokenIconView(token: token, size: 28)
                                        .frame(width: 36, height: 36)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(token.symbol)
                                            .font(.headline)
                                            .foregroundColor(.primary)

                                        Text(token.name)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    if let balance = tokenStore.balance(for: token, on: network) {
                                        Text("\(balance.formattedBalance)")
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundColor(balance.hasBalance ? .primary : .secondary)
                                    } else if tokenStore.isLoadingBalances {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                    } else {
                                        Text("--")
                                            .foregroundColor(.secondary)
                                    }

                                    if isSelected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button {
                        showAddToken = true
                    } label: {
                        Label("Add Custom Token", systemImage: "plus.circle")
                    }
                } header: {
                    HStack {
                        Text("ERC-20 Tokens")
                        Spacer()
                        if tokenStore.isLoadingBalances {
                            ProgressView()
                                .scaleEffect(0.6)
                        }
                    }
                }
            }
            .navigationTitle("Select Token")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                // Fetch token balances when the picker opens
                if !walletAddress.isEmpty {
                    await tokenStore.fetchTokenBalances(
                        for: walletAddress,
                        network: network
                    )
                }
            }
            .sheet(isPresented: $showAddToken) {
                AddCustomTokenView(
                    tokenStore: tokenStore,
                    balanceService: balanceService
                )
            }
        }
    }
}
