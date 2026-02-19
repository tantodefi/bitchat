//
// XMTPJSBridge.swift
// bitchat
//
// JavaScriptCore bridge that provides exact CLI-compatible command parsing
// and JSON output formatting, matching the official @xmtp/cli interface.
//
// The xmtp-js CLI depends on @xmtp/node-sdk (native Rust/NAPI bindings)
// which cannot run in JavaScriptCore. Instead, this bridge uses JSCore for:
//   1. CLI command parsing (flags, args, validation) identical to oclif
//   2. JSON response formatting identical to the official CLI output
//   3. Human-readable output formatting with the same layout
//
// Actual XMTP operations are delegated to the native Swift XMTP SDK,
// which talks to the same libxmtp/network backend.
//
// This is free and unencumbered software released into the public domain.
//

import Foundation
import JavaScriptCore

// MARK: - CLI Error

/// Simple error type for CLI parsing failures
struct XMTPCLIParseError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Parsed Command

/// A parsed CLI command matching the @xmtp/cli structure
struct XMTPCLICommand {
    let topic: String          // "client", "conversations", "conversation", "preferences", or "" (root)
    let action: String         // "info", "list", "create-dm", "send-text", etc.
    let args: [String]         // Positional arguments
    let flags: [String: Any]   // Named flags (--json, --limit 10, etc.)
    
    var fullCommand: String {
        topic.isEmpty ? action : "\(topic) \(action)"
    }
}

// MARK: - CLI Output

/// Formatted output matching the official @xmtp/cli JSON schema
struct XMTPCLIOutput: Error {
    let json: String           // JSON string (for --json mode)
    let human: String          // Human-readable string
    let isError: Bool
    
    static func success(data: Any, human: String) -> XMTPCLIOutput {
        let json = XMTPJSBridge.shared.formatJSON(data)
        return XMTPCLIOutput(json: json, human: human, isError: false)
    }
    
    static func error(_ message: String) -> XMTPCLIOutput {
        let errorObj: [String: Any] = ["error": message]
        let json = XMTPJSBridge.shared.formatJSON(errorObj)
        return XMTPCLIOutput(json: json, human: "❌ \(message)", isError: true)
    }
}

// MARK: - JS Bridge

/// JavaScriptCore-powered command parser and JSON formatter
/// that exactly matches the @xmtp/cli interface
final class XMTPJSBridge {
    static let shared = XMTPJSBridge()
    
    private let context: JSContext
    
    private init() {
        context = JSContext()!
        context.exceptionHandler = { _, exception in
            if let err = exception?.toString() {
                print("[XMTPJSBridge] JS Error: \(err)")
            }
        }
        loadCLIParser()
    }
    
    // MARK: - Setup
    
