// XMTPPeerInfoSheet.swift
// Bitchat
//
// Sheet view displaying XMTP peer information with conversation details,
// group members, consent management, and stream controls.

import SwiftUI
import CoreImage.CIFilterBuiltins
import XMTP

struct XMTPPeerInfoSheet: View {
    let peerID: PeerID
    @Binding var isPresented: Bool
    
    @EnvironmentObject var viewModel: ChatViewModel
    @EnvironmentObject var xmtpContainer: XMTPServiceContainer
    
    @Environment(\.colorScheme) private var colorScheme
    @State private var isLoading = true
    @State private var fullInboxIdLoaded: String?
    @State private var resolvedDstealthName: String?
    @State private var isResolvingName = false
    @State private var copiedField: String?
    @State private var isEditingNickname = false
    @State private var editedNickname = ""
    @State private var resolvedWalletAddress: String?
    @State private var showWalletQR = false
    
    // Conversation details
    @State private var conversationType: ConversationType = .unknown
    @State private var groupMembers: [ResolvedMember] = []
    @State private var isLoadingMembers = false
    @State private var groupName: String?
    @State private var currentConsentState: String = "unknown"
    
    // Stream and sync
    @State private var isSyncing = false
    @State private var isRestarting = false
    @State private var syncResult: String?
    
    // Consent
    @State private var isTogglingConsent = false
    @State private var consentActionResult: String?
    
    // Disappearing messages
    @State private var disappearingEnabled = false
    @State private var disappearingDuration: Int64 = 3600_000_000_000 // 1 hour default (ns)
    @State private var isUpdatingDisappearing = false
    @State private var disappearingResult: String?
    
    enum ConversationType {
        case dm
        case group
        case unknown
    }
    
    struct ResolvedMember: Identifiable {
        let id: String
        let walletAddress: String?
        var resolvedName: String?
        let permissionLevel: String
        let isMe: Bool
        
        var displayName: String {
            if let name = resolvedName, !name.isEmpty { return name }
            if let addr = walletAddress, !addr.isEmpty {
                return String(addr.prefix(6)) + "..." + String(addr.suffix(4))
            }
            return String(id.prefix(8)) + "..."
        }
    }
    
    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var xmtpOrange: Color {
        Color(red: 0.96, green: 0.42, blue: 0.26)
    }
    
    private var fullInboxId: String? {
        if let loaded = fullInboxIdLoaded {
            return loaded
        }
        let truncated = peerID.bare
        return xmtpContainer.clientService.inboxIdMap[truncated]
    }
    
    private var savedContact: XMTPContact? {
        let truncated = peerID.bare
        return xmtpContainer.clientService.savedContacts.first { $0.truncatedId == truncated }
    }
    
