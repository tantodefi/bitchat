//
// IPFSUploadService.swift
// Bitchat
//
// File upload service for XMTP remote attachments
// Uses anonymous file hosting services as IPFS pinning services require auth
//

import Foundation
import BitLogger

/// Service for uploading encrypted attachments for XMTP remote attachments
actor IPFSUploadService {
    static let shared = IPFSUploadService()
    
    enum UploadError: Error, LocalizedError {
        case uploadFailed(String)
        case allEndpointsFailed
        case invalidResponse
        case fileTooLarge
        
        var errorDescription: String? {
            switch self {
            case .uploadFailed(let reason):
                return "Upload failed: \(reason)"
            case .allEndpointsFailed:
                return "All upload endpoints failed"
            case .invalidResponse:
                return "Invalid response from server"
            case .fileTooLarge:
                return "File exceeds maximum size for upload"
            }
        }
    }
    
    /// Maximum file size (10MB)
    private let maxFileSize = 10 * 1024 * 1024
    
    private init() {}
    
    /// Upload data and return the HTTPS URL
    /// - Parameters:
    ///   - data: The data to upload
    ///   - filename: The filename for the upload
    /// - Returns: HTTPS URL to access the content
    func upload(_ data: Data, filename: String) async throws -> String {
        guard data.count <= maxFileSize else {
            throw UploadError.fileTooLarge
        }
        
        // Try multiple upload services in order of preference
        var lastError: Error = UploadError.allEndpointsFailed
        
        // Try custom/private endpoint first (recommended for XMTP web compatibility)
        if let endpoint = customUploadEndpoint() {
            do {
                let url = try await uploadToCustomEndpoint(endpoint, data: data, filename: filename)
                SecureLogger.info("📤 Uploaded attachment via custom endpoint: \(filename) -> \(url.prefix(40))…", category: .network)
                return url
            } catch {
                SecureLogger.warning("Custom upload endpoint failed: \(error.localizedDescription)", category: .network)
                lastError = error
            }
        }
        
        // Try 0x0.st first (simple, reliable, no auth needed)
        do {
            let url = try await uploadTo0x0(data, filename: filename)
            SecureLogger.info("📤 Uploaded attachment: \(filename) -> \(url.prefix(40))…", category: .network)
            return url
        } catch {
            SecureLogger.warning("0x0.st upload failed: \(error.localizedDescription)", category: .network)
            lastError = error
        }
        
        // Try catbox.moe as fallback
        do {
            let url = try await uploadToCatbox(data, filename: filename)
            SecureLogger.info("📤 Uploaded attachment: \(filename) -> \(url.prefix(40))…", category: .network)
            return url
        } catch {
            SecureLogger.warning("catbox.moe upload failed: \(error.localizedDescription)", category: .network)
            lastError = error
        }
        
        throw lastError
    }
    
    private func customUploadEndpoint() -> URL? {
        func parseEndpoint(_ raw: String) -> URL? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            
            if let url = URL(string: trimmed), url.scheme == "https" {
                return url
            }
            
            // Allow shorthand values like "example.workers.dev/upload"
            if !trimmed.contains("://"),
               let url = URL(string: "https://\(trimmed)"),
               url.scheme == "https" {
                return url
            }
            
            return nil
        }

        let env = ProcessInfo.processInfo.environment
        if let endpoint = env["XMTP_UPLOAD_ENDPOINT"],
           let url = parseEndpoint(endpoint) {
            return url
        }
        
        if let endpoint = Bundle.main.infoDictionary?["XMTP_UPLOAD_ENDPOINT"] as? String,
           !endpoint.isEmpty,
           endpoint != "$(XMTP_UPLOAD_ENDPOINT)",
           let url = parseEndpoint(endpoint) {
            return url
        }
        
        return nil
    }
    
    private func customUploadBearerToken() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let token = env["XMTP_UPLOAD_BEARER_TOKEN"], !token.isEmpty {
            return token
        }
        
        if let token = Bundle.main.infoDictionary?["XMTP_UPLOAD_BEARER_TOKEN"] as? String,
           !token.isEmpty,
           token != "$(XMTP_UPLOAD_BEARER_TOKEN)" {
            return token
        }
        
        return nil
    }
    
    private struct UploadResponse: Decodable {
        let url: String
    }
    
    private struct WrappedUploadResponse: Decodable {
        let data: UploadResponse?
    }
    
    /// Upload to a custom HTTPS endpoint that returns either:
    /// - plain text URL
    /// - JSON: {"url":"https://..."}
    /// - JSON: {"data":{"url":"https://..."}}
    private func uploadToCustomEndpoint(_ endpoint: URL, data: Data, filename: String) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(filename, forHTTPHeaderField: "X-Filename")
        
        if let bearer = customUploadBearerToken() {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        
        let (responseData, response) = try await URLSession.shared.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse else {
            throw UploadError.uploadFailed("No HTTP response from custom endpoint")
        }
        
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw UploadError.uploadFailed("Custom endpoint HTTP \(http.statusCode): \(body.prefix(120))")
        }
        
        if let plain = String(data: responseData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           plain.hasPrefix("https://") {
            return plain
        }
        
        let decoder = JSONDecoder()
        if let direct = try? decoder.decode(UploadResponse.self, from: responseData),
           direct.url.hasPrefix("https://") {
            return direct.url
        }
        if let wrapped = try? decoder.decode(WrappedUploadResponse.self, from: responseData),
           let url = wrapped.data?.url,
           url.hasPrefix("https://") {
            return url
        }
        
        throw UploadError.invalidResponse
    }
    
    /// Upload to 0x0.st - simple anonymous file hosting
    private func uploadTo0x0(_ data: Data, filename: String) async throws -> String {
        guard let url = URL(string: "https://0x0.st") else {
            throw UploadError.uploadFailed("Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        request.timeoutInterval = 60
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw UploadError.uploadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        
        // 0x0.st returns the URL directly as text
        guard let urlString = String(data: responseData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              urlString.hasPrefix("https://") else {
            throw UploadError.invalidResponse
        }
        
        return urlString
    }
    
    /// Upload to catbox.moe - anonymous file hosting
    private func uploadToCatbox(_ data: Data, filename: String) async throws -> String {
        guard let url = URL(string: "https://catbox.moe/user/api.php") else {
            throw UploadError.uploadFailed("Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        // Add reqtype field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"reqtype\"\r\n\r\n".data(using: .utf8)!)
        body.append("fileupload".data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
        // Add file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"fileToUpload\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        request.timeoutInterval = 60
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw UploadError.uploadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        
        // Catbox returns the URL directly as text
        guard let urlString = String(data: responseData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              urlString.hasPrefix("https://") else {
            throw UploadError.invalidResponse
        }
        
        return urlString
    }
    
    /// Get alternative URLs for a given URL (not applicable for non-IPFS hosting)
    func alternativeURLs(for url: String) -> [String] {
        return [url]
    }
}
