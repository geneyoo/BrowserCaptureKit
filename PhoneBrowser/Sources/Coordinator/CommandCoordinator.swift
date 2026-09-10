import BrowserCaptureKit
import CryptoKit
import Foundation

/// Serializes remote commands against the one browser. Validates binding,
/// controller ownership, deadline, and capability; journals acceptance and
/// the dispatching marker before any side effect; records terminal results
/// before acknowledging them.
@MainActor
final class CommandCoordinator {
    struct Observation {
        let id: String
        let snapshot: BrowserAccessibilitySnapshot
        let controllerGeneration: Int
        let elementIDs: Set<String>
    }

    static let maxRetainedObservations = 16

    let owner: BrowserOwner
    let journal: CommandJournal
    let evidence: EvidenceCollector

    private(set) var sessionID: String
    private(set) var controllerGeneration = 1
    private(set) var humanControl = false
    private(set) var activeCommandID: String?

    var onOutbound: ((RelayOutboundMessage) -> Void)?
    var onStatusChanged: (() -> Void)?
    var onObservation: ((BrowserAccessibilitySnapshot) -> Void)?

    private var observations: [String: Observation] = [:]
    private var observationOrder: [String] = []
    private var queue: [RemoteCommand] = []
    private var drainTask: Task<Void, Never>?
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(owner: BrowserOwner, journal: CommandJournal, evidence: EvidenceCollector, sessionID: String = UUID().uuidString) {
        self.owner = owner
        self.journal = journal
        self.evidence = evidence
        self.sessionID = sessionID
        owner.onCaptureEvent = { [weak self] event in
            guard let self else { return }
            evidence.record(.capture(event), pageEpoch: owner.session.pageEpoch)
        }
        owner.onDialog = { [weak self] kind, message in
            guard let self else { return }
            evidence.record(.dialog(kind: kind, message: message), pageEpoch: owner.session.pageEpoch)
        }
        owner.onLifecycle = { [weak self] name in
            guard let self else { return }
            evidence.record(.lifecycle(name), pageEpoch: owner.session.pageEpoch)
            onStatusChanged?()
        }
        owner.onDocumentInvalidated = { [weak self] in
            self?.rotateSession(reason: "webContentProcessTerminated")
        }
    }

    // MARK: - State

    var readiness: DeviceReadiness {
        if owner.isRecovering { return .recovering }
        if !owner.isForeground { return .foregroundRequired }
        if humanControl { return .humanControl }
        if activeCommandID != nil { return .executing }
        return .ready
    }

    func status() -> DeviceStatus {
        DeviceStatus(
            readiness: readiness,
            sessionID: sessionID,
            controllerGeneration: controllerGeneration,
            humanControl: humanControl,
            foreground: owner.isForeground,
            activeCommandID: activeCommandID,
            pageURL: ExportSanitizer.url(owner.webView.url),
            eventCursor: evidence.latestSequence
        )
    }

    func hello(deviceID: String, processInstanceID: String, appVersion: String, osVersion: String) -> DeviceHello {
        DeviceHello(
            protocolVersion: PhoneBrowserProtocol.version,
            deviceID: deviceID,
            sessionID: sessionID,
            processInstanceID: processInstanceID,
            appVersion: appVersion,
            osVersion: osVersion,
            libraryVersion: BrowserCaptureContract.libraryVersion,
            controllerGeneration: controllerGeneration,
            readiness: readiness,
            eventCursor: evidence.latestSequence,
            capabilities: .current(configuration: owner.session.configuration)
        )
    }

    /// Human takeover: ownership is invalidated and queued work is rejected.
    /// A command already dispatching finishes and reports its actual result.
    func takeover() {
        guard !humanControl else { return }
        humanControl = true
        evidence.record(.lifecycle("humanControl.begin"), pageEpoch: owner.session.pageEpoch)
        Task { await rejectQueued(reason: .humanControl, message: "A person took control of the browser.") }
        onStatusChanged?()
    }