    private var displayName: String {
        // Priority: nickname > ENS name > truncated ID
        if let contact = savedContact,
           let nick = contact.nickname, !nick.isEmpty {
            return nick
        }
        if let ensName = resolvedDstealthName {
            return ensName
        }
        return "XMTP:" + String(peerID.bare.prefix(8)) + "..."
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: 20) {
                        headerSection
                        conversationTypeSection
                        if conversationType == .group {
                            groupMembersSection
                        }
                        infoCardsSection
                        streamControlsSection
                        consentSection
                        disappearingMessagesSection
                        saveSection
                    }
                    .padding(.bottom, 24)
                }
                .background(backgroundColor)
                
                // QR code overlay
                if showWalletQR, let addr = resolvedWalletAddress {
                    walletQROverlay(address: addr)
                }
            }
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
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(xmtpOrange.opacity(0.15))
                    .frame(width: 80, height: 80)
                
                Image(systemName: conversationType == .group ? "person.3.fill" : "person.circle.fill")
                    .font(.system(size: conversationType == .group ? 35 : 50))
                    .foregroundColor(xmtpOrange)
            }
            .padding(.top, 20)
            
            if isEditingNickname {
                HStack(spacing: 8) {
                    TextField("Nickname", text: $editedNickname)
                        .font(.bitchatSystem(size: 18, weight: .semibold, design: .monospaced))
                        .foregroundColor(textColor)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 220)
                        .onSubmit { saveNickname() }
                    
                    Button(action: { saveNickname() }) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.bitchatSystem(size: 20))
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { isEditingNickname = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.bitchatSystem(size: 20))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.bitchatSystem(size: 20, weight: .semibold, design: .monospaced))
                        .foregroundColor(textColor)
                    
                    // Only show pencil edit icon when displayName is not a resolved ENS name
                    // (i.e. it's either a nickname or the XMTP:... fallback)
                    if resolvedDstealthName == nil || (savedContact?.nickname != nil && !savedContact!.nickname!.isEmpty) {
                        Button(action: {
                            editedNickname = savedContact?.nickname ?? ""
                            isEditingNickname = true
                        }) {
                            Image(systemName: "pencil")
                                .font(.bitchatSystem(size: 14))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            
            if let dstealthName = resolvedDstealthName {
                HStack(spacing: 6) {
                    Text(dstealthName)
                        .font(.bitchatSystem(size: 14, design: .monospaced))
                        .foregroundColor(xmtpOrange)
                    
                    Button(action: { copyToClipboard(dstealthName, field: "dstealth") }) {
                        Image(systemName: copiedField == "dstealth" ? "checkmark" : "doc.on.doc")
                            .font(.bitchatSystem(size: 12))
                            .foregroundColor(copiedField == "dstealth" ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            } else if isResolvingName {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Resolving name...")
                        .font(.bitchatSystem(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            
            if savedContact != nil {
                Label("Saved Contact", systemImage: "star.fill")
                    .font(.bitchatSystem(size: 12))
                    .foregroundColor(.yellow)
            }
        }
    }
    
    // MARK: - Conversation Type Section
    
    private var conversationTypeSection: some View {
        HStack(spacing: 12) {
            Image(systemName: convTypeIcon)
                .font(.bitchatSystem(size: 16))
                .foregroundColor(xmtpOrange)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Conversation Type")
                    .font(.bitchatSystem(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                
                convTypeLabel
            }
            
            Spacer()
        }
        .padding(12)
        .background(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
        .cornerRadius(8)
        .padding(.horizontal, 16)
    }
    
    private var convTypeIcon: String {
        switch conversationType {
        case .group: return "person.3.fill"
        case .dm: return "bubble.left.and.bubble.right.fill"
        case .unknown: return "questionmark.circle"
        }
    }
    
    @ViewBuilder
    private var convTypeLabel: some View {
        switch conversationType {
        case .dm:
            Text("Direct Message")
                .font(.bitchatSystem(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(textColor)
        case .group:
            VStack(alignment: .leading, spacing: 2) {
                Text("Group")
                    .font(.bitchatSystem(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(textColor)
                if let name = groupName, !name.isEmpty {
                    Text(name)
                        .font(.bitchatSystem(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        case .unknown:
            if isLoading {
                HStack(spacing: 4) {
                    ProgressView().scaleEffect(0.5)
                    Text("Loading...")
                        .font(.bitchatSystem(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Direct Message")
                    .font(.bitchatSystem(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(textColor)
            }
        }
    }
    
    // MARK: - Group Members Section
    
    private var groupMembersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.2.fill")
                    .font(.bitchatSystem(size: 14))
                    .foregroundColor(xmtpOrange)
                Text("Members (\(groupMembers.count))")
                    .font(.bitchatSystem(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)
                Spacer()
                if isLoadingMembers {
                    ProgressView().scaleEffect(0.5)
                }
            }
            
            if groupMembers.isEmpty && !isLoadingMembers {
                Text("No members found")
                    .font(.bitchatSystem(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(groupMembers) { member in
                        memberRow(member)
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .padding(12)
        .background(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
        .cornerRadius(8)
        .padding(.horizontal, 16)
    }
    
    private func memberRow(_ member: ResolvedMember) -> some View {
        HStack(spacing: 8) {
            Image(systemName: member.isMe ? "person.fill.checkmark" : "person.fill")
                .font(.bitchatSystem(size: 11))
                .foregroundColor(member.isMe ? .green : .secondary)
                .frame(width: 18)
            
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(member.displayName)
                        .font(.bitchatSystem(size: 12, design: .monospaced))
                        .foregroundColor(member.isMe ? .green : textColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    if member.isMe {
                        Text("(you)")
                            .font(.bitchatSystem(size: 10))
                            .foregroundColor(.green.opacity(0.7))
                    }
                }
                
                if member.resolvedName != nil, let addr = member.walletAddress, !addr.isEmpty {
                    Text(addr)
                        .font(.bitchatSystem(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            
            Spacer()
            
            if member.permissionLevel != "Member" {
                Text(member.permissionLevel)
                    .font(.bitchatSystem(size: 9, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(member.permissionLevel == "SuperAdmin" ? Color.purple : xmtpOrange)
                    .cornerRadius(4)
            }
            
            Button(action: {
                let value = member.walletAddress ?? member.id
                let fieldKey = "m" + String(member.id.prefix(6))
                copyToClipboard(value, field: fieldKey)
            }) {
                let fieldKey = "m" + String(member.id.prefix(6))
                Image(systemName: copiedField == fieldKey ? "checkmark" : "doc.on.doc")
                    .font(.bitchatSystem(size: 10))
                    .foregroundColor(copiedField == fieldKey ? .green : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(member.isMe ? Color.green.opacity(0.05) : Color.clear)
        .cornerRadius(4)
    }
    
    // MARK: - Info Cards Section
    
    private var infoCardsSection: some View {
        VStack(spacing: 12) {
            if let dstealthName = resolvedDstealthName {
                infoCard(title: "ENS Name", value: dstealthName, icon: "at", copyable: true)
            }
            
            infoCard(
                title: "XMTP Inbox ID",
                value: fullInboxId ?? peerID.bare,
                icon: "envelope.fill",
                copyable: true,
                fullText: true
            )
            
            if conversationType == .dm {
                if let walletAddress = resolvedWalletAddress {
                    walletAddressCard(address: walletAddress)
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: "wallet.bifold.fill")
                            .font(.bitchatSystem(size: 16))
                            .foregroundColor(xmtpOrange)
                            .frame(width: 24)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Wallet Address")
                                .font(.bitchatSystem(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                            
                            HStack(spacing: 6) {
                                ProgressView()
                                    .scaleEffect(0.5)
                                Text("Resolving...")
                                    .font(.bitchatSystem(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Spacer()
                    }
                    .padding(12)
                    .background(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
                    .cornerRadius(8)
                }
            }
            
            infoCard(title: "Peer ID", value: peerID.id, icon: "person.fill", copyable: true)
            
            let messageCount = viewModel.privateChats[peerID]?.count ?? 0
            infoCard(title: "Messages", value: String(messageCount), icon: "bubble.left.and.bubble.right.fill", copyable: false)
        }
        .padding(.horizontal, 16)
    }
    
    // MARK: - Stream Controls Section
    
    private var streamControlsSection: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.bitchatSystem(size: 14))
                    .foregroundColor(xmtpOrange)
                Text("Stream & Sync")
                    .font(.bitchatSystem(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)
                Spacer()
            }
            
            HStack(spacing: 16) {
                streamStatusDot(
                    label: "Messages",
                    isActive: xmtpContainer.clientService.isMessageStreamActive
                )
                streamStatusDot(
                    label: "Conversations",
                    isActive: xmtpContainer.clientService.isConversationStreamActive
                )
                Spacer()
            }
            
            HStack(spacing: 12) {
                Button(action: {
                    isRestarting = true
                    xmtpContainer.clientService.restartStreams()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        isRestarting = false
                    }
                }) {
                    HStack(spacing: 4) {
                        if isRestarting {
                            ProgressView().scaleEffect(0.5)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.bitchatSystem(size: 11))
                        }
                        Text(isRestarting ? "restarting..." : "restart streams")
                            .font(.bitchatSystem(size: 11, design: .monospaced))
                    }
                    .foregroundColor(xmtpOrange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(xmtpOrange.opacity(0.1))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(isRestarting)
                
                Button(action: {
                    isSyncing = true
                    syncResult = nil
                    Task {
                        do {
                            try await xmtpContainer.clientService.syncAll()
                            await MainActor.run {
                                syncResult = "synced"
                                isSyncing = false
                            }
                        } catch {
                            await MainActor.run {
                                syncResult = "failed"
                                isSyncing = false
                            }
                        }
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        await MainActor.run { syncResult = nil }
                    }
                }) {
                    HStack(spacing: 4) {
                        if isSyncing {
                            ProgressView().scaleEffect(0.5)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.bitchatSystem(size: 11))
                        }
                        Text(syncResult ?? (isSyncing ? "syncing..." : "sync all"))
                            .font(.bitchatSystem(size: 11, design: .monospaced))
                    }
                    .foregroundColor(xmtpOrange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(xmtpOrange.opacity(0.1))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(isSyncing)
                
                Spacer()
            }
        }
        .padding(12)
        .background(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
        .cornerRadius(8)
        .padding(.horizontal, 16)
    }
    
    private func streamStatusDot(label: String, isActive: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isActive ? Color.green : Color.red)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.bitchatSystem(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Consent Section
    
    private var consentSection: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "hand.raised.fill")
                    .font(.bitchatSystem(size: 14))
                    .foregroundColor(xmtpOrange)
                Text("Consent")
                    .font(.bitchatSystem(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)
                Spacer()
                
                Text(currentConsentState)
                    .font(.bitchatSystem(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(consentBadgeColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(consentBadgeColor.opacity(0.15))
                    .cornerRadius(4)
            }
            
            if let result = consentActionResult {
                Text(result)
                    .font(.bitchatSystem(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            
            HStack(spacing: 12) {
                Button(action: { setConsent(allowed: true) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.bitchatSystem(size: 11))
                        Text("Allow")
                            .font(.bitchatSystem(size: 11, weight: .medium, design: .monospaced))
                    }
                    .foregroundColor(.green)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(isTogglingConsent || currentConsentState == "allowed")
                
                Button(action: { setConsent(allowed: false) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.shield.fill")
                            .font(.bitchatSystem(size: 11))
                        Text("Block")
                            .font(.bitchatSystem(size: 11, weight: .medium, design: .monospaced))
                    }
                    .foregroundColor(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(isTogglingConsent || currentConsentState == "denied")
            }
        }
        .padding(12)
        .background(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
        .cornerRadius(8)
        .padding(.horizontal, 16)
    }
    
    private var consentBadgeColor: Color {
        switch currentConsentState {
        case "allowed": return .green
        case "denied": return .red
        default: return .secondary
        }
    }
    
    // MARK: - Disappearing Messages Section
    
    private var disappearingMessagesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "timer")
                    .font(.bitchatSystem(size: 14))
                    .foregroundColor(xmtpOrange)
                Text("Disappearing Messages")
                    .font(.bitchatSystem(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)
                Spacer()
            }
            
            Toggle(isOn: $disappearingEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-delete messages")
                        .font(.bitchatSystem(size: 13))
                        .foregroundColor(textColor)
                    Text(disappearingEnabled ? "Messages will disappear after \(disappearingDurationLabel)" : "Messages are kept indefinitely")
                        .font(.bitchatSystem(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .tint(xmtpOrange)
            
            if disappearingEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Duration")
                        .font(.bitchatSystem(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 8) {
                        ForEach(disappearingDurationOptions, id: \.ns) { option in
                            Button(action: { disappearingDuration = option.ns }) {
                                Text(option.label)
                                    .font(.bitchatSystem(size: 11, weight: disappearingDuration == option.ns ? .semibold : .regular))
                                    .foregroundColor(disappearingDuration == option.ns ? .white : textColor)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(disappearingDuration == option.ns ? xmtpOrange : (colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.08)))
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            
            Button(action: { updateDisappearingMessages() }) {
                HStack(spacing: 6) {
                    if isUpdatingDisappearing {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
                    Text(disappearingEnabled ? "Apply" : "Clear")
                        .font(.bitchatSystem(size: 12, weight: .medium))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(isUpdatingDisappearing ? Color.gray : xmtpOrange)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(isUpdatingDisappearing)
            
            if let result = disappearingResult {
                Text(result)
                    .font(.bitchatSystem(size: 10))
                    .foregroundColor(result.hasPrefix("Failed") ? .red : .green)
            }
        }
        .padding(12)
        .background(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
        .cornerRadius(8)
        .padding(.horizontal, 16)
    }
    
    private var disappearingDurationLabel: String {
        let ns = disappearingDuration
        let seconds = ns / 1_000_000_000
        if seconds < 3600 { return "\(seconds / 60) min" }
        if seconds < 86400 { return "\(seconds / 3600) hr" }
        return "\(seconds / 86400) day\(seconds / 86400 == 1 ? "" : "s")"
    }
    
    private struct DurationOption {
        let label: String
        let ns: Int64
    }
    
    private var disappearingDurationOptions: [DurationOption] {
        [
            DurationOption(label: "1h", ns: 3_600_000_000_000),
            DurationOption(label: "6h", ns: 21_600_000_000_000),
            DurationOption(label: "24h", ns: 86_400_000_000_000),
            DurationOption(label: "7d", ns: 604_800_000_000_000),
        ]
    }
    
    // MARK: - Save Section
    
    private var saveSection: some View {
        VStack(spacing: 12) {
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
    }
    
    // MARK: - Actions
    
    private func saveNickname() {
        let trimmed = editedNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let nickname: String? = trimmed.isEmpty ? nil : trimmed
        
        if let inboxId = fullInboxId {
            if !xmtpContainer.clientService.isContactSaved(inboxId) {
                xmtpContainer.clientService.saveContact(inboxId, nickname: nickname)
            } else {
                xmtpContainer.clientService.updateContactNickname(inboxId, nickname: nickname)
            }
        }
        
        isEditingNickname = false
    }
    
    private func setConsent(allowed: Bool) {
        guard let inboxId = fullInboxId else { return }
        isTogglingConsent = true
        consentActionResult = nil
        
        Task {
            do {
                if allowed {
                    try await xmtpContainer.clientService.allowContact(inboxId)
                } else {
                    try await xmtpContainer.clientService.blockContact(inboxId)
                }
                await MainActor.run {
                    currentConsentState = allowed ? "allowed" : "denied"
                    consentActionResult = allowed ? "Contact allowed" : "Contact blocked"
                    isTogglingConsent = false
                }
            } catch {
                await MainActor.run {
                    consentActionResult = "Failed: " + error.localizedDescription
                    isTogglingConsent = false
                }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run { consentActionResult = nil }
        }
    }
    
    private func updateDisappearingMessages() {
        guard let inboxId = fullInboxId else { return }
        isUpdatingDisappearing = true
        disappearingResult = nil
        
        Task {
            do {
                guard let conversation = try await xmtpContainer.clientService.getConversationDetails(for: inboxId) else {
                    await MainActor.run {
                        disappearingResult = "Failed: conversation not found"
                        isUpdatingDisappearing = false
                    }
                    return
                }
                
                if disappearingEnabled {
                    let settings = DisappearingMessageSettings(
                        disappearStartingAtNs: Int64(Date().timeIntervalSince1970 * 1_000_000_000),
                        retentionDurationInNs: disappearingDuration
                    )
                    try await conversation.updateDisappearingMessageSettings(settings)
                } else {
                    try await conversation.clearDisappearingMessageSettings()
                }
                
                await MainActor.run {
                    disappearingResult = disappearingEnabled ? "Disappearing messages enabled" : "Disappearing messages cleared"
                    isUpdatingDisappearing = false
                }
            } catch {
                await MainActor.run {
                    disappearingResult = "Failed: \(error.localizedDescription)"
                    isUpdatingDisappearing = false
                }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run { disappearingResult = nil }
        }
    }
    
    private func copyToClipboard(_ value: String, field: String) {
        #if os(iOS)
        UIPasteboard.general.string = value
        #else
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
        #endif
        withAnimation { copiedField = field }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { copiedField = nil }
        }
    }
    
    // MARK: - Data Loading
    
    private func loadInboxId() {
        let truncated = peerID.bare
        
        // Check if we already have the full inbox ID mapped (in-memory cache)
        if let fullId = xmtpContainer.clientService.inboxIdMap[truncated] {
            fullInboxIdLoaded = fullId
            isLoading = false
            resolveDstealthName()
            loadConversationDetails()
            resolveWalletAddress()
            return
        }
        
        // Scan existing DMs to resolve full inbox ID from truncated prefix.
        // This handles the case after app restart when inboxIdMap is empty.
        Task {
            if let resolved = await xmtpContainer.clientService.resolveFullInboxId(truncated: truncated) {
                await MainActor.run {
                    self.fullInboxIdLoaded = resolved
                    self.isLoading = false
                }
            } else {
                // Last resort: the bare value is all we have
                await MainActor.run {
                    self.fullInboxIdLoaded = truncated
                    self.isLoading = false
                }
            }
            resolveDstealthName()
            loadConversationDetails()
            resolveWalletAddress()
        }
    }
    
    private func resolveDstealthName() {
        guard let inboxId = fullInboxId else { return }
        isResolvingName = true
        
        Task {
            let name = await xmtpContainer.clientService.resolveDstealthName(for: inboxId)
            await MainActor.run {
                self.resolvedDstealthName = name
                self.isResolvingName = false
            }
        }
    }
    
    private func resolveWalletAddress() {
        guard let inboxId = fullInboxId else { return }
        
        Task {
            do {
                let addresses = try await xmtpContainer.clientService.getWalletAddresses(for: inboxId)
                if let first = addresses.first {
                    await MainActor.run {
                        self.resolvedWalletAddress = first
                    }
                }
            } catch {
                // Wallet address resolution failed silently
            }
        }
    }
    
    private func loadConversationDetails() {
        guard let inboxId = fullInboxId else { return }
        
        Task {
            do {
                guard let conversation = try await xmtpContainer.clientService.getConversationDetails(for: inboxId) else {
                    await MainActor.run { conversationType = .dm }
                    return
                }
                
                let state = (try? conversation.consentState())?.rawValue ?? "unknown"
                
                // Load disappearing messages state
                let isDisappearing = (try? conversation.isDisappearingMessagesEnabled()) ?? false
                let dmSettings = conversation.disappearingMessageSettings
                
                await MainActor.run {
                    disappearingEnabled = isDisappearing
                    if let settings = dmSettings {
                        disappearingDuration = settings.retentionDurationInNs
                    }
                }
                
                switch conversation {
                case .dm:
                    await MainActor.run {
                        conversationType = .dm
                        currentConsentState = state
                    }
                    
                case .group(let group):
                    let name = try? group.name()
                    await MainActor.run {
                        conversationType = .group
                        groupName = name
                        currentConsentState = state
                        isLoadingMembers = true
                    }
                    
                    let members = try await group.members
                    let myInboxId = xmtpContainer.clientService.inboxId
                    
                    var resolved: [ResolvedMember] = []
                    for member in members {
                        let walletAddress = member.identities.first?.identifier
                        let permLevel: String
                        switch member.permissionLevel {
                        case .SuperAdmin: permLevel = "SuperAdmin"
                        case .Admin: permLevel = "Admin"
                        case .Member: permLevel = "Member"
                        }
                        
                        var rm = ResolvedMember(
                            id: member.inboxId,
                            walletAddress: walletAddress,
                            resolvedName: nil,
                            permissionLevel: permLevel,
                            isMe: member.inboxId == myInboxId
                        )
                        
                        if let saved = xmtpContainer.clientService.savedContacts.first(where: { $0.id == member.inboxId }),
                           let nick = saved.nickname, !nick.isEmpty {
                            rm.resolvedName = nick
                        }
                        
                        resolved.append(rm)
                    }
                    
                    resolved.sort { a, b in
                        if a.isMe != b.isMe { return a.isMe }
                        if a.permissionLevel != b.permissionLevel {
                            let order = ["SuperAdmin": 0, "Admin": 1, "Member": 2]
                            return (order[a.permissionLevel] ?? 3) < (order[b.permissionLevel] ?? 3)
                        }
                        return a.displayName < b.displayName
                    }
                    
                    await MainActor.run {
                        groupMembers = resolved
                        isLoadingMembers = false
                    }
                    
                    for (idx, member) in resolved.enumerated() {
                        if member.resolvedName == nil && !member.isMe {
                            if let name = await xmtpContainer.clientService.resolveDstealthName(for: member.id) {
                                await MainActor.run {
                                    if idx < groupMembers.count {
                                        groupMembers[idx].resolvedName = name
                                    }
                                }
                            }
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    conversationType = .dm
                }
            }
        }
    }
    
    // MARK: - Wallet Address Card (with QR button)
    
    private func walletAddressCard(address: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "wallet.bifold.fill")
                .font(.bitchatSystem(size: 16))
                .foregroundColor(xmtpOrange)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Wallet Address")
                    .font(.bitchatSystem(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                
                Text(address)
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                    .foregroundColor(textColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
            Spacer()
            
            Button(action: { showWalletQR = true }) {
                Image(systemName: "qrcode")
                    .font(.bitchatSystem(size: 16))
                    .foregroundColor(xmtpOrange)
            }
            .buttonStyle(.plain)
            
            Button(action: { copyToClipboard(address, field: "Wallet Address") }) {
                Image(systemName: copiedField == "Wallet Address" ? "checkmark" : "doc.on.doc")
                    .font(.bitchatSystem(size: 12))
                    .foregroundColor(copiedField == "Wallet Address" ? .green : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
        .cornerRadius(8)
    }
    
    // MARK: - Wallet QR Overlay
    
    private func walletQROverlay(address: String) -> some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { showWalletQR = false }
            
            VStack(spacing: 16) {
                HStack {
                    Spacer()
                    Button(action: { showWalletQR = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.trailing, 4)
                
                Text("Wallet Address")
                    .font(.bitchatSystem(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                
                if let qrImage = generateQRCode(from: address) {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .cornerRadius(8)
                } else {
                    Image(systemName: "qrcode")
                        .font(.system(size: 100))
                        .foregroundColor(.secondary)
                }
                
                Text(address)
                    .font(.bitchatSystem(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                
                Button(action: { copyToClipboard(address, field: "Wallet Address") }) {
                    HStack(spacing: 6) {
                        Image(systemName: copiedField == "Wallet Address" ? "checkmark" : "doc.on.doc")
                        Text(copiedField == "Wallet Address" ? "Copied!" : "Copy Address")
                            .font(.bitchatSystem(size: 13, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(xmtpOrange)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(colorScheme == .dark ? Color(.systemGray6) : Color.white)
            )
            .padding(.horizontal, 40)
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: showWalletQR)
    }
    
    // MARK: - QR Code Generator
    
    private func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        
        guard let outputImage = filter.outputImage else { return nil }
        let scale = 200.0 / outputImage.extent.width
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    
    // MARK: - Info Card Helper
    
    private func infoCard(title: String, value: String, icon: String, copyable: Bool, fullText: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.bitchatSystem(size: 16))
                .foregroundColor(xmtpOrange)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.bitchatSystem(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                
                if fullText {
                    Text(value)
                        .font(.bitchatSystem(size: 11, design: .monospaced))
                        .foregroundColor(textColor)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(value)
                        .font(.bitchatSystem(size: 12, design: .monospaced))
                        .foregroundColor(textColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            
            Spacer()
            
            if copyable {
                Button(action: { copyToClipboard(value, field: title) }) {
                    Image(systemName: copiedField == title ? "checkmark" : "doc.on.doc")
                        .font(.bitchatSystem(size: 12))
                        .foregroundColor(copiedField == title ? .green : .secondary)
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
