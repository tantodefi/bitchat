//
// EthereumBalanceService.swift
// bitchat
//
// Privacy-focused Ethereum balance fetching using Flashbots Protect RPC via Tor.
// Flashbots Protect prevents transaction frontrunning and provides additional privacy.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Combine
import Foundation
import Tor

/// Service for fetching Ethereum wallet balances using privacy-focused RPC providers.
/// Routes requests through Tor for additional anonymity.
@MainActor
final class EthereumBalanceService: ObservableObject {
    /// Supported networks for balance fetching
    enum Network: String, CaseIterable {
        case ethereum = "Ethereum"
        case base = "Base"
        
        var chainId: Int {
            switch self {
            case .ethereum: return 1
            case .base: return 8453
            }
        }
        
        var rpcURL: URL {
            switch self {
            case .ethereum:
                // Flashbots Protect RPC - private, no frontrunning
                // https://docs.flashbots.net/flashbots-protect/quick-start
                return URL(string: "https://rpc.flashbots.net")!
            case .base:
                // Base public RPC (consider privacy alternatives in production)
                return URL(string: "https://mainnet.base.org")!
            }
        }
    }
    
    struct Balance: Equatable {
        let network: Network
        let wei: BigUInt
        let lastUpdated: Date
        
        var eth: Double {
            let divisor = BigUInt(10).power(18)
            let wholePart = wei / divisor
            let fractionalPart = wei % divisor
            
            // Convert to Double with reasonable precision
            let fractionalDouble = fractionalPart.toDouble() / divisor.toDouble()
            return wholePart.toDouble() + fractionalDouble
        }
        
        var formattedETH: String {
            String(format: "%.6f", eth)
        }
    }
    
    // MARK: - Published State
    
    @Published private(set) var balances: [Network: Balance] = [:]
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?
    
    // MARK: - Properties
    
    private let defaultNetworks: [Network] = [.ethereum, .base]
    
    // MARK: - Public Methods
    
    /// Fetches balance for the given address on all supported networks
    func fetchBalances(for address: String) async {
        guard isValidAddress(address) else {
            lastError = "Invalid Ethereum address"
            return
        }
        
        isLoading = true
        lastError = nil
        
        await withTaskGroup(of: (Network, Balance?).self) { group in
            for network in defaultNetworks {
                group.addTask { [weak self] in
                    guard let self = self else { return (network, nil) }
                    let balance = await self.fetchBalance(for: address, network: network)
                    return (network, balance)
                }
            }
            
            for await (network, balance) in group {
                if let balance = balance {
                    balances[network] = balance
                }
            }
        }
        
        isLoading = false
    }
    
    /// Fetches balance for a specific network
    func fetchBalance(for address: String, network: Network) async -> Balance? {
        let session = TorURLSession.shared.session
        
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "eth_getBalance",
            "params": [address, "latest"],
            "id": 1
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            SecureLogger.error("EthereumBalanceService: Failed to encode request", category: .network)
            return nil
        }
        
        var request = URLRequest(url: network.rpcURL)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                SecureLogger.warning("EthereumBalanceService: Bad response for \(network.rawValue)", category: .network)
                return nil
            }
            
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resultHex = json["result"] as? String else {
                SecureLogger.warning("EthereumBalanceService: Invalid JSON for \(network.rawValue)", category: .network)
                return nil
            }
            
            // Parse hex balance
            guard let wei = BigUInt(hexString: resultHex) else {
                SecureLogger.warning("EthereumBalanceService: Failed to parse balance hex", category: .network)
                return nil
            }
            
            SecureLogger.debug("EthereumBalanceService: \(network.rawValue) balance = \(wei)", category: .network)
            
            return Balance(network: network, wei: wei, lastUpdated: Date())
        } catch {
            SecureLogger.error("EthereumBalanceService: \(error.localizedDescription)", category: .network)
            await MainActor.run {
                lastError = error.localizedDescription
            }
            return nil
        }
    }
    
    /// Clears all cached balances
    func clearBalances() {
        balances.removeAll()
        lastError = nil
    }
    
    // MARK: - Private Helpers
    
    private func isValidAddress(_ address: String) -> Bool {
        // Basic Ethereum address validation
        let stripped = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
        guard stripped.count == 40 else { return false }
        return stripped.allSatisfy { $0.isHexDigit }
    }
}

// MARK: - BigUInt (Minimal Implementation)

/// Minimal unsigned big integer for wei handling.
/// Avoids external dependencies while supporting 256-bit values.
struct BigUInt: Equatable, CustomStringConvertible {
    private var words: [UInt64]
    
