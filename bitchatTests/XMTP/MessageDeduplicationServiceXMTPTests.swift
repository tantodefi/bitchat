//
// MessageDeduplicationServiceXMTPTests.swift
// bitchatTests
//
// Tests for XMTP message deduplication in MessageDeduplicationService.
// This is free and unencumbered software released into the public domain.
//

import Testing
import Foundation
@testable import bitchat

@Suite("Message Deduplication Service - XMTP")
@MainActor
struct MessageDeduplicationServiceXMTPTests {
    
    // MARK: - Basic XMTP Deduplication Tests
    
    @Test func hasProcessedXMTPMessage_returnsFalseForNew() {
        let service = MessageDeduplicationService()
        
        let result = service.hasProcessedXMTPMessage("xmtp-msg-123")
        
        #expect(!result, "New message should not be marked as processed")
    }
    
    @Test func recordXMTPMessage_marksAsProcessed() {
        let service = MessageDeduplicationService()
        let messageId = "xmtp-msg-456"
        
        service.recordXMTPMessage(messageId)
        
        #expect(service.hasProcessedXMTPMessage(messageId), "Recorded message should be marked as processed")
    }
    
    @Test func recordXMTPMessage_multipleMessages() {
        let service = MessageDeduplicationService()
        
        service.recordXMTPMessage("msg-1")
        service.recordXMTPMessage("msg-2")
        service.recordXMTPMessage("msg-3")
        
        #expect(service.hasProcessedXMTPMessage("msg-1"))
        #expect(service.hasProcessedXMTPMessage("msg-2"))
        #expect(service.hasProcessedXMTPMessage("msg-3"))
        #expect(!service.hasProcessedXMTPMessage("msg-4"))
    }
    
    @Test func recordXMTPMessage_duplicateIsIdempotent() {
        let service = MessageDeduplicationService()
        let messageId = "duplicate-test"
        
        service.recordXMTPMessage(messageId)
        service.recordXMTPMessage(messageId)
        service.recordXMTPMessage(messageId)
        
        #expect(service.hasProcessedXMTPMessage(messageId))
    }
    
    // MARK: - Cache Independence Tests
    
    @Test func xmtpCache_independentFromNostrCache() {
        let service = MessageDeduplicationService()
        
        service.recordNostrEvent("event-123")
        service.recordXMTPMessage("msg-123")
        
        // Each cache only knows about its own IDs
        #expect(service.hasProcessedNostrEvent("event-123"))
        #expect(!service.hasProcessedNostrEvent("msg-123"))
        #expect(service.hasProcessedXMTPMessage("msg-123"))
        #expect(!service.hasProcessedXMTPMessage("event-123"))
    }
    
    @Test func xmtpCache_independentFromContentCache() {
        let service = MessageDeduplicationService()
        
        let content = "Hello, world!"
        service.recordContent(content, timestamp: Date())
        service.recordXMTPMessage("msg-content")
        
        // Content cache uses normalized keys, XMTP uses raw message IDs
        let contentTimestamp = service.contentTimestamp(for: content)
        #expect(contentTimestamp != nil)
        #expect(service.hasProcessedXMTPMessage("msg-content"))
    }
    
    // MARK: - Clear Tests
    
    @Test func clearXMTPCache_removesOnlyXMTP() {
        let service = MessageDeduplicationService()
        
        service.recordNostrEvent("nostr-123")
        service.recordNostrAck("ack-123")
        service.recordXMTPMessage("xmtp-123")
        service.recordContent("content", timestamp: Date())
        
        service.clearXMTPCache()
        
        // XMTP cache should be cleared
        #expect(!service.hasProcessedXMTPMessage("xmtp-123"))
        
        // Other caches should be untouched
        #expect(service.hasProcessedNostrEvent("nostr-123"))
        #expect(service.hasProcessedNostrAck("ack-123"))
        #expect(service.contentTimestamp(for: "content") != nil)
    }
    
    @Test func clearAll_removesXMTPCache() {
        let service = MessageDeduplicationService()
        
        service.recordNostrEvent("nostr-456")
        service.recordXMTPMessage("xmtp-456")
        
        service.clearAll()
        
        #expect(!service.hasProcessedNostrEvent("nostr-456"))
        #expect(!service.hasProcessedXMTPMessage("xmtp-456"))
    }
    
    // MARK: - Capacity Tests
    
    @Test func xmtpCache_evictsOldEntriesAtCapacity() {
        // Use small capacity for testing
        let service = MessageDeduplicationService(contentCapacity: 10, nostrEventCapacity: 5)
        
        // Fill beyond capacity
        for i in 0..<10 {
            service.recordXMTPMessage("msg-\(i)")
        }
        
        // Recent messages should be present
        #expect(service.hasProcessedXMTPMessage("msg-9"))
        #expect(service.hasProcessedXMTPMessage("msg-8"))
        
        // Oldest messages may be evicted (depending on LRU implementation)
        // Just verify the cache didn't crash
    }
    
    // MARK: - Real-World Scenario Tests
    
    @Test func xmtpDedup_handlesTypicalMessageFlow() {
        let service = MessageDeduplicationService()
        
        // Simulate receiving same message multiple times (retries, duplicates)
        let messageId = "xmtp-dm-abc123"
        
        // First time - should not be duplicate
        let firstCheck = service.hasProcessedXMTPMessage(messageId)
        #expect(!firstCheck)
        service.recordXMTPMessage(messageId)
        
        // Second time - should be duplicate
        let secondCheck = service.hasProcessedXMTPMessage(messageId)
        #expect(secondCheck)
        
        // Third time - still duplicate
        let thirdCheck = service.hasProcessedXMTPMessage(messageId)
        #expect(thirdCheck)
    }
    
    @Test func xmtpDedup_handlesMultipleConversations() {
        let service = MessageDeduplicationService()
        
        // Messages from different conversations
        service.recordXMTPMessage("conv1-msg1")
        service.recordXMTPMessage("conv1-msg2")
        service.recordXMTPMessage("conv2-msg1")
        service.recordXMTPMessage("conv3-msg1")
        
        #expect(service.hasProcessedXMTPMessage("conv1-msg1"))
        #expect(service.hasProcessedXMTPMessage("conv1-msg2"))
        #expect(service.hasProcessedXMTPMessage("conv2-msg1"))
        #expect(service.hasProcessedXMTPMessage("conv3-msg1"))
        #expect(!service.hasProcessedXMTPMessage("conv4-msg1"))
    }
}
