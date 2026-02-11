//
// NamestoneService.swift
// bitchat
//
// Namestone API client for gasless ENS subdomain management.
// Manages .dstealth.eth subdomains for bitchat users.
//
// API Documentation: https://namestone.com/docs
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Service for managing ENS subdomains via Namestone API
actor NamestoneService {
    
    // MARK: - Singleton
    
    static let shared = NamestoneService()
    
    // MARK: - Configuration
    
    private let baseURL = "https://namestone.com/api/public_v1"
    private let domain = "dstealth.eth"
    
    /// API key from secure configuration
    private var apiKey: String { SecureConfig.namestoneAPIKey }
    
    /// Check if service is properly configured
    var isConfigured: Bool { SecureConfig.hasNamestoneAPIKey }
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public API
    
    /// Register a new subdomain for a wallet address
    /// - Parameters:
    ///   - name: The subdomain name (e.g., "alice" for alice.dstealth.eth)
    ///   - address: Ethereum wallet address (0x...)
    ///   - xmtpInboxId: Optional XMTP inbox ID to store as text record
    /// - Returns: True if registration succeeded
    func setName(
        name: String,
        address: String,
        xmtpInboxId: String? = nil
    ) async throws -> Bool {
        guard isConfigured else {
            throw NamestoneError.notConfigured
        }
        
        // Validate and normalize name
        let normalizedName = try validateAndNormalizeName(name)
        
        // Build request body
        var body: [String: Any] = [
            "domain": domain,
            "name": normalizedName,
            "address": address
        ]
        
        // Add text records if we have XMTP inbox ID
        if let inboxId = xmtpInboxId, !inboxId.isEmpty {
            body["text_records"] = [
                "com.xmtp.inbox": inboxId
            ]
        }
        
        let response: NamestoneSuccessResponse = try await post(
            endpoint: "set-name",
            body: body
        )
        
        return response.success
    }
    
    /// Update an existing subdomain with a new name
    /// - Parameters:
    ///   - oldName: Current subdomain name
    ///   - newName: New subdomain name
    ///   - address: Wallet address
    ///   - xmtpInboxId: Optional XMTP inbox ID
    /// - Returns: True if update succeeded
    func updateName(
        oldName: String,
        newName: String,
        address: String,
        xmtpInboxId: String? = nil
    ) async throws -> Bool {
        guard isConfigured else {
            throw NamestoneError.notConfigured
        }
        
        // Delete old name first
        _ = try? await deleteName(name: oldName)
        
        // Register new name
        return try await setName(
            name: newName,
            address: address,
            xmtpInboxId: xmtpInboxId
        )
    }
    
    /// Get names registered to a wallet address
    /// - Parameter address: Ethereum wallet address
    /// - Returns: Array of registered names
    func getNames(address: String) async throws -> [NamestoneRecord] {
        guard isConfigured else {
            throw NamestoneError.notConfigured
        }
        
        let params = [
            "domain": domain,
            "address": address
        ]
        
        return try await get(endpoint: "get-names", params: params)
    }
    
    /// Search for a name to check availability
    /// - Parameters:
    ///   - name: Name to search for
    ///   - exactMatch: If true, only return exact matches
    /// - Returns: Array of matching names (empty if available)
    func searchName(name: String, exactMatch: Bool = false) async throws -> [NamestoneRecord] {
        // Search endpoint doesn't require auth for public names
        var params = [
            "domain": domain,
            "name": name.lowercased()
        ]
        
        if exactMatch {
            params["exact_match"] = "1"
        }
        
        return try await get(endpoint: "search-names", params: params)
    }
    
    /// Check if a name is available for registration
    /// - Parameter name: Name to check
    /// - Returns: True if available
    func isNameAvailable(_ name: String) async throws -> Bool {
        let normalizedName = name.lowercased().trimmingCharacters(in: .whitespaces)
        let results = try await searchName(name: normalizedName, exactMatch: true)
        return results.isEmpty
    }
    
    /// Delete a subdomain
    /// - Parameter name: Subdomain name to delete
    /// - Returns: True if deletion succeeded
    func deleteName(name: String) async throws -> Bool {
        guard isConfigured else {
            throw NamestoneError.notConfigured
        }
        
        let body: [String: Any] = [
            "domain": domain,
            "name": name.lowercased()
        ]
        
        let response: NamestoneSuccessResponse = try await post(
            endpoint: "delete-name",
            body: body
        )
        
        return response.success
    }
    
    // MARK: - Private Helpers
    
    /// Validate and normalize a subdomain name
    private func validateAndNormalizeName(_ name: String) throws -> String {
        let normalized = name.lowercased().trimmingCharacters(in: .whitespaces)
        
        // Check length
        guard normalized.count >= 1, normalized.count <= 32 else {
            throw NamestoneError.invalidName("Name must be 1-32 characters")
        }
        
        // Check characters (alphanumeric and hyphens only, no leading/trailing hyphens)
        let validCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard normalized.unicodeScalars.allSatisfy({ validCharacters.contains($0) }) else {
            throw NamestoneError.invalidName("Name can only contain letters, numbers, and hyphens")
        }
        
        guard !normalized.hasPrefix("-"), !normalized.hasSuffix("-") else {
            throw NamestoneError.invalidName("Name cannot start or end with a hyphen")
        }
        
        return normalized
    }
    
    /// Make a GET request
    private func get<T: Decodable>(endpoint: String, params: [String: String]) async throws -> T {
        var components = URLComponents(string: "\(baseURL)/\(endpoint)")!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        
        guard let url = components.url else {
            throw NamestoneError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue(apiKey, forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        try validateResponse(response, data: data)
        
        return try JSONDecoder().decode(T.self, from: data)
    }
    
    /// Make a POST request
    private func post<T: Decodable>(endpoint: String, body: [String: Any]) async throws -> T {
        guard let url = URL(string: "\(baseURL)/\(endpoint)") else {
            throw NamestoneError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(apiKey, forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        try validateResponse(response, data: data)
        
        return try JSONDecoder().decode(T.self, from: data)
    }
    
    /// Validate HTTP response
    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NamestoneError.networkError("Invalid response type")
        }
        
        switch httpResponse.statusCode {
        case 200...299:
            return // Success
        case 401:
            throw NamestoneError.unauthorized
        case 404:
            throw NamestoneError.notFound
        case 409:
            throw NamestoneError.nameAlreadyTaken
        case 429:
            throw NamestoneError.rateLimited
        default:
            // Try to parse error message
            if let errorResponse = try? JSONDecoder().decode(NamestoneErrorResponse.self, from: data) {
                throw NamestoneError.apiError(errorResponse.message ?? "Unknown error")
            }
            throw NamestoneError.networkError("HTTP \(httpResponse.statusCode)")
        }
    }
}

// MARK: - Response Models

struct NamestoneSuccessResponse: Codable {
    let success: Bool
}

struct NamestoneErrorResponse: Codable {
    let success: Bool?
    let message: String?
    let error: String?
}

/// Record representing a registered subdomain
struct NamestoneRecord: Codable {
    let name: String
    let domain: String
    let address: String
    let textRecords: [String: String]?
    let coinTypes: [String: String]?
    
    enum CodingKeys: String, CodingKey {
        case name, domain, address
        case textRecords = "text_records"
        case coinTypes = "coin_types"
    }
    
    /// Full ENS name (e.g., "alice.dstealth.eth")
    var fullName: String { "\(name).\(domain)" }
    
    /// Extract XMTP inbox ID from text records
    var xmtpInboxId: String? { textRecords?["com.xmtp.inbox"] }
}

// MARK: - Errors

enum NamestoneError: Error, LocalizedError {
    case notConfigured
    case invalidURL
    case invalidName(String)
    case unauthorized
    case notFound
    case nameAlreadyTaken
    case rateLimited
    case networkError(String)
    case apiError(String)
    
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Namestone API key not configured"
        case .invalidURL:
            return "Invalid API URL"
        case .invalidName(let reason):
            return "Invalid name: \(reason)"
        case .unauthorized:
            return "Invalid API key"
        case .notFound:
            return "Name not found"
        case .nameAlreadyTaken:
            return "This name is already taken"
        case .rateLimited:
            return "Too many requests. Please try again later."
        case .networkError(let details):
            return "Network error: \(details)"
        case .apiError(let message):
            return message
        }
    }
}