    init(_ value: UInt64 = 0) {
        self.words = value == 0 ? [] : [value]
    }
    
    init?(hexString: String) {
        let hex = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard !hex.isEmpty else {
            self.words = []
            return
        }
        
        // Parse hex string in 16-character (64-bit) chunks from right to left
        var result: [UInt64] = []
        var remaining = hex
        
        while !remaining.isEmpty {
            let chunkEnd = remaining.endIndex
            let chunkStart = remaining.index(chunkEnd, offsetBy: -min(16, remaining.count))
            let chunk = String(remaining[chunkStart..<chunkEnd])
            
            guard let value = UInt64(chunk, radix: 16) else { return nil }
            result.append(value)
            remaining = String(remaining[..<chunkStart])
        }
        
        // Remove leading zeros
        while result.last == 0 { result.removeLast() }
        self.words = result
    }
    
    var description: String {
        if words.isEmpty { return "0" }
        // Simple decimal conversion for display
        return toDecimalString()
    }
    
    /// Convert to Double (may lose precision for very large values)
    func toDouble() -> Double {
        if words.isEmpty { return 0 }
        
        // For small values, use direct conversion
        if words.count == 1 {
            return Double(words[0])
        }
        
        // For larger values, combine words
        var result: Double = 0
        let multiplier: Double = pow(2, 64)
        var wordMultiplier: Double = 1
        
        for word in words {
            result += Double(word) * wordMultiplier
            wordMultiplier *= multiplier
        }
        
        return result
    }
    
    private func toDecimalString() -> String {
        if words.isEmpty { return "0" }
        
        // For small values, use direct conversion
        if words.count == 1 {
            return String(words[0])
        }
        
        // For larger values, use repeated division
        var result = ""
        var current = self
        let ten = BigUInt(10)
        
        while !current.isZero {
            let (quotient, remainder) = current.dividedBy(ten)
            result = remainder.description + result
            current = quotient
        }
        
        return result.isEmpty ? "0" : result
    }
    
    var isZero: Bool {
        words.isEmpty || words.allSatisfy { $0 == 0 }
    }
    
    static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var result: [UInt64] = []
        var carry: UInt64 = 0
        let maxLen = max(lhs.words.count, rhs.words.count)
        
        for i in 0..<maxLen {
            let a = i < lhs.words.count ? lhs.words[i] : 0
            let b = i < rhs.words.count ? rhs.words[i] : 0
            let (sum1, overflow1) = a.addingReportingOverflow(b)
            let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
            result.append(sum2)
            carry = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
        }
        
        if carry > 0 { result.append(carry) }
        while result.last == 0 { result.removeLast() }
        