    private func loadCLIParser() {
        // Embed the CLI command parser and formatter as JavaScript
        // This replicates the oclif-style parsing from @xmtp/cli
        let parserJS = """
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // XMTP CLI Command Parser (mirrors @oclif/core parsing)
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        var XMTP_CLI = {};

        // All valid commands from the official @xmtp/cli
        XMTP_CLI.COMMANDS = {
            // Root commands
            'init':                        { topic: '', action: 'init', args: [], flags: ['env', 'force'] },
            'can-message':                 { topic: '', action: 'can-message', args: ['identifiers'], flags: ['env', 'json', 'verbose'], varArgs: true },
            
            // Client commands
            'client info':                 { topic: 'client', action: 'info', args: [], flags: ['json', 'verbose'] },
            'client sign':                 { topic: 'client', action: 'sign', args: ['message'], flags: ['json', 'verbose'] },
            'client verify-signature':     { topic: 'client', action: 'verify-signature', args: ['message'], flags: ['signature', 'json', 'verbose'] },
            'client add-account':          { topic: 'client', action: 'add-account', args: [], flags: ['new-wallet-key', 'force', 'json', 'verbose'] },
            'client remove-account':       { topic: 'client', action: 'remove-account', args: [], flags: ['identifier', 'force', 'json', 'verbose'] },
            'client revoke-installations': { topic: 'client', action: 'revoke-installations', args: [], flags: ['installation-id', 'force', 'json', 'verbose'] },
            'client revoke-all-other-installations': { topic: 'client', action: 'revoke-all-other-installations', args: [], flags: ['force', 'json', 'verbose'] },
            'client change-recovery-identifier': { topic: 'client', action: 'change-recovery-identifier', args: [], flags: ['new-recovery-identifier', 'force', 'json', 'verbose'] },

            // Conversations (plural) commands
            'conversations list':              { topic: 'conversations', action: 'list', args: [], flags: ['type', 'consent-state', 'order-by', 'limit', 'created-after', 'created-before', 'json', 'verbose'] },
            'conversations create-dm':         { topic: 'conversations', action: 'create-dm', args: ['identifier'], flags: ['identifier-kind', 'json', 'verbose'] },
            'conversations create-group':      { topic: 'conversations', action: 'create-group', args: ['members'], flags: ['name', 'description', 'permissions', 'image-url', 'pinned-frame-url', 'json', 'verbose'], varArgs: true },
            'conversations get':               { topic: 'conversations', action: 'get', args: ['id'], flags: ['json', 'verbose'] },
            'conversations get-dm':            { topic: 'conversations', action: 'get-dm', args: ['addressOrInboxId'], flags: ['json', 'verbose'] },
            'conversations get-message':       { topic: 'conversations', action: 'get-message', args: ['id'], flags: ['json', 'verbose'] },
            'conversations sync':              { topic: 'conversations', action: 'sync', args: [], flags: ['json', 'verbose'] },
            'conversations stream':            { topic: 'conversations', action: 'stream', args: [], flags: ['type', 'timeout', 'count', 'disable-sync', 'json', 'verbose'] },
            'conversations stream-all-messages': { topic: 'conversations', action: 'stream-all-messages', args: [], flags: ['type', 'timeout', 'count', 'consent-state', 'disable-sync', 'json', 'verbose'] },

            // Conversation (singular) commands
            'conversation send-text':          { topic: 'conversation', action: 'send-text', args: ['id', 'text'], flags: ['optimistic', 'json', 'verbose'] },
            'conversation send-markdown':      { topic: 'conversation', action: 'send-markdown', args: ['id', 'markdown'], flags: ['optimistic', 'json', 'verbose'] },
            'conversation send-reply':         { topic: 'conversation', action: 'send-reply', args: ['id', 'messageId', 'text'], flags: ['optimistic', 'json', 'verbose'] },
            'conversation send-reaction':      { topic: 'conversation', action: 'send-reaction', args: ['id', 'messageId', 'action', 'emoji'], flags: ['optimistic', 'json', 'verbose'] },
            'conversation messages':           { topic: 'conversation', action: 'messages', args: ['id'], flags: ['limit', 'direction', 'sync', 'sent-before', 'sent-after', 'kind', 'content-type', 'exclude-content-type', 'delivery-status', 'exclude-sender', 'sort-by', 'json', 'verbose'] },
            'conversation count-messages':     { topic: 'conversation', action: 'count-messages', args: ['id'], flags: ['sync', 'sent-before', 'sent-after', 'kind', 'content-type', 'exclude-content-type', 'delivery-status', 'exclude-sender', 'json', 'verbose'] },
            'conversation members':            { topic: 'conversation', action: 'members', args: ['id'], flags: ['json', 'verbose'] },
            'conversation add-members':        { topic: 'conversation', action: 'add-members', args: ['id', 'members'], flags: ['json', 'verbose'], varArgs: true },
            'conversation remove-members':     { topic: 'conversation', action: 'remove-members', args: ['id', 'members'], flags: ['json', 'verbose'], varArgs: true },
            'conversation consent-state':      { topic: 'conversation', action: 'consent-state', args: ['id'], flags: ['json', 'verbose'] },
            'conversation update-consent':     { topic: 'conversation', action: 'update-consent', args: ['id'], flags: ['state', 'json', 'verbose'] },
            'conversation stream':             { topic: 'conversation', action: 'stream', args: ['id'], flags: ['timeout', 'count', 'disable-sync', 'json', 'verbose'] },
            'conversation sync':               { topic: 'conversation', action: 'sync', args: ['id'], flags: ['json', 'verbose'] },
            'conversation publish-messages':   { topic: 'conversation', action: 'publish-messages', args: ['id'], flags: ['json', 'verbose'] },
            'conversation debug-info':         { topic: 'conversation', action: 'debug-info', args: ['id'], flags: ['json', 'verbose'] },
            'conversation permissions':        { topic: 'conversation', action: 'permissions', args: ['id'], flags: ['json', 'verbose'] },
            'conversation leave':              { topic: 'conversation', action: 'leave', args: ['id'], flags: ['force', 'json', 'verbose'] },
            'conversation update-name':        { topic: 'conversation', action: 'update-name', args: ['id', 'name'], flags: ['json', 'verbose'] },
            'conversation update-description': { topic: 'conversation', action: 'update-description', args: ['id', 'description'], flags: ['json', 'verbose'] },
            'conversation update-image-url':   { topic: 'conversation', action: 'update-image-url', args: ['id', 'url'], flags: ['json', 'verbose'] },
            'conversation update-pinned-frame-url': { topic: 'conversation', action: 'update-pinned-frame-url', args: ['id', 'url'], flags: ['json', 'verbose'] },

            // Preferences commands
            'preferences get-consent':     { topic: 'preferences', action: 'get-consent', args: [], flags: ['entity-type', 'entity', 'json', 'verbose'] },
            'preferences set-consent':     { topic: 'preferences', action: 'set-consent', args: [], flags: ['entity-type', 'entity', 'state', 'json', 'verbose'] },
            'preferences inbox-state':     { topic: 'preferences', action: 'inbox-state', args: ['inboxIds'], flags: ['refresh', 'json', 'verbose'], varArgs: true },
            'preferences sync':            { topic: 'preferences', action: 'sync', args: [], flags: ['json', 'verbose'] },
            'preferences stream':          { topic: 'preferences', action: 'stream', args: [], flags: ['timeout', 'json', 'verbose'] },
            'preferences hmac-keys':       { topic: 'preferences', action: 'hmac-keys', args: [], flags: ['json', 'verbose'] }
        };

        // Parse a raw command string into a structured command object
        // Input: "conversations create-dm 0xABC --json"
        // Output: { topic, action, args, flags, error }
        XMTP_CLI.parse = function(input) {
            var tokens = XMTP_CLI.tokenize(input);
            if (tokens.length === 0) {
                return { error: 'Empty command' };
            }

            // Try two-word command first (e.g. "client info"), then one-word (e.g. "can-message")
            var cmdKey = null;
            var cmdDef = null;
            var argStart = 0;

            if (tokens.length >= 2) {
                var twoWord = tokens[0] + ' ' + tokens[1];
                if (XMTP_CLI.COMMANDS[twoWord]) {
                    cmdKey = twoWord;
                    cmdDef = XMTP_CLI.COMMANDS[twoWord];
                    argStart = 2;
                }
            }
            if (!cmdDef && XMTP_CLI.COMMANDS[tokens[0]]) {
                cmdKey = tokens[0];
                cmdDef = XMTP_CLI.COMMANDS[tokens[0]];
                argStart = 1;
            }

            if (!cmdDef) {
                return { error: 'Unknown command: ' + tokens[0] + (tokens.length > 1 ? ' ' + tokens[1] : '') };
            }

            // Parse flags and positional args from remaining tokens
            var flags = {};
            var positional = [];
            var i = argStart;
            while (i < tokens.length) {
                var t = tokens[i];
                if (t.indexOf('--') === 0) {
                    var flagName = t.substring(2);
                    // Boolean flags
                    if (flagName === 'json' || flagName === 'verbose' || flagName === 'force' ||
                        flagName === 'sync' || flagName === 'optimistic' || flagName === 'disable-sync' ||
                        flagName === 'refresh') {
                        flags[flagName] = true;
                    } else if (i + 1 < tokens.length && tokens[i+1].indexOf('--') !== 0) {
                        // Repeatable flags (consent-state, content-type, etc.)
                        i++;
                        if (flags[flagName] !== undefined) {
                            if (!Array.isArray(flags[flagName])) {
                                flags[flagName] = [flags[flagName]];
                            }
                            flags[flagName].push(tokens[i]);
                        } else {
                            flags[flagName] = tokens[i];
                        }
                    } else {
                        flags[flagName] = true;
                    }
                } else {
                    positional.push(t);
                }
                i++;
            }

            // Map positional args to named args based on command definition
            var namedArgs = {};
            if (cmdDef.varArgs && cmdDef.args.length > 0) {
                // For varArgs commands, first positional is named, rest are collected
                if (cmdDef.args.length === 1) {
                    namedArgs[cmdDef.args[0]] = positional;
                } else {
                    // First N-1 are named individually, last collects the rest
                    for (var a = 0; a < cmdDef.args.length - 1 && a < positional.length; a++) {
                        namedArgs[cmdDef.args[a]] = positional[a];
                    }
                    if (positional.length > cmdDef.args.length - 1) {
                        namedArgs[cmdDef.args[cmdDef.args.length - 1]] = positional.slice(cmdDef.args.length - 1);
                    }
                }
            } else {
                for (var b = 0; b < cmdDef.args.length && b < positional.length; b++) {
                    namedArgs[cmdDef.args[b]] = positional[b];
                }
            }

            return {
                topic: cmdDef.topic,
                action: cmdDef.action,
                args: namedArgs,
                positional: positional,
                flags: flags,
                error: null
            };
        };

        // Shell-like tokenizer that handles quoted strings
        XMTP_CLI.tokenize = function(input) {
            var tokens = [];
            var current = '';
            var inQuote = false;
            var quoteChar = '';
            for (var i = 0; i < input.length; i++) {
                var c = input[i];
                if (inQuote) {
                    if (c === quoteChar) {
                        inQuote = false;
                    } else {
                        current += c;
                    }
                } else if (c === '"' || c === "'") {
                    inQuote = true;
                    quoteChar = c;
                } else if (c === ' ' || c === '\\t') {
                    if (current.length > 0) {
                        tokens.push(current);
                        current = '';
                    }
                } else {
                    current += c;
                }
            }
            if (current.length > 0) {
                tokens.push(current);
            }
            return tokens;
        };

        // Format output exactly like the official CLI
        XMTP_CLI.formatJSON = function(data) {
            return JSON.stringify(data, null, 2);
        };

        // Format key-value sections like the CLI's human-readable output
        XMTP_CLI.formatSections = function(sections, indent) {
            indent = indent || 2;
            var pad = '';
            for (var i = 0; i < indent; i++) pad += ' ';
            
            var lines = [];
            for (var s = 0; s < sections.length; s++) {
                var section = sections[s];
                lines.push(section.title + ':');
                var keys = Object.keys(section.data);
                var maxLen = 0;
                for (var k = 0; k < keys.length; k++) {
                    if (keys[k].length > maxLen) maxLen = keys[k].length;
                }
                for (var j = 0; j < keys.length; j++) {
                    var key = keys[j];
                    var val = section.data[key];
                    if (val === undefined || val === null) val = '-';
                    var spacing = '';
                    for (var p = 0; p < maxLen - key.length; p++) spacing += ' ';
                    lines.push(pad + key + spacing + '  ' + val);
                }
                if (s < sections.length - 1) lines.push('');
            }
            return lines.join('\\n');
        };

        // Get list of all supported commands (for help text)
        XMTP_CLI.listCommands = function() {
            return Object.keys(XMTP_CLI.COMMANDS).sort();
        };
        """
        
        context.evaluateScript(parserJS)
    }
    
