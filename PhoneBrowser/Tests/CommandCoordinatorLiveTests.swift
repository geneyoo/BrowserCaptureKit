import BrowserCaptureKit
import UIKit
import WebKit
import XCTest

@testable import PhoneBrowser

/// Live `WKWebView` tests for the command coordinator: binding, ownership,
/// deduplication, cancellation, and export redaction against a controlled
/// page with an authoritative in-page submission counter.
@MainActor
final class CommandCoordinatorLiveTests: XCTestCase {
    private static let counterPage = """
        <!doctype html><html><body>
          <h1>Counter fixture</h1>
          <form id="f">
            <label for="note">Note</label>
            <input id="note" name="note" placeholder="Type a note">
            <button type="submit">Submit note</button>
          </form>
          <p id="count">0</p>
          <a href="https://shop.example/next?token=SECRET#frag">Next</a>
          <script>
            let n = 0;
            document.getElementById("f").addEventListener("submit", (event) => {
              event.preventDefault();
              n += 1;
              document.getElementById("count").textContent = String(n);
              window.__submits = n;
              window.__lastNote = document.getElementById("note").value;
            });
          </script>
        </body></html>
        """

    private static let sensitivePage = """
        <!doctype html><html><body>
          <form>
            <label for="user">Email</label><input id="user" name="email" value="person@example.com">
            <label for="pw">Password</label><input id="pw" type="password" name="password" value="hunter2">
            <button type="submit">Sign in</button>
          </form>
        </body></html>
        """

    @MainActor
    private final class Harness {
        let owner: BrowserOwner
        let journal: CommandJournal
        let evidence: EvidenceCollector
        let coordinator: CommandCoordinator
        private(set) var outbound: [RelayOutboundMessage] = []
        private var resultWaiters: [String: [XCTestExpectation]] = [:]
        private var loadWaiters: [XCTestExpectation] = []

        init() throws {
            owner = BrowserOwner(configuration: BrowserCaptureConfiguration(storageMode: .nonPersistent))
            journal = try CommandJournal(path: CommandJournal.inMemoryPath)
            evidence = EvidenceCollector()
            coordinator = CommandCoordinator(owner: owner, journal: journal, evidence: evidence)
            coordinator.onOutbound = { [weak self] message in
                guard let self else { return }
                outbound.append(message)
                if case .result(let result) = message {
                    resultWaiters.removeValue(forKey: result.commandID)?.forEach { $0.fulfill() }
                }
            }
            let forward = owner.onCaptureEvent
            owner.onCaptureEvent = { [weak self] event in
                forward?(event)
                if case .page(let page) = event, page.kind == .navigationFinished {
                    self?.loadWaiters.forEach { $0.fulfill() }
                    self?.loadWaiters = []
                }
            }
            let window = try XCTUnwrap(
                UIApplication.shared.connectedScenes
                    .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                    .first
            )
            owner.webView.frame = CGRect(x: 0, y: 0, width: 390, height: 640)
            window.addSubview(owner.webView)
        }

        func unmount() {
            owner.webView.removeFromSuperview()
        }

        func load(_ html: String, testCase: XCTestCase) async throws {
            let loaded = testCase.expectation(description: "page loaded")
            loadWaiters.append(loaded)
            owner.webView.loadHTMLString(html, baseURL: try XCTUnwrap(URL(string: "https://fixture.example/page")))
            await testCase.fulfillment(of: [loaded], timeout: 10)
        }

        func command(
            _ operation: RemoteOperation,
            id: String = UUID().uuidString,
            sessionID: String? = nil,
            generation: Int? = nil,
            deadline: Date = Date().addingTimeInterval(30)
        ) -> RemoteCommand {
            RemoteCommand(
                commandID: id,
                sessionID: sessionID ?? coordinator.sessionID,
                controllerGeneration: generation ?? coordinator.controllerGeneration,
                deadline: deadline,
                operation: operation
            )
        }

        @discardableResult
        func run(_ command: RemoteCommand, testCase: XCTestCase) async -> CommandResultMessage {
            let done = testCase.expectation(description: "result \(command.commandID)")
            resultWaiters[command.commandID, default: []].append(done)
            await coordinator.handle(command)
            await testCase.fulfillment(of: [done], timeout: 40)
            return results(for: command.commandID).last!
        }

