//
// XMTPServiceContainer.swift
// bitchat
//
// Container for XMTP services, manages lifecycle and inter-service dependencies.
// This is free and unencumbered software released into the public domain.
//

import BitLogger
import Combine
import Foundation

/// Container for all XMTP-related services
/// Provides a single initialization point and manages dependencies
@MainActor
final class XMTPServiceContainer: ObservableObject {
    
    // MARK: - Published State
    
    @Published private(set) var isInitialized = false
    @Published private(set) var initializationError: Error?
    
    // MARK: - Services
    
    let wallet: EmbeddedWallet
    let identityBridge: XMTPIdentityBridge
    let clientService: XMTPClientService
    let transport: XMTPTransport
    let locationChannels: XMTPLocationChannels
    let balanceService: EthereumBalanceService
    let meshTransactionRelay: MeshTransactionRelay
    let geohashGroupRegistry: GeohashGroupRegistry
    
    // MARK: - PQ Services
    
    let pqKeyManager: PQKeyManager
    /// Per-chain PQ service sets (keyed by chainId)
    private(set) var pqChainServices: [UInt64: PQAccountViewModel.ChainServiceSet] = [:]
    
    // MARK: - Private
    
    private let keychain: KeychainManagerProtocol
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Singleton
    
    private static var _shared: XMTPServiceContainer?
    
    static var shared: XMTPServiceContainer {
        guard let instance = _shared else {
            fatalError("XMTPServiceContainer.shared accessed before configure() was called")
        }
        return instance
    }
    
    static var isConfigured: Bool {
        _shared != nil
    }
    
    /// Configure the shared container. Call once during app startup.
    @discardableResult
    static func configure(keychain: KeychainManagerProtocol) -> XMTPServiceContainer {
        if let existing = _shared {
            return existing
        }
        let container = XMTPServiceContainer(keychain: keychain)
        _shared = container
        return container
    }
    
    /// Reset the shared container (for testing or logout)
    static func reset() {
        _shared = nil
    }
    
    // MARK: - Initialization
    
    private init(keychain: KeychainManagerProtocol) {
        self.keychain = keychain
        
        // Create embedded wallet
        self.wallet = EmbeddedWallet(keychain: keychain)
        
        // Create identity bridge
        self.identityBridge = XMTPIdentityBridge(keychain: keychain)
        
        // Create client service
        self.clientService = XMTPClientService(keychain: keychain, wallet: wallet, identityBridge: identityBridge)
        
        // Create transport
        self.transport = XMTPTransport(
            keychain: keychain,
            identityBridge: identityBridge,
            clientService: clientService
        )
        
        // Create location channels
        self.locationChannels = XMTPLocationChannels(
            identityBridge: identityBridge,
            clientService: clientService
        )
        
        // Create geohash group registry for open location groups
        self.geohashGroupRegistry = GeohashGroupRegistry(clientService: clientService)
        
        // Connect location channels to registry
        self.locationChannels.setRegistry(geohashGroupRegistry)
        
        // Create balance service
        self.balanceService = EthereumBalanceService()
        
        // Create mesh transaction relay
        self.meshTransactionRelay = MeshTransactionRelay(keychain: keychain)
        
        // Create PQ key manager (always available, keys derived from wallet)
        self.pqKeyManager = PQKeyManager(keychain: keychain)
        
        // Create PQ account infrastructure for all testnet chains (requires Pimlico API key)
        if SecureConfig.hasPimlicoAPIKey {
            var services: [UInt64: PQAccountViewModel.ChainServiceSet] = [:]
            for chain in PQAccountDeployer.Chain.allCases {
                let deployer = PQAccountDeployer(chain: chain)
                let bundler = PimlicoBundler(
                    apiKey: SecureConfig.pimlicoAPIKey,
                    chainId: chain.chainId
                )
                let signer = PQTransactionSigner(
                    wallet: wallet,
                    pqKeyManager: pqKeyManager,
                    bundler: bundler,
                    deployer: deployer,
                    chainId: chain.chainId
                )
                services[chain.chainId] = PQAccountViewModel.ChainServiceSet(
                    chain: chain,
                    deployer: deployer,
                    bundler: bundler,
                    signer: signer
                )
            }
            self.pqChainServices = services
        }
    }
    
