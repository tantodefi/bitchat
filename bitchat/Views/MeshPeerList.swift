import SwiftUI

struct MeshPeerList: View {
    @ObservedObject var viewModel: ChatViewModel
    let textColor: Color
    let secondaryTextColor: Color
    let onTapPeer: (PeerID) -> Void
    let onToggleFavorite: (PeerID) -> Void
    let onShowFingerprint: (PeerID) -> Void
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var xmtpContainer: XMTPServiceContainer

    @State private var orderedIDs: [String] = []
    @State private var showXMTPConversations: Bool = false

    private enum Strings {
        static let noneNearby: LocalizedStringKey = "geohash_people.none_nearby"
        static let blockedTooltip = String(localized: "geohash_people.tooltip.blocked", comment: "Tooltip shown next to a blocked peer indicator")
        static let newMessagesTooltip = String(localized: "mesh_peers.tooltip.new_messages", comment: "Tooltip for the unread messages indicator")
    }
    
    private var xmtpOrange: Color { .orange }

    var body: some View {
        let myPeerID = viewModel.meshService.myPeerID
        let mapped: [(peer: BitchatPeer, isMe: Bool, hasUnread: Bool, enc: EncryptionStatus)] = viewModel.allPeers.map { peer in
            let isMe = peer.peerID == myPeerID
            let hasUnread = viewModel.hasUnreadMessages(for: peer.peerID)
            let enc = viewModel.getEncryptionStatus(for: peer.peerID)
            return (peer, isMe, hasUnread, enc)
        }
        // Stable visual order without mutating state here
        let currentIDs = mapped.map { $0.peer.peerID.id }
        let displayIDs = orderedIDs.filter { currentIDs.contains($0) } + currentIDs.filter { !orderedIDs.contains($0) }
        let peers: [(peer: BitchatPeer, isMe: Bool, hasUnread: Bool, enc: EncryptionStatus)] = displayIDs.compactMap { id in
            mapped.first(where: { $0.peer.peerID.id == id })
        }
        
        if viewModel.allPeers.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(Strings.noneNearby)
                    .font(.bitchatSystem(size: 14, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
                    .padding(.horizontal)
                    .padding(.top, 12)
                
                // XMTP Conversations Section even when no mesh peers
                xmtpSection
                    .padding(.horizontal)
                    .padding(.top, 16)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<peers.count, id: \.self) { idx in
                    let item = peers[idx]
                    let peer = item.peer
                    let isMe = item.isMe
                    HStack(spacing: 4) {
                        let assigned = viewModel.colorForMeshPeer(id: peer.peerID, isDark: colorScheme == .dark)
                        let baseColor = isMe ? Color.orange : assigned
                        if isMe {
                            Image(systemName: "person.fill")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(baseColor)
                        } else if peer.isConnected {
                            // Mesh-connected peer: radio icon
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(baseColor)
                        } else if peer.isReachable {
                            // Mesh-reachable (relayed): point.3 icon
                            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(baseColor)
                        } else if peer.isMutualFavorite && peer.isXMTPReachable {
                            // Mutual favorite reachable via XMTP: wallet icon (blue)
                            Image(systemName: "creditcard.fill")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(.blue)
                        } else if peer.isMutualFavorite {
                            // Mutual favorite reachable via Nostr: globe icon (purple)
                            Image(systemName: "globe")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(.purple)
                        } else {
                            // Fallback icon for others (dimmed)
                            Image(systemName: "person")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(secondaryTextColor)
                        }

                        let displayName = isMe ? viewModel.nickname : peer.nickname
                        let (base, suffix) = displayName.splitSuffix()
                        HStack(spacing: 0) {
                            Text(base)
                                .font(.bitchatSystem(size: 14, design: .monospaced))
                                .foregroundColor(baseColor)
                            if !suffix.isEmpty {
                                let suffixColor = isMe ? Color.orange.opacity(0.6) : baseColor.opacity(0.6)
                                Text(suffix)
                                    .font(.bitchatSystem(size: 14, design: .monospaced))
                                    .foregroundColor(suffixColor)
                            }
                        }

                        if !isMe, viewModel.isPeerBlocked(peer.peerID) {
                            Image(systemName: "nosign")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(.red)
                                .help(Strings.blockedTooltip)
                        }

                        if !isMe {
                            if peer.isConnected {
                                if let icon = item.enc.icon {
                                    Image(systemName: icon)
                                        .font(.bitchatSystem(size: 10))
                                        .foregroundColor(baseColor)
                                }
                            } else {
                                // Offline: prefer showing verified badge from persisted fingerprints
                                if let fp = viewModel.getFingerprint(for: peer.peerID),
                                   viewModel.verifiedFingerprints.contains(fp) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.bitchatSystem(size: 10))
                                        .foregroundColor(baseColor)
                                } else if let icon = item.enc.icon {
                                    // Fallback to whatever status says (likely lock if we had a past session)
                                    Image(systemName: icon)
                                        .font(.bitchatSystem(size: 10))
                                        .foregroundColor(baseColor)
                                }
                            }
                        }

                        Spacer()

                        // Unread message indicator for this peer
                        if !isMe, item.hasUnread {
                            Image(systemName: "envelope.fill")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(.orange)
                                .help(Strings.newMessagesTooltip)
                        }

                        if !isMe {
                            Button(action: { onToggleFavorite(peer.peerID) }) {
                                Image(systemName: (peer.favoriteStatus?.isFavorite ?? false) ? "star.fill" : "star")
                                    .font(.bitchatSystem(size: 12))
                                    .foregroundColor((peer.favoriteStatus?.isFavorite ?? false) ? .yellow : secondaryTextColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                    .padding(.top, idx == 0 ? 10 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { if !isMe { onTapPeer(peer.peerID) } }
                    .onTapGesture(count: 2) { if !isMe { onShowFingerprint(peer.peerID) } }
                }
            }
            // Seed and update order outside result builder
            .onAppear {
                let currentIDs = mapped.map { $0.peer.peerID.id }
                orderedIDs = currentIDs
            }
            .onChange(of: mapped.map { $0.peer.peerID.id }) { ids in
                var newOrder = orderedIDs
                newOrder.removeAll { !ids.contains($0) }
                for id in ids where !newOrder.contains(id) { newOrder.append(id) }
                if newOrder != orderedIDs { orderedIDs = newOrder }
            }
            
            // XMTP Conversations Section
            xmtpSection
                .padding(.horizontal)
                .padding(.top, 16)
        }
    }
    
    // MARK: - XMTP Section
    
    private var xmtpSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { showXMTPConversations.toggle() }) {
                HStack {
                    Text("#xmtp")
                        .font(.bitchatSystem(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(xmtpOrange)
                    
                    if xmtpContainer.isInitialized {
                        let contactCount = xmtpContainer.clientService.savedContacts.count
                        Text("[\(contactCount) saved]")
                            .font(.bitchatSystem(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    } else {
                        Text("[not connected]")
                            .font(.bitchatSystem(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: showXMTPConversations ? "chevron.up" : "chevron.down")
                        .font(.bitchatSystem(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            
            if showXMTPConversations {
                xmtpConversationsList
            }
        }
        .padding(12)
        .background(xmtpOrange.opacity(0.08))
        .cornerRadius(8)
    }
    
    @ViewBuilder
    private var xmtpConversationsList: some View {
        if !xmtpContainer.isInitialized {
            Text("Connect wallet in settings to use XMTP")
                .font(.bitchatSystem(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.top, 4)
        } else {
            let contacts = xmtpContainer.clientService.savedContacts
            let privateChats = viewModel.privateChats.filter { $0.key.isXMTPDM }
            
            if contacts.isEmpty && privateChats.isEmpty {
                Text("No XMTP conversations yet.\nUse /dm-wallet <inbox-id> to start one.")
                    .font(.bitchatSystem(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            } else {
                VStack(spacing: 0) {
                    // Show saved contacts first
                    ForEach(contacts) { contact in
                        xmtpContactRow(contact)
                    }
                    
                    // Show unsaved conversations
                    let unsavedPeers = privateChats.keys.filter { peerID in
                        !contacts.contains { $0.peerID == peerID }
                    }
                    ForEach(Array(unsavedPeers), id: \.self) { peerID in
                        xmtpPeerRow(peerID)
                    }
                }
            }
        }
    }
    
    private func xmtpContactRow(_ contact: XMTPContact) -> some View {
        Button(action: {
            viewModel.selectedPrivateChatPeer = contact.peerID
        }) {
            HStack {
                Image(systemName: "star.fill")
                    .font(.bitchatSystem(size: 10))
                    .foregroundColor(xmtpOrange)
                
                Text(contact.displayName)
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                    .foregroundColor(.primary)
                
                Spacer()
                
                // Unread indicator
                if viewModel.unreadPrivateMessages.contains(contact.peerID) {
                    Circle()
                        .fill(xmtpOrange)
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
    
    private func xmtpPeerRow(_ peerID: PeerID) -> some View {
        Button(action: {
            viewModel.selectedPrivateChatPeer = peerID
        }) {
            HStack {
                Image(systemName: "bubble.left")
                    .font(.bitchatSystem(size: 10))
                    .foregroundColor(.secondary)
                
                Text("XMTP:\(peerID.bare.prefix(8))…")
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                    .foregroundColor(.primary)
                
                Spacer()
                
                // Unread indicator
                if viewModel.unreadPrivateMessages.contains(peerID) {
                    Circle()
                        .fill(xmtpOrange)
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}
