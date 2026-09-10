import BrowserCaptureKit
import Foundation
import Observation
import SwiftUI
import UIKit

/// Wires the browser owner, journal, evidence, coordinator, and relay
/// connection for the one foreground browser this app hosts.
@MainActor
@Observable
final class PhoneBrowserModel {
    private enum Defaults {
        static let profileKey = "phonebrowser.profile-id"
        static let deviceNameKey = "phonebrowser.device-name"
    }

    let owner: BrowserOwner
    let evidence: EvidenceCollector
    let coordinator: CommandCoordinator
    let processInstanceID = UUID().uuidString

    private(set) var credential: DeviceCredential?
    private(set) var connectionState: RelayConnection.State = .disconnected(reason: nil)
    private(set) var readiness: DeviceReadiness = .disconnected
    private(set) var recovery: JournalRecovery?
    private(set) var latestSnapshot: BrowserAccessibilitySnapshot?
    private(set) var startupError: String?
    /// Set when the device credential could not be stored in the Keychain: the
    /// phone stays paired for this launch only and must pair again next time.
    private(set) var credentialWarning: String?
    var pairingError: String?
    var isPairing = false
    var addressText = ""
    var showsHUD = false

    @ObservationIgnored private var connection: RelayConnection?
    @ObservationIgnored private let journal: CommandJournal

    init() {
        let defaults = UserDefaults.standard
        let profileID: UUID
        if let stored = defaults.string(forKey: Defaults.profileKey), let parsed = UUID(uuidString: stored) {
            profileID = parsed
        } else {
            profileID = UUID()
            defaults.set(profileID.uuidString, forKey: Defaults.profileKey)
        }

        owner = BrowserOwner(
            configuration: BrowserCaptureConfiguration(
                storageMode: .persistent(identifier: profileID),
                capturesConsole: false
            )
        )
        evidence = EvidenceCollector()

        var journalError: String?
        let journal: CommandJournal
        do {
            journal = try CommandJournal(path: Self.journalPath())
        } catch {
            journalError = "Command journal unavailable on disk; using memory only: \(error)"
            // swiftlint:disable:next force_try
            journal = try! CommandJournal(path: CommandJournal.inMemoryPath)
        }
        self.journal = journal
        startupError = journalError
        coordinator = CommandCoordinator(owner: owner, journal: journal, evidence: evidence)

        coordinator.onOutbound = { [weak self] message in
            self?.connection?.send(message)
        }
        coordinator.onStatusChanged = { [weak self] in
            guard let self else { return }
            readiness = coordinator.readiness
            connection?.send(.status(coordinator.status()))
        }
        coordinator.onObservation = { [weak self] snapshot in
            self?.latestSnapshot = snapshot
        }
        readiness = coordinator.readiness
    }

    func start() async {
        recovery = try? await journal.recoverAfterLaunch()
        credential = DeviceCredentialStore.load()
        if let automatic = Self.automaticPairing() {
            // Automation hook (simulator runs, device gates): an explicit code in
            // the launch environment replaces any stored credential, since a
            // stored one may belong to a relay that no longer exists.
            await pair(relayURLText: automatic.relayURL, code: automatic.code)
            return
        }
        connect()
    }

    /// `PHONEBROWSER_RELAY_URL` and `PHONEBROWSER_PAIRING_CODE` in the launch
    /// environment. The code is single use, so this cannot silently re-pair.
    private static func automaticPairing() -> (relayURL: String, code: String)? {
        let environment = ProcessInfo.processInfo.environment
        guard let relayURL = environment["PHONEBROWSER_RELAY_URL"], !relayURL.isEmpty,
            let code = environment["PHONEBROWSER_PAIRING_CODE"], !code.isEmpty
        else {
            return nil
        }
        return (relayURL, code)
    }

    func setScenePhase(_ phase: ScenePhase) {
        owner.setForeground(phase == .active)
    }

    // MARK: - Pairing

    func pair(relayURLText: String, code: String) async {
        isPairing = true
        pairingError = nil
        defer { isPairing = false }
        do {
            let credential = try await PairingClient.pair(
                relayURLText: relayURLText,
                code: code,
                deviceName: UIDevice.current.name
            )
            do {
                try DeviceCredentialStore.save(credential)
                credentialWarning = nil
            } catch {
                credentialWarning = "Credential not persisted (Keychain unavailable: \(error.localizedDescription)); pair again after relaunch."
            }
            self.credential = credential
            connect()
        } catch {
            pairingError = error.localizedDescription
        }
    }

    func unpair() {
        connection?.stop()
        connection = nil
        DeviceCredentialStore.clear()
        credential = nil
        connectionState = .disconnected(reason: "unpaired")
    }

    // MARK: - Local controls

    func takeover() {
        coordinator.takeover()
    }

    func resume() {
        coordinator.resume()
    }

    func navigateFromAddressBar() {
        var text = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.contains("://") {
            text = "https://" + text
        }
        guard let url = URL(string: text) else { return }
        owner.session.load(url)
    }

    // MARK: - Connection

    private func connect() {
        connection?.stop()
        connection = nil
        guard let credential, let socketURL = credential.webSocketURL else { return }
        let connection = RelayConnection(url: socketURL, token: credential.token)
        connection.makeHello = { [weak self] in
            guard let self else {
                preconditionFailure("Model released while connected.")
            }
            return coordinator.hello(
                deviceID: credential.deviceID,
                processInstanceID: processInstanceID,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
                osVersion: UIDevice.current.systemVersion
            )
        }
        connection.onStateChanged = { [weak self] state in
            self?.connectionState = state
            self?.readiness = state == .connected ? (self?.coordinator.readiness ?? .disconnected) : .disconnected
        }
        connection.onInbound = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                switch message {
                case .helloAck(let ack):
                    await self.coordinator.reconcile(unresolvedCommandIDs: ack.unresolvedCommandIDs)
                    connection.send(.status(self.coordinator.status()))
                case .command(let command):
                    await self.coordinator.handle(command)
                case .cancel(let commandID):
                    await self.coordinator.cancel(commandID: commandID)
                case .unknown:
                    break
                }
            }
        }
        self.connection = connection
        connection.start()
    }

    private static func journalPath() throws -> String {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "PhoneBrowser", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "journal.sqlite").path
    }
}