        var bigUInt = BigUInt()
        bigUInt.words = result
        return bigUInt
    }
    
    static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        if lhs.isZero || rhs.isZero { return BigUInt() }
        
        var result = Array(repeating: UInt64(0), count: lhs.words.count + rhs.words.count)
        
        for i in 0..<lhs.words.count {
            var carry: UInt64 = 0
            for j in 0..<rhs.words.count {
                let (high, low) = lhs.words[i].multipliedFullWidth(by: rhs.words[j])
                let (sum1, o1) = result[i + j].addingReportingOverflow(low)
                let (sum2, o2) = sum1.addingReportingOverflow(carry)
                result[i + j] = sum2
                carry = high + (o1 ? 1 : 0) + (o2 ? 1 : 0)
            }
            if carry > 0 { result[i + rhs.words.count] = carry }
        }
        
        while result.last == 0 { result.removeLast() }
        var bigUInt = BigUInt()
        bigUInt.words = result
        return bigUInt
    }
    
    static func / (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        lhs.dividedBy(rhs).quotient
    }
    
    static func % (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        lhs.dividedBy(rhs).remainder
    }
    
    func dividedBy(_ divisor: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        if divisor.isZero { fatalError("Division by zero") }
        if self.isZero { return (BigUInt(), BigUInt()) }
        
        // Simple case: single word divisor
        if divisor.words.count == 1 {
            let (q, r) = dividedBySingleWord(divisor.words[0])
            return (q, BigUInt(r))
        }
        
        // For larger divisors, use long division (simplified)
        var quotient = BigUInt()
        var remainder = BigUInt()
        
        let bits = words.count * 64
        for i in (0..<bits).reversed() {
            remainder = remainder * BigUInt(2)
            if getBit(i) {
                remainder = remainder + BigUInt(1)
            }
            if remainder >= divisor {
                remainder = remainder - divisor
                quotient.setBit(i)
            }
        }
        
        return (quotient, remainder)
    }
    
    private func dividedBySingleWord(_ divisor: UInt64) -> (quotient: BigUInt, remainder: UInt64) {
        var quotientWords: [UInt64] = []
        var remainder: UInt64 = 0
        
        for word in words.reversed() {
            let dividend = (DoubleWord(remainder) << 64) | DoubleWord(word)
            let (q, r) = dividend.quotientAndRemainder(dividingBy: DoubleWord(divisor))
            quotientWords.insert(q.low, at: 0)
            remainder = r.low
        }
        
        while quotientWords.last == 0 { quotientWords.removeLast() }
        var quotient = BigUInt()
        quotient.words = quotientWords
        return (quotient, remainder)
    }
    
    private func getBit(_ index: Int) -> Bool {
        let wordIndex = index / 64
        let bitIndex = index % 64
        guard wordIndex < words.count else { return false }
        return (words[wordIndex] >> bitIndex) & 1 == 1
    }
    
    private mutating func setBit(_ index: Int) {
        let wordIndex = index / 64
        let bitIndex = index % 64
        while words.count <= wordIndex { words.append(0) }
        words[wordIndex] |= (1 << bitIndex)
    }
    
    static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var result: [UInt64] = []
        var borrow: UInt64 = 0
        
        for i in 0..<lhs.words.count {
            let a = lhs.words[i]
            let b = i < rhs.words.count ? rhs.words[i] : 0
            let (diff1, overflow1) = a.subtractingReportingOverflow(b)
            let (diff2, overflow2) = diff1.subtractingReportingOverflow(borrow)
            result.append(diff2)
            borrow = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
        }
        
        while result.last == 0 { result.removeLast() }
        var bigUInt = BigUInt()
        bigUInt.words = result
        return bigUInt
    }
    
    static func >= (lhs: BigUInt, rhs: BigUInt) -> Bool {
        if lhs.words.count != rhs.words.count {
            return lhs.words.count > rhs.words.count
        }
        for i in (0..<lhs.words.count).reversed() {
            if lhs.words[i] != rhs.words[i] {
                return lhs.words[i] > rhs.words[i]
            }
        }
        return true
    }
    
    func power(_ exponent: Int) -> BigUInt {
        if exponent == 0 { return BigUInt(1) }
        var result = BigUInt(1)
        var base = self
        var exp = exponent
        
        while exp > 0 {
            if exp & 1 == 1 {
                result = result * base
            }
            base = base * base
            exp >>= 1
        }
        
        return result
    }
}

// MARK: - DoubleWord Helper (for division)

private struct DoubleWord {
    let high: UInt64
    let low: UInt64
    
    init(_ value: UInt64) {
        self.high = 0
        self.low = value
    }
    
    init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }
    
    static func << (lhs: DoubleWord, rhs: Int) -> DoubleWord {
        if rhs >= 128 { return DoubleWord(0) }
        if rhs >= 64 {
            return DoubleWord(high: lhs.low << (rhs - 64), low: 0)
        }
        if rhs == 0 { return lhs }
        let newHigh = (lhs.high << rhs) | (lhs.low >> (64 - rhs))
        let newLow = lhs.low << rhs
        return DoubleWord(high: newHigh, low: newLow)
    }
    
    static func | (lhs: DoubleWord, rhs: DoubleWord) -> DoubleWord {
        DoubleWord(high: lhs.high | rhs.high, low: lhs.low | rhs.low)
    }
    
    func quotientAndRemainder(dividingBy divisor: DoubleWord) -> (DoubleWord, DoubleWord) {
        // Simple division for our use case (divisor fits in UInt64)
        if divisor.high == 0 && high == 0 {
            let (q, r) = low.quotientAndRemainder(dividingBy: divisor.low)
            return (DoubleWord(q), DoubleWord(r))
        }
        
        // For cases where dividend is 128-bit but divisor is 64-bit
        if divisor.high == 0 {
            let div = divisor.low
            let (qHigh, remHigh) = high.quotientAndRemainder(dividingBy: div)
            let combined = (DoubleWord(remHigh) << 64) | DoubleWord(low)
            // Approximate division
            let qLow = combined.low / div
            let remainder = combined.low % div
            return (DoubleWord(high: qHigh, low: qLow), DoubleWord(remainder))
        }
        
        // Fallback for larger divisors
        return (DoubleWord(0), self)
    }
}
