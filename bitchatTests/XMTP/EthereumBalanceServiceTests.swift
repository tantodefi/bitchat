//
// EthereumBalanceServiceTests.swift
// bitchatTests
//
// Tests for EthereumBalanceService and BigUInt implementation.
// This is free and unencumbered software released into the public domain.
//

import Testing
import Foundation
@testable import bitchat

@Suite("Ethereum Balance Service")
struct EthereumBalanceServiceTests {
    
    // MARK: - BigUInt Parsing Tests
    
    @Test func bigUInt_parsesZero() {
        let result = BigUInt(hexString: "0x0")
        #expect(result != nil)
        #expect(result!.isZero)
    }
    
    @Test func bigUInt_parsesSmallValue() {
        let result = BigUInt(hexString: "0x64")
        #expect(result != nil)
        #expect(result!.description == "100")
    }
    
    @Test func bigUInt_parsesLargeValue() {
        // 1 ETH = 10^18 wei = 0xDE0B6B3A7640000
        let result = BigUInt(hexString: "0xDE0B6B3A7640000")
        #expect(result != nil)
        #expect(result!.description == "1000000000000000000")
    }
    
    @Test func bigUInt_parsesWithoutPrefix() {
        let result = BigUInt(hexString: "FF")
        #expect(result != nil)
        #expect(result!.description == "255")
    }
    
    @Test func bigUInt_returnsNilForInvalidHex() {
        let result = BigUInt(hexString: "0xGGG")
        #expect(result == nil)
    }
    
    @Test func bigUInt_parsesEmptyAsZero() {
        let result = BigUInt(hexString: "0x")
        #expect(result != nil)
        #expect(result!.isZero)
    }
    
    // MARK: - BigUInt Arithmetic Tests
    
    @Test func bigUInt_addition() {
        let a = BigUInt(100)
        let b = BigUInt(200)
        let result = a + b
        #expect(result.description == "300")
    }
    
    @Test func bigUInt_subtraction() {
        let a = BigUInt(300)
        let b = BigUInt(100)
        let result = a - b
        #expect(result.description == "200")
    }
    
    @Test func bigUInt_multiplication() {
        let a = BigUInt(1000)
        let b = BigUInt(1000)
        let result = a * b
        #expect(result.description == "1000000")
    }
    
    @Test func bigUInt_division() {
        let a = BigUInt(1000)
        let b = BigUInt(3)
        let result = a / b
        #expect(result.description == "333")
    }
    
    @Test func bigUInt_modulo() {
        let a = BigUInt(1000)
        let b = BigUInt(3)
        let result = a % b
        #expect(result.description == "1")
    }
    
    @Test func bigUInt_power() {
        let base = BigUInt(10)
        let result = base.power(6)
        #expect(result.description == "1000000")
    }
    
    // MARK: - Balance Conversion Tests
    
    @Test func balance_weiToEth() {
        // 1.5 ETH in wei
        let weiString = "1500000000000000000"
        guard let wei = BigUInt(hexString: "0x14D1120D7B160000") else {
            #expect(Bool(false), "Failed to parse wei")
            return
        }
        
        let balance = EthereumBalanceService.Balance(
            network: .ethereum,
            wei: wei,
            lastUpdated: Date()
        )
        
        #expect(balance.eth >= 1.49 && balance.eth <= 1.51, "Should be approximately 1.5 ETH")
    }
    
    @Test func balance_zeroWei() {
        let balance = EthereumBalanceService.Balance(
            network: .ethereum,
            wei: BigUInt(0),
            lastUpdated: Date()
        )
        
        #expect(balance.eth == 0)
        #expect(balance.formattedETH == "0.000000")
    }
    
    @Test func balance_smallWei() {
        // 0.001 ETH = 10^15 wei
        let wei = BigUInt(10).power(15)
        let balance = EthereumBalanceService.Balance(
            network: .ethereum,
            wei: wei,
            lastUpdated: Date()
        )
        
        #expect(balance.eth >= 0.0009 && balance.eth <= 0.0011)
    }
    
    // MARK: - Network Tests
    
    @Test func network_hasCorrectChainIds() {
        #expect(EthereumBalanceService.Network.ethereum.chainId == 1)
        #expect(EthereumBalanceService.Network.base.chainId == 8453)
    }
    
    @Test func network_hasValidRPCURLs() {
        let ethereumURL = EthereumBalanceService.Network.ethereum.rpcURL
        let baseURL = EthereumBalanceService.Network.base.rpcURL
        
        #expect(ethereumURL.absoluteString.contains("flashbots"))
        #expect(baseURL.absoluteString.contains("base"))
    }
    
    // MARK: - Address Validation Tests
    
    @MainActor
    @Test func service_initialState() async {
        let service = EthereumBalanceService()
        
        #expect(service.balances.isEmpty)
        #expect(!service.isLoading)
        #expect(service.lastError == nil)
    }
    
    // MARK: - BigUInt Edge Cases
    
    @Test func bigUInt_handlesMaxUInt64() {
        let maxU64 = BigUInt(UInt64.max)
        #expect(!maxU64.isZero)
        #expect(maxU64.description == String(UInt64.max))
    }
    
    @Test func bigUInt_largeHexParsing() {
        // Very large wei value (100 ETH)
        let result = BigUInt(hexString: "0x56BC75E2D63100000")
        #expect(result != nil)
        #expect(!result!.isZero)
    }
    
    @Test func bigUInt_comparisonEqual() {
        let a = BigUInt(1000)
        let b = BigUInt(1000)
        #expect(a >= b)
        #expect(b >= a)
    }
    
    @Test func bigUInt_comparisonGreater() {
        let a = BigUInt(2000)
        let b = BigUInt(1000)
        #expect(a >= b)
        #expect(!(b >= a) || b == a)
    }
}
