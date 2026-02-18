//
// PQAccountSigner.swift
// bitchat
//
// XMTP SigningKey conformance for the PQ smart contract wallet.
// Enables the PQ ERC-4337 account to initialize its own XMTP client
// using SCW (Smart Contract Wallet) identity verification via ERC-1271.
//
// When XMTP sees a .SCW signer, it calls `addScwSignature` which
// verifies the signature on-chain by calling `isValidSignature(bytes32,bytes)`
// on the smart contract at the given address and chainId.
//
// Requirements:
//   1. The ZKNOX PQ account must implement ERC-1271 isValidSignature
//   2. The target chain must be in XMTP's supported SCW chain list
//   3. The PQ account must be deployed before XMTP client creation
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation
import XMTP

// MARK: - PQ Account Signer (SCW)

/// XMTP SigningKey conformance for the PQ smart contract wallet.
///
/// Uses the hybrid ECDSA + ML-DSA-44 signing scheme that the
/// PQ account's `isValidSignature` expects for ERC-1271 verification.
public struct PQAccountSigner: SigningKey {
    private let wallet: EmbeddedWallet
    private let pqKeyManager: PQKeyManager
    private let pqAccountAddress: String
    private let pqChainId: Int64
    
    /// The XMTP identity is the PQ smart contract wallet address.
    public var identity: PublicIdentity {
        PublicIdentity(kind: .ethereum, identifier: pqAccountAddress)
    }
    
    /// Smart Contract Wallet type — tells XMTP to use ERC-1271 verification.
    public var type: SignerType { .SCW }
    
    /// Chain where the PQ account is deployed (required for SCW verification).
    public var chainId: Int64? { pqChainId }
    
    /// Optional block number for verification (nil = latest).
    public var blockNumber: Int64? { nil }
    
    init(
        wallet: EmbeddedWallet,
        pqKeyManager: PQKeyManager,
        accountAddress: String,
        chainId: Int64
    ) {
        self.wallet = wallet
        self.pqKeyManager = pqKeyManager
        self.pqAccountAddress = accountAddress
        self.pqChainId = chainId
    }
    
    /// Sign a message using the hybrid ECDSA + ML-DSA-44 scheme.
    ///
    /// XMTP passes the signature text as a plain string. The PQ account's
    /// `isValidSignature(bytes32 hash, bytes signature)` expects:
    ///   - `hash` = the EIP-191 hash of the message
    ///   - `signature` = ABI-encoded hybrid signature (ECDSA + ML-DSA-44)
    ///
    /// The XMTP SDK handles EIP-191 hashing internally for SCW verification,
    /// so we sign the raw message bytes and return the hybrid signature.
    public func sign(_ message: String) async throws -> SignedData {
        // 1. Hash the message with EIP-191 prefix (personal_sign)
        //    This matches what isValidSignature will verify against
        let messageData = Data(message.utf8)
        let messageHash = try await wallet.signMessageHash(messageData)
        
        // 2. Sign with ML-DSA-44
        let mldsaSignature = try await pqKeyManager.sign(message: messageHash)
        
        // 3. Build hybrid signature: ABI-encode(ecdsaSig, mldsaSig)
        //    ECDSA signs the same hash via the wallet's personal_sign
        let ecdsaSignature = try await wallet.signMessage(message)
        
        let hybridSignature = ABIEncoder.encodeHybridSignature(
            preQuantumSig: ecdsaSignature,
            postQuantumSig: mldsaSignature
        )
        
        return SignedData(rawData: hybridSignature)
    }
}

// MARK: - EmbeddedWallet Extension for PQ Signing

extension EmbeddedWallet {
    /// Hash a message with EIP-191 personal_sign prefix without signing.
    /// Returns keccak256("\x19Ethereum Signed Message:\n" + len(message) + message)
    func signMessageHash(_ message: Data) throws -> Data {
        let prefix = "\u{19}Ethereum Signed Message:\n\(message.count)"
        guard let prefixData = prefix.data(using: .ascii) else {
            throw WalletError.invalidMessage
        }
        let prefixed = prefixData + message
        return Data(prefixed.sha3(.keccak256))
    }
}
