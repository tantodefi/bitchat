import SwiftUI

struct AppInfoView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var viewModel: ChatViewModel
    @EnvironmentObject var xmtpContainer: XMTPServiceContainer
    @State private var showXMTPSettings = false
    @State private var showWalletView = false
    @State private var showMessagingSettings = false
    @ObservedObject private var transportPrefs = TransportPreferences.shared
    
    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }
    
    // MARK: - Constants
    private enum Strings {
        static let appName: LocalizedStringKey = "app_info.app_name"
        static let tagline: LocalizedStringKey = "app_info.tagline"

        enum Features {
            static let title: LocalizedStringKey = "app_info.features.title"
            static let offlineComm = AppInfoFeatureInfo(
                icon: "wifi.slash",
                title: "app_info.features.offline.title",
                description: "app_info.features.offline.description"
            )
            static let encryption = AppInfoFeatureInfo(
                icon: "lock.shield",
                title: "app_info.features.encryption.title",
                description: "app_info.features.encryption.description"
            )
            static let extendedRange = AppInfoFeatureInfo(
                icon: "antenna.radiowaves.left.and.right",
                title: "app_info.features.extended_range.title",
                description: "app_info.features.extended_range.description"
            )
            static let mentions = AppInfoFeatureInfo(
                icon: "at",
                title: "app_info.features.mentions.title",
                description: "app_info.features.mentions.description"
            )
            static let favorites = AppInfoFeatureInfo(
                icon: "star.fill",
                title: "app_info.features.favorites.title",
                description: "app_info.features.favorites.description"
            )
            static let geohash = AppInfoFeatureInfo(
                icon: "number",
                title: "app_info.features.geohash.title",
                description: "app_info.features.geohash.description"
            )
        }
        
        enum XMTP {
            static let wallet = AppInfoFeatureInfo(
                icon: "wallet.pass.fill",
                title: "app_info.xmtp.wallet.title",
                description: "app_info.xmtp.wallet.description"
            )
            static let messaging = AppInfoFeatureInfo(
                icon: "envelope.badge.shield.half.filled",
                title: "app_info.xmtp.messaging.title",
                description: "app_info.xmtp.messaging.description"
            )
            static let offlineTransactions = AppInfoFeatureInfo(
                icon: "arrow.triangle.2.circlepath",
                title: "app_info.xmtp.offline_transactions.title",
                description: "app_info.xmtp.offline_transactions.description"
            )
            static let torPrivacy = AppInfoFeatureInfo(
                icon: "network.badge.shield.half.filled",
                title: "app_info.xmtp.tor_privacy.title",
                description: "app_info.xmtp.tor_privacy.description"
            )
        }

        enum Privacy {
            static let title: LocalizedStringKey = "app_info.privacy.title"
            static let noTracking = AppInfoFeatureInfo(
                icon: "eye.slash",
                title: "app_info.privacy.no_tracking.title",
                description: "app_info.privacy.no_tracking.description"
            )
            static let ephemeral = AppInfoFeatureInfo(
                icon: "shuffle",
                title: "app_info.privacy.ephemeral.title",
                description: "app_info.privacy.ephemeral.description"
            )
            static let panic = AppInfoFeatureInfo(
                icon: "hand.raised.fill",
                title: "app_info.privacy.panic.title",
                description: "app_info.privacy.panic.description"
            )
        }

        enum HowToUse {
            static let title: LocalizedStringKey = "app_info.how_to_use.title"
            static let instructions: [LocalizedStringKey] = [
                "app_info.how_to_use.set_nickname",
                "app_info.how_to_use.change_channels",
                "app_info.how_to_use.open_sidebar",
                "app_info.how_to_use.start_dm",
                "app_info.how_to_use.clear_chat",
                "app_info.how_to_use.commands"
            ]
        }

    }
    
    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            // Custom header for macOS
            HStack {
                Spacer()
                Button("app_info.done") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(textColor)
                .padding()
            }
            .background(backgroundColor.opacity(0.95))
            
            ScrollView {
                infoContent
            }
            .background(backgroundColor)
        }
        .frame(width: 600, height: 700)
        #else
        NavigationView {
            ScrollView {
                infoContent
            }
            .background(backgroundColor)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.bitchatSystem(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(textColor)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("app_info.close")
                }
            }
        }
        #endif
    }
    
    @ViewBuilder
    private var infoContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Scroll hint at top
            HStack(spacing: 4) {
                Spacer()
                Image(systemName: "arrow.up")
                    .font(.bitchatSystem(size: 10, design: .monospaced))
                Text("scroll up")
                    .font(.bitchatSystem(size: 10, design: .monospaced))
                Spacer()
            }
            .foregroundColor(textColor.opacity(0.6))
            .padding(.top, 4)
            
            // Header
            VStack(alignment: .center, spacing: 8) {
                Text(Strings.appName)
                    .font(.bitchatSystem(size: 32, weight: .bold, design: .monospaced))
                    .foregroundColor(textColor)
                
                Text(Strings.tagline)
                    .font(.bitchatSystem(size: 16, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical)
            
            // How to Use
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(Strings.HowToUse.title)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(Strings.HowToUse.instructions.enumerated()), id: \.offset) { _, instruction in
                        Text(instruction)
                    }
                }
                .font(.bitchatSystem(size: 14, design: .monospaced))
                .foregroundColor(textColor)
            }

            // Features
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(Strings.Features.title)

                FeatureRow(info: Strings.Features.offlineComm)

                FeatureRow(info: Strings.Features.encryption)

                FeatureRow(info: Strings.Features.extendedRange)

                FeatureRow(info: Strings.Features.favorites)

                FeatureRow(info: Strings.Features.geohash)

                FeatureRow(info: Strings.Features.mentions)
            }

            // Privacy
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(Strings.Privacy.title)

                FeatureRow(info: Strings.Privacy.noTracking)

                FeatureRow(info: Strings.Privacy.ephemeral)

                FeatureRow(info: Strings.Privacy.panic)
            }
            
            // Messaging & Transports
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader("app_info.messaging.title")
                
                // Transport Status Overview
                HStack(spacing: 16) {
                    TransportIndicator(
                        icon: "antenna.radiowaves.left.and.right",
                        name: "BLE",
                        isEnabled: true,
                        isConnected: true
                    )
                    TransportIndicator(
                        icon: "globe",
                        name: "Nostr",
                        isEnabled: transportPrefs.isNostrEnabled,
                        isConnected: NostrRelayManager.shared.isConnected
                    )
                    TransportIndicator(
                        icon: "wallet.pass",
                        name: "XMTP",
                        isEnabled: transportPrefs.isXMTPEnabled,
                        isConnected: xmtpContainer.clientService.isConnected
                    )
                }
                .padding(.vertical, 8)
                
                // Messaging Settings button (prominent)
                Button {
                    showMessagingSettings = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.bitchatSystem(size: 20))
                            .foregroundColor(.white)
                            .frame(width: 30)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("app_info.messaging.settings")
                                .font(.bitchatSystem(size: 14, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                            
                            Text("app_info.messaging.settings.description")
                                .font(.bitchatSystem(size: 12, design: .monospaced))
                                .foregroundColor(.white.opacity(0.8))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.bitchatSystem(size: 14))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.green.opacity(0.8))
                    )
                }
                .buttonStyle(.plain)
                
                FeatureRow(info: Strings.XMTP.wallet)
                FeatureRow(info: Strings.XMTP.messaging)
                FeatureRow(info: Strings.XMTP.offlineTransactions)
                FeatureRow(info: Strings.XMTP.torPrivacy)
                
                // Wallet button
                Button {
                    showWalletView = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "wallet.pass.fill")
                            .font(.bitchatSystem(size: 20))
                            .foregroundColor(textColor)
                            .frame(width: 30)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("app_info.xmtp.view_wallet")
                                .font(.bitchatSystem(size: 14, weight: .semibold, design: .monospaced))
                                .foregroundColor(textColor)
                            
                            Text("app_info.xmtp.view_wallet.description")
                                .font(.bitchatSystem(size: 12, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.bitchatSystem(size: 14))
                            .foregroundColor(secondaryTextColor)
                    }
                }
                .buttonStyle(.plain)
                
                // XMTP Settings button
                Button {
                    showXMTPSettings = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "gearshape.fill")
                            .font(.bitchatSystem(size: 20))
                            .foregroundColor(textColor)
                            .frame(width: 30)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("app_info.xmtp.settings")
                                .font(.bitchatSystem(size: 14, weight: .semibold, design: .monospaced))
                                .foregroundColor(textColor)
                            
                            Text("app_info.xmtp.settings.description")
                                .font(.bitchatSystem(size: 12, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.bitchatSystem(size: 14))
                            .foregroundColor(secondaryTextColor)
                    }
                }
                .buttonStyle(.plain)
            }
            
            // Version
            VStack(alignment: .center, spacing: 4) {
                Text("app_info.version")
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    .font(.bitchatSystem(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
        }
        .padding()
        .sheet(isPresented: $showMessagingSettings) {
            NavigationStack {
                MessagingSettingsView()
                    .environmentObject(xmtpContainer)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showMessagingSettings = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showXMTPSettings) {
            NavigationStack {
                XMTPSettingsView(
                    transactionQueue: xmtpContainer.transactionQueue,
                    clientService: xmtpContainer.clientService,
                    wallet: xmtpContainer.wallet
                )
            }
        }
        .sheet(isPresented: $showWalletView) {
            NavigationStack {
                WalletView(wallet: xmtpContainer.wallet)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showWalletView = false }
                        }
                    }
            }
        }
    }
}

