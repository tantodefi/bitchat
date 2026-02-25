//
// TokenIconView.swift
// bitchat
//
// A reusable view that displays a token icon.
// Tries to load the remote logoURI via AsyncImage first,
// then falls back to the SF Symbol iconName.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// Displays a token's logo. Prefers the remote `logoURI` (e.g. from CoinGecko/TrustWallet),
/// with an SF Symbol `iconName` as a synchronous fallback.
struct TokenIconView: View {
    let logoURI: String?
    let iconName: String
    let size: CGFloat

    init(token: TokenMetadata, size: CGFloat = 28) {
        self.logoURI = token.logoURI
        self.iconName = token.iconName
        self.size = size
    }

    init(logoURI: String?, iconName: String, size: CGFloat = 28) {
        self.logoURI = logoURI
        self.iconName = iconName
        self.size = size
    }

    var body: some View {
        if let urlString = logoURI, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                case .failure:
                    sfSymbolFallback
                case .empty:
                    ProgressView()
                        .frame(width: size, height: size)
                @unknown default:
                    sfSymbolFallback
                }
            }
        } else {
            sfSymbolFallback
        }
    }

    private var sfSymbolFallback: some View {
        Image(systemName: iconName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .foregroundStyle(.secondary)
    }
}

/// Convenience for native ETH icon.
struct ETHIconView: View {
    let size: CGFloat

    init(size: CGFloat = 28) {
        self.size = size
    }

    var body: some View {
        Image(systemName: "diamond.fill")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .foregroundStyle(.blue)
    }
}
