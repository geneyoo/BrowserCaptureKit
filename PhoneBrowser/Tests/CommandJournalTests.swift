import Foundation
import XCTest

@testable import PhoneBrowser

final class CommandJournalTests: XCTestCase {
    private var path = ""

    override func setUp() {
        super.setUp()
        path = NSTemporaryDirectory() + "journal-\(UUID().uuidString).sqlite"
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
        super.tearDown()
    }

    private func resultJSON(_ commandID: String, state: CommandState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(CommandResultMessage(
            commandID: commandID,
            state: state,
            startedAt: nil,
            completedAt: Date(),
            retryClassification: .unsafe,
            reason: nil,
            message: "stored",
            payload: nil
        ))
    }

    func testAcceptIsUniquePerCommandIDAndBoundToPayloadDigest() async throws {
        let journal = try CommandJournal(path: path)
        let awaited1 = try await journal.accept(commandID: "c1", sessionID: "s", digest: "d1")
        XCTAssertEqual(awaited1, .accepted)
        let duplicate = try await journal.accept(commandID: "c1", sessionID: "s", digest: "d1")
        guard case .duplicate(let record) = duplicate else {
            return XCTFail("Expected duplicate, got \(duplicate)")
        }
        XCTAssertEqual(record.state, .accepted)
        let reused = try await journal.accept(commandID: "c1", sessionID: "s", digest: "d2")
        guard case .reusedWithDifferentPayload = reused else {
            return XCTFail("Expected reuse rejection, got \(reused)")
        }
    }

    func testDuplicateTerminalCommandReturnsSavedResult() async throws {
        let journal = try CommandJournal(path: path)
        _ = try await journal.accept(commandID: "c1", sessionID: "s", digest: "d")
        let awaited2 = try await journal.claimDispatch(commandID: "c1")
        XCTAssertTrue(awaited2)
        let awaited3 = try await journal.claimDispatch(commandID: "c1")
        XCTAssertFalse(awaited3, "A dispatch can be claimed once")
        let json = try resultJSON("c1", state: .completed)
        try await journal.complete(commandID: "c1", state: .completed, retryClassification: .unsafe, resultJSON: json)
        let outcome = try await journal.accept(commandID: "c1", sessionID: "s", digest: "d")
        guard case .duplicate(let record) = outcome else {
            return XCTFail("Expected duplicate, got \(outcome)")
        }
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(record.resultJSON, json)
        XCTAssertNotNil(record.dispatchingAt)
        XCTAssertNotNil(record.completedAt)
    }

    func testCancelOnlyWinsBeforeDispatch() async throws {
        let journal = try CommandJournal(path: path)
        _ = try await journal.accept(commandID: "queued", sessionID: "s", digest: "d")
        _ = try await journal.accept(commandID: "running", sessionID: "s", digest: "d")
        let awaited4 = try await journal.claimDispatch(commandID: "running")
        XCTAssertTrue(awaited4)
        let json = try resultJSON("x", state: .cancelled)
        let awaited5 = try await journal.cancelIfUndispatched(commandID: "queued", resultJSON: json)
        XCTAssertTrue(awaited5)
        let awaited6 = try await journal.cancelIfUndispatched(commandID: "running", resultJSON: json)
        XCTAssertFalse(awaited6)
        let awaited7 = try await journal.claimDispatch(commandID: "queued")
        XCTAssertFalse(awaited7, "Cancelled work must not dispatch later")
        let awaited8 = try await journal.record(commandID: "queued")?.state
        XCTAssertEqual(awaited8, .cancelled)
        let awaited9 = try await journal.record(commandID: "running")?.state
        XCTAssertEqual(awaited9, .dispatching)
    }

    func testRestartMarksDispatchingUncertainAndExpiresAcceptedWork() async throws {
        do {
            let journal = try CommandJournal(path: path)
            _ = try await journal.accept(commandID: "was-dispatching", sessionID: "s", digest: "d")
            let awaited10 = try await journal.claimDispatch(commandID: "was-dispatching")
            XCTAssertTrue(awaited10)
            _ = try await journal.accept(commandID: "was-accepted", sessionID: "s", digest: "d")
            _ = try await journal.accept(commandID: "was-done", sessionID: "s", digest: "d")
            let awaited11 = try await journal.claimDispatch(commandID: "was-done")
            XCTAssertTrue(awaited11)
            try await journal.complete(
                commandID: "was-done",
                state: .completed,
                retryClassification: .unsafe,
                resultJSON: try resultJSON("was-done", state: .completed)
            )
        }

        let reopened = try CommandJournal(path: path)
        let recovery = try await reopened.recoverAfterLaunch()
        XCTAssertEqual(recovery.uncertainCommandIDs, ["was-dispatching"])
        XCTAssertEqual(recovery.expiredCommandIDs, ["was-accepted"])

        let uncertainRecord = try await reopened.record(commandID: "was-dispatching")
        let uncertain = try XCTUnwrap(uncertainRecord)
        XCTAssertEqual(uncertain.state, .uncertain)
        XCTAssertEqual(uncertain.retryClassification, .unsafe)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stored = try decoder.decode(CommandResultMessage.self, from: try XCTUnwrap(uncertain.resultJSON))
        XCTAssertEqual(stored.state, .uncertain)
        XCTAssertEqual(stored.retryClassification, .unsafe)

        let expiredRecord = try await reopened.record(commandID: "was-accepted")
        let expired = try XCTUnwrap(expiredRecord)
        XCTAssertEqual(expired.state, .rejected)
        XCTAssertEqual(expired.retryClassification, .notStarted)

        let awaited12 = try await reopened.record(commandID: "was-done")?.state
        XCTAssertEqual(awaited12, .completed)
        let awaited13 = try await reopened.claimDispatch(commandID: "was-dispatching")
        XCTAssertFalse(awaited13, "Uncertain work is never re-run")
    }

    func testCompleteUnknownCommandThrows() async throws {
        let journal = try CommandJournal(path: CommandJournal.inMemoryPath)
        do {
            try await journal.complete(commandID: "ghost", state: .completed, retryClassification: .safe, resultJSON: Data())
            XCTFail("Expected unknownCommand")
        } catch CommandJournalError.unknownCommand(let id) {
            XCTAssertEqual(id, "ghost")
        }
    }
}
