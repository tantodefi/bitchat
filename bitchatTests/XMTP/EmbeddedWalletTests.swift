//
// EmbeddedWalletTests.swift
// bitchatTests
//
// Tests for EmbeddedWallet key generation, signing, and address derivation.
// This is free and unencumbered software released into the public domain.
//

import Testing
import Foundation
@testable import bitchat

@Suite("Embedded Wallet")
struct EmbeddedWalletTests {
    
    // MARK: - Key Generation Tests
    
    @Test func newWallet_generatesPrivateKey() async throws {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        
        let privateKey = try await wallet.getOrCreatePrivateKey()
        
        #expect(privateKey.count == 32, "Private key should be 32 bytes")
    }
    
    @Test func existingWallet_loadsPrivateKey() async throws {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        
        // Generate key first time
        let firstKey = try await wallet.getOrCreatePrivateKey()
        
        // Create new wallet instance with same keychain
        let wallet2 = EmbeddedWallet(keychain: keychain)
        let secondKey = try await wallet2.getOrCreatePrivateKey()
        
        #expect(firstKey == secondKey, "Should load same key from keychain")
    }
    
    @Test func walletExists_returnsFalseForNew() async {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        
        let exists = await wallet.walletExists()
        
        #expect(!exists, "New wallet should not exist")
    }
    
    @Test func walletExists_returnsTrueAfterCreation() async throws {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        
        _ = try await wallet.getOrCreatePrivateKey()
        let exists = await wallet.walletExists()
        
        #expect(exists, "Wallet should exist after key creation")
    }
    
    // MARK: - Address Tests
    
    @Test func getAddress_returnsValidEthereumAddress() async throws {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        
        let address = try await wallet.getAddress()
        
        #expect(address.hasPrefix("0x"), "Address should start with 0x")
        #expect(address.count == 42, "Address should be 42 characters (0x + 40 hex)")
        
        // Validate hex characters
        let hex = String(address.dropFirst(2))
        #expect(hex.allSatisfy { $0.isHexDigit }, "Address should be valid hex")
    }
    
    @Test func getAddress_returnsSameAddressOnMultipleCalls() async throws {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        
        let address1 = try await wallet.getAddress()
        let address2 = try await wallet.getAddress()
        
        #expect(address1 == address2, "Address should be deterministic")
    }
    
    // MARK: - Public Key Tests
    
    @Test func getPublicKey_returnsUncompressedKey() async throws {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        
        let publicKey = try await wallet.getPublicKey()
        
        // Uncompressed secp256k1 public key: 0x04 + 32 bytes X + 32 bytes Y = 65 bytes
        #expect(publicKey.count == 65, "Public key should be 65 bytes (uncompressed)")
        #expect(publicKey[0] == 0x04, "Uncompressed key should start with 0x04")
    }
    
    // MARK: - Signing Tests
    
    @Test func signMessage_returnsValidSignature() async throws {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        
        let signature = try await wallet.signMessage("Hello, XMTP!")
        
        // Ethereum signature: 65 bytes (r || s || v)
        #expect(signature.count == 65, "Signature should be 65 bytes (Ethereum format)")
    }
    
    @Test func signMessage_returnsDifferentSignaturesForDifferentMessages() async throws {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        
        let sig1 = try await wallet.signMessage("Message 1")
        let sig2 = try await wallet.signMessage("Message 2")
        
        #expect(sig1 != sig2, "Different messages should produce different signatures")
    }
    
    @Test func signBytes_returnsValidSignature() async throws {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        
        let testData = Data([0x01, 0x02, 0x03, 0x04])
        let signature = try await wallet.signBytes(testData)
        
        #expect(signature.count == 65, "Signature should be 65 bytes (Ethereum format)")
    }
    
    // MARK: - Clear Wallet Tests
    
    @Test func clearWallet_removesKey() async throws {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        
        // Create wallet
        _ = try await wallet.getOrCreatePrivateKey()
        let existsBefore = await wallet.walletExists()
        #expect(existsBefore, "Wallet should exist")
        
        // Clear wallet
        await wallet.clearWallet()
        
        // Verify cleared
        let existsAfter = await wallet.walletExists()
        #expect(!existsAfter, "Wallet should not exist after clear")
    }
    
    @Test func clearWallet_generatesNewKeyOnNextAccess() async throws {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        
        // Create wallet
        let firstKey = try await wallet.getOrCreatePrivateKey()
        
        // Clear wallet
        await wallet.clearWallet()
        
        // Access generates new key
        let secondKey = try await wallet.getOrCreatePrivateKey()
        
        #expect(firstKey != secondKey, "Should generate new key after clear")
    }
}
