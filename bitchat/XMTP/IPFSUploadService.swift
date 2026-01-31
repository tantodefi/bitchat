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
