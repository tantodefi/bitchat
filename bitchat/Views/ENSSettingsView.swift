//
// ENSSettingsView.swift
// bitchat
//
// UI for viewing and editing ENS subdomain (.dstealth.eth).
// Allows users to customize their subdomain name.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// View for editing ENS subdomain settings
struct ENSSettingsView: View {
    let currentName: String
    let walletAddress: String
    let xmtpInboxId: String?
    let onNameChanged: ((String) -> Void)?
    
    @State private var newSubdomain: String = ""
    @State private var isChecking = false
    @State private var isAvailable: Bool?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showSuccess = false
    @State private var checkTask: Task<Void, Never>?
    
    @Environment(\.dismiss) private var dismiss
    
    // MARK: - Computed Properties
    
    private var currentSubdomain: String {
        currentName.replacingOccurrences(of: ".dstealth.eth", with: "")
    }
    
    private var canSave: Bool {
        !newSubdomain.isEmpty &&
        isAvailable == true &&
        !isSaving &&
        newSubdomain.lowercased() != currentSubdomain.lowercased()
    }
    
    private var isValidFormat: Bool {
        let normalized = newSubdomain.lowercased().trimmingCharacters(in: .whitespaces)
        guard normalized.count >= 1, normalized.count <= 32 else { return false }
        
        let validCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard normalized.unicodeScalars.allSatisfy({ validCharacters.contains($0) }) else { return false }
        guard !normalized.hasPrefix("-"), !normalized.hasSuffix("-") else { return false }
        
        return true
    }
    
    // MARK: - Body
    
    var body: some View {
        List {
            // Current Name Section
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current ENS Name")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Text(currentName)
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Spacer()
                        
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Current Identity")
            }
            
            // New Name Section
            Section {
                HStack(spacing: 0) {
                    TextField("newname", text: $newSubdomain)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: newSubdomain) { _ in
                            isAvailable = nil
                            errorMessage = nil
                            checkAvailabilityDebounced()
                        }
                    
                    Text(".dstealth.eth")
                        .foregroundColor(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
                
                // Availability status
                if !newSubdomain.isEmpty {
                    availabilityStatus
                }
            } header: {
                Text("New Subdomain")
            } footer: {
                Text("Choose a unique name. Only lowercase letters, numbers, and hyphens allowed. 1-32 characters.")
            }
            
            // Error Section
            if let error = errorMessage {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            }
            
            // Save Button Section
            Section {
                Button {
                    saveNewName()
                } label: {
                    HStack {
                        Spacer()
                        if isSaving {
                            ProgressView()
                                .progressViewStyle(.circular)
                            Text("Saving...")
                                .padding(.leading, 8)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Save Changes")
                        }
                        Spacer()
                    }
                }
                .disabled(!canSave)
            }
            
            // Info Section
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    InfoRow(
                        icon: "globe",
                        title: "Your ENS identity",
                        description: "This name resolves to your wallet address and XMTP inbox, making it easy for others to send you messages and payments."
                    )
                    
                    InfoRow(
                        icon: "bolt.fill",
                        title: "Gasless updates",
                        description: "Name changes are free and instant via Namestone."
                    )
                    
                    InfoRow(
                        icon: "lock.shield.fill",
                        title: "Your name, your control",
                        description: "Only you can update or transfer this name."
                    )
                }
            } header: {
                Text("About ENS Names")
            }
        }
        .navigationTitle("Edit ENS Name")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Success!", isPresented: $showSuccess) {
            Button("OK") {
                onNameChanged?("\(newSubdomain.lowercased()).dstealth.eth")
                dismiss()
            }
        } message: {
            Text("Your ENS name has been updated to \(newSubdomain.lowercased()).dstealth.eth")
        }
        .onAppear {
            newSubdomain = currentSubdomain
        }
        .onDisappear {
            checkTask?.cancel()
        }
    }
    
    // MARK: - Availability Status View
    
    @ViewBuilder
    private var availabilityStatus: some View {
        HStack(spacing: 8) {
            if isChecking {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Checking availability...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if !isValidFormat {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.orange)
                Text("Invalid format")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else if let available = isAvailable {
                if available {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Available!")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                    Text("Already taken")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            } else if newSubdomain.lowercased() == currentSubdomain.lowercased() {
                Image(systemName: "equal.circle.fill")
                    .foregroundColor(.secondary)
                Text("Same as current")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
    
    // MARK: - Actions
    
    private func checkAvailabilityDebounced() {
        checkTask?.cancel()
        
        let subdomain = newSubdomain.lowercased().trimmingCharacters(in: .whitespaces)
        
        // Skip if same as current
        guard subdomain != currentSubdomain.lowercased() else {
            isAvailable = nil
            return
        }
        
        // Skip if invalid format
        guard isValidFormat else {
            isAvailable = nil
            return
        }
        
        checkTask = Task {
            // Debounce: wait 500ms before checking
            try? await Task.sleep(nanoseconds: 500_000_000)
            
            guard !Task.isCancelled else { return }
            
            await MainActor.run { isChecking = true }
            
            do {
                let available = try await NamestoneService.shared.isNameAvailable(subdomain)
                
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    isChecking = false
                    isAvailable = available
                }
            } catch {
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    isChecking = false
                    errorMessage = "Could not check availability: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func saveNewName() {
        guard canSave else { return }
        
        isSaving = true
        errorMessage = nil
        
        Task {
            do {
                let success = try await NamestoneService.shared.updateName(
                    oldName: currentSubdomain,
                    newName: newSubdomain.lowercased(),
                    address: walletAddress,
                    xmtpInboxId: xmtpInboxId
                )
                
                await MainActor.run {
                    isSaving = false
                    if success {
                        showSuccess = true
                    } else {
                        errorMessage = "Failed to update name. Please try again."
                    }
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Info Row Component

private struct InfoRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    NavigationStack {
        ENSSettingsView(
            currentName: "anon1234.dstealth.eth",
            walletAddress: "0x1234567890abcdef1234567890abcdef12345678",
            xmtpInboxId: "abc123def456",
            onNameChanged: { newName in
                print("Name changed to: \(newName)")
            }
        )
    }
}
#endif
