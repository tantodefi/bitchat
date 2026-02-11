// XMTPPeerInfoSheet.swift
// Bitchat
//
// Sheet view displaying XMTP peer information

import SwiftUI

struct XMTPPeerInfoSheet: View {
    let peerID: PeerID
    @Binding var isPresented: Bool
    
    @EnvironmentObject var viewModel: ChatViewModel
    @EnvironmentObject var xmtpContainer: XMTPServiceContainer
    
    @Environment(\.colorScheme) private var colorScheme
    @State private var isLoading = true
    @State private var fullInboxIdLoaded: String?
    
    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var xmtpOrange: Color {
        Color(red: 0.96, green: 0.42, blue: 0.26)
    }
    
    // Get the full inbox ID from the truncated peer ID
    private var fullInboxId: String? {
        if let loaded = fullInboxIdLoaded {
            return loaded
        }
        let truncated = peerID.bare
        return xmtpContainer.clientService.inboxIdMap[truncated]
    }
    
    // Check if this contact is saved
    private var savedContact: XMTPContact? {
        let truncated = peerID.bare
        return xmtpContainer.clientService.savedContacts.first { $0.truncatedId == truncated }
    }
    
    // Get display name
    private var displayName: String {
        if let contact = savedContact {
            return contact.displayName
        }
        return "XMTP:\(peerID.bare.prefix(8))…"
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Avatar/Icon
                ZStack {
                    Circle()
                        .fill(xmtpOrange.opacity(0.15))
                        .frame(width: 80, height: 80)
                    
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(xmtpOrange)
                }
                .padding(.top, 20)
                
                // Name
                VStack(spacing: 4) {
                    Text(displayName)
                        .font(.bitchatSystem(size: 20, weight: .semibold, design: .monospaced))
                        .foregroundColor(textColor)
                    
                    if savedContact != nil {
                        Label("Saved Contact", systemImage: "star.fill")
                            .font(.bitchatSystem(size: 12))
                            .foregroundColor(.yellow)
                    }
                }
                
                // Info Cards
                VStack(spacing: 12) {
                    // Inbox ID
                    infoCard(
                        title: "XMTP Inbox ID",
                        value: fullInboxId ?? peerID.bare,
                        icon: "envelope.fill",
                        copyable: true
                    )
                    
                    // Peer ID (truncated)
                    infoCard(
                        title: "Peer ID",
                        value: peerID.id,
                        icon: "person.fill",
                        copyable: true
                    )
                    
                    // Message count
                    let messageCount = viewModel.privateChats[peerID]?.count ?? 0
                    infoCard(
                        title: "Messages",
                        value: "\(messageCount)",
                        icon: "bubble.left.and.bubble.right.fill",
                        copyable: false
                    )
                }
                .padding(.horizontal, 16)
                
                Spacer()
                
                // Action Buttons
                VStack(spacing: 12) {
                    // Save/Unsave button
                    Button(action: {
                        viewModel.toggleFavorite(peerID: peerID)
                    }) {
                        HStack {
                            Image(systemName: savedContact != nil ? "star.slash.fill" : "star.fill")
                            Text(savedContact != nil ? "Remove from Saved" : "Save Contact")
                        }
                        .font(.bitchatSystem(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(savedContact != nil ? Color.gray : xmtpOrange)
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(backgroundColor)
            .navigationTitle("Contact Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
            .onAppear {
                loadInboxId()
            }
        }
    }
    
    private func loadInboxId() {
        let truncated = peerID.bare
        
        // Check if already loaded
        if xmtpContainer.clientService.inboxIdMap[truncated] != nil {
            isLoading = false
            return
        }
        
        // The peerID.id contains "xmtp_" prefix followed by the full inbox ID
        // Extract the full inbox ID
        let fullId = peerID.id.hasPrefix("xmtp_") ? String(peerID.id.dropFirst(5)) : peerID.id
        
        // Try to populate the inbox ID map
        Task {
            do {
                try await xmtpContainer.clientService.findOrCreateDM(with: fullId)
                await MainActor.run {
                    self.fullInboxIdLoaded = fullId
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    // Use the full ID from peerID even if DM creation failed
                    self.fullInboxIdLoaded = fullId
                    self.isLoading = false
                }
            }
        }
    }
    
    private func infoCard(title: String, value: String, icon: String, copyable: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.bitchatSystem(size: 16))
                .foregroundColor(xmtpOrange)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.bitchatSystem(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                
                Text(value)
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                    .foregroundColor(textColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
            Spacer()
            
            if copyable {
                Button(action: {
                    #if os(iOS)
                    UIPasteboard.general.string = value
                    #else
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(value, forType: .string)
                    #endif
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.bitchatSystem(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
        .cornerRadius(8)
    }
}

#if DEBUG
struct XMTPPeerInfoSheet_Previews: PreviewProvider {
    static var previews: some View {
        XMTPPeerInfoSheet(
            peerID: PeerID(str: "xmtp_abc123def456"),
            isPresented: .constant(true)
        )
    }
}
#endif