    // MARK: - BLE Service Configuration
    
    /// Configure BLE service reference for transaction relay
    /// Call this after BLEService is initialized
    func configureBLEService(_ bleService: BLEService?) {
        meshTransactionRelay.configure(bleService: bleService)
    }
    
    // MARK: - Lifecycle
    
    /// Initialize all XMTP services asynchronously
    func initialize() async {
        guard !isInitialized else { return }
        
        let prefs = TransportPreferences.shared
        // Check if XMTP is enabled (either directly or via geo transport)
        guard prefs.isXMTPEnabled || prefs.geoTransport == .xmtp else {
            SecureLogger.info("XMTP: Skipping initialization (disabled in preferences and not used for geo)", category: .session)
            return
        }
        
        do {
            // Ensure wallet exists (generates if needed)
            let address = try await wallet.getAddress()
            SecureLogger.info("XMTP: Wallet ready at \(address.prefix(10))…", category: .session)
            
            // Connect XMTP client
            try await clientService.connect()
            
            // Associate XMTP identity with Noise key
            if let inboxId = clientService.inboxId,
               let noiseKey = identityBridge.getOwnNoisePublicKey() {
                identityBridge.associateIdentity(noisePublicKey: noiseKey, with: inboxId)
                SecureLogger.info("XMTP: Identity bridge configured", category: .session)
            }
            
            isInitialized = true
            initializationError = nil
            
            SecureLogger.info("XMTP: All services initialized successfully", category: .session)
            
            // Start location channels if XMTP is the geo transport
            if TransportPreferences.shared.geoTransport == .xmtp {
                startLocationChannels()
            }
            
        } catch {
            initializationError = error
            SecureLogger.error("XMTP: Initialization failed: \(error.localizedDescription)", category: .session)
            
            // If this looks like a database/encryption error, schedule a reset for next attempt
            let errorString = error.localizedDescription.lowercased()
            if errorString.contains("sqlcipher") || errorString.contains("encryption") || errorString.contains("storage") {
                clientService.forceResetDatabase()
                SecureLogger.info("XMTP: Scheduled database reset due to encryption/storage error", category: .session)
            }
        }
        
        // Observe preference changes
        setupPreferenceObserver()
    }
    
    private func setupPreferenceObserver() {
        NotificationCenter.default.publisher(for: .transportPreferencesChanged)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handlePreferenceChange()
                }
            }
            .store(in: &cancellables)
    }
    
    private func handlePreferenceChange() {
        let prefs = TransportPreferences.shared
        
        // Handle XMTP enable/disable - also auto-enable if geo transport is XMTP
        let shouldBeInitialized = prefs.isXMTPEnabled || prefs.geoTransport == .xmtp
        
        if shouldBeInitialized && !isInitialized {
            Task {
                await initialize()
            }
        } else if !shouldBeInitialized && isInitialized {
            Task {
                await shutdown()
            }
        }
        
        // Handle geo transport switching
        if prefs.geoTransport == .xmtp && isInitialized {
            startLocationChannels()
        } else if prefs.geoTransport != .xmtp {
            locationChannels.leaveAllChannels()
        }
    }
    
    private func startLocationChannels() {
        // Get current location and join appropriate channels
        if let currentChannel = LocationStateManager.shared.availableChannels.first(where: { $0.geohash.count == 5 }) {
            Task {
                try? await locationChannels.joinChannel(geohash: currentChannel.geohash)
            }
        }
    }
    
    /// Shut down XMTP services cleanly
    func shutdown() async {
        transport.stopServices()
        locationChannels.leaveAllChannels()
        
        isInitialized = false
        SecureLogger.info("XMTP: Services shut down", category: .session)
    }
    
}

// MARK: - App Integration Extension

extension XMTPServiceContainer {
    
    /// Get the XMTP inbox ID for display/sharing
    var myInboxId: String? {
        clientService.inboxId
    }
    
    /// Get wallet address for display/sharing
    var myWalletAddress: String? {
        get async {
            try? await wallet.getAddress()
        }
    }
    
    /// Whether PQ account services are available (Pimlico key configured)
    var isPQEnabled: Bool {
        !pqChainServices.isEmpty
    }
}
