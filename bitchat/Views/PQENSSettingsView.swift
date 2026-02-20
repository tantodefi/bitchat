//
// PQENSSettingsView.swift
// bitchat
//
// UI for viewing and editing PQ stealth ENS subdomain (.pq.dstealth.eth).
// Slightly modified version of ENSSettingsView for the PQ stealth namespace.
// Users edit the name to the left of .pq.dstealth.eth.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// View for editing PQ stealth ENS subdomain settings
struct PQENSSettingsView: View {
    let currentPQName: String
    let pqAccountAddress: String
    let stealthIndex: UInt32
    @ObservedObject var viewModel: StealthPQAccountViewModel
    
    @State private var newSubdomain: String = ""
    @State private var isChecking = false
    @State private var isAvailable: Bool?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showSuccess = false
    @State private var checkTask: Task<Void, Never>?
    
    @Environment(\.dismiss) private var dismiss
    
    // MARK: - Computed Properties
    
    /// Extract just the label from the current PQ name
    /// e.g. "alice.pq.dstealth.eth" → "alice"
    private var currentLabel: String {
        currentPQName
            .replacingOccurrences(of: ".pq.dstealth.eth", with: "")
            .replacingOccurrences(of: ".dstealth.eth", with: "")
    }
    
    private var canSave: Bool {
        !newSubdomain.isEmpty &&
        isAvailable == true &&
        !isSaving &&
        newSubdomain.lowercased() != currentLabel.lowercased()
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
            // Current PQ Name Section
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current PQ Stealth Name")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Text(currentPQName)
                            .font(.headline)
                            .foregroundColor(.purple)
                        
                        Spacer()
                        
                        Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                            .foregroundColor(.purple)
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
                    
                    Text(".pq.dstealth.eth")
                        .foregroundColor(.purple.opacity(0.7))
                        .font(.system(.body, design: .monospaced))
                }
                
                // Availability status
                if !newSubdomain.isEmpty {
                    availabilityStatus
                }
            } header: {
                Text("New PQ Subdomain")
            } footer: {
                Text("Choose a unique name for your PQ stealth address. Only lowercase letters, numbers, and hyphens allowed. 1-32 characters.")
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
                        icon: "shield.lefthalf.filled",
                        title: "Quantum-resistant receive",
                        description: "This name resolves to your current stealth PQ Account address. Senders use it to pay you via a unique, quantum-safe address."
                    )
                    
                    InfoRow(
                        icon: "bolt.fill",
                        title: "Gasless updates",
                        description: "Name changes are free and instant via Namestone."
                    )
                    
                    InfoRow(
                        icon: "arrow.triangle.2.circlepath",
                        title: "Auto-rotating address",
                        description: "The address behind this name rotates after each sweep, so each payment uses a fresh stealth address."
                    )
                }
            } header: {
                Text("About PQ Stealth Names")
            }
        }
        .navigationTitle("Edit PQ Name")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Success!", isPresented: $showSuccess) {
            Button("OK") {
                viewModel.updatePQENSName(newSubdomain.lowercased())
                dismiss()
            }
        } message: {
            Text("Your PQ stealth name has been updated to \(newSubdomain.lowercased()).pq.dstealth.eth")
        }
        .onAppear {
            newSubdomain = currentLabel
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
            } else if newSubdomain.lowercased() == currentLabel.lowercased() {
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
        guard subdomain != currentLabel.lowercased() else {
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
                // Check availability on the pq.dstealth.eth domain
                let available = try await viewModel.namestoneService.isPQNameAvailable(subdomain)
                
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
                let success = try await viewModel.namestoneService.updatePQName(
                    oldName: currentLabel,
                    newName: newSubdomain.lowercased(),
                    pqAccountAddress: pqAccountAddress,
                    stealthIndex: stealthIndex
                )
                
                await MainActor.run {
                    isSaving = false
                    if success {
                        showSuccess = true
                    } else {
                        errorMessage = "Failed to update PQ name. Please try again."
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

// MARK: - Info Row Component (reused from ENSSettingsView pattern)

private struct InfoRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.purple)
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

// Preview requires mock dependencies; use live app for testing.
