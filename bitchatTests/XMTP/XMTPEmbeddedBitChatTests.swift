//
// XMTPEmbeddedBitChatTests.swift
// bitchatTests
//
// Tests for XMTPEmbeddedBitChat packet encoding and decoding.
// This is free and unencumbered software released into the public domain.
//

import Testing
import Foundation
@testable import bitchat

@Suite("XMTP Embedded BitChat Packets")
struct XMTPEmbeddedBitChatTests {
    
    // MARK: - PM Encoding Tests
    
    @Test func encodePM_createsValidPacket() {
        let recipientPeerID = PeerID(str: "recipient123")
        let senderPeerID = PeerID(str: "sender456")
        
        let encoded = XMTPEmbeddedBitChat.encodePM(
            content: "Hello, World!",
            messageID: "msg-123",
            recipientPeerID: recipientPeerID,
            senderPeerID: senderPeerID
        )
        
        #expect(encoded != nil)
        #expect(encoded!.hasPrefix("bitchat1:"))
    }
    
    @Test func encodePM_decodesCorrectly() {
        let recipientPeerID = PeerID(str: "recipient123")
        let senderPeerID = PeerID(str: "sender456")
        let content = "Hello, World!"
        let messageID = "msg-123"
        
        let encoded = XMTPEmbeddedBitChat.encodePM(
            content: content,
            messageID: messageID,
            recipientPeerID: recipientPeerID,
            senderPeerID: senderPeerID
        )!
        
        let decoded = XMTPEmbeddedBitChat.decode(encoded)
        
        #expect(decoded != nil)
        #expect(decoded!["type"] as? String == "pm")
        #expect(decoded!["content"] as? String == content)
        #expect(decoded!["messageID"] as? String == messageID)
        #expect(decoded!["recipient"] as? String == recipientPeerID.id)
        #expect(decoded!["sender"] as? String == senderPeerID.id)
        #expect(decoded!["timestamp"] != nil)
    }
    
    // MARK: - ACK Encoding Tests
    
    @Test func encodeAck_createsValidDeliveredAck() {
        let senderPeerID = PeerID(str: "sender456")
        
        let encoded = XMTPEmbeddedBitChat.encodeAck(
            type: .delivered,
            messageID: "msg-123",
            senderPeerID: senderPeerID
        )
        
        #expect(encoded != nil)
        #expect(encoded!.hasPrefix("bitchat1:"))
    }
    
    @Test func encodeAck_createsValidReadReceiptAck() {
        let senderPeerID = PeerID(str: "sender456")
        
        let encoded = XMTPEmbeddedBitChat.encodeAck(
            type: .readReceipt,
            messageID: "msg-123",
            senderPeerID: senderPeerID
        )
        
        let decoded = XMTPEmbeddedBitChat.decode(encoded!)
        
        #expect(decoded!["type"] as? String == "ack")
        #expect(decoded!["ackType"] as? String == "READ")
    }
    
    @Test func encodeAck_decodesCorrectly() {
        let senderPeerID = PeerID(str: "sender456")
        let messageID = "msg-456"
        
        let encoded = XMTPEmbeddedBitChat.encodeAck(
            type: .delivered,
            messageID: messageID,
            senderPeerID: senderPeerID
        )!
        
        let decoded = XMTPEmbeddedBitChat.decode(encoded)
        
        #expect(decoded != nil)
        #expect(decoded!["type"] as? String == "ack")
        #expect(decoded!["ackType"] as? String == "DELIVERED")
        #expect(decoded!["messageID"] as? String == messageID)
        #expect(decoded!["sender"] as? String == senderPeerID.id)
    }
    
    // MARK: - File Encoding Tests
    
    @Test func encodeFile_createsValidVoicePacket() {
        let packet = BitchatFilePacket(
            fileName: "voice_20240101.m4a",
            fileSize: 1024,
            mimeType: "audio/mp4",
            content: Data(repeating: 0xAA, count: 100)
        )
        let senderPeerID = PeerID(str: "sender456")
        
        let encoded = XMTPEmbeddedBitChat.encodeFile(
            packet: packet,
            fileType: .voice,
            transferId: "transfer-123",
            recipientPeerID: nil,
            senderPeerID: senderPeerID
        )
        
        #expect(encoded != nil)
        #expect(encoded!.hasPrefix("bitchat1:"))
    }
    
    @Test func encodeFile_decodesVoiceCorrectly() {
        let originalContent = Data(repeating: 0xBB, count: 50)
        let packet = BitchatFilePacket(
            fileName: "voice_test.m4a",
            fileSize: nil,
            mimeType: "audio/aac",
            content: originalContent
        )
        let senderPeerID = PeerID(str: "sender456")
        let recipientPeerID = PeerID(str: "recipient123")
        
        let encoded = XMTPEmbeddedBitChat.encodeFile(
            packet: packet,
            fileType: .voice,
            transferId: "transfer-voice",
            recipientPeerID: recipientPeerID,
            senderPeerID: senderPeerID
        )!
        
        let decoded = XMTPEmbeddedBitChat.decode(encoded)
        
        #expect(decoded != nil)
        #expect(decoded!["type"] as? String == "file")
        #expect(decoded!["fileType"] as? String == "voice")
        #expect(decoded!["fileName"] as? String == "voice_test.m4a")
        #expect(decoded!["mimeType"] as? String == "audio/aac")
        #expect(decoded!["transferId"] as? String == "transfer-voice")
        #expect(decoded!["recipient"] as? String == recipientPeerID.id)
    }
    