    /// Returning control starts a new controller generation; every earlier
    /// observation is invalid for element actions.
    func resume() {
        guard humanControl else { return }
        humanControl = false
        controllerGeneration += 1
        // Earlier observations stay retained so an action against one is
        // reported as `observationBeforeResume` rather than as unknown.
        evidence.record(.lifecycle("humanControl.end"), pageEpoch: owner.session.pageEpoch)
        onStatusChanged?()
    }

    func rotateSession(reason: String) {
        sessionID = UUID().uuidString
        observations = [:]
        observationOrder = []
        Task { await rejectQueued(reason: .sessionMismatch, message: "The browser session was rotated: \(reason).") }
        onStatusChanged?()
    }

    // MARK: - Inbound

    func handle(_ command: RemoteCommand) async {
        if case .unsupported(let kind, let detail) = command.operation {
            send(.receipt(.rejected(command.commandID, .unsupportedOperation, "Unsupported operation '\(kind)': \(detail)")))
            return
        }
        if let rejection = admissionFailure(for: command) {
            send(.receipt(.rejected(command.commandID, rejection.reason, rejection.message)))
            return
        }

        let digest: String
        do {
            digest = try Self.digest(of: command.operation, encoder: encoder)
        } catch {
            send(.receipt(.rejected(command.commandID, .unsupportedOperation, "The operation could not be canonicalized.")))
            return
        }

        let outcome: JournalAcceptOutcome
        do {
            outcome = try await journal.accept(commandID: command.commandID, sessionID: command.sessionID, digest: digest)
        } catch {
            send(.receipt(.rejected(command.commandID, .notReady, "The command journal is unavailable: \(error)")))
            return
        }

        switch outcome {
        case .accepted:
            send(.receipt(.accepted(command.commandID)))
            queue.append(command)
            drain()
        case .duplicate(let record):
            if record.state.isTerminal {
                send(storedResult(for: record))
            } else {
                send(.receipt(.accepted(command.commandID, state: record.state)))
            }
        case .reusedWithDifferentPayload:
            send(.receipt(.rejected(command.commandID, .commandReused, "This command ID was already used with a different operation.")))
        }
    }

    func cancel(commandID: String) async {
        if let index = queue.firstIndex(where: { $0.commandID == commandID }) {
            queue.remove(at: index)
        }
        let result = CommandResultMessage(
            commandID: commandID,
            state: .cancelled,
            startedAt: nil,
            completedAt: Date(),
            retryClassification: .notStarted,
            reason: .cancelled,
            message: "Cancelled before dispatch.",
            payload: nil
        )
        guard let record = try? await journal.record(commandID: commandID) else {
            send(.receipt(.rejected(commandID, .unknownCommand, "No journal record for this command.")))
            return
        }
        if record.state.isTerminal {
            send(storedResult(for: record))
            return
        }
        if let resultJSON = try? encoder.encode(result),
            (try? await journal.cancelIfUndispatched(commandID: commandID, resultJSON: resultJSON)) == true
        {
            send(.result(result))
        } else {
            send(.receipt(CommandReceipt(
                commandID: commandID,
                accepted: true,
                state: .dispatching,
                reason: nil,
                message: "Cancel ignored: dispatch already began; the result will follow."
            )))
        }
    }

    /// Answers the service's unresolved command list from the journal before
    /// new mutation work is accepted.
    func reconcile(unresolvedCommandIDs: [String]) async {
        for commandID in unresolvedCommandIDs {
            guard let record = try? await journal.record(commandID: commandID) else {
                send(.receipt(.rejected(commandID, .unknownCommand, "This device never accepted the command.")))
                continue
            }
            if record.state.isTerminal {
                send(storedResult(for: record))
            } else {
                send(.receipt(.accepted(commandID, state: record.state)))
            }
        }
    }

    // MARK: - Validation

    private struct Rejection {
        let reason: RejectionReason
        let message: String
    }