struct AppInfoFeatureInfo {
    let icon: String
    let title: LocalizedStringKey
    let description: LocalizedStringKey
}

struct SectionHeader: View {
    let title: LocalizedStringKey
    @Environment(\.colorScheme) var colorScheme
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    init(_ title: LocalizedStringKey) {
        self.title = title
    }
    
    var body: some View {
        Text(title)
            .font(.bitchatSystem(size: 16, weight: .bold, design: .monospaced))
            .foregroundColor(textColor)
            .padding(.top, 8)
    }
}

struct FeatureRow: View {
    let info: AppInfoFeatureInfo
    @Environment(\.colorScheme) var colorScheme
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: info.icon)
                .font(.bitchatSystem(size: 20))
                .foregroundColor(textColor)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(info.title)
                    .font(.bitchatSystem(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)
                
                Text(info.description)
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
        }
    }
}

// MARK: - Transport Indicator

struct TransportIndicator: View {
    let icon: String
    let name: String
    let isEnabled: Bool
    let isConnected: Bool
    
    @Environment(\.colorScheme) var colorScheme
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var statusColor: Color {
        if !isEnabled { return .gray }
        return isConnected ? .green : .orange
    }
    
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.2))
                    .frame(width: 44, height: 44)
                
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(isEnabled ? textColor : .gray)
            }
            
            Text(name)
                .font(.bitchatSystem(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(isEnabled ? textColor : .gray)
            
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview("Default") {
    AppInfoView()
}

#Preview("Dynamic Type XXL") {
    AppInfoView()
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
}

#Preview("Dynamic Type XS") {
    AppInfoView()
        .environment(\.sizeCategory, .extraSmall)
}
