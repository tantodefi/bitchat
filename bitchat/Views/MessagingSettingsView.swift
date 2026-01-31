//
// MessagingSettingsView.swift
// bitchat
//
// Settings UI for transport layer configuration.
// Allows users to enable/disable and configure BLE, Nostr, and XMTP transports.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// Settings view for transport layer configuration
struct MessagingSettingsView: View {
    @EnvironmentObject var xmtpContainer: XMTPServiceContainer
    @ObservedObject private var preferences = TransportPreferences.shared
    @ObservedObject private var nostrRelayManager = NostrRelayManager.shared
    
    @State private var showingXMTPSettings = false
    @State private var showingNostrInfo = false
    
    var body: some View {
        List {
            // MARK: - Transport Status Overview
            Section {
                TransportStatusRow(
                    transport: .ble,
                    isEnabled: .constant(true), // Always enabled
                    isConnected: true, // BLE is always "connected" locally
                    canDisable: false
                )
                
                TransportStatusRow(
                    transport: .nostr,
                    isEnabled: Binding(
                        get: { preferences.isNostrEnabled },
                        set: { newValue in
                            if newValue {
                                preferences.enable(.nostr)
                            } else {
                                preferences.disable(.nostr)
                            }
                        }
                    ),
                    isConnected: nostrRelayManager.isConnected,
                    canDisable: true
                )
                
                TransportStatusRow(
                    transport: .xmtp,
                    isEnabled: Binding(
                        get: { preferences.isXMTPEnabled },
                        set: { newValue in
                            if newValue {
                                preferences.enable(.xmtp)
                            } else {
                                preferences.disable(.xmtp)
                            }
                        }
                    ),
                    isConnected: xmtpContainer.clientService.isConnected,
                    canDisable: true
                )
            } header: {
                Text("Active Transports")
            } footer: {
                Text("Enable the messaging layers you want to use. BLE mesh is always active for local communication.")
            }
            
            // MARK: - Primary DM Transport
            Section {
                Picker("Primary for DMs", selection: $preferences.primaryDMTransport) {
                    ForEach(MessagingTransport.allCases.filter { $0 != .ble && preferences.isEnabled($0) }) { transport in
                        Label(transport.displayName, systemImage: transport.icon)
                            .tag(transport)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Direct Messages")
            } footer: {
                Text("Messages are sent via BLE mesh when peers are nearby. This transport is used as fallback for remote contacts.")
            }
            
            // MARK: - Geo Transport
            Section {
                Picker("Geo Channels", selection: $preferences.geoTransport) {
                    ForEach([MessagingTransport.nostr, .xmtp].filter { preferences.isEnabled($0) }) { transport in
                        Label(transport.displayName, systemImage: transport.icon)
                            .tag(transport)
                    }
                }
                .pickerStyle(.menu)
                
                if preferences.geoTransport == .xmtp {
                    Label {
                        Text("Using XMTP groups for location channels")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } icon: {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                    }
                }
            } header: {
                Text("Location Features")
            } footer: {
                Text("Transport used for geo-location channels and presence broadcasting.")
            }
            
            // MARK: - XMTP Configuration
            if preferences.isXMTPEnabled {
                Section {
                    NavigationLink {
                        XMTPSettingsView(
                            transactionQueue: xmtpContainer.transactionQueue,
                            clientService: xmtpContainer.clientService,
                            wallet: xmtpContainer.wallet
                        )
                    } label: {
                        Label("XMTP Settings", systemImage: "gearshape")
                    }
                    
                    NavigationLink {
                        WalletView(wallet: xmtpContainer.wallet)
                    } label: {
                        Label("Wallet", systemImage: "wallet.pass")
                    }
                } header: {
                    Text("XMTP Configuration")
                }
            }
            
            // MARK: - Transport Info
            Section {
                ForEach(MessagingTransport.allCases) { transport in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(transport.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Divider()
                            
                            Text("Features:")
                                .font(.caption)
                                .fontWeight(.medium)
                            
                            ForEach(transport.features, id: \.self) { feature in
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption2)
                                        .foregroundColor(.green)
                                    Text(feature)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } label: {
                        Label(transport.displayName, systemImage: transport.icon)
                    }
                }
            } header: {
                Text("About Transports")
            }
            
            // MARK: - Reset
            Section {
                Button(role: .destructive) {
                    preferences.resetToDefaults()
                } label: {
                    Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .navigationTitle("Messaging")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Transport Status Row

struct TransportStatusRow: View {
    let transport: MessagingTransport
    @Binding var isEnabled: Bool
    let isConnected: Bool
    let canDisable: Bool
    
    var body: some View {
        HStack {
            Image(systemName: transport.icon)
                .font(.title3)
                .foregroundColor(isEnabled ? .primary : .secondary)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(transport.displayName)
                    .font(.subheadline)
                    .foregroundColor(isEnabled ? .primary : .secondary)
                
                HStack(spacing: 4) {
                    if isEnabled {
                        Circle()
                            .fill(isConnected ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(isConnected ? "Connected" : "Connecting…")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Disabled")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            
            if canDisable {
                Toggle("", isOn: $isEnabled)
                    .labelsHidden()
            } else {
                Text("Required")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        MessagingSettingsView()
            .environmentObject(XMTPServiceContainer.configure(keychain: KeychainManager()))
    }
}