    private func admissionFailure(for command: RemoteCommand, now: Date = Date()) -> Rejection? {
        if command.sessionID != sessionID {
            return Rejection(reason: .sessionMismatch, message: "Command session \(command.sessionID) is not the live session.")
        }
        if command.deadline <= now {
            return Rejection(reason: .expired, message: "The command deadline has passed.")
        }
        if humanControl {
            return Rejection(reason: .humanControl, message: "A person controls the browser; resume agent control first.")
        }
        if owner.isRecovering {
            return Rejection(reason: .notReady, message: "The browser is recovering from web content process loss.")
        }
        if !owner.isForeground {
            return Rejection(reason: .notReady, message: "The browser app is not in the foreground.")
        }
        if command.controllerGeneration != controllerGeneration {
            return Rejection(
                reason: .controllerGenerationMismatch,
                message: "Controller generation \(command.controllerGeneration) is not current (\(controllerGeneration))."
            )
        }
        switch command.operation {
        case .act(let act):
            return bindingFailure(for: act)
        case .navigate(let url):
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return Rejection(reason: .unsupportedURL, message: "Only http and https navigation is supported.")
            }
            return nil
        case .observe, .events, .commandStatus, .unsupported:
            return nil
        }
    }

    private func bindingFailure(for act: RemoteAct) -> Rejection? {
        guard let observation = observations[act.observationID] else {
            return Rejection(reason: .unknownObservation, message: "Observation \(act.observationID) is not retained on this device.")
        }
        if observation.controllerGeneration != controllerGeneration {
            return Rejection(reason: .observationBeforeResume, message: "Observe again after control was returned to the agent.")
        }
        if observation.snapshot.pageEpoch != owner.session.pageEpoch {
            return Rejection(reason: .staleObservation, message: "The page changed since observation \(act.observationID).")
        }
        guard observation.elementIDs.contains(act.elementID) else {
            return Rejection(reason: .unknownElement, message: "Element \(act.elementID) is not part of observation \(act.observationID).")
        }
        if act.kind == .fill, (act.text ?? "").count > RemoteAct.maxFillTextCharacters {
            return Rejection(reason: .oversizedInput, message: "Fill text exceeds \(RemoteAct.maxFillTextCharacters) characters.")
        }
        return nil
    }

    nonisolated static func digest(of operation: RemoteOperation, encoder: JSONEncoder) throws -> String {
        let canonical = JSONEncoder()
        canonical.outputFormatting = [.sortedKeys]
        canonical.dateEncodingStrategy = .iso8601
        let data = try canonical.encode(operation)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Execution

    private func drain() {
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor [weak self] in
            while let self, !self.queue.isEmpty {
                let command = self.queue.removeFirst()
                await self.execute(command)
            }
            self?.drainTask = nil
        }
    }

    private func execute(_ command: RemoteCommand) async {
        // Re-validate immediately before dispatch: the lease, page, and deadline
        // may all have changed while the command waited.
        if let rejection = admissionFailure(for: command) {
            await finish(
                command,
                state: .rejected,
                retryClassification: .notStarted,
                reason: rejection.reason,
                message: rejection.message,
                payload: nil,
                startedAt: nil
            )
            return
        }
        guard (try? await journal.claimDispatch(commandID: command.commandID)) == true else {
            // Cancelled between acceptance and dispatch; the cancel path reported it.
            return
        }
        activeCommandID = command.commandID
        onStatusChanged?()
        let startedAt = Date()
        let outcome = await run(command)
        await finish(
            command,
            state: outcome.state,
            retryClassification: outcome.retryClassification,
            reason: outcome.reason,
            message: outcome.message,
            payload: outcome.payload,
            startedAt: startedAt
        )
        activeCommandID = nil
        onStatusChanged?()
    }

    private struct Outcome {
        let state: CommandState
        let retryClassification: RetryClassification
        let reason: RejectionReason?
        let message: String?
        let payload: CommandResultPayload?
    }

    private func run(_ command: RemoteCommand) async -> Outcome {
        switch command.operation {
        case .observe(let includeImage, let maxElements):
            let bundle = await makeObservation(includeImage: includeImage, maxElements: maxElements)
            return Outcome(state: .completed, retryClassification: .safe, reason: nil, message: nil, payload: .observation(bundle))
        case .navigate(let url):
            let result = await owner.session.perform(.openURL(url), authorizationGate: gate(for: command))
            if result.status == .staleSnapshot {
                return Outcome(state: .rejected, retryClassification: .notStarted, reason: .controllerGenerationMismatch, message: result.message, payload: nil)
            }
            let payload = NavigationOutcome(
                status: result.status.rawValue,
                message: result.message,
                urlBefore: ExportSanitizer.url(result.urlBefore),
                urlAfter: ExportSanitizer.url(result.urlAfter),
                pageEpoch: owner.session.pageEpoch,
                networkEventCountDelta: result.networkEventCountDelta
            )
            return Outcome(state: .completed, retryClassification: .safe, reason: nil, message: nil, payload: .navigation(payload))
        case .act(let act):
            return await runAct(act, command: command)
        case .events(let afterSequence, let limit):
            let page = evidence.page(after: afterSequence, limit: limit)
            return Outcome(state: .completed, retryClassification: .safe, reason: nil, message: nil, payload: .events(page))
        case .commandStatus(let commandID):
            guard let record = try? await journal.record(commandID: commandID) else {
                return Outcome(state: .rejected, retryClassification: .notStarted, reason: .unknownCommand, message: "No journal record for \(commandID).", payload: nil)
            }
            let summary = JournalRecordSummary(
                commandID: record.commandID,
                sessionID: record.sessionID,
                state: record.state,
                acceptedAt: record.acceptedAt,
                dispatchingAt: record.dispatchingAt,
                completedAt: record.completedAt,
                retryClassification: record.retryClassification,
                result: record.resultJSON.flatMap { try? decoder.decode(CommandResultMessage.self, from: $0) }
            )
            return Outcome(state: .completed, retryClassification: .safe, reason: nil, message: nil, payload: .commandStatus(summary))
        case .unsupported(let kind, let detail):
            return Outcome(state: .rejected, retryClassification: .notStarted, reason: .unsupportedOperation, message: "\(kind): \(detail)", payload: nil)
        }
    }

    private func runAct(_ act: RemoteAct, command: RemoteCommand) async -> Outcome {
        guard let observation = observations[act.observationID] else {
            return Outcome(state: .rejected, retryClassification: .notStarted, reason: .unknownObservation, message: "Observation vanished before dispatch.", payload: nil)
        }
        // Identity only: no role, label, text, or bounds, so the in-page
        // matcher cannot score a replacement element above threshold.
        let target = BrowserElementTarget(
            snapshotID: observation.snapshot.id,
            pageEpoch: observation.snapshot.pageEpoch,
            stableID: act.elementID
        )
        let request: BrowserActionRequest
        switch act.kind {
        case .tap:
            request = .tap(target: target)
        case .fill:
            request = .fill(target: target, text: act.text ?? "", submit: false)
        }
        let result = await owner.session.perform(request, authorizationGate: gate(for: command))

        var warnings = result.warnings
        var state: CommandState
        var classification: RetryClassification
        var reason: RejectionReason?
        switch result.status {
        case .succeeded:
            state = .completed
            classification = .unsafe
        case .processInterruptedAfterClaim, .acknowledgementTimedOut:
            state = .uncertain
            classification = .unsafe
        case .staleSnapshot:
            state = .rejected
            classification = .notStarted
            reason = .staleObservation
        case .humanInputRequired, .userActivationRequired:
            state = .completed
            classification = .notStarted
        default:
            state = .completed
            classification = .notStarted
        }
        if result.status == .succeeded, let selected = result.selectedElement,
            let index = selected.index, let fingerprint = selected.selectorFingerprint,
            !act.elementID.hasSuffix("\(index):\(fingerprint)")
        {
            state = .uncertain
            classification = .unsafe
            warnings.append("The acted element's identity did not match the bound element ID.")
        }

        let payload = ActionOutcome(
            kind: act.kind.rawValue,
            status: result.status.rawValue,
            message: result.message,
            observationID: act.observationID,
            elementID: act.elementID,
            matchedElementCount: result.matchedElementCount,
            urlBefore: ExportSanitizer.url(result.urlBefore),
            urlAfter: ExportSanitizer.url(result.urlAfter),
            pageEpochAfter: owner.session.pageEpoch,
            networkEventCountDelta: result.networkEventCountDelta,
            warnings: warnings
        )
        return Outcome(state: state, retryClassification: classification, reason: reason, message: nil, payload: .action(payload))
    }

    /// Checked by the package immediately before the in-page script runs.
    private func gate(for command: RemoteCommand) -> @MainActor () -> Bool {
        { [weak self] in
            guard let self else { return false }
            return !humanControl
                && controllerGeneration == command.controllerGeneration
                && sessionID == command.sessionID
                && owner.isForeground
                && !owner.isRecovering
        }
    }

    private func finish(
        _ command: RemoteCommand,
        state: CommandState,
        retryClassification: RetryClassification,
        reason: RejectionReason?,
        message: String?,
        payload: CommandResultPayload?,
        startedAt: Date?
    ) async {
        var result = CommandResultMessage(
            commandID: command.commandID,
            state: state,
            startedAt: startedAt,
            completedAt: Date(),
            retryClassification: retryClassification,
            reason: reason,
            message: message,
            payload: payload
        )
        do {
            let json = try encoder.encode(result)
            try await journal.complete(commandID: command.commandID, state: state, retryClassification: retryClassification, resultJSON: json)
            // Send exactly what was persisted so a later duplicate or
            // reconciliation resends a byte-identical result.
            result = try decoder.decode(CommandResultMessage.self, from: json)
        } catch {
            result = CommandResultMessage(
                commandID: result.commandID,
                state: result.state,
                startedAt: result.startedAt,
                completedAt: result.completedAt,
                retryClassification: result.retryClassification,
                reason: result.reason,
                message: [result.message, "Result persistence failed: \(error)"].compactMap { $0 }.joined(separator: " "),
                payload: result.payload
            )
        }
        send(.result(result))
    }

    private func rejectQueued(reason: RejectionReason, message: String) async {
        let pending = queue
        queue = []
        for command in pending {
            await finish(command, state: .cancelled, retryClassification: .notStarted, reason: reason, message: message, payload: nil, startedAt: nil)
        }
    }

    private func storedResult(for record: JournalRecord) -> RelayOutboundMessage {
        if let json = record.resultJSON, let result = try? decoder.decode(CommandResultMessage.self, from: json) {
            return .result(result)
        }
        return .result(CommandResultMessage(
            commandID: record.commandID,
            state: record.state,
            startedAt: record.dispatchingAt,
            completedAt: record.completedAt,
            retryClassification: record.retryClassification ?? .unsafe,
            reason: nil,
            message: "Terminal state recorded without a stored result.",
            payload: nil
        ))
    }

    private func send(_ message: RelayOutboundMessage) {
        onOutbound?(message)
    }

    // MARK: - Observation

    static func isSensitive(_ element: BrowserAccessibilityElementSnapshot) -> Bool {
        if element.inputType?.lowercased() == "password" {
            return true
        }
        return element.isEditable && !element.supportedActions.contains(.fill)
    }

    func makeObservation(includeImage: Bool, maxElements: Int) async -> ObservationBundle {
        let startedAt = Date()
        let epochAtStart = owner.session.pageEpoch
        let snapshot = await owner.session.accessibilitySnapshot(reason: "remote.observe")

        var image: ObservationImage?
        var imageOmittedReason: String?
        if includeImage {
            if snapshot.elements.contains(where: { $0.isVisible && Self.isSensitive($0) }) {
                imageOmittedReason = "A sensitive field is visible; image masking is not trusted, so the image was omitted."
            } else if let captured = await owner.takeSnapshotImage() {
                image = captured
            } else {
                imageOmittedReason = "The web view could not produce a snapshot."
            }
        }

        let endedAt = Date()
        let epochAtEnd = owner.session.pageEpoch
        let changed = epochAtStart != epochAtEnd || snapshot.pageEpoch != epochAtEnd
        let loading = owner.webView.isLoading

        let identified = snapshot.elements.filter { $0.stableID != nil }
        let exported = identified.prefix(maxElements).compactMap(Self.exportedElement)
        let observationID = snapshot.id.uuidString
        retain(Observation(
            id: observationID,
            snapshot: snapshot,
            controllerGeneration: controllerGeneration,
            elementIDs: Set(exported.map(\.id))
        ))
        onObservation?(snapshot)

        var notes: [String] = []
        if changed {
            notes.append("The document changed during capture; element actions against this observation will be rejected.")
        }
        if loading {
            notes.append("A navigation is in progress; the elements may describe the outgoing document. Observe again after it finishes.")
        }
        if image == nil, includeImage == false {
            notes.append("Image not requested.")
        }

        return ObservationBundle(
            observationID: observationID,
            sessionID: sessionID,
            controllerGeneration: controllerGeneration,
            pageEpoch: snapshot.pageEpoch,
            url: ExportSanitizer.url(snapshot.url),
            title: ExportSanitizer.bounded(snapshot.title, limit: 120).text,
            capture: CaptureInterval(
                startedAt: startedAt,
                endedAt: endedAt,
                pageEpochAtStart: epochAtStart,
                pageEpochAtEnd: epochAtEnd,
                changedDuringCapture: changed
            ),
            documentLoading: loading,
            viewport: ViewportInfo(
                width: snapshot.viewportWidth,
                height: snapshot.viewportHeight,
                scrollX: snapshot.scrollX,
                scrollY: snapshot.scrollY,
                webViewPointWidth: owner.webView.bounds.width,
                webViewPointHeight: owner.webView.bounds.height
            ),
            elements: exported,
            elementCount: snapshot.elementCount,
            elementsOmitted: snapshot.elementsOmitted + (identified.count - exported.count),
            image: image,
            imageOmittedReason: imageOmittedReason,
            eventCursor: evidence.latestSequence,
            coverage: ObservationCoverage(
                javaScriptError: snapshot.javaScriptError,
                childFrameOrigins: Array(Set(snapshot.elements.compactMap(\.frameOrigin))).sorted(),
                elementsWithoutStableIdentity: snapshot.elements.count - identified.count,
                notes: notes
            )
        )
    }

    private func retain(_ observation: Observation) {
        observations[observation.id] = observation
        observationOrder.append(observation.id)
        while observationOrder.count > Self.maxRetainedObservations {
            observations[observationOrder.removeFirst()] = nil
        }
    }

    static func exportedElement(_ element: BrowserAccessibilityElementSnapshot) -> ObservedElement? {
        guard let id = element.stableID else {
            return nil
        }
        let sensitive = isSensitive(element)
        let supported = element.supportedActions
            .map(\.rawValue)
            .filter { RemoteAct.Kind(rawValue: $0) != nil }
        return ObservedElement(
            id: id,
            index: element.index,
            tagName: element.tagName,
            role: element.role,
            label: ExportSanitizer.bounded(element.label, limit: 200).text,
            text: sensitive ? nil : ExportSanitizer.bounded(element.text, limit: 200).text,
            value: element.isEditable || sensitive ? nil : ExportSanitizer.bounded(element.value, limit: 200).text,
            placeholder: ExportSanitizer.bounded(element.placeholder, limit: 120).text,
            inputType: element.inputType,
            href: ExportSanitizer.url(element.href),
            isVisible: element.isVisible,
            isInteractive: element.isInteractive,
            isDisabled: element.isDisabled,
            isEditable: element.isEditable,
            isObscuredAtCenter: element.isObscuredAtCenter,
            isSensitive: sensitive,
            bounds: element.bounds,
            frameOrigin: element.frameOrigin,
            supportedActions: sensitive ? supported.filter { $0 != "fill" } : supported
        )
    }
}
