//
// SecureConfig.swift
// bitchat
//
// Secure configuration management for API keys and sensitive values.
// Uses xcconfig for development and keychain for production overrides.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Secure configuration manager for API keys and sensitive settings
enum SecureConfig {
    
    // MARK: - Keychain Configuration
    
    private static let keychainService = "com.bitchat.config"
    private static let namestoneKeyName = "namestone-api-key"
    private static let pimlicoKeyName = "pimlico-api-key"
    
    // MARK: - Namestone API Key
    
    /// Get the Namestone API key from keychain or bundled config
    static var namestoneAPIKey: String {
        // 1. Try keychain first (user-provided or remotely configured)
        if let keyData = KeychainHelper.load(key: namestoneKeyName, service: keychainService),
           let key = String(data: keyData, encoding: .utf8), !key.isEmpty {
            return key
        }
        
        // 2. Fall back to bundled key from Info.plist (via xcconfig)
        if let key = Bundle.main.infoDictionary?["NAMESTONE_API_KEY"] as? String,
           !key.isEmpty, key != "$(NAMESTONE_API_KEY)" {
            return key
        }
        
        // 3. No key available
        return ""
    }
    
    /// Check if Namestone API key is configured
    static var hasNamestoneAPIKey: Bool {
        !namestoneAPIKey.isEmpty
    }
    
    /// Store a Namestone API key in keychain (for runtime configuration)
    static func setNamestoneAPIKey(_ key: String) -> Bool {
        guard !key.isEmpty else {
            // Clear the key
            return KeychainHelper.delete(key: namestoneKeyName, service: keychainService)
        }
        return KeychainHelper.save(key: namestoneKeyName, data: Data(key.utf8), service: keychainService)
    }
    
    /// Clear the stored Namestone API key from keychain
    static func clearNamestoneAPIKey() -> Bool {
        KeychainHelper.delete(key: namestoneKeyName, service: keychainService)
    }
    
    // MARK: - Pimlico API Key
    
    /// Get the Pimlico bundler API key from keychain or bundled config
    static var pimlicoAPIKey: String {
        // 1. Try keychain first (user-provided or remotely configured)
        if let keyData = KeychainHelper.load(key: pimlicoKeyName, service: keychainService),
           let key = String(data: keyData, encoding: .utf8), !key.isEmpty {
            return key
        }
        
        // 2. Fall back to bundled key from Info.plist (via xcconfig)
        if let key = Bundle.main.infoDictionary?["PIMLICO_API_KEY"] as? String,
           !key.isEmpty, key != "$(PIMLICO_API_KEY)" {
            return key
        }
        
        // 3. No key available
        return ""
    }
    
    /// Check if Pimlico API key is configured
    static var hasPimlicoAPIKey: Bool {
        !pimlicoAPIKey.isEmpty
    }
    
    /// Store a Pimlico API key in keychain (for runtime configuration)
    static func setPimlicoAPIKey(_ key: String) -> Bool {
        guard !key.isEmpty else {
            return KeychainHelper.delete(key: pimlicoKeyName, service: keychainService)
        }
        return KeychainHelper.save(key: pimlicoKeyName, data: Data(key.utf8), service: keychainService)
    }
    
    /// Clear the stored Pimlico API key from keychain
    static func clearPimlicoAPIKey() -> Bool {
        KeychainHelper.delete(key: pimlicoKeyName, service: keychainService)
    }
}

// MARK: - Keychain Helper

/// Simple keychain helper for secure storage
enum KeychainHelper {
    
    /// Save data to keychain
    static func save(key: String, data: Data, service: String) -> Bool {
        // Delete any existing item first
        _ = delete(key: key, service: service)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    /// Load data from keychain
    static func load(key: String, service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess else {
            return nil
        }
        
        return result as? Data
    }
    
    /// Delete data from keychain
    @discardableResult
    static func delete(key: String, service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
