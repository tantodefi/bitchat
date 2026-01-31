//
// XMTPIdentityBridgeTests.swift
// bitchatTests
//
// Tests for XMTPIdentityBridge mapping between XMTP inbox IDs and Noise public keys.
// This is free and unencumbered software released into the public domain.
//

import Testing
import Foundation
@testable import bitchat

@Suite("XMTP Identity Bridge")
struct XMTPIdentityBridgeTests {
    
    // MARK: - Registration Tests
    
    @Test func associateIdentity_storesInboxId() async {
        let keychain = MockKeychain()
        let bridge = XMTPIdentityBridge(keychain: keychain)
        
        let noiseKey = Data(repeating: 0x42, count: 32)
        let inboxId = "inbox_test_123"
        
        bridge.associateIdentity(noisePublicKey: noiseKey, with: inboxId)
        
        let retrieved = bridge.getXMTPInboxId(for: noiseKey)
        #expect(retrieved == inboxId)
    }
    
    @Test func associateIdentity_allowsUpdating() async {
        let keychain = MockKeychain()
        let bridge = XMTPIdentityBridge(keychain: keychain)
        
        let noiseKey = Data(repeating: 0x42, count: 32)
        
        bridge.associateIdentity(noisePublicKey: noiseKey, with: "first_inbox")
        bridge.associateIdentity(noisePublicKey: noiseKey, with: "second_inbox")
        
        let retrieved = bridge.getXMTPInboxId(for: noiseKey)
        #expect(retrieved == "second_inbox")
    }
    
    // MARK: - Lookup Tests
    
    @Test func getXMTPInboxId_returnsNilForUnknown() {
        let keychain = MockKeychain()
        let bridge = XMTPIdentityBridge(keychain: keychain)
        
        let unknownKey = Data(repeating: 0xFF, count: 32)
        let result = bridge.getXMTPInboxId(for: unknownKey)
        
        #expect(result == nil)
    }
    
    @Test func getNoisePublicKey_returnsRegisteredKey() async {
        let keychain = MockKeychain()
        let bridge = XMTPIdentityBridge(keychain: keychain)
        
        let noiseKey = Data(repeating: 0x42, count: 32)
        let inboxId = "inbox_test_123"
        
        bridge.associateIdentity(noisePublicKey: noiseKey, with: inboxId)
        
        let retrieved = bridge.getNoisePublicKey(for: inboxId)
        #expect(retrieved == noiseKey)
    }
    
    @Test func getNoisePublicKey_returnsNilForUnknown() {
        let keychain = MockKeychain()
        let bridge = XMTPIdentityBridge(keychain: keychain)
        
        let result = bridge.getNoisePublicKey(for: "unknown_inbox")
        #expect(result == nil)
    }
    
    // MARK: - Bidirectional Mapping Tests
    
    @Test func bidirectionalMapping_worksCorrectly() async {
        let keychain = MockKeychain()
        let bridge = XMTPIdentityBridge(keychain: keychain)
        
        let noiseKey = Data(repeating: 0xAB, count: 32)
        let inboxId = "bidirectional_test"
        
        bridge.associateIdentity(noisePublicKey: noiseKey, with: inboxId)
        
        // Forward lookup
        let foundInboxId = bridge.getXMTPInboxId(for: noiseKey)
        #expect(foundInboxId == inboxId)
        
        // Reverse lookup
        let foundNoiseKey = bridge.getNoisePublicKey(for: inboxId)
        #expect(foundNoiseKey == noiseKey)
    }
    
    // MARK: - Multiple Mappings Tests
    
    @Test func multipleMappings_storedCorrectly() async {
        let keychain = MockKeychain()
        let bridge = XMTPIdentityBridge(keychain: keychain)
        
        let key1 = Data(repeating: 0x01, count: 32)
        let key2 = Data(repeating: 0x02, count: 32)
        let key3 = Data(repeating: 0x03, count: 32)
        
        bridge.associateIdentity(noisePublicKey: key1, with: "inbox1")
        bridge.associateIdentity(noisePublicKey: key2, with: "inbox2")
        bridge.associateIdentity(noisePublicKey: key3, with: "inbox3")
        
        #expect(bridge.getXMTPInboxId(for: key1) == "inbox1")
        #expect(bridge.getXMTPInboxId(for: key2) == "inbox2")
        #expect(bridge.getXMTPInboxId(for: key3) == "inbox3")
    }
    
    // MARK: - Store Own Noise Key Tests
    
    @Test func storeOwnNoisePublicKey_retrievable() {
        let keychain = MockKeychain()
        let bridge = XMTPIdentityBridge(keychain: keychain)
        
        let noiseKey = Data(repeating: 0xDE, count: 32)
        bridge.storeOwnNoisePublicKey(noiseKey)
        
        let retrieved = bridge.getOwnNoisePublicKey()
        #expect(retrieved == noiseKey)
    }
    
    @Test func getOwnNoisePublicKey_returnsNilInitially() {
        let keychain = MockKeychain()
        let bridge = XMTPIdentityBridge(keychain: keychain)
        
        let result = bridge.getOwnNoisePublicKey()
        #expect(result == nil)
    }
    
    // MARK: - Inbox ID Storage Tests
    
    @Test func storeInboxId_retrievable() {
        let keychain = MockKeychain()
        let bridge = XMTPIdentityBridge(keychain: keychain)
        
        let inboxId = "stored_inbox_id_test"
        bridge.storeInboxId(inboxId)
        
        let retrieved = bridge.getStoredInboxId()
        #expect(retrieved == inboxId)
    }
    
    @Test func getStoredInboxId_returnsNilInitially() {
        let keychain = MockKeychain()
        let bridge = XMTPIdentityBridge(keychain: keychain)
        
        let result = bridge.getStoredInboxId()
        #expect(result == nil)
    }
}
