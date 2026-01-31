//
// TransportPreferences.swift
// bitchat
//
// User preferences for transport layer selection (BLE, Nostr, XMTP).
// Allows users to control which messaging transports are active.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Combine
import Foundation

/// Available messaging transport types
enum MessagingTransport: String, CaseIterable, Identifiable, Codable {
    case ble = "ble"
    case nostr = "nostr"
    case xmtp = "xmtp"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .ble: return "BLE Mesh"
        case .nostr: return "Nostr Relays"
        case .xmtp: return "XMTP Network"
        }
    }
    
    var icon: String {
        switch self {
        case .ble: return "antenna.radiowaves.left.and.right"
        case .nostr: return "globe"
        case .xmtp: return "wallet.pass"
        }
    }
    
    var description: String {
        switch self {
        case .ble:
            return "Local mesh network via Bluetooth. Works offline without internet."
        case .nostr:
            return "Decentralized relay network. Used for geo-channels and DM fallback."
        case .xmtp:
            return "Wallet-based messaging with transaction relay support."
        }
    }
    
    /// Features enabled by this transport
    var features: [String] {
        switch self {
        case .ble:
            return ["Local mesh chat", "Offline messaging", "Peer discovery", "File sharing"]
        case .nostr:
            return ["Geo-location channels", "Presence broadcast", "Global DM fallback"]
        case .xmtp:
            return ["Wallet messaging", "Transaction relay", "MLS encryption", "Group chats"]
        }
    }
}

/// User preferences for transport layer configuration
final class TransportPreferences: ObservableObject {
    static let shared = TransportPreferences()
    
    // MARK: - Keys
    
    private enum Keys {
        static let enabledTransports = "transport.enabled"
        static let primaryTransport = "transport.primary"
        static let geoTransport = "transport.geo"
    }
    
    // MARK: - Published Properties
    
    /// Which transports are enabled
    @Published private(set) var enabledTransports: Set<MessagingTransport> {
        didSet { save() }
    }
    
    /// Primary transport for DMs (fallback order: BLE -> primary -> queue)
    @Published var primaryDMTransport: MessagingTransport {
        didSet { save() }
    }
    
    /// Transport for geo-location features
    @Published var geoTransport: MessagingTransport {
        didSet { save() }
    }
    
    // MARK: - Computed Properties
    
    var isBLEEnabled: Bool { enabledTransports.contains(.ble) }
    var isNostrEnabled: Bool { enabledTransports.contains(.nostr) }
    var isXMTPEnabled: Bool { enabledTransports.contains(.xmtp) }
    
    // MARK: - Initialization
    
    private init() {
        // Load saved preferences or use defaults
        if let savedData = UserDefaults.standard.data(forKey: Keys.enabledTransports),
           let saved = try? JSONDecoder().decode(Set<MessagingTransport>.self, from: savedData) {
            self.enabledTransports = saved
        } else {
            // Default: all transports enabled
            self.enabledTransports = Set(MessagingTransport.allCases)
        }
        
        if let primaryRaw = UserDefaults.standard.string(forKey: Keys.primaryTransport),
           let primary = MessagingTransport(rawValue: primaryRaw) {
            self.primaryDMTransport = primary
        } else {
            // Default: XMTP for DMs if available, otherwise Nostr
            self.primaryDMTransport = .xmtp
        }
        
        if let geoRaw = UserDefaults.standard.string(forKey: Keys.geoTransport),
           let geo = MessagingTransport(rawValue: geoRaw) {
            self.geoTransport = geo
        } else {
            // Default: Nostr for geo features (most mature implementation)
            self.geoTransport = .nostr
        }
    }
    
    // MARK: - Public Methods
    
    /// Enable a transport
    func enable(_ transport: MessagingTransport) {
        enabledTransports.insert(transport)
        SecureLogger.info("Transport enabled: \(transport.displayName)", category: .session)
        NotificationCenter.default.post(name: .transportPreferencesChanged, object: nil)
    }
    
    /// Disable a transport
    func disable(_ transport: MessagingTransport) {
        // Don't allow disabling BLE (always need local mesh)
        guard transport != .ble else {
            SecureLogger.warning("Cannot disable BLE mesh transport", category: .session)
            return
        }
        enabledTransports.remove(transport)
        
        // Update primary/geo if needed
        if primaryDMTransport == transport {
            primaryDMTransport = .nostr
        }
        if geoTransport == transport {
            geoTransport = .nostr
        }
        
        SecureLogger.info("Transport disabled: \(transport.displayName)", category: .session)
        NotificationCenter.default.post(name: .transportPreferencesChanged, object: nil)
    }
    
    /// Toggle a transport
    func toggle(_ transport: MessagingTransport) {
        if enabledTransports.contains(transport) {
            disable(transport)
        } else {
            enable(transport)
        }
    }
    
    /// Check if a transport is enabled
    func isEnabled(_ transport: MessagingTransport) -> Bool {
        enabledTransports.contains(transport)
    }
    
    /// Reset to defaults
    func resetToDefaults() {
        enabledTransports = Set(MessagingTransport.allCases)
        primaryDMTransport = .xmtp
        geoTransport = .nostr
        SecureLogger.info("Transport preferences reset to defaults", category: .session)
        NotificationCenter.default.post(name: .transportPreferencesChanged, object: nil)
    }
    
    // MARK: - Private Methods
    
    private func save() {
        if let data = try? JSONEncoder().encode(enabledTransports) {
            UserDefaults.standard.set(data, forKey: Keys.enabledTransports)
        }
        UserDefaults.standard.set(primaryDMTransport.rawValue, forKey: Keys.primaryTransport)
        UserDefaults.standard.set(geoTransport.rawValue, forKey: Keys.geoTransport)
    }
}

// MARK: - Notification

extension Notification.Name {
    static let transportPreferencesChanged = Notification.Name("transportPreferencesChanged")
}