        func results(for commandID: String) -> [CommandResultMessage] {
            outbound.compactMap {
                if case .result(let result) = $0, result.commandID == commandID { return result }
                return nil
            }
        }

        func receipts(for commandID: String) -> [CommandReceipt] {
            outbound.compactMap {
                if case .receipt(let receipt) = $0, receipt.commandID == commandID { return receipt }
                return nil
            }
        }

        func observe(testCase: XCTestCase, includeImage: Bool = false) async throws -> ObservationBundle {
            let result = await run(command(.observe(includeImage: includeImage, maxElements: 100)), testCase: testCase)
            guard case .observation(let bundle) = result.payload else {
                throw XCTSkipNever.expectedObservation
            }
            return bundle
        }

        func submitCount() async throws -> Int {
            let value = try await owner.webView.evaluateJavaScript("window.__submits || 0")
            return value as? Int ?? 0
        }
    }

    private enum XCTSkipNever: Error {
        case expectedObservation
    }

    func testObserveFillTapSubmitsOnceAndDuplicateCommandReturnsSavedResult() async throws {
        let harness = try Harness()
        defer { harness.unmount() }
        try await harness.load(Self.counterPage, testCase: self)

        let observation = try await harness.observe(testCase: self)
        XCTAssertEqual(observation.sessionID, harness.coordinator.sessionID)
        XCTAssertEqual(observation.url, "https://fixture.example/page")
        let note = try XCTUnwrap(observation.elements.first { $0.role == "textbox" })
        let submit = try XCTUnwrap(observation.elements.first { $0.role == "button" && $0.label == "Submit note" })
        let link = try XCTUnwrap(observation.elements.first { $0.role == "link" })
        XCTAssertEqual(link.href, "https://shop.example/next")
        XCTAssertTrue(submit.supportedActions.contains("tap"))
        XCTAssertTrue(note.supportedActions.contains("fill"))

        let fill = await harness.run(
            harness.command(.act(RemoteAct(kind: .fill, observationID: observation.observationID, elementID: note.id, text: "hello"))),
            testCase: self
        )
        XCTAssertEqual(fill.state, .completed)
        XCTAssertEqual(fill.retryClassification, .unsafe)
        guard case .action(let fillOutcome) = fill.payload else {
            return XCTFail("Expected an action payload")
        }
        XCTAssertEqual(fillOutcome.status, "succeeded")
        XCTAssertEqual(fillOutcome.elementID, note.id)

        let tapID = "tap-\(UUID().uuidString)"
        let tap = await harness.run(
            harness.command(.act(RemoteAct(kind: .tap, observationID: observation.observationID, elementID: submit.id)), id: tapID),
            testCase: self
        )
        XCTAssertEqual(tap.state, .completed)
        let awaited1 = try await harness.submitCount()
        XCTAssertEqual(awaited1, 1)
        let awaited2 = try await harness.owner.webView.evaluateJavaScript("window.__lastNote") as? String
        XCTAssertEqual(awaited2, "hello")

        // Same command ID again: the saved result comes back and nothing runs.
        let duplicate = await harness.run(
            harness.command(.act(RemoteAct(kind: .tap, observationID: observation.observationID, elementID: submit.id)), id: tapID),
            testCase: self
        )
        XCTAssertEqual(duplicate, tap)
        let awaited3 = try await harness.submitCount()
        XCTAssertEqual(awaited3, 1, "A duplicate terminal command must never execute again")

        // Same ID with a different payload is refused outright.
        await harness.coordinator.handle(
            harness.command(.act(RemoteAct(kind: .tap, observationID: observation.observationID, elementID: note.id)), id: tapID)
        )
        XCTAssertEqual(harness.receipts(for: tapID).last?.reason, .commandReused)
        let awaited4 = try await harness.submitCount()
        XCTAssertEqual(awaited4, 1)

        // The fill text never enters the exported evidence.
        let events = await harness.run(harness.command(.events(afterSequence: 0, limit: 200)), testCase: self)
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains("hello"))
        XCTAssertFalse(encoded.contains("SECRET"))
    }

    func testBindingRejectsUnknownElementUnknownObservationAndStaleObservation() async throws {
        let harness = try Harness()
        defer { harness.unmount() }
        try await harness.load(Self.counterPage, testCase: self)
        let observation = try await harness.observe(testCase: self)
        let submit = try XCTUnwrap(observation.elements.first { $0.role == "button" })

        let unknownElement = harness.command(.act(RemoteAct(kind: .tap, observationID: observation.observationID, elementID: "999:nope")))
        await harness.coordinator.handle(unknownElement)
        XCTAssertEqual(harness.receipts(for: unknownElement.commandID).last?.reason, .unknownElement)

        let unknownObservation = harness.command(.act(RemoteAct(kind: .tap, observationID: "missing", elementID: submit.id)))
        await harness.coordinator.handle(unknownObservation)
        XCTAssertEqual(harness.receipts(for: unknownObservation.commandID).last?.reason, .unknownObservation)

        try await harness.load(Self.counterPage, testCase: self)
        let stale = harness.command(.act(RemoteAct(kind: .tap, observationID: observation.observationID, elementID: submit.id)))
        await harness.coordinator.handle(stale)
        XCTAssertEqual(harness.receipts(for: stale.commandID).last?.reason, .staleObservation)
        let awaited5 = try await harness.submitCount()
        XCTAssertEqual(awaited5, 0)
        let awaited6 = try await harness.journal.record(commandID: stale.commandID)?.state
        XCTAssertEqual(awaited6, nil, "Rejected commands are not journaled")
    }

    func testHumanControlRejectsWorkAndResumeRequiresFreshObservation() async throws {
        let harness = try Harness()
        defer { harness.unmount() }
        try await harness.load(Self.counterPage, testCase: self)
        let before = try await harness.observe(testCase: self)
        let submit = try XCTUnwrap(before.elements.first { $0.role == "button" })
        let generationBefore = harness.coordinator.controllerGeneration

        harness.coordinator.takeover()
        XCTAssertEqual(harness.coordinator.readiness, .humanControl)
        let paused = harness.command(.observe(includeImage: false, maxElements: 10))
        await harness.coordinator.handle(paused)
        XCTAssertEqual(harness.receipts(for: paused.commandID).last?.reason, .humanControl)

        harness.coordinator.resume()
        XCTAssertEqual(harness.coordinator.controllerGeneration, generationBefore + 1)

        let oldGeneration = harness.command(
            .act(RemoteAct(kind: .tap, observationID: before.observationID, elementID: submit.id)),
            generation: generationBefore
        )
        await harness.coordinator.handle(oldGeneration)
        XCTAssertEqual(harness.receipts(for: oldGeneration.commandID).last?.reason, .controllerGenerationMismatch)

        let oldObservation = harness.command(.act(RemoteAct(kind: .tap, observationID: before.observationID, elementID: submit.id)))
        await harness.coordinator.handle(oldObservation)
        XCTAssertEqual(harness.receipts(for: oldObservation.commandID).last?.reason, .observationBeforeResume)

        let after = try await harness.observe(testCase: self)
        let submitAfter = try XCTUnwrap(after.elements.first { $0.role == "button" })
        let tap = await harness.run(
            harness.command(.act(RemoteAct(kind: .tap, observationID: after.observationID, elementID: submitAfter.id))),
            testCase: self
        )
        XCTAssertEqual(tap.state, .completed)
        let awaited7 = try await harness.submitCount()
        XCTAssertEqual(awaited7, 1)
    }

    func testSessionMismatchExpiredDeadlineAndUnsupportedOperationAreRejectedByID() async throws {
        let harness = try Harness()
        defer { harness.unmount() }
        try await harness.load(Self.counterPage, testCase: self)

        let wrongSession = harness.command(.observe(includeImage: false, maxElements: 10), sessionID: "other-session")
        await harness.coordinator.handle(wrongSession)
        XCTAssertEqual(harness.receipts(for: wrongSession.commandID).last?.reason, .sessionMismatch)

        let expired = harness.command(.observe(includeImage: false, maxElements: 10), deadline: Date().addingTimeInterval(-1))
        await harness.coordinator.handle(expired)
        XCTAssertEqual(harness.receipts(for: expired.commandID).last?.reason, .expired)

        let unsupported = harness.command(.unsupported(kind: "evaluateJavaScript", detail: "no"))
        await harness.coordinator.handle(unsupported)
        XCTAssertEqual(harness.receipts(for: unsupported.commandID).last?.reason, .unsupportedOperation)

        let badScheme = harness.command(.navigate(url: try XCTUnwrap(URL(string: "javascript:alert(1)"))))
        await harness.coordinator.handle(badScheme)
        XCTAssertEqual(harness.receipts(for: badScheme.commandID).last?.reason, .unsupportedURL)

        harness.coordinator.rotateSession(reason: "test")
        let rotated = harness.command(.observe(includeImage: false, maxElements: 10), sessionID: wrongSession.sessionID)
        await harness.coordinator.handle(rotated)
        XCTAssertEqual(harness.receipts(for: rotated.commandID).last?.reason, .sessionMismatch)

        let status = await harness.run(harness.command(.commandStatus(commandID: expired.commandID)), testCase: self)
        XCTAssertEqual(status.state, .rejected)
        XCTAssertEqual(status.reason, .unknownCommand)
    }

    func testCancelBeforeDispatchNeverExecutes() async throws {
        let harness = try Harness()
        defer { harness.unmount() }
        try await harness.load(Self.counterPage, testCase: self)
        let observation = try await harness.observe(testCase: self)
        let note = try XCTUnwrap(observation.elements.first { $0.role == "textbox" })
        let submit = try XCTUnwrap(observation.elements.first { $0.role == "button" })

        let first = harness.command(.act(RemoteAct(kind: .fill, observationID: observation.observationID, elementID: note.id, text: "queued")))
        let second = harness.command(.act(RemoteAct(kind: .tap, observationID: observation.observationID, elementID: submit.id)))
        let firstDone = expectation(description: "first result")
        let secondDone = expectation(description: "second result")
        var seen: Set<String> = []
        let previous = harness.coordinator.onOutbound
        harness.coordinator.onOutbound = { message in
            previous?(message)
            if case .result(let result) = message, seen.insert(result.commandID).inserted {
                if result.commandID == first.commandID { firstDone.fulfill() }
                if result.commandID == second.commandID { secondDone.fulfill() }
            }
        }
        await harness.coordinator.handle(first)
        await harness.coordinator.handle(second)
        await harness.coordinator.cancel(commandID: second.commandID)
        await fulfillment(of: [firstDone, secondDone], timeout: 20)

        XCTAssertEqual(harness.results(for: first.commandID).last?.state, .completed)
        let cancelled = try XCTUnwrap(harness.results(for: second.commandID).last)
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertEqual(cancelled.retryClassification, .notStarted)
        let awaited8 = try await harness.submitCount()
        XCTAssertEqual(awaited8, 0, "Cancelled work must never reach the page")
        let awaited9 = try await harness.journal.record(commandID: second.commandID)?.state
        XCTAssertEqual(awaited9, .cancelled)

        // Cancel after completion returns the saved result, never a second run.
        await harness.coordinator.cancel(commandID: first.commandID)
        XCTAssertEqual(harness.results(for: first.commandID).count, 2)
        XCTAssertEqual(harness.results(for: first.commandID).last?.state, .completed)
    }

    func testReconcileAnswersFromJournal() async throws {
        let harness = try Harness()
        defer { harness.unmount() }
        try await harness.load(Self.counterPage, testCase: self)
        let done = await harness.run(harness.command(.observe(includeImage: false, maxElements: 5)), testCase: self)

        await harness.coordinator.reconcile(unresolvedCommandIDs: [done.commandID, "never-seen"])
        XCTAssertEqual(harness.results(for: done.commandID).count, 2)
        XCTAssertEqual(harness.results(for: done.commandID).last, done)
        XCTAssertEqual(harness.receipts(for: "never-seen").last?.reason, .unknownCommand)
    }

    func testObservationRedactsEditableValuesOmitsImageForSensitiveViewAndRefusesSensitiveFill() async throws {
        let harness = try Harness()
        defer { harness.unmount() }
        try await harness.load(Self.sensitivePage, testCase: self)

        let observation = try await harness.observe(testCase: self, includeImage: true)
        XCTAssertNil(observation.image)
        XCTAssertNotNil(observation.imageOmittedReason)
        let email = try XCTUnwrap(observation.elements.first { $0.inputType == "email" || $0.label == "Email" })
        XCTAssertNil(email.value, "editable values never leave the phone")
        let password = try XCTUnwrap(observation.elements.first { $0.inputType == "password" })
        XCTAssertTrue(password.isSensitive)
        XCTAssertFalse(password.supportedActions.contains("fill"))
        let encoded = String(decoding: try JSONEncoder().encode(observation), as: UTF8.self)
        XCTAssertFalse(encoded.contains("hunter2"))
        XCTAssertFalse(encoded.contains("person@example.com"))

        let fill = await harness.run(
            harness.command(.act(RemoteAct(kind: .fill, observationID: observation.observationID, elementID: password.id, text: "x"))),
            testCase: self
        )
        XCTAssertEqual(fill.state, .completed)
        XCTAssertEqual(fill.retryClassification, .notStarted)
        guard case .action(let outcome) = fill.payload else {
            return XCTFail("Expected an action payload")
        }
        XCTAssertEqual(outcome.status, "humanInputRequired")
        let awaited10 = try await harness.owner.webView.evaluateJavaScript("document.getElementById('pw').value") as? String
        XCTAssertEqual(awaited10, "hunter2")
    }

    private static let duplicateLabelsPage = """
        <!doctype html><html><body>
          <h1>Duplicate labels</h1>
          <section><h2>Order A</h2><button type="button" onclick="window.__tapped='A'">Confirm</button></section>
          <section><h2>Order B</h2><button type="button" onclick="window.__tapped='B'">Confirm</button></section>
        </body></html>
        """

    func testIdenticalLabelsAreDistinguishedByBoundElementIdentity() async throws {
        let harness = try Harness()
        defer { harness.unmount() }
        try await harness.load(Self.duplicateLabelsPage, testCase: self)
        let observation = try await harness.observe(testCase: self)
        let confirms = observation.elements.filter { $0.role == "button" && $0.label == "Confirm" }
        XCTAssertEqual(confirms.count, 2)
        XCTAssertNotEqual(confirms[0].id, confirms[1].id)

        let tapSecond = await harness.run(
            harness.command(.act(RemoteAct(kind: .tap, observationID: observation.observationID, elementID: confirms[1].id))),
            testCase: self
        )
        XCTAssertEqual(tapSecond.state, .completed)
        guard case .action(let outcome) = tapSecond.payload else {
            return XCTFail("Expected an action payload")
        }
        XCTAssertEqual(outcome.status, "succeeded")
        XCTAssertEqual(outcome.matchedElementCount, 1, "identity binding must not report the twin as a candidate")
        let tapped = try await harness.owner.webView.evaluateJavaScript("window.__tapped") as? String
        XCTAssertEqual(tapped, "B")
    }

    func testObservationImageIsLabelledAsWebViewViewport() async throws {
        let harness = try Harness()
        defer { harness.unmount() }
        try await harness.load(Self.counterPage, testCase: self)
        let observation = try await harness.observe(testCase: self, includeImage: true)
        let image = try XCTUnwrap(observation.image, observation.imageOmittedReason ?? "no image")
        XCTAssertEqual(image.scope, "webViewViewport")
        XCTAssertEqual(image.format, "jpeg")
        XCTAssertGreaterThan(image.pixelWidth, 0)
        XCTAssertEqual(image.pointWidth, 390)
        XCTAssertFalse(observation.capture.changedDuringCapture)
        XCTAssertFalse(observation.documentLoading)
        XCTAssertEqual(observation.viewport.webViewPointHeight, 640)
    }
}
