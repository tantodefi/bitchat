# Namestone ENS Integration Plan

> **Domain**: `dstealth.eth`  
> **Purpose**: Gasless ENS subdomains for bitchat users (`anon1234.dstealth.eth`)  
> **API**: Namestone v1 (https://namestone.com)

---

## Overview

This integration enables automatic ENS subdomain registration for bitchat users. When a user first opens the app and gets assigned an `anon#` username, we'll register `anon#.dstealth.eth` pointing to their wallet address. Users can later customize their subdomain.

### User Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                        First App Launch                              │
├─────────────────────────────────────────────────────────────────────┤
│  1. Generate wallet private key → 0xABC...                          │
│  2. Generate anon username → anon4523                               │
│  3. Create XMTP inbox → 64-char hex ID                              │
│  4. Register ENS subdomain:                                          │
│     POST /set-name {                                                 │
│       domain: "dstealth.eth",                                        │
│       name: "anon4523",                                              │
│       address: "0xABC...",                                           │
│       text_records: {                                                │
│         "com.xmtp.inbox": "64charhexinboxid"                        │
│       }                                                              │
│     }                                                                │
│  5. Store ENS name locally: "anon4523.dstealth.eth"                 │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Components to Implement

### 1. NamestoneService (`/bitchat/Services/NamestoneService.swift`)

Core service for Namestone API interactions.

```swift
actor NamestoneService {
    static let shared = NamestoneService()
    
    private let baseURL = "https://namestone.com/api/public_v1"
    private let domain = "dstealth.eth"
    
    // API key loaded from secure storage
    private var apiKey: String { SecureConfig.namestoneAPIKey }
    
    // MARK: - Public API
    
    /// Register a new subdomain for a wallet address
    func setName(
        name: String,
        address: String,
        xmtpInboxId: String?
    ) async throws -> Bool
    
    /// Update an existing subdomain
    func updateName(
        oldName: String,
        newName: String,
        address: String,
        xmtpInboxId: String?
    ) async throws -> Bool
    
    /// Get names registered to an address
    func getNames(address: String) async throws -> [NamestoneRecord]
    
    /// Search for a name (for availability check)
    func searchName(name: String, exactMatch: Bool) async throws -> [NamestoneRecord]
    
    /// Resolve ENS name to address and inbox ID
    func resolve(ensName: String) async throws -> ENSResolution?
    
    /// Delete a subdomain (for cleanup)
    func deleteName(name: String) async throws -> Bool
}

struct NamestoneRecord: Codable {
    let name: String
    let domain: String
    let address: String
    let textRecords: [String: String]?
    let coinTypes: [String: String]?
    
    var fullName: String { "\(name).\(domain)" }
    var xmtpInboxId: String? { textRecords?["com.xmtp.inbox"] }
}

struct ENSResolution {
    let address: String
    let xmtpInboxId: String?
    let fullName: String
}
```

### 2. Secure API Key Storage

**Option A: Build Configuration (Recommended for Development)**

Create `/bitchat/Configs/Secrets.xcconfig`:
```
// DO NOT commit this file - add to .gitignore
NAMESTONE_API_KEY = your_api_key_here
```

Reference in `Info.plist`:
```xml
<key>NAMESTONE_API_KEY</key>
<string>$(NAMESTONE_API_KEY)</string>
```

**Option B: Keychain Storage (Production)**

```swift
// SecureConfig.swift
enum SecureConfig {
    private static let keychainService = "com.bitchat.config"
    private static let namestoneKeyName = "namestone-api-key"
    
    static var namestoneAPIKey: String {
        // 1. Try keychain first (user-provided or remotely configured)
        if let key = KeychainHelper.load(key: namestoneKeyName, service: keychainService) {
            return String(data: key, encoding: .utf8) ?? ""
        }
        // 2. Fall back to bundled key (from xcconfig)
        return Bundle.main.infoDictionary?["NAMESTONE_API_KEY"] as? String ?? ""
    }
    
    static func setNamestoneAPIKey(_ key: String) {
        KeychainHelper.save(key: namestoneKeyName, data: Data(key.utf8), service: keychainService)
    }
}
```

**Security Notes:**
- API key allows subdomain creation under `dstealth.eth` only
- Rate limited by Namestone
- Consider server-side proxy for production to hide API key completely

### 3. ENS Registration on First Launch

Modify `ChatViewModel.swift` and coordinate with wallet/XMTP initialization:

```swift
// In ChatViewModel.loadNickname() - after generating anon username
private func loadNickname() {
    if let savedNickname = userDefaults.string(forKey: nicknameKey) {
        nickname = savedNickname.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        nickname = "anon\(Int.random(in: 1000...9999))"
        saveNickname()
        
        // NEW: Register ENS subdomain for new users
        Task {
            await registerENSSubdomainIfNeeded()
        }
    }
}

private func registerENSSubdomainIfNeeded() async {
    // Wait for wallet and XMTP to be ready
    guard let address = await getWalletAddress(),
          let inboxId = await getXMTPInboxId() else { return }
    
    // Check if already registered
    guard userDefaults.string(forKey: "ensSubdomain") == nil else { return }
    
    do {
        let success = try await NamestoneService.shared.setName(
            name: nickname,
            address: address,
            xmtpInboxId: inboxId
        )
        if success {
            userDefaults.set("\(nickname).dstealth.eth", forKey: "ensSubdomain")
        }
    } catch {
        SecureLogger.error("Failed to register ENS: \(error)", category: .network)
    }
}
```

### 4. ENS Display in WalletView

Add ENS name display below QR code in `WalletView.swift`:

```swift
// After qrCodeSection, before addressSection
private var ensNameSection: some View {
    Group {
        if let ensName = ensSubdomain {
            HStack(spacing: 8) {
                Text(ensName)
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(.primary)
                
                Button {
                    copyENSName()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                
                NavigationLink {
                    ENSSettingsView(
                        currentName: ensName,
                        walletAddress: address,
                        onNameChanged: { newName in
                            self.ensSubdomain = newName
                        }
                    )
                } label: {
                    Image(systemName: "pencil.circle.fill")
                        .font(.title3)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 8)
        }
    }
}

@AppStorage("ensSubdomain") private var ensSubdomain: String?
```

### 5. ENS Settings View (`/bitchat/Views/ENSSettingsView.swift`)

New view for editing ENS subdomain:

```swift
struct ENSSettingsView: View {
    let currentName: String
    let walletAddress: String
    let onNameChanged: (String) -> Void
    
    @State private var newSubdomain: String = ""
    @State private var isChecking = false
    @State private var isAvailable: Bool?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showSuccess = false
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Current ENS Name")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(currentName)
                        .font(.headline)
                }
            }
            
            Section {
                HStack {
                    TextField("newname", text: $newSubdomain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: newSubdomain) { _ in
                            isAvailable = nil
                            checkAvailabilityDebounced()
                        }
                    
                    Text(".dstealth.eth")
                        .foregroundColor(.secondary)
                }
                
                if isChecking {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Checking availability...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if let available = isAvailable {
                    HStack {
                        Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(available ? .green : .red)
                        Text(available ? "Available!" : "Already taken")
                            .font(.caption)
                            .foregroundColor(available ? .green : .red)
                    }
                }
            } header: {
                Text("New Subdomain")
            } footer: {
                Text("Choose a unique name. Only lowercase letters, numbers, and hyphens allowed.")
            }
            
            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
            
            Section {
                Button {
                    saveNewName()
                } label: {
                    HStack {
                        Spacer()
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save Changes")
                        }
                        Spacer()
                    }
                }
                .disabled(!canSave)
            }
        }
        .navigationTitle("Edit ENS Name")
        .alert("Success!", isPresented: $showSuccess) {
            Button("OK") { dismiss() }
        } message: {
            Text("Your ENS name has been updated to \(newSubdomain).dstealth.eth")
        }
        .onAppear {
            // Pre-fill with current name (without .dstealth.eth)
            newSubdomain = currentName.replacingOccurrences(of: ".dstealth.eth", with: "")
        }
    }
    
    private var canSave: Bool {
        !newSubdomain.isEmpty && 
        isAvailable == true && 
        !isSaving &&
        newSubdomain != currentName.replacingOccurrences(of: ".dstealth.eth", with: "")
    }
    
    private func checkAvailabilityDebounced() {
        // Debounce implementation...
    }
    
    private func saveNewName() {
        // API call to update name...
    }
}
```

### 6. Add ENS Section to WalletSettingsView

Add new section in `WalletSettingsView.swift`:

```swift
// After Stealth Addresses section
Section {
    if let ensName = ensSubdomain {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current Name")
                    Text(ensName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } icon: {
                Image(systemName: "globe")
            }
            
            Spacer()
            
            NavigationLink {
                ENSSettingsView(
                    currentName: ensName,
                    walletAddress: walletAddress,
                    onNameChanged: { newName in
                        ensSubdomain = newName
                    }
                )
            } label: {
                Image(systemName: "pencil")
            }
        }
    } else {
        Button {
            registerENSName()
        } label: {
            Label("Register ENS Name", systemImage: "plus.circle")
        }
    }
} header: {
    Text("ENS Identity")
} footer: {
    Text("Your .dstealth.eth name lets others find your wallet and message you easily.")
}

@AppStorage("ensSubdomain") private var ensSubdomain: String?
```

### 7. Enhanced `/dm-wallet` Command

Update `CommandProcessor.swift` to support ENS resolution:

```swift
private func handleDMWallet(_ args: String) -> CommandResult {
    let input = args.trimmingCharacters(in: .whitespaces)
    
    guard !input.isEmpty else {
        return .error(message: """
            usage: /dm-wallet <inbox_id or ens_name>
            
            Examples:
              /dm-wallet alice.dstealth.eth
              /dm-wallet vitalik.eth
              /dm-wallet alice.base.eth
              /dm-wallet 64charhexinboxid
            """)
    }
    
    // Check if it's an ENS name
    if input.contains(".eth") {
        return resolveAndDM(ensName: input)
    }
    
    // Validate inbox ID format (64 char hex)
    guard input.count == 64, input.allSatisfy({ $0.isHexDigit }) else {
        return .error(message: "invalid input. Provide ENS name (*.eth) or 64-char hex inbox ID")
    }
    
    guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
        return .error(message: "XMTP not connected. Check /xmtp status")
    }
    
    Task {
        await contextProvider?.startXMTPChat(with: input)
    }
    
    return .success(message: "opening XMTP DM with \(input.prefix(8))…")
}

private func resolveAndDM(ensName: String) -> CommandResult {
    guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
        return .error(message: "XMTP not connected. Check /xmtp status")
    }
    
    Task {
        do {
            let resolution = try await ENSResolver.shared.resolve(ensName)
            
            if let inboxId = resolution.xmtpInboxId {
                // Has XMTP inbox - use that directly
                await MainActor.run {
                    contextProvider?.startXMTPChat(with: inboxId)
                }
            } else if !resolution.address.isEmpty {
                // Has address but no inbox - try to find/create conversation by address
                await MainActor.run {
                    contextProvider?.startXMTPChatByAddress(resolution.address)
                }
            } else {
                await MainActor.run {
                    contextProvider?.showError("Could not resolve \(ensName)")
                }
            }
        } catch {
            await MainActor.run {
                contextProvider?.showError("ENS resolution failed: \(error.localizedDescription)")
            }
        }
    }
    
    return .success(message: "resolving \(ensName)…")
}
```

### 8. ENS Resolver Service (`/bitchat/Services/ENSResolver.swift`)

Unified ENS resolution supporting multiple providers:

```swift
actor ENSResolver {
    static let shared = ENSResolver()
    
    /// Resolve any ENS name to address and optional XMTP inbox ID
    func resolve(_ ensName: String) async throws -> ENSResolution {
        let name = ensName.lowercased()
        
        // Route based on domain
        if name.hasSuffix(".dstealth.eth") {
            return try await resolveViaNamestone(name)
        } else if name.hasSuffix(".base.eth") {
            return try await resolveViaBasename(name)
        } else if name.hasSuffix(".eth") {
            return try await resolveViaENS(name)
        } else {
            throw ENSError.unsupportedDomain
        }
    }
    
    // MARK: - Namestone (.dstealth.eth)
    
    private func resolveViaNamestone(_ name: String) async throws -> ENSResolution {
        let subdomain = name.replacingOccurrences(of: ".dstealth.eth", with: "")
        let records = try await NamestoneService.shared.searchName(name: subdomain, exactMatch: true)
        
        guard let record = records.first else {
            throw ENSError.notFound
        }
        
        return ENSResolution(
            address: record.address,
            xmtpInboxId: record.textRecords?["com.xmtp.inbox"],
            fullName: record.fullName
        )
    }
    
    // MARK: - Basename (.base.eth)
    
    private func resolveViaBasename(_ name: String) async throws -> ENSResolution {
        // Base L2 ENS resolution via basescan or direct contract call
        // https://docs.base.org/guides/build-with-basename/
        let url = URL(string: "https://resolver.base.org/name/\(name)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let result = try JSONDecoder().decode(BasenameResolution.self, from: data)
        
        return ENSResolution(
            address: result.address,
            xmtpInboxId: nil, // Would need additional lookup
            fullName: name
        )
    }
    
    // MARK: - Standard ENS (.eth)
    
    private func resolveViaENS(_ name: String) async throws -> ENSResolution {
        // Use ENS public resolver or Cloudflare ENS gateway
        // https://eth.limo or direct contract call via JSON-RPC
        let url = URL(string: "https://\(name).eth.limo/")!
        // Or use: https://api.ensideas.com/ens/resolve/\(name)
        
        // For production, implement proper ENS resolution via:
        // 1. Direct contract call to ENS registry
        // 2. Use a trusted RPC endpoint
        
        // Simplified example using ENS Ideas API:
        let apiURL = URL(string: "https://api.ensideas.com/ens/resolve/\(name)")!
        let (data, _) = try await URLSession.shared.data(from: apiURL)
        let result = try JSONDecoder().decode(ENSIdeasResponse.self, from: data)
        
        return ENSResolution(
            address: result.address,
            xmtpInboxId: nil,
            fullName: name
        )
    }
}

enum ENSError: Error, LocalizedError {
    case notFound
    case unsupportedDomain
    case networkError
    case invalidResponse
    
    var errorDescription: String? {
        switch self {
        case .notFound: return "ENS name not found"
        case .unsupportedDomain: return "Unsupported ENS domain"
        case .networkError: return "Network error during resolution"
        case .invalidResponse: return "Invalid response from resolver"
        }
    }
}
```

---

## File Changes Summary

| File | Action | Description |
|------|--------|-------------|
| `Services/NamestoneService.swift` | **NEW** | Namestone API client |
| `Services/ENSResolver.swift` | **NEW** | Unified ENS resolution |
| `Services/SecureConfig.swift` | **NEW** | Secure API key management |
| `Views/ENSSettingsView.swift` | **NEW** | ENS editing UI |
| `Views/WalletView.swift` | **MODIFY** | Add ENS display below QR |
| `Views/WalletSettingsView.swift` | **MODIFY** | Add ENS section |
| `Services/CommandProcessor.swift` | **MODIFY** | ENS support in /dm-wallet |
| `ViewModels/ChatViewModel.swift` | **MODIFY** | Auto-register ENS on first launch |
| `Configs/Secrets.xcconfig` | **NEW** | API key config (gitignored) |
| `.gitignore` | **MODIFY** | Add Secrets.xcconfig |

---

## API Key Setup Instructions

### Development Setup

1. **Create secrets config file:**
   ```bash
   touch bitchat/Configs/Secrets.xcconfig
   echo "NAMESTONE_API_KEY = your_key_here" > bitchat/Configs/Secrets.xcconfig
   ```

2. **Add to .gitignore:**
   ```
   # Secrets
   **/Secrets.xcconfig
   ```

3. **Include in build configs:**
   
   In `Debug.xcconfig`:
   ```
   #include? "Secrets.xcconfig"
   ```
   
   In `Release.xcconfig`:
   ```
   #include? "Secrets.xcconfig"
   ```

4. **Add to Info.plist:**
   ```xml
   <key>NAMESTONE_API_KEY</key>
   <string>$(NAMESTONE_API_KEY)</string>
   ```

### Production Considerations

For production release, consider:

1. **Server-side proxy**: Route all Namestone requests through your own server to hide API key
2. **Rate limiting**: Implement client-side rate limiting to prevent abuse
3. **Key rotation**: Support updating API key via remote config

---

## Text Records Schema

When registering subdomains, we store these text records:

| Key | Description | Example |
|-----|-------------|---------|
| `com.xmtp.inbox` | XMTP inbox ID for messaging | `abc123...` (64 chars) |
| `description` | Optional user bio | `Anon user` |
| `avatar` | Optional avatar URL | `https://...` |

---

## Error Handling

| Scenario | Handling |
|----------|----------|
| Name already taken | Show "Name unavailable" in UI, suggest alternatives |
| Network error | Retry with exponential backoff, show offline indicator |
| API rate limited | Queue request, retry after delay |
| Invalid name format | Client-side validation before API call |
| API key missing | Log warning, disable ENS features gracefully |

---

## Testing Checklist

- [ ] Fresh install registers ENS name automatically
- [ ] ENS name displays in wallet view
- [ ] Edit button opens ENS settings
- [ ] Name availability check works
- [ ] Name update succeeds and reflects everywhere
- [ ] `/dm-wallet alice.dstealth.eth` resolves correctly
- [ ] `/dm-wallet vitalik.eth` resolves via standard ENS
- [ ] `/dm-wallet alice.base.eth` resolves via Basename
- [ ] Error states display appropriately
- [ ] API key not exposed in app bundle (obfuscated or server-proxied)

---

## Implementation Order

1. **Phase 1: Core Service**
   - [ ] Create `NamestoneService.swift`
   - [ ] Create `SecureConfig.swift`
   - [ ] Set up API key configuration

2. **Phase 2: Auto-Registration**
   - [ ] Modify `ChatViewModel.swift` for first-launch registration
   - [ ] Store ENS name in UserDefaults/AppStorage

3. **Phase 3: Wallet UI**
   - [ ] Add ENS display to `WalletView.swift`
   - [ ] Create `ENSSettingsView.swift`
   - [ ] Add ENS section to `WalletSettingsView.swift`

4. **Phase 4: Resolution**
   - [ ] Create `ENSResolver.swift`
   - [ ] Update `CommandProcessor.swift` for ENS in `/dm-wallet`

5. **Phase 5: Polish**
   - [ ] Error handling and edge cases
   - [ ] Loading states and animations
   - [ ] Testing on device

---

## Notes

- Domain `dstealth.eth` must have Namestone resolver configured (mainnet: `0xA87361C4E58B619c390f469B9E6F27d759715125`)
- Subdomains are gasless - Namestone handles the on-chain resolution
- XMTP inbox ID stored as text record enables direct messaging without knowing wallet address
- Consider caching resolved addresses locally to reduce API calls