    // MARK: - Public API
    
    /// Parse a CLI-style command string into a structured command.
    /// Input: "conversations create-dm 0xABC --json"
    /// Output: XMTPCLICommand with topic="conversations", action="create-dm", args=["0xABC"], flags=["json": true]
    func parseCommand(_ input: String) -> Result<XMTPCLICommand, XMTPCLIParseError> {
        guard let parseFunc = context.objectForKeyedSubscript("XMTP_CLI")?.objectForKeyedSubscript("parse") else {
            return .failure(XMTPCLIParseError(message: "JS bridge not initialized"))
        }
        
        guard let result = parseFunc.call(withArguments: [input]) else {
            return .failure(XMTPCLIParseError(message: "Parse returned nil"))
        }
        
        // Check for error
        if let error = result.objectForKeyedSubscript("error"), !error.isNull, !error.isUndefined {
            return .failure(XMTPCLIParseError(message: error.toString()))
        }
        
        let topic = result.objectForKeyedSubscript("topic")?.toString() ?? ""
        let action = result.objectForKeyedSubscript("action")?.toString() ?? ""
        
        // Extract positional args
        var positionalArgs: [String] = []
        if let positional = result.objectForKeyedSubscript("positional"), !positional.isUndefined {
            if let arr = positional.toArray() as? [String] {
                positionalArgs = arr
            }
        }
        
        // Extract named args
        var namedArgs: [String: Any] = [:]
        if let args = result.objectForKeyedSubscript("args"), !args.isUndefined {
            if let dict = args.toDictionary() {
                for (key, value) in dict {
                    namedArgs["\(key)"] = value
                }
            }
        }
        
        // Extract flags
        var flags: [String: Any] = [:]
        if let flagsJS = result.objectForKeyedSubscript("flags"), !flagsJS.isUndefined {
            if let dict = flagsJS.toDictionary() {
                for (key, value) in dict {
                    flags["\(key)"] = value
                }
            }
        }
        
        // Merge named args into a combined args dict for the engine
        var combinedFlags = flags
        for (key, value) in namedArgs {
            combinedFlags["_arg_\(key)"] = value
        }
        
        return .success(XMTPCLICommand(
            topic: topic,
            action: action,
            args: positionalArgs,
            flags: combinedFlags
        ))
    }
    