    @Test func encodeFile_decodesImageCorrectly() {
        let originalContent = Data(repeating: 0xCC, count: 200)
        let packet = BitchatFilePacket(
            fileName: "image_test.jpg",
            fileSize: 200,
            mimeType: "image/jpeg",
            content: originalContent
        )
        let senderPeerID = PeerID(str: "sender456")
        
        let encoded = XMTPEmbeddedBitChat.encodeFile(
            packet: packet,
            fileType: .image,
            transferId: "transfer-image",
            recipientPeerID: nil,
            senderPeerID: senderPeerID
        )!
        
        let decoded = XMTPEmbeddedBitChat.decode(encoded)
        
        #expect(decoded!["fileType"] as? String == "image")
        #expect(decoded!["fileName"] as? String == "image_test.jpg")
        #expect(decoded!["fileSize"] as? UInt64 == 200)
    }
    
    @Test func decodeFilePacket_reconstructsData() {
        let originalContent = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let packet = BitchatFilePacket(
            fileName: "test.bin",
            fileSize: 5,
            mimeType: "application/octet-stream",
            content: originalContent
        )
        let senderPeerID = PeerID(str: "sender456")
        
        let encoded = XMTPEmbeddedBitChat.encodeFile(
            packet: packet,
            fileType: .file,
            transferId: "transfer-bin",
            recipientPeerID: nil,
            senderPeerID: senderPeerID
        )!
        
        let decoded = XMTPEmbeddedBitChat.decode(encoded)!
        let reconstructed = XMTPEmbeddedBitChat.decodeFilePacket(from: decoded)
        
        #expect(reconstructed != nil)
        #expect(reconstructed!.content == originalContent)
        #expect(reconstructed!.fileName == "test.bin")
        #expect(reconstructed!.mimeType == "application/octet-stream")
    }
    
    // MARK: - Decode Edge Cases
    
    @Test func decode_returnsNilForInvalidPrefix() {
        let result = XMTPEmbeddedBitChat.decode("invalid:data")
        #expect(result == nil)
    }
    
    @Test func decode_returnsNilForEmptyContent() {
        let result = XMTPEmbeddedBitChat.decode("bitchat1:")
        #expect(result == nil)
    }
    
    @Test func decode_returnsNilForInvalidBase64() {
        let result = XMTPEmbeddedBitChat.decode("bitchat1:!!!invalid!!!")
        #expect(result == nil)
    }
    
    @Test func decode_returnsNilForNonJSON() {
        // Valid base64 but not JSON
        let notJson = Data("not json".utf8).base64EncodedString()
        let result = XMTPEmbeddedBitChat.decode("bitchat1:\(notJson)")
        #expect(result == nil)
    }
    
    // MARK: - Round Trip Tests
    
    @Test func roundTrip_pm_preservesAllFields() {
        let recipientPeerID = PeerID(str: "recipient-roundtrip")
        let senderPeerID = PeerID(str: "sender-roundtrip")
        let content = "Round trip test message with unicode: 🔐💬"
        let messageID = "roundtrip-msg-id"
        
        let encoded = XMTPEmbeddedBitChat.encodePM(
            content: content,
            messageID: messageID,
            recipientPeerID: recipientPeerID,
            senderPeerID: senderPeerID
        )!
        
        let decoded = XMTPEmbeddedBitChat.decode(encoded)!
        
        #expect(decoded["content"] as? String == content)
        #expect(decoded["messageID"] as? String == messageID)
    }
    
    @Test func roundTrip_file_preservesContent() {
        // Test with binary data including null bytes
        let originalContent = Data([0x00, 0x01, 0xFF, 0xFE, 0x00, 0x42])
        let packet = BitchatFilePacket(
            fileName: "binary.dat",
            fileSize: 6,
            mimeType: "application/octet-stream",
            content: originalContent
        )
        let senderPeerID = PeerID(str: "sender")
        
        let encoded = XMTPEmbeddedBitChat.encodeFile(
            packet: packet,
            fileType: .file,
            transferId: "binary-test",
            recipientPeerID: nil,
            senderPeerID: senderPeerID
        )!
        
        let decoded = XMTPEmbeddedBitChat.decode(encoded)!
        let reconstructed = XMTPEmbeddedBitChat.decodeFilePacket(from: decoded)!
        
        #expect(reconstructed.content == originalContent)
    }
}
