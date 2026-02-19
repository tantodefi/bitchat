//
// XMTPSettingsView.swift
// bitchat
//
// Settings UI for XMTP configuration including transaction relay preferences.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// Settings view for XMTP and transaction relay configuration
struct XMTPSettingsView: View {
    @ObservedObject var clientService: XMTPClientService
    
    // Read receipts setting
    @AppStorage("enableReadReceipts") private var enableReadReceipts = true
    
    // Disappearing messages default
    @AppStorage("defaultDisappearingMessages") private var defaultDisappearingMessages = false
    @AppStorage("defaultDisappearingDurationNs") private var defaultDisappearingDurationNs: Int = 3_600_000_000_000
    
    var body: some View {
        List {
            // MARK: - Connection Status
            Section {
                HStack {
                    Label("XMTP Status", systemImage: clientService.isConnected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(clientService.isConnected ? .green : .secondary)
                    Spacer()
                    Text(clientService.isConnected ? "Connected" : "Disconnected")
                        .foregroundColor(.secondary)
                }
                
                if let inboxId = clientService.inboxId {
                    HStack {
                        Text("Inbox ID")
                        Spacer()
                        Text(String(inboxId.prefix(16)) + "…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if !clientService.isConnected && clientService.bootstrapProgress > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connecting…")
                            .font(.caption)
                        ProgressView(value: clientService.bootstrapProgress)
                    }
                }
            } header: {
                Text("XMTP Connection")
            }
            
            // MARK: - Read Receipts
            Section {
                Toggle(isOn: $enableReadReceipts) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Read Receipts")
                            Text(enableReadReceipts ? "Others can see when you read messages" : "Read status hidden from others")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: enableReadReceipts ? "eye.fill" : "eye.slash.fill")
                    }
                }
                .onChange(of: enableReadReceipts) { newValue in
                    // Update the read receipts content type in the XMTP client
                    Task {
                        await clientService.setReadReceiptsEnabled(newValue)
                    }
                }
            } header: {
                Text("Message Settings")
            } footer: {
                Text("When enabled, conversation partners can see when you've read their messages.")
            }
            
            // MARK: - Disappearing Messages Default
            Section {
                Toggle(isOn: $defaultDisappearingMessages) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Disappearing Messages")
                            Text(defaultDisappearingMessages ? "New conversations will auto-delete messages" : "Messages are kept indefinitely by default")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: defaultDisappearingMessages ? "timer" : "timer.circle")
                    }
                }
                
                if defaultDisappearingMessages {
                    Picker("Default Duration", selection: $defaultDisappearingDurationNs) {
                        Text("1 hour").tag(3_600_000_000_000)
                        Text("6 hours").tag(21_600_000_000_000)
                        Text("24 hours").tag(86_400_000_000_000)
                        Text("7 days").tag(604_800_000_000_000)
                    }
                }
            } header: {
                Text("Disappearing Messages")
            } footer: {
                Text("Sets the default disappearing message duration for new conversations. You can override this per-chat in the contact info sheet.")
            }
            
            // MARK: - Privacy Info
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("End-to-End Encrypted", systemImage: "lock.shield.fill")
                        .font(.subheadline)
                    
                    Text("All XMTP messages use MLS encryption. Transaction requests relayed through the mesh are visible to relay peers but cannot be modified.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Privacy")
            }
        }
        .navigationTitle("XMTP Settings")
    }
}

// MARK: - Private Key Export Sheet

struct PrivateKeyExportSheet: View {
    let privateKey: String
    let onDismiss: () -> Void
    
    @State private var showKey = false
    @State private var copied = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Warning header
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)
                    
                    Text("Keep This Secret!")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("Anyone with this key can access all funds in your wallet. Never share it online or with anyone.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                
                // Key display
                VStack(spacing: 12) {
                    if showKey {
                        Text(privateKey)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
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
                            UIPasteboard.general.string = privateKey
                            #else
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(privateKey, forType: .string)
                            #endif
                            copied = true
                            
                            // Clear clipboard after 60 seconds for security
                            Task {
                                try? await Task.sleep(nanoseconds: 60_000_000_000)
                                #if os(iOS)
                                if UIPasteboard.general.string == privateKey {
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
            .navigationTitle("Private Key")
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

// MARK: - Mesh Relay Row

struct MeshRelayRow: View {
    let relay: MeshTransactionRelay.PendingRelay
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(relay.payload.description ?? "Transaction")
                    .font(.subheadline)
                Spacer()
                MeshStatusBadge(status: relay.status)
            }
            
            HStack {
                let chainName = relay.payload.chainId == 1 ? "ETH" : (relay.payload.chainId == 11155111 ? "Sepolia" : "Chain \(relay.payload.chainId)")
                Text("To: \(relay.payload.toAddress.prefix(10))… • \(chainName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text(relay.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            if let relayedVia = relay.relayedVia {
                Text("Relayed via: \(relayedVia.prefix(8))…")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Mesh Status Badge

struct MeshStatusBadge: View {
    let status: MeshTransactionRelay.RelayStatus
    
    var body: some View {
        Text(status.displayText)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(status.color.opacity(0.2))
            .foregroundColor(status.color)
            .clipShape(Capsule())
    }
}

extension MeshTransactionRelay.RelayStatus {
    var displayText: String {
        switch self {
        case .queued: return "Queued"
        case .relaying: return "Relaying"
        case .awaitingConfirmation: return "Awaiting"
        case .confirmed: return "Confirmed"
        case .failed: return "Failed"
        }
    }
    
    var color: Color {
        switch self {
        case .queued: return .orange
        case .relaying: return .blue
        case .awaitingConfirmation: return .purple
        case .confirmed: return .green
        case .failed: return .red
        }
    }
}

// MARK: - Preview

#if DEBUG
struct XMTPSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            // Preview placeholder - actual implementation needs real objects
            Text("XMTP Settings Preview")
        }
    }
}
#endif