    /// Format a Swift dictionary/array as JSON matching the official CLI output
    func formatJSON(_ data: Any) -> String {
        guard let formatFunc = context.objectForKeyedSubscript("XMTP_CLI")?.objectForKeyedSubscript("formatJSON") else {
            // Fallback to native Swift JSON
            if let jsonData = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: jsonData, encoding: .utf8) {
                return str
            }
            return "{}"
        }
        
        // Convert Swift types to JS-compatible
        let jsData = convertToJSCompatible(data)
        return formatFunc.call(withArguments: [jsData])?.toString() ?? "{}"
    }
    
    /// Format sections for human-readable output (like the CLI's `client info`)
    func formatSections(_ sections: [(title: String, data: [String: String])]) -> String {
        guard let formatFunc = context.objectForKeyedSubscript("XMTP_CLI")?.objectForKeyedSubscript("formatSections") else {
            // Fallback
            return sections.map { section in
                "\(section.title):\n" + section.data.map { "  \($0.key): \($0.value)" }.joined(separator: "\n")
            }.joined(separator: "\n\n")
        }
        
        let jsSections = sections.map { section -> [String: Any] in
            return ["title": section.title, "data": section.data]
        }
        
        return formatFunc.call(withArguments: [jsSections, 2])?.toString() ?? ""
    }
    
    /// Get list of all supported commands
    func listCommands() -> [String] {
        guard let listFunc = context.objectForKeyedSubscript("XMTP_CLI")?.objectForKeyedSubscript("listCommands") else {
            return []
        }
        return listFunc.call(withArguments: [])?.toArray() as? [String] ?? []
    }
    
    /// Check if --json flag is set
    func isJSONMode(_ command: XMTPCLICommand) -> Bool {
        return command.flags["json"] as? Bool == true
    }
    
    // MARK: - Helpers
    
    private func convertToJSCompatible(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            var result: [String: Any] = [:]
            for (k, v) in dict { result[k] = convertToJSCompatible(v) }
            return result
        case let arr as [Any]:
            return arr.map { convertToJSCompatible($0) }
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let data as Data:
            return data.map { String(format: "%02x", $0) }.joined()
        default:
            return value
        }
    }
}
