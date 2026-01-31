//
// OfflineTransactionQueueTests.swift
// bitchatTests
//
// Tests for OfflineTransactionQueue and transaction relay functionality.
// This is free and unencumbered software released into the public domain.
//

import Testing
import Foundation
@testable import bitchat

@Suite("Offline Transaction Queue")
struct OfflineTransactionQueueTests {
    
    // MARK: - Relay Strategy Tests
    
    @Test func relayStrategy_displaysCorrectNames() {
        #expect(!TransactionRelayStrategy.relayFirst.displayName.isEmpty)
        #expect(!TransactionRelayStrategy.queueOnly.displayName.isEmpty)
    }
    
    @Test func relayStrategy_hasDescriptions() {
        for strategy in TransactionRelayStrategy.allCases {
            #expect(!strategy.description.isEmpty)
        }
    }
    
    @Test func relayStrategy_allCases() {
        let cases = TransactionRelayStrategy.allCases
        #expect(cases.count == 2)
        #expect(cases.contains(.relayFirst))
        #expect(cases.contains(.queueOnly))
    }
    
    // MARK: - Queue Initialization Tests
    
    @Test @MainActor func queue_startsEmpty() async {
        let keychain = MockKeychain()
        let queue = OfflineTransactionQueue(keychain: keychain)
        
        #expect(queue.pendingTransactions.isEmpty)
    }
    
    @Test @MainActor func queue_defaultStrategyIsRelayFirst() async {
        let keychain = MockKeychain()
        let queue = OfflineTransactionQueue(keychain: keychain)
        
        #expect(queue.relayStrategy == .relayFirst)
    }
    
    // MARK: - Transaction Status Tests
    
    @Test func transactionStatus_hasCorrectDisplayText() {
        #expect(PendingTransactionStatus.pending.rawValue == "pending")
        #expect(PendingTransactionStatus.relaying.rawValue == "relaying")
        #expect(PendingTransactionStatus.relayed.rawValue == "relayed")
        #expect(PendingTransactionStatus.submitted.rawValue == "submitted")
        #expect(PendingTransactionStatus.confirmed.rawValue == "confirmed")
        #expect(PendingTransactionStatus.failed.rawValue == "failed")
    }
    
    // MARK: - Transaction Request Tests
    
    @Test func transactionRequest_encodesCorrectly() {
        let call = TransactionCall(
            to: "0x1234567890123456789012345678901234567890",
            value: "1000000000000000000",
            data: "0x",
            metadata: nil
        )
        let request = TransactionRequest(
            chainId: "1",
            from: "0xabcdef1234567890abcdef1234567890abcdef12",
            calls: [call]
        )
        
        #expect(request.chainId == "1")
        #expect(request.calls.count == 1)
        #expect(request.calls[0].to == "0x1234567890123456789012345678901234567890")
        #expect(request.from == "0xabcdef1234567890abcdef1234567890abcdef12")
    }
    
    @Test func transactionCall_withMetadata() {
        let metadata = TransactionMetadata(
            description: "Test transaction",
            transactionType: "transfer",
            currency: "ETH",
            amount: 1000000000000000000,
            decimals: 18,
            toAddress: "0x0000000000000000000000000000000000000000"
        )
        let call = TransactionCall(
            to: "0x0000000000000000000000000000000000000000",
            value: "0",
            data: "0xabcdef",
            metadata: metadata
        )
        
        #expect(call.metadata?.description == "Test transaction")
        #expect(call.metadata?.transactionType == "transfer")
    }
    
    // MARK: - Pending Transaction Tests
    
    @Test func pendingTransaction_hasIdFromRequest() {
        let request = TransactionRequest(
            chainId: "1",
            from: "0xabcdef1234567890abcdef1234567890abcdef12",
            calls: []
        )
        let tx = PendingTransaction(
            request: request,
            recipientInboxId: "inbox1"
        )
        
        #expect(tx.id == request.id)
    }
    
    @Test func pendingTransaction_startsAsPending() {
        let request = TransactionRequest(
            chainId: "1",
            from: "0xabcdef1234567890abcdef1234567890abcdef12",
            calls: []
        )
        let tx = PendingTransaction(
            request: request,
            recipientInboxId: "inbox"
        )
        
        #expect(tx.status == .pending)
    }
    
    @Test func pendingTransaction_hasCreatedAt() {
        let before = Date()
        let request = TransactionRequest(
            chainId: "1",
            from: "0xabcdef1234567890abcdef1234567890abcdef12",
            calls: []
        )
        let tx = PendingTransaction(
            request: request,
            recipientInboxId: "inbox"
        )
        let after = Date()
        
        #expect(tx.createdAt >= before)
        #expect(tx.createdAt <= after)
    }
    
    @Test func pendingTransaction_relayedViaStartsNil() {
        let request = TransactionRequest(
            chainId: "1",
            from: "0xabcdef1234567890abcdef1234567890abcdef12",
            calls: []
        )
        let tx = PendingTransaction(
            request: request,
            recipientInboxId: "inbox"
        )
        
        #expect(tx.relayedVia == nil)
    }
    
    // MARK: - Clear Queue Tests
    
    @MainActor
    @Test func clearAll_emptiesQueue() {
        let keychain = MockKeychain()
        let queue = OfflineTransactionQueue(keychain: keychain)
        
        // Queue is already empty, verify clearAll doesn't crash
        queue.clearAll()
        
        #expect(queue.pendingTransactions.isEmpty)
    }
}
